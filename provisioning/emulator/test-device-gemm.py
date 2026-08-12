#!/usr/bin/env python3
# provisioning/emulator/test-device-gemm.py
# End-to-end device test: drive cogniforge-gpu entirely from the host via
# QEMU's qtest protocol. No guest OS is needed.
#
#  1. launch qemu-system-x86_64 -qtest stdio with the device attached
#  2. scan PCI config space (ports 0xCF8/0xCFC) to find the device
#  3. program BAR0 (MMIO) and BAR4 (VRAM)
#  4. place a command block + A/B matrices in VRAM
#  5. write REG_CMD -> device runs its real GEMM on the host CPU
#  6. read C back from VRAM and compare with the expected product
#
# Usage: python test-device-gemm.py [path/to/qemu-system-x86_64.exe]
import os
import struct
import subprocess
import sys
import time

QEMU = sys.argv[1] if len(sys.argv) > 1 else "qemu-system-x86_64.exe"

# MSYS2-built binaries need the runtime DLLs (C:\msys64\mingw64\bin) on PATH.
_MINGW = r"C:\msys64\mingw64\bin"
if not any(p.lower() == _MINGW.lower() for p in os.environ.get("PATH", "").split(os.pathsep)):
    os.environ["PATH"] = _MINGW + os.pathsep + os.environ.get("PATH", "")

VRAM_SIZE = 128 * 1024 * 1024
BAR0_ADDR = 0xE0000000   # MMIO, 4K => last@0xE0000FFF
VRAM_ADDR = 0xF0000000   # VRAM, 128M => last@0xF7FFFFFF (< UINT32_MAX)
MAGIC = 0x43474745  # 'CGGE'

A = [1.0, 2.0, 3.0, 4.0]  # 2x2 row-major
B = [5.0, 6.0, 7.0, 8.0]
expC = [sum(A[i * 2 + p] * B[p * 2 + j] for p in range(2))
        for i in range(2) for j in range(2)]

A_OFF, B_OFF, C_OFF = 0x100, 0x200, 0x300


def f32(v):
    return struct.unpack("<I", struct.pack("<f", v))[0]


