#!/bin/bash
# provisioning/emulator/run-vm.sh
# QEMU emulator entry point - boots a VM from an ISO and attaches a virtual
# GPU (virtio-gpu with virgl). Used on the Linux hosts to build the cluster
# VMs from installer media instead of Vagrant cloud images.
#
# Usage:
#   ISO=ubuntu-24.04.2-live-server-amd64.iso ./run-vm.sh cogniforge-worker-01
#
# Env:
#   ISO       - installer ISO path (required)
#   NAME      - VM name / hostname
#   RAM       - guest RAM in MB (default 131072 = 128 GiB)
#   VCPU      - vCPUs (default 16)
#   VRAM      - virtio-gpu video memory in MB (default 512)
#   DISK      - disk image path (auto-created if missing, default ./$NAME.qcow2)
#   NET       - user-mode networking (default); set to bridge:br-mgmt for fabric
#   DISPLAY   - qemu display backend: none|vnc=<port>|gtk (default vnc=:1)
#   QEMU      - qemu binary (default qemu-system-x86_64)
#   UEFI      - use OVMF firmware if set (recommended for Ubuntu 24.04)
set -euo pipefail

NAME="${NAME:-$1}"
ISO="${ISO:?Set ISO=<path-to-installer.iso>}"
RAM="${RAM:-131072}"
VCPU="${VCPU:-16}"
VRAM="${VRAM:-512}"
QEMU="${QEMU:-qemu-system-x86_64}"
DISK="${DISK:-./${NAME}.qcow2}"
DISPLAY="${DISPLAY:-vnc=:1}"
NET="${NET:-user}"
UEFI="${UEFI:-}"

if [ -z "${NAME:-}" ]; then
  echo "Usage: ISO=... ./run-vm.sh <vm-name>" >&2
  exit 1
fi

if [ ! -f "${DISK}" ]; then
  echo "==> Creating disk image ${DISK}"
  qemu-img create -f qcow2 "${DISK}" "${DISK_SIZE:-40G}"
fi

ARGS=(
  -name "${NAME}" -machine q35,accel=kvm
  -m "${RAM}" -smp "${VCPU}"
  -cpu host -enable-kvm
  -drive file="${DISK}",if=virtio,format=qcow2
)

# --- Boot from installer ISO -------------------------------------------------
if [ -n "${ISO}" ]; then
  ARGS+=( -cdrom "${ISO}" -boot d )
fi

# --- UEFI firmware (OVMF) -----------------------------------------------------
if [ -n "${UEFI}" ]; then
  ARGS+=( -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd )
  ARGS+=( -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS_4M.fd )
fi

# --- VIRTUAL GPU (virtio-gpu + virgl, host-accelerated OpenGL) ----------------
ARGS+=( -device virtio-gpu-pci,id=gpu0,hostmem="${VRAM}M",max_hostmem="4096M" )
ARGS+=( -device virtio-mouse-pci -device virtio-keyboard-pci )

# --- Networking ---------------------------------------------------------------
if [ "${NET}" = "user" ]; then
  ARGS+=( -netdev user,id=net0 -device virtio-net-pci,netdev=net0 )
else
  # e.g. NET=bridge:br-mgmt
  ARGS+=( -netdev bridge,id=net0,br="${NET#bridge:}" -device virtio-net-pci,netdev=net0 )
fi

ARGS+=( -display "${DISPLAY}" )

# --- Attach the optional emulated compute accelerator (if QEMU was built with
#     the cogniforge-gpu device; see cogniforge-gpu.c) -------------------------
if "${QEMU}" -device help 2>/dev/null | grep -q cogniforge-gpu; then
  # vram_size is a plain integer; M/G suffixes are rejected by QEMU
  ARGS+=( -device cogniforge-gpu,sm_count=256,vram_size=2147483648 )
fi

echo "==> Launching ${NAME}: ${QEMU} ${ARGS[*]}"
exec "${QEMU}" "${ARGS[@]}"
