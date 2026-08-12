#!/bin/bash
# ---------------------------------------------------------------------------
# network/ib-setup.sh
# InfiniBand + management network setup for each PHYSICAL host in the cluster.
#
# The worker/control-plane VMs get their NICs from the host via a libvirt
# bridge (virbr-mgmt), so the host must own the fabric adapters and act as
# the gateway/bridge into the management LAN.
#
# Usage: HOST_ID=<1..N> ./ib-setup.sh
#   HOST_ID 1 runs the OpenSM subnet manager (designate exactly one host).
# ---------------------------------------------------------------------------
set -euo pipefail

HOST_ID="${HOST_ID:?Set HOST_ID (1..N) before running}"
MGMT_IP="10.0.0.${HOST_ID}"
MGMT_CIDR=24
MGMT_BRIDGE="br-mgmt"

echo "==> Configuring fabric on host ${HOST_ID} (${MGMT_IP}/${MGMT_CIDR})"

# --- 1. Mellanox OFED drivers (only if not already installed) --------------
if ! command -v mlxconfig >/dev/null 2>&1 && ! ls /usr/src/ofa_kernel >/dev/null 2>&1; then
    echo "==> Installing MLNX_OFED"
    sudo apt-get update
    # Ubuntu 24.04 example - pin the build that matches your kernel
    OFED="MLNX_OFED_LINUX-24.10-0.6.6.0-ubuntu24.04-x86_64"
    wget "https://www.mellanox.com/downloads/ofed/MLNX_OFED-24.10-0.6.6.0/${OFED}.tgz"
    tar -xzf "${OFED}.tgz"
    ( cd "${OFED}" && sudo ./mlnxofedinstall --add-kernel-support )
    sudo /etc/init.d/openibd restart
else
    echo "==> OFED already installed, skipping driver install"
fi

# --- 2. Bring up ib0 and bridge it to the VM management bridge -------------
echo "==> Configuring netplan for ib0 + ${MGMT_BRIDGE}"
sudo tee /etc/netplan/01-netcfg.yaml >/dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ib0:
      dhcp4: false
      addresses:
        - ${MGMT_IP}/${MGMT_CIDR}
  bridges:
    ${MGMT_BRIDGE}:
      interfaces: [ ib0 ]
      dhcp4: false
      addresses:
        - 192.168.1.${HOST_ID}/24
EOF
sudo netplan apply

# --- 3. Subnet manager on the designated host ------------------------------
if [ "${HOST_ID}" == "1" ]; then
    echo "==> Enabling OpenSM subnet manager"
    sudo apt-get install -y opensm
    sudo systemctl enable opensm
    sudo systemctl start opensm
fi

# --- 4. Verify ---------------------------------------------------------------
echo "==> Verification"
ibv_devinfo || true
ip addr show ib0
ip addr show "${MGMT_BRIDGE}"

echo "==> Done. The libvirt bridge ${MGMT_BRIDGE} now carries the VMs on 192.168.1.0/24."
