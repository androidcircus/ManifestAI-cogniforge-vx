/*
 * provisioning/emulator/cogniforge-gpu.c
 *
 * OPTIONAL experiment: a QEMU PCI device model for an emulated compute
 * accelerator ("CogniForge GPU"). The guest sees a PCI 3D controller with:
 *
 *   BAR0  MMIO      - control/status registers (32-bit window)
 *   BAR2  MMIO      - doorbell: write target SM id to trigger a "kernel kick"
 *   BAR4  MMIO      - VRAM: plain RAM window sized by the vram_size property
 *
 * This device emulates the guest contract (BAR layout, doorbell trap, status
 * registers) AND performs REAL compute: writing a command block into VRAM and
 * poking REG_CMD makes the device run a real FP32 matrix multiply-accumulate
 * (GEMM) on the host CPU (cogniforge-gemm.c, scalar + AVX-512 kernels) with
 * operands read from its own VRAM. It does NOT run the ~14B Wan 2.1 diffusion
 * model - that runs on real NVIDIA GPUs via the cluster in /kubernetes and
 * /modules; this device provides the tensor-operation test bed.
 *
 * MMA command protocol (guest driver contract):
 *   - place a CogniForgeMmaCmd struct at VRAM offset 0 (see REG_CMD comment)
 *   - write 1 to REG_CMD (BAR0 + 0x10) to execute it synchronously
 *   - poll REG_STATUS: bit1 busy, bit0 ready, bit31 error
 *   - read REG_CMD_RESULT (BAR0 + 0x14) for the GEMM return code
 *   - verify standalone: provisioning/emulator/test-gemm.sh (no QEMU needed)
 *   - verify end-to-end: provisioning/emulator/test-device-gemm.py drives the
 *     device over QEMU's qtest protocol (PCI scan, BAR program, VRAM writes,
 *     REG_CMD trigger) with no guest OS
 *
 * Build (verified against qemu-11.0.3, apply provisioning/emulator patch):
 *   cd qemu-11.0.3 && patch -p1 < cogniforge-qemu-11.0.3.patch
 *   mkdir build && cd build
 *   ../configure --target-list=x86_64-softmmu --prefix=/mingw64 \
 *     --disable-werror --disable-docs --disable-gtk --disable-sdl \
 *     --disable-curses --disable-gnutls --disable-nettle --disable-gcrypt \
 *     --disable-virglrenderer --disable-opengl --disable-debug-info
 *   ninja qemu-system-x86_64.exe
 *
 * QEMU 11 API notes (why the code looks the way it does):
 *   - properties array must be 'static const Property' and needs no
 *     DEFINE_PROP_END_OF_LIST() terminator (size is checked at runtime)
 *   - include "hw/core/qdev-properties.h" (moved in QEMU 11)
 *   - use device_class_set_legacy_reset() instead of dc->reset
 *   - class_init takes (ObjectClass *, const void *)
 *   - .interfaces must declare INTERFACE_CONVENTIONAL_PCI_DEVICE /
 *     INTERFACE_PCIE_DEVICE or PCI class init aborts
 *
 * Run:
 *   qemu-system-x86_64 ... -device cogniforge-gpu,sm_count=256,vram_size=2G
 *   (vram_size is a plain integer; 'M'/'G' suffixes are not accepted)
 */
#include "qemu/osdep.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/pci.h"
#include "hw/core/qdev-properties.h"
#include "qemu/units.h"
#include "qemu/log.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "qom/object.h"
#include "hw/misc/cogniforge-gemm.h"

#define TYPE_COGNIFORGE_GPU "cogniforge-gpu"
OBJECT_DECLARE_SIMPLE_TYPE(CogniForgeGPUState, COGNIFORGE_GPU)

#define COGNIFORGE_VENDOR_ID   0x1aef     /* example vendor */
#define COGNIFORGE_DEVICE_ID   0xce1a
#define COGNIFORGE_CLASS       PCI_CLASS_DISPLAY_3D

/* Register offsets (BAR0) */
#define REG_STATUS        0x00   /* bit0 ready, bit1 busy, bit31 error */
#define REG_SM_COUNT      0x04   /* streaming multiprocessors reported */
#define REG_VRAM_SIZE     0x08   /* VRAM bytes exposed by BAR4 */
#define REG_VERSION       0x0c
#define REG_CMD           0x10   /* write 1: execute MMA cmd block in VRAM */
#define REG_CMD_RESULT    0x14   /* last GEMM return code (signed) */

/* MMA command block, placed by the guest at VRAM offset 0. Offsets are byte
 * offsets into the device's own VRAM (BAR4) and must be 4-byte aligned. */
#define COGNIFORGE_MMA_MAGIC 0x43474745u  /* 'CGGE' */

