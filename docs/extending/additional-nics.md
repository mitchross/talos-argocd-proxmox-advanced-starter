# Add a second Proxmox NIC

The v0.2.0 Proxmox provider can attach additional NICs directly from machine
class provider data. Use this for a storage VLAN or a physically separate
storage network; keep Kubernetes node identity on the management subnet.

Add this under `providerdata: |` in the worker machine class:

```yaml
      network_bridge: vmbr0
      additional_nics:
        - bridge: vmbr1
          vlan: 20       # omit when vmbr1 is already untagged
          firewall: false
```

Then reapply the class:

```bash
omnictl apply -f omni/machine-classes/worker.yaml
```

Machine-class edits affect newly provisioned VMs; they do not hot-add a NIC to
an existing worker. For an existing cluster, add a replacement worker or make
the equivalent Proxmox hardware change during a controlled shutdown.

Let Talos use DHCP on available links unless you have a reason to pin static
link configuration. PCI enumeration can change when another disk or passthrough
device is added, so interface names such as `ens18` are not durable identity.
The starter's `machine.kubelet.nodeIP.validSubnets` keeps the Kubernetes node IP
on the management CIDR even when a storage NIC also has an address.

Verify both layers:

```bash
talosctl -n <node-ip> get links
talosctl -n <node-ip> get addresses
kubectl get node -o wide
```

If the storage service is on the second subnet, test that route from a pod as
well as from the Talos host. A host route working does not prove the Cilium
egress policy allows the same destination.
