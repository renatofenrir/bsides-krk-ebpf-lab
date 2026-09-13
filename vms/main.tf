# ---------------------------------------------------------------------------
# BSides Kraków eBPF lab -- disposable cluster
# ---------------------------------------------------------------------------
# TWO nodes, named *-bsides-krk-demo, on 10.1.1.40-41:
#
#   k8s-master-0  10.1.1.40  control plane, UNTAINTED so it also runs workloads
#   k8s-worker-0  10.1.1.41  worker
#
# This is deliberately NOT the prod topology. Nothing here shares a Terraform
# state key, an inventory file, or an IP with bifrost-prod-v4. Destroying this
# cluster is a normal thing to do; destroying prod is not.
#
# Why the control plane is untainted rather than adding a third VM: the demo
# needs pod-to-pod traffic that CROSSES A NODE BOUNDARY, or every Hubble flow
# is node-local and the datapath observability story falls flat. Two schedulable
# nodes is the smallest cluster that still gives that. The untaint is a
# post-bootstrap step, not a Terraform one -- see the Makefile's `untaint`
# target and the bootstrap-cluster CI stage.
# ---------------------------------------------------------------------------

locals {
  cluster_suffix = "bsides-krk-demo"

  common_tags = ["bsides", "lab", "ebpf", "disposable"]

  ssh_public_keys = concat(
    [var.ssh_public_key],
    [for k in split("\n", var.extra_ssh_public_keys) : trimspace(k) if trimspace(k) != ""],
  )
}

resource "proxmox_virtual_environment_vm" "master" {
  name        = "k8s-master-0-${local.cluster_suffix}"
  node_name   = var.proxmox_node
  description = "BSides Kraków eBPF lab -- control plane. Disposable."
  tags        = local.common_tags
  bios        = "seabios"
  started     = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = false
  }

  cpu {
    cores   = 4
    sockets = 1

    # "host" passes the hypervisor's CPU flags straight through, including
    # VT-x/AMD-V. KubeVirt in Phase 3 needs that to run a real VM instead of
    # falling back to software emulation. Verify on the Proxmox host with:
    #   cat /sys/module/kvm_intel/parameters/nested   # expect Y or 1
    type = "host"
  }

  memory {
    # 8G, not 6G. Prod learned this the hard way: 6G control planes OOM every
    # day or two once etcd, the apiserver and Cilium are all resident.
    dedicated = 8192
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 80
    file_format  = "raw"
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    mtu    = 1
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.master_ip}/24"
        gateway = var.gateway_ip
      }
    }
    dns {
      servers = [var.dns_server]
    }
    user_account {
      keys = local.ssh_public_keys
    }
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count       = length(var.worker_ips)
  name        = "k8s-worker-${count.index}-${local.cluster_suffix}"
  node_name   = var.proxmox_node
  description = "BSides Kraków eBPF lab -- worker. Disposable."
  tags        = local.common_tags
  bios        = "seabios"
  started     = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = false
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "host" # nested virt for KubeVirt -- see the note on the master
  }

  memory {
    # 8G rather than prod's 6G. Workers here carry Tetragon, Hubble relay/UI,
    # and in Phase 3 a virt-launcher pod holding a whole Ubuntu guest.
    dedicated = 8192
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 80
    file_format  = "raw"
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    mtu    = 1
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.worker_ips[count.index]}/24"
        gateway = var.gateway_ip
      }
    }
    dns {
      servers = [var.dns_server]
    }
    user_account {
      keys = local.ssh_public_keys
    }
  }
}