typedef struct CogniForgeMmaCmd {
    uint32_t magic;
    uint32_t m, n, k;
    uint32_t lda, ldb, ldc;    /* row strides in float elements */
    uint64_t a_off, b_off, c_off;
    uint32_t flags;            /* COGNIFORGE_GEMM_ACCUM to accumulate */
    uint32_t reserved;
} QEMU_PACKED CogniForgeMmaCmd;

/* Doorbell (BAR2) value encoding: low 32 = sm_id, high 32 = command */
#define DOORBELL_CMD_RUN  0x1

typedef struct CogniForgeGPUState {
    PCIDevice parent_obj;

    MemoryRegion mmio;       /* BAR0 */
    MemoryRegion doorbell;   /* BAR2 */
    MemoryRegion vram;       /* BAR4 */

    uint64_t vram_size;      /* property, bytes */
    uint32_t sm_count;       /* property */

    uint32_t status;
    uint32_t version;
    int32_t cmd_result;      /* last MMA/GEMM return code */
} CogniForgeGPUState;

/* ------------------------------------------------------------------ */
/* BAR0 - MMIO control window                                         */
/* ------------------------------------------------------------------ */
static void cogniforge_gpu_exec_mma(CogniForgeGPUState *s);

static uint64_t cogniforge_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    CogniForgeGPUState *s = opaque;
    uint32_t val = 0;

    switch (addr) {
    case REG_STATUS:
        val = s->status;
        break;
    case REG_SM_COUNT:
        val = s->sm_count;
        break;
    case REG_VRAM_SIZE:
        val = (uint32_t)(s->vram_size & 0xffffffff);
        break;
    case REG_VERSION:
        val = s->version;
        break;
    case REG_CMD_RESULT:
        val = (uint32_t)s->cmd_result;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR, "cogniforge-gpu: bad MMIO read @%#"PRIx64"\n",
                      addr);
        break;
    }
    return val;
}

static void cogniforge_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                                  unsigned size)
{
    CogniForgeGPUState *s = opaque;

    switch (addr) {
    case REG_STATUS:
        /* guest may clear the error bit */
        s->status &= ~(val & (1u << 31));
        break;
    case REG_CMD:
        if (val & 1u) {
            cogniforge_gpu_exec_mma(s);
        }
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR, "cogniforge-gpu: bad MMIO write @%#"PRIx64
                      " = %#"PRIx64"\n", addr, val);
        break;
    }
}

/* ------------------------------------------------------------------ */
/* MMA command execution - REAL compute via cogniforge-gemm.c          */
/* ------------------------------------------------------------------ */
static void cogniforge_gpu_exec_mma(CogniForgeGPUState *s)
{
    uint8_t *vram;
    CogniForgeMmaCmd *cmd;
    CogniForgeGemmDesc gd;
    uint64_t a_end, b_end, c_end;
    int rc;

    if (s->status & (1u << 1)) {
        return;                     /* still busy */
    }
    vram = memory_region_get_ram_ptr(&s->vram);
    cmd = (CogniForgeMmaCmd *)vram;

    if (cmd->magic != COGNIFORGE_MMA_MAGIC) {
        s->cmd_result = COGNIFORGE_GEMM_BAD_PARAMS;
        s->status |= (1u << 31);
        return;
    }

    /* Bounds check every operand against the VRAM window (overflow-safe). */
    if (__builtin_mul_overflow((uint64_t)cmd->m - 1, cmd->lda, &a_end) ||
        __builtin_add_overflow(a_end, cmd->k, &a_end) ||
        __builtin_add_overflow(cmd->a_off, a_end * 4, &a_end) ||
        a_end > s->vram_size) {
        rc = COGNIFORGE_GEMM_BAD_PARAMS;
        goto fail;
    }
    if (__builtin_mul_overflow((uint64_t)cmd->k - 1, cmd->ldb, &b_end) ||
        __builtin_add_overflow(b_end, cmd->n, &b_end) ||
        __builtin_add_overflow(cmd->b_off, b_end * 4, &b_end) ||
        b_end > s->vram_size) {
        rc = COGNIFORGE_GEMM_BAD_PARAMS;
        goto fail;
    }
    if (__builtin_mul_overflow((uint64_t)cmd->m - 1, cmd->ldc, &c_end) ||
        __builtin_add_overflow(c_end, cmd->n, &c_end) ||
        __builtin_add_overflow(cmd->c_off, c_end * 4, &c_end) ||
        c_end > s->vram_size) {
        rc = COGNIFORGE_GEMM_BAD_PARAMS;
        goto fail;
    }

    s->status |= (1u << 1);         /* busy */
    gd = (CogniForgeGemmDesc){
        .m = cmd->m, .n = cmd->n, .k = cmd->k,
        .lda = cmd->lda, .ldb = cmd->ldb, .ldc = cmd->ldc,
        .a = (const float *)(vram + cmd->a_off),
        .b = (const float *)(vram + cmd->b_off),
        .c = (float *)(vram + cmd->c_off),
        .flags = cmd->flags,
    };
    rc = cogniforge_gemm(&gd);
    s->status &= ~(1u << 1);        /* busy clear */
    if (rc == COGNIFORGE_GEMM_OK) {
        s->cmd_result = 0;
        s->status |= 1u;            /* ready */
        s->status &= ~(1u << 31);
    } else {
        s->cmd_result = rc;
        s->status |= (1u << 31);
    }
    return;

fail:
    s->cmd_result = rc;
    s->status |= (1u << 31);
}

