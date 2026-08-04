# Put Longhorn on an additional disk

This recipe attaches one extra virtual disk to every worker, lets Talos format
and mount it as a user volume, and tells Longhorn to schedule on that mount.
Use a size selector that cannot also match the Talos system disk.

## 1. Add the Proxmox disk

Under `providerdata: |` in `omni/machine-classes/worker.yaml`:

```yaml
      disk_size: 200
      additional_disks:
        - disk_size: 500
          storage_selector: name == "__REPLACE_ME_PROXMOX_STORAGE_POOL__"
          disk_ssd: true
          disk_discard: true
          disk_iothread: true
          disk_cache: none
          disk_aio: io_uring
```

## 2. Provision a Talos user volume

Add this patch to the `Workers` block in the cluster template:

```yaml
  - name: longhorn-data-volume
    inline:
      apiVersion: v1alpha1
      kind: UserVolumeConfig
      name: longhorn-data
      provisioning:
        diskSelector:
          match: "!system_disk && disk.size >= 450u * GB"
        minSize: 450GB
        grow: true
```

Talos mounts that volume at `/var/mnt/longhorn-data`. The lower bound is
load-bearing: the starter's 200 GB system disk must never satisfy it. If you add
more disks later, give each selector non-overlapping bounds.

## 3. Register the disk with Longhorn

First change these settings in `infrastructure/storage/longhorn/values.yaml` so
Longhorn uses the node's explicit disk list instead of auto-registering only the
default path:

```yaml
defaultSettings:
  createDefaultDiskLabeledNodes: "true"
  storageReservedPercentageForDefaultDisk: "0"
```

Then add a second worker patch:

```yaml
  - name: longhorn-disk-registration
    inline:
      machine:
        nodeLabels:
          node.longhorn.io/create-default-disk: "config"
        nodeAnnotations:
          node.longhorn.io/default-disks-config: >-
            [{"name":"talos-ephemeral","path":"/var/lib/longhorn","allowScheduling":false,"diskType":"filesystem","storageReserved":32212254720,"tags":[]},{"name":"longhorn-data","path":"/var/mnt/longhorn-data","allowScheduling":true,"diskType":"filesystem","storageReserved":21474836480,"tags":[]}]
```

The explicit setting makes the annotation authoritative on first registration.
The example disables scheduling on the system partition and reserves 20 GiB on
the data disk; tune both choices to the actual devices.

## 4. Apply safely

For a new cluster, apply the machine class and sync the template normally. For
an existing cluster, adding provider data does not resize or rewrite the
existing VM. Back up first, add or replace one worker at a time, and confirm
Longhorn has moved/rebuilt data before touching the next worker.

```bash
omnictl apply -f omni/machine-classes/worker.yaml
omnictl cluster template sync -f omni/cluster-template/cluster-template.yaml
talosctl -n <node-ip> get disks
talosctl -n <node-ip> get volumestatus
kubectl -n longhorn-system get nodes.longhorn.io -o yaml
```

Disk capacity on two VMs is not redundancy when both virtual disks live on one
physical Proxmox device. Keep the off-cluster kopiur/Barman copies regardless
of the Longhorn replica count.
