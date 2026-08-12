#!/bin/bash
# provisioning/scripts/attach-gpu.sh
# Hot-plugs one physical GPU into each GPU worker VM via virsh attach-device.
#
# Mapping (edit to match your hosts; see hardware/rack-layout.md):
#   worker-01..04 -> host-1 GPUs at 0000:31:00.0 .. 0000:34:00.0
#   worker-05..08 -> host-2 GPUs at 0000:31:00.0 .. 0000:34:00.0
#
# After attaching, REBOOT each worker so the kernel initializes the device:
#   virsh reboot cogniforge-worker-01
set -euo pipefail

GPUS_PER_HOST=( "0000:31:00.0" "0000:32:00.0" "0000:33:00.0" "0000:34:00.0" )

make_device_xml() {
  # domain='0x0000' bus='0x31' slot='0x00' function='0x0' from BDF "0000:31:00.0"
  local bdf="$1"
  local domain="0x$(echo "$bdf" | cut -d: -f1)"
  local bus="0x$(echo "$bdf" | cut -d: -f2)"
  local slot="0x$(echo "$bdf" | cut -d: -f3)"
  local func="0x0"
  cat <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <driver name='vfio'/>
  <source>
    <address domain='$domain' bus='$bus' slot='$slot' function='$func'/>
  </source>
</hostdev>
EOF
}

for host in 1 2; do
  for idx in 0 1 2 3; do
    worker=$(printf "cogniforge-worker-%02d" $(( (host - 1) * 4 + idx + 1 )))
    bdf=${GPUS_PER_HOST[$idx]}
    xml=$(make_device_xml "$bdf")
    echo "==> Attaching GPU ${bdf} -> ${worker}"
    virsh list --all | grep -q "${worker}" || {
      echo "    SKIP: VM ${worker} does not exist (still creating?)"
      continue
    }
    echo "$xml" | virsh attach-device --domain "${worker}" --file /dev/stdin --persistent
    echo "    Remember: virsh reboot ${worker} to initialize the GPU."
  done
done

echo "==> Done. Verify inside each worker: nvidia-smi"
