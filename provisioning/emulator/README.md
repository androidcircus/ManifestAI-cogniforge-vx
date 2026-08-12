# Emulator - running the ISO with a virtual GPU

The cluster VMs can be created two ways:

1. **Vagrant + cloud images** (`../Vagrantfile`) - fastest for development.
2. **QEMU emulator booting the installer ISO** (this directory) - the
   "emulator runs the ISO" flow. Each VM boots Ubuntu Server from `.iso`
   media while a **virtual GPU** is presented on the PCI bus.

## What the emulator does

`run-vm.sh` / `run-vm.ps1` launches `qemu-system-x86_64` with:

| Piece | Device | Purpose |
|-------|--------|---------|
| Virtual GPU | `virtio-gpu-pci` + virgl | Guest display + GL acceleration, video memory sized via `hostmem` |
| Compute accelerator (optional) | `cogniforge-gpu` | Custom QEMU PCI device exposing BAR0 MMIO / BAR2 doorbell / BAR4 VRAM (see `cogniforge-gpu.c`) |
| Boot media | `-cdrom <installer>.iso` | Install Ubuntu Server into the qcow2 disk |
| vCPUs / RAM | `-smp 16 -m 128G` | Sized per the VM inventory in `hardware/BOM.csv` |

## Quick start (Linux host)

```bash
# 1. Download an installer ISO
wget https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso

# 2. Boot the control-plane VM from the ISO
ISO=./ubuntu-24.04.2-live-server-amd64.iso NAME=cogniforge-cp ./run-vm.sh cogniforge-cp
# Connect VNC to :1 (or set DISPLAY=gtk) and run the installer
# Repeat for each cogniforge-worker-NN with a different VNC port.

# 3. Boot an already-installed VM from its disk (skip the ISO):
DISK=./cogniforge-cp.qcow2 NAME=cogniforge-cp ./run-vm.sh cogniforge-cp
```

## Quick start (Windows host)

```powershell
winget install -e --id SoftwareFreedomConservancy.QEMU
$env:ISO = "C:\isos\ubuntu-24.04.2-live-server-amd64.iso"
.\run-vm.ps1 cogniforge-cp
```

To get the custom `cogniforge-gpu` device you must build QEMU from source
(the winget build does not include it). See "Building QEMU 11.0.3 with the
custom device" below for the flow verified on this machine.

## Custom device (cogniforge-gpu.c)

The `.c` file is a QEMU device model. It must be built into a QEMU
source tree; it is **not** a prebuilt binary. Apply `cogniforge-qemu-11.0.3.patch`
(device source + GEMM library + meson wiring + a Windows
`symlink-install-tree.py` guard) to a pristine qemu-11.0.3 checkout. Once
built, enable it with:

```bash
qemu-system-x86_64 ... -device cogniforge-gpu,sm_count=256,vram_size=2G
```

Note: `vram_size` is a plain integer (uint64 property) - `M`/`G` suffixes are
rejected by QEMU, so use e.g. `vram_size=268435456` for 256 MiB.

The device does **real compute**: writing a command block into VRAM and poking
`REG_CMD` makes it run an FP32 matrix multiply on the host CPU
(`cogniforge-gemm.c`, scalar + AVX-512 FMA kernels selected at runtime by
`__builtin_cpu_supports("avx512f")`). It does NOT run the ~14B Wan 2.1 model -
that needs real NVIDIA GPUs via `/kubernetes` and `/modules`; this device is
the tensor-operation test bed.

### Verifying the device

```bash
# 1) GEMM math alone (no QEMU needed): scalar + AVX-512 kernels
bash provisioning/emulator/test-gemm.sh

# 2) End-to-end: boot the device under -qtest stdio, find it on the PCI bus,
#    program its BARs, write a command block into VRAM, trigger REG_CMD,
#    and check the C matrix that comes back (host-driven, no guest OS).
python provisioning/emulator/test-device-gemm.py C:/msys64/mingw64/qemu-system-x86_64.exe
```

`test-device-gemm.py` is self-contained: it speaks QEMU's qtest protocol,
scans PCI config space via ports 0xCF8/0xCFC, and asserts the GEMM result
(`[19,22,43,50]` for the bundled 2x2 case) plus the bad-magic error path.
Keep the BAR addresses it uses aligned to the region size (QEMU silently
aligns BARs down, and a 32-bit BAR whose `last_addr >= 0xffffffff` is left
unmapped by `pci_bar_address`).

