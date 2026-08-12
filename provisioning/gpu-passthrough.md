# GPU Passthrough - Host Configuration

Each physical host must release its GPUs to the guest VMs using
`vfio-pci`. Do this BEFORE booting the worker VMs.

## 1. Identify GPU BDFs

```bash
lspci -nn | grep -i nvidia
# e.g. 31:00.0 3D controller [0302]: NVIDIA Corporation H100 [10de:2331]
```

## 2. Bind GPUs to vfio-pci

```bash
sudo tee /etc/modprobe.d/vfio.conf >/dev/null <<'EOF'
options vfio-pci ids=10de:2331
EOF

sudo tee /etc/modprobe.d/blacklist-nvidia.conf >/dev/null <<'EOF'
blacklist nouveau
EOF

sudo update-initramfs -u
sudo reboot
```

Confirm the devices are now owned by vfio:

```bash
lspci -nn -s 31:00.0 -v | grep -i kernel
# Kernel driver in use: vfio-pci
```

## 3. IOMMU

Enable IOMMU in the kernel cmdline and confirm groups:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"
# AMD hosts: "amd_iommu=on iommu=pt"
sudo update-grub && sudo reboot

# Every GPU must be in an isolated IOMMU group:
find /sys/kernel/iommu_groups/ -maxdepth 1 -type l | wc -l
lspci -nnk | grep -A3 'NVIDIA'
```

If a GPU shares an IOMMU group with other devices, add the additional
device IDs to `vfio.conf` so the whole group is taken over.

## 4. Attach to the worker VMs

```bash
cd provisioning
vagrant up
./scripts/attach-gpu.sh      # virsh attach-device for each worker
```

The script hot-plugs the device with `virsh attach-device`; reboot each
worker afterwards so the NVIDIA driver stack initializes:

```bash
for vm in $(virsh list --all --name | grep worker); do virsh reboot "$vm"; done
```

## 5. Verify inside the VMs

```bash
vagrant ssh cogniforge-worker-01
nvidia-smi
# Driver Version: <host-matching>  CUDA Version: 12.4+
```

The NVIDIA GPU Operator (deployed in kubernetes/ phase) injects the driver,
toolkit and device plugin into the worker nodes.
