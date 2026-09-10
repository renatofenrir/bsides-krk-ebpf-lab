# ---------------------------------------------------------------------------
# BSides Kraków eBPF lab -- disposable cluster
# ---------------------------------------------------------------------------
# 1 control-plane + 2 workers, named *-bsides-krk-demo, on 10.1.1.40-42.
#
# This is deliberately NOT the prod topology. Nothing here shares a Terraform
# state key, an inventory file, or an IP with bifrost-prod-v4. Destroying this
# cluster is a normal thing to do; destroying prod is not.
#
# Two workers rather than one so Hubble can show pod-to-pod traffic crossing a
# node boundary -- on a single-node cluster every flow is local and the demo
# loses the part that makes eBPF datapath observability interesting.
# ---------------------------------------------------------------------------

locals {
  cluster_suffix = "bsides-krk-demo"

  common_tags = ["bsides", "lab", "ebpf", "disposable"]
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
      keys = [var.ssh_public_key]
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
      keys = [var.ssh_public_key]
    }
  }
}
