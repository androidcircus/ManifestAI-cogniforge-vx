# Rack Layout - Virtual Machine GPU Cluster

> The document `rack-layout.pdf` in the original build package is replaced by
> this Markdown file with an embedded Mermaid diagram. Render it with any
> Mermaid-capable viewer (VS Code, mermaid.live, GitHub) or convert to PDF.

## Topology

Two physical hosts each carry four H100 GPUs. Eight GPU worker VMs are created
with Vagrant + libvirt; each worker is assigned exactly one physical GPU via
PCI passthrough (`vfio-pci`). A lightweight control-plane VM runs RKE2 server,
Argo Workflows, the Rack Engine API and the monitoring stack.

```mermaid
graph TB
    subgraph HOST-A["Physical Host A (4U) - 4x H100"]
        A1["VM: cogniforge-worker-01<br/>GPU0 passthrough"]
        A2["VM: cogniforge-worker-02<br/>GPU1 passthrough"]
        A3["VM: cogniforge-worker-03<br/>GPU2 passthrough"]
        A4["VM: cogniforge-worker-04<br/>GPU3 passthrough"]
    end

    subgraph HOST-B["Physical Host B (4U) - 4x H100"]
        B1["VM: cogniforge-worker-05<br/>GPU0 passthrough"]
        B2["VM: cogniforge-worker-06<br/>GPU1 passthrough"]
        B3["VM: cogniforge-worker-07<br/>GPU2 passthrough"]
        B4["VM: cogniforge-worker-08<br/>GPU3 passthrough"]
    end

    subgraph MGMT["Management / Control Plane"]
        CP["VM: cogniforge-cp<br/>RKE2 server + Argo + Rack Engine + Prometheus/Grafana"]
    end

    A1 --- SW1["InfiniBand / 25GbE switch"]
    A2 --- SW1
    A3 --- SW1
    A4 --- SW1
    B1 --- SW1
    B2 --- SW1
    B3 --- SW1
    B4 --- SW1
    CP --- SW1
```

## IP / VLAN plan

- Management network: `192.168.1.0/24` (VM management NICs, libvirt bridge)
- InfiniBand / high-speed fabric: `10.0.0.0/24` (physical host IB; VMs use
  bridged virtio NICs on the host fabric)
- Storage: local NVMe on each host exposed via `local-nvme` StorageClass

## GPU assignment (host A)

| VM | PCI BDF | GPU UUID (example) |
|----|---------|--------------------|
| cogniforge-worker-01 | `0000:31:00.0` | GPU-aaaa1111 |
| cogniforge-worker-02 | `0000:32:00.0` | GPU-bbbb2222 |
| cogniforge-worker-03 | `0000:33:00.0` | GPU-cccc3333 |
| cogniforge-worker-04 | `0000:34:00.0` | GPU-dddd4444 |

Discover the real BDFs with `lspci -nn | grep -i nvidia` before configuring
`/etc/modprobe.d/vfio.conf` (see [provisioning/gpu-passthrough.md](../provisioning/gpu-passthrough.md)).
