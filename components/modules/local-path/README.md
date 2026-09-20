# local-path

Installs **local-path-provisioner** (Helm chart from `charts.containeroo.ch`)
into namespace `local-path-provisioner`. It creates PersistentVolumes as plain
directories on the node's own disk.

| Value | Set to | Meaning |
|---|---|---|
| `storageClass.name` | `var.storage_class_name` | lab: `local-path` |
| `storageClass.defaultPath` / `nodePathMap` | `var.default_path` | lab: `/opt/local-path-provisioner` on every node |
| `storageClass.pathPattern` | `${.node.name}/${.claim.namespace}/${.claim.name}` | one directory per claim |
| `storageClass.reclaimPolicy` | `Retain` | deleting a PVC keeps the data on disk |
| affinity | nodes where `node_label_key` is in `node_label_values` | where the provisioner pod may run |

## Inputs

| Variable | Module default (prod-flavoured) | Lab passes |
|---|---|---|
| `chart_version` | `null` (latest) | – |
| `storage_class_name` | `local-path-nvme` | `local-path` |
| `default_path` | `/mnt/nvme/local-path` | `/opt/local-path-provisioner` |
| `path_pattern` | node/namespace/claim | – |
| `is_default` | `false` | `true` |
| `node_label_key` | `nvidia.com/gpu.present` | `kubernetes.io/os` |
| `node_label_values` | `["true"]` | `["linux"]` |

Prod pins it to GPU nodes; the lab has no GPUs, so it widens the selector to
every Linux node. **Output:** `status`.

## Watch out

- **`is_default` currently does nothing, so `local-path` is *not* the default
  StorageClass.** The `kubernetes_storage_class` resource that would set the
  `is-default-class` annotation is commented out in `main.tf` (upstream, not a
  lab edit), and the chart's own `storageClass.defaultClass` defaults to
  `false` (chart 0.0.38) and isn't overridden here. `LAB_GUIDE.md` and
  `components/main.tf` describe it as the default; they're wrong. PVCs without
  an explicit `storageClassName` will stay `Pending`. To fix, either pass
  `storageClass.defaultClass = true` in the module's Helm values, or once by hand:
  `kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.
- `pathPattern` is passed as `${.node.name}/…`, while the chart's own example
  uses Go-template syntax (`{{ .PVC.Namespace }}-…`). Inherited from prod; if
  you actually use PVCs in the lab, check the directory names it creates.
- `Retain` means volumes pile up in `/opt/local-path-provisioner` on the nodes.
  Irrelevant for a lab that gets destroyed.