def run_qemu():
    import tempfile
    qlog = os.path.join(tempfile.gettempdir(), "opencode", "qtest-device.log")
    return subprocess.Popen(
        [QEMU, "-qtest", "stdio", "-machine", "q35", "-nodefaults",
         "-m", "1G", "-device", f"cogniforge-gpu,vram_size={VRAM_SIZE}",
         "-accel", "tcg", "-S", "-display", "none", "-monitor", "none",
         "-serial", "none"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=open(qlog, "w"),
    )


class QTest:
    def __init__(self, proc):
        self.proc = proc

    def _line(self):
        buf = bytearray()
        while True:
            ch = self.proc.stdout.read(1)
            if not ch:
                raise EOFError("qtest stream closed")
            buf.append(ch[0])
            if ch == b"\n":
                break
        return buf.decode().strip()

    def cmd(self, line):
        self.proc.stdin.write(line.encode() + b"\n")
        self.proc.stdin.flush()
        return self._line()

    def inl(self, addr):
        r = self.cmd(f"inl 0x{addr:x}")
        try:
            return int(r.split()[1], 0)
        except Exception:
            print(f"RAW inl response: {r!r}", file=sys.stderr)
            raise

    def outl(self, addr, val):
        r = self.cmd(f"outl 0x{addr:x} 0x{val:x}")
        assert r == "OK", r

    def readl(self, addr):
        r = self.cmd(f"readl 0x{addr:x}")
        return int(r.split()[1], 0)

    def writel(self, addr, val):
        r = self.cmd(f"writel 0x{addr:x} 0x{val:x}")
        assert r == "OK", r


def main():
    proc = run_qemu()
    t = QTest(proc)
    try:
        # --- find the device on PCI bus 0 -----------------------------------
        bdf = None
        for dev in range(0x20):
            t.outl(0xCF8, 0x80000000 | (dev << 11))
            vid = t.inl(0xCFC)
            if (vid & 0xFFFF) == 0x1AEF:
                bdf = dev
                devid = (vid >> 16) & 0xFFFF
                break
        assert bdf is not None, "cogniforge-gpu not found on PCI bus 0"
        print(f"found cogniforge-gpu at 00:{bdf:02x}.0, device id {devid:#06x}")

        cfg = lambda reg: 0x80000000 | (bdf << 11) | reg  # noqa: E731

        def cfg_read(reg):
            t.outl(0xCF8, cfg(reg))
            return t.inl(0xCFC)

        def cfg_write(reg, val):
            t.outl(0xCF8, cfg(reg))
            t.outl(0xCFC, val)

        # --- program BARs + enable memory/master ----------------------------
        cmd_word = cfg_read(0x04)
        cfg_write(0x04, cmd_word | 0x6)
        cfg_write(0x10, BAR0_ADDR)
        cfg_write(0x20, VRAM_ADDR)
        assert cfg_read(0x10) & 0xFFF == 0  # BAR0 took the address
        print(f"BAR0 cfg now={cfg_read(0x10):#x} BAR4 cfg now={cfg_read(0x20):#x} "
              f"CMD={cfg_read(0x04):#x}")

        # --- sanity: version + status ---------------------------------------
        assert t.readl(BAR0_ADDR + 0x0C) == 0x0200
        assert t.readl(BAR0_ADDR + 0x00) == 0   # status: ready=0, not busy
        print("REG_VERSION=0x0200, REG_STATUS=0")

        # --- write command block into VRAM ----------------------------------
        t.writel(VRAM_ADDR + 0x00, MAGIC)
        t.writel(VRAM_ADDR + 0x04, 2)   # m
        t.writel(VRAM_ADDR + 0x08, 2)   # n
        t.writel(VRAM_ADDR + 0x0C, 2)   # k
        t.writel(VRAM_ADDR + 0x10, 2)   # lda
        t.writel(VRAM_ADDR + 0x14, 2)   # ldb
        t.writel(VRAM_ADDR + 0x18, 2)   # ldc
        lo, hi = struct.unpack("<II", struct.pack("<Q", A_OFF))
        t.writel(VRAM_ADDR + 0x1C, lo); t.writel(VRAM_ADDR + 0x20, hi)
        lo, hi = struct.unpack("<II", struct.pack("<Q", B_OFF))
        t.writel(VRAM_ADDR + 0x24, lo); t.writel(VRAM_ADDR + 0x28, hi)
        lo, hi = struct.unpack("<II", struct.pack("<Q", C_OFF))
        t.writel(VRAM_ADDR + 0x2C, lo); t.writel(VRAM_ADDR + 0x30, hi)
        t.writel(VRAM_ADDR + 0x34, 0)   # flags

        for i, v in enumerate(A):
            t.writel(VRAM_ADDR + A_OFF + 4 * i, f32(v))
        for i, v in enumerate(B):
            t.writel(VRAM_ADDR + B_OFF + 4 * i, f32(v))

        # --- trigger the MMA -------------------------------------------------
        t.writel(BAR0_ADDR + 0x10, 1)   # REG_CMD = 1
        time.sleep(0.2)

        status = t.readl(BAR0_ADDR + 0x00)
        result = t.readl(BAR0_ADDR + 0x14)
        print(f"REG_STATUS={status:#x} REG_CMD_RESULT={result}")
        print("REG_VRAM_SIZE=%#x" % t.readl(BAR0_ADDR + 0x08))
        print("VRAM cmdbuf:", [t.readl(VRAM_ADDR + 4 * i) for i in range(15)])

        assert result == 0, f"GEMM failed: {result}"
        assert status & 0x80000000 == 0, "error bit set"
        assert status & 1 == 1, "ready bit not set"

        # --- verify C ---------------------------------------------------------
        got = []
        for i in range(4):
            got.append(struct.unpack("<f", struct.pack("<I", t.readl(VRAM_ADDR + C_OFF + 4 * i)))[0])
        ok = all(abs(g - e) <= 1e-3 for g, e in zip(got, expC))
        print("A:", A)
        print("B:", B)
        print("C:", [round(g, 4) for g in got], "expected", expC)

        # --- error path: bad magic -------------------------------------------
        t.writel(VRAM_ADDR + 0x00, 0xDEADBEEF)
        t.writel(BAR0_ADDR + 0x10, 1)
        time.sleep(0.2)
        r2 = t.readl(BAR0_ADDR + 0x14)
        st2 = t.readl(BAR0_ADDR + 0x00)
        print(f"bad-magic: REG_CMD_RESULT={r2} REG_STATUS={st2:#x}")
        assert r2 == 0xFFFFFFFF and st2 & 0x80000000, "bad magic not rejected"

        assert ok, "C mismatch"
        print("PASS: cogniforge-gpu executed a real GEMM via MMIO and wrote correct VRAM")
        return 0
    finally:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())