static const MemoryRegionOps cogniforge_mmio_ops = {
    .read  = cogniforge_mmio_read,
    .write = cogniforge_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
};

/* ------------------------------------------------------------------ */
/* BAR2 - doorbell                                                     */
/* ------------------------------------------------------------------ */
static uint64_t cogniforge_doorbell_read(void *opaque, hwaddr addr, unsigned size)
{
    CogniForgeGPUState *s = opaque;
    return (uint64_t)s->sm_count;   /* dummy: guest can poll readiness */
}

static void cogniforge_doorbell_write(void *opaque, hwaddr addr, uint64_t val,
                                      unsigned size)
{
    CogniForgeGPUState *s = opaque;
    uint32_t cmd = (uint32_t)(val >> 32);
    uint32_t sm_id = (uint32_t)(val & 0xffffffff);

    if (sm_id >= s->sm_count) {
        s->status |= (1u << 31);
        return;
    }
    switch (cmd) {
    case DOORBELL_CMD_RUN:
        s->status |= 1u;               /* ready */
        s->status &= ~(1u << 1);       /* clear busy */
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cogniforge-gpu: unknown doorbell cmd %#x\n", cmd);
        break;
    }
}

static const MemoryRegionOps cogniforge_doorbell_ops = {
    .read  = cogniforge_doorbell_read,
    .write = cogniforge_doorbell_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
};

/* ------------------------------------------------------------------ */
/* PCI lifecycle                                                       */
/* ------------------------------------------------------------------ */
static void cogniforge_gpu_reset(DeviceState *dev)
{
    CogniForgeGPUState *s = COGNIFORGE_GPU(dev);
    s->status = 0;
    s->cmd_result = 0;
}

static void cogniforge_gpu_realize(PCIDevice *pci_dev, Error **errp)
{
    CogniForgeGPUState *s = COGNIFORGE_GPU(pci_dev);

    if (s->sm_count == 0) {
        s->sm_count = 1;
    }
    if (s->vram_size == 0) {
        s->vram_size = 256 * MiB;
    }
    s->version = 0x0200;  /* 0x0200: adds MMA/GEMM command on REG_CMD */

    pci_set_word(pci_dev->config + PCI_VENDOR_ID, COGNIFORGE_VENDOR_ID);
    pci_set_word(pci_dev->config + PCI_DEVICE_ID, COGNIFORGE_DEVICE_ID);
    pci_set_word(pci_dev->config + PCI_CLASS_DEVICE, COGNIFORGE_CLASS);
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    memory_region_init_io(&s->mmio, OBJECT(s), &cogniforge_mmio_ops, s,
                          "cogniforge-gpu-mmio", 0x1000);
    memory_region_init_io(&s->doorbell, OBJECT(s), &cogniforge_doorbell_ops,
                          s, "cogniforge-gpu-doorbell", 0x1000);
    memory_region_init_ram(&s->vram, OBJECT(s), "cogniforge-gpu-vram",
                           s->vram_size, errp);
    if (*errp) {
        return;
    }

    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);
    pci_register_bar(pci_dev, 2, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->doorbell);
    pci_register_bar(pci_dev, 4, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->vram);
}

static const Property cogniforge_gpu_properties[] = {
    DEFINE_PROP_UINT32("sm_count", CogniForgeGPUState, sm_count, 256),
    DEFINE_PROP_UINT64("vram_size", CogniForgeGPUState, vram_size, 2 * GiB),
};

static void cogniforge_gpu_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = cogniforge_gpu_realize;
    k->exit = NULL;
    device_class_set_legacy_reset(dc, cogniforge_gpu_reset);
    device_class_set_props(dc, cogniforge_gpu_properties);
    dc->desc = "CogniForge emulated compute accelerator";
}

static const TypeInfo cogniforge_gpu_info = {
    .name = TYPE_COGNIFORGE_GPU,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CogniForgeGPUState),
    .class_init = cogniforge_gpu_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { INTERFACE_PCIE_DEVICE },
        { },
    },
};

static void cogniforge_gpu_register_types(void)
{
    type_register_static(&cogniforge_gpu_info);
}

type_init(cogniforge_gpu_register_types)
