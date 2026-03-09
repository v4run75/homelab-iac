resource "proxmox_virtual_environment_vm" "ubuntu_server_template" {
  name      = "Ubuntu-Server-24-template"
  node_name = "proxmox-node"  # Configure: your Proxmox node name
  description = "Managed by Terraform"
  tags        = ["terraform", "ubuntu"]



  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  # set to true if you want to create a template
  template = true

 agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = false
  }

  # Initialization = cloud-init
  initialization {
    datastore_id = "local-lvm"  # Configure: your cloud-init datastore

    #  user_account {
    #   keys     = [trimspace(tls_private_key.ubuntu_vm_key.public_key_openssh)]
    #   password = random_password.ubuntu_vm_password.result
    #   username = "ubuntu"
    # }

    # ip_config {
    #   ipv4 {
    #     address = "dhcp"
    #   }
    # ipv4 {
    #   address = "10.0.0.2/24"   # Configure: your K3s VM IP
    #   gateway = "10.0.0.1"      # Configure: your network gateway
    # }
    # }
  }

 disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_virtual_environment_download_file.latest_ubuntu_22_noble_qcow2_img_template.id
    interface    = "scsi0"
  }

  vga {
    memory = 16
    type = "qxl"
  }

  cpu {
    cores   = 4
    sockets = 2
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 16384
    floating  = 16384
  }

    network_device {
        bridge  = "vmbr0"
        model   = "virtio"
    }
}


resource "proxmox_virtual_environment_download_file" "latest_ubuntu_22_noble_qcow2_img_template" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "proxmox-node"
  url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  # need to rename the file to *.qcow2 to indicate the actual file format for import
  file_name = "noble-server-cloudimg-amd64-template-image.qcow2"

  lifecycle {
    ignore_changes = all
  }
}

