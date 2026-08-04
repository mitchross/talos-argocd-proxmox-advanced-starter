# Add a GPU worker

GPU passthrough is a separate failure domain and lifecycle. Keep it in its own
machine class and Omni worker set instead of adding GPU assumptions to every
worker.

## 1. Prepare Proxmox

Enable IOMMU on the Proxmox host, bind the GPU functions to VFIO, and create a
PCI Resource Mapping in **Datacenter → Resource Mappings → PCI Devices**. Map
all functions the card needs. Verify the host is no longer using the device
before asking Omni to provision a VM around it.

## 2. Create a machine class

Copy the base worker class to `omni/machine-classes/gpu-worker.yaml`, give it a
new ID such as `proxmox-gpu-worker`, and add the passthrough-specific provider
data:

```yaml
      cores: 16
      sockets: 1
      memory: 65536
      disk_size: 300
      network_bridge: vmbr0
      storage_selector: name == "__REPLACE_ME_PROXMOX_STORAGE_POOL__"
      cpu_type: host
      machine_type: q35
      numa: true
      balloon: false
      pci_devices:
        - mapping: nvidia-gpu-1
          pcie: true
```

The `mapping` value is the Proxmox Resource Mapping name, not a raw PCI address.
The v0.2.0 provider reconciles this field without a custom image.

## 3. Add a dedicated Omni worker set

Append a second `Workers` document to the cluster template:

```yaml
---
kind: Workers
name: gpu-workers
machineClass:
  name: proxmox-gpu-worker
  size: 1
systemExtensions:
  - siderolabs/iscsi-tools
  - siderolabs/util-linux-tools
  - siderolabs/nonfree-kmod-nvidia-production
  - siderolabs/nvidia-container-toolkit-production
patches:
  - name: gpu-modules-and-labels
    inline:
      machine:
        kernel:
          modules:
            - name: nvidia
            - name: nvidia_uvm
            - name: nvidia_drm
            - name: nvidia_modeset
        kubelet:
          nodeIP:
            validSubnets:
              - __REPLACE_ME_NODE_CIDR__
        nodeLabels:
          gpu-worker: "true"
```

Use the matching `-lts` extensions instead of `-production` for GPU
architectures no longer supported by the production NVIDIA driver branch.
Driver branch, Talos version, and the NVIDIA operator/toolkit must remain a
compatible set.

## 4. Add the Kubernetes GPU controller explicitly

The base starter does not ship the NVIDIA GPU Operator. Add it as a platform
directory and list that path in `infrastructure-appset.yaml`, or add a
standalone wave-gated Application if workloads depend on its CRDs during the
same sync. Follow the repository rules: pin the chart and images, render it in
CI, and keep GPU monitoring at Wave 5 rather than making observability a core
dependency.

Apply and verify:

```bash
omnictl apply -f omni/machine-classes/gpu-worker.yaml
omnictl cluster template sync -f omni/cluster-template/cluster-template.yaml
talosctl -n <gpu-node-ip> dmesg | rg -i nvidia
kubectl get node -l gpu-worker=true
kubectl describe node <gpu-node> | rg 'nvidia.com/gpu'
```

Do not schedule a real workload until the allocatable `nvidia.com/gpu` resource
appears. A passed-through PCI device alone is not proof that the Talos module,
container toolkit, and Kubernetes device plugin agree.