### Building QEMU 11.0.3 with the custom device (Windows/MSYS2, verified)

Prereqs installed via pacman (slow mirrors: set `ParallelDownloads = 16` in
`C:\msys64\etc\pacman.conf`; pre-fetch packages into
`C:\msys64\var\cache\pacman\pkg` with a parallel downloader such as
`para-get.ps1`, then install from cache to avoid single-connection timeouts):

```bash
pacman -S base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja mingw-w64-x86_64-pkgconf mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-pixman mingw-w64-x86_64-libslirp mingw-w64-x86_64-zlib \
  mingw-w64-x86_64-pcre2 mingw-w64-x86_64-dtc mingw-w64-x86_64-libyaml \
  mingw-w64-x86_64-python
```

Configure and build (MINGW64 shell):

```bash
cd qemu-11.0.3
patch -p1 < cogniforge-qemu-11.0.3.patch
mkdir build && cd build
../configure --target-list=x86_64-softmmu --prefix=/mingw64 \
  --disable-werror --disable-docs --disable-gtk --disable-sdl \
  --disable-curses --disable-gnutls --disable-nettle --disable-gcrypt \
  --disable-virglrenderer --disable-opengl --disable-debug-info
ninja qemu-system-x86_64.exe
ninja install
```

`qemu-system-x86_64 --version` -> "QEMU emulator version 11.0.3" and
`-device help` lists `name "cogniforge-gpu", bus PCI, desc "CogniForge emulated
compute accelerator"`.

Windows gotchas learned the hard way:

- `ninja install` places the binaries at the **prefix root**, i.e.
  `C:\msys64\mingw64\qemu-system-x86_64.exe` (this build's `bindir` is `.`).
  Run the binary from there. If you copy it to `mingw64\bin\`, QEMU's
  `get_relocated_path()` computes a bogus datadir and you get
  `could not load PC BIOS 'bios-256k.bin'` - either run from the prefix root,
  pass `-L C:/msys64/mingw64/share`, or set firmware accordingly.
- The `symlink-install-tree.py` postconf step is skipped on Windows (symlinks
  need Developer Mode); that guard is part of the patch.
- QEMU 11 API changes already accounted for in `cogniforge-gpu.c`:
  `hw/core/qdev-properties.h`, `static const Property` with no
  `DEFINE_PROP_END_OF_LIST()`, `device_class_set_legacy_reset()`,
  `class_init(ObjectClass *, const void *)`, and `.interfaces` listing
  `INTERFACE_CONVENTIONAL_PCI_DEVICE` / `INTERFACE_PCIE_DEVICE`.

### Guest device contract

Inside the guest the device enumerates as a PCI 3D controller:

```
$ lspci -nn | grep -i 1aef
00:04.0 3D controller [0302]: Device [1aef:ce1a]
```

Guest driver contract (BARs):

- BAR0 + 0x00 `status`     - bit0 ready, bit1 busy, bit31 error
- BAR0 + 0x04 `sm_count`   - number of SMs emulated
- BAR0 + 0x08 `vram_size`  - VRAM bytes
- BAR0 + 0x0c `version`    - 0x0200 (adds the MMA/GEMM command)
- BAR0 + 0x10 `cmd`        - write 1 to execute the MMA command block in VRAM
- BAR0 + 0x14 `cmd_result` - last GEMM return code (signed, `COGNIFORGE_GEMM_*`)
- BAR2 (doorbell)          - write `(cmd << 32) | sm_id` to kick an SM
- BAR4 (VRAM)              - host RAM window

MMA command block (packed 60-byte struct at VRAM offset 0): `magic` (`'CGGE'`,
`0x43474745`), `m n k`, `lda ldb ldc` (row strides in floats), `a_off b_off
c_off` (byte offsets into VRAM, 4-byte aligned), `flags`
(`COGNIFORGE_GEMM_ACCUM`), `reserved`.

This is a device/guest contract emulator plus a real FP32 tensor kernel, not a
performance emulator. For real throughput the worker VMs in the rack use
physical GPU passthrough (`../gpu-passthrough.md`).
