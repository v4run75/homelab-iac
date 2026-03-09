resource "proxmox_virtual_environment_vm" "wazuh_server" {
  name        = "Wazuh-Server"
  node_name   = "proxmox-node"  # Configure: your Proxmox node name
  description = "Managed by Terraform"
  tags        = ["terraform", "ubuntu"]

  stop_on_destroy = true

  clone {
    vm_id = var.template_vm_id
  }

  agent {
    enabled = false
  }

  initialization {
    datastore_id = "local-lvm"  # Configure: your datastore

    user_account {
      keys     = [trimspace(tls_private_key.wazuh_vm_key.public_key_openssh)]
      password = random_password.wazuh_vm_password.result
      username = "ubuntu"
    }

    ip_config {
      ipv4 {
        address = "10.0.0.3/24"   # Configure: your Wazuh VM IP
        gateway = "10.0.0.1"      # Configure: your network gateway
      }
    }
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 50
  }

  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }
}

resource "random_password" "wazuh_vm_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

resource "tls_private_key" "wazuh_vm_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "onepassword_item" "wazuh_vm" {
  vault    = var.op_vault_id
  title    = "Wazuh VM"
  category = "login"

  url      = "ssh://10.0.0.3"  # Configure: your Wazuh VM IP
  username = "ubuntu"
  password = random_password.wazuh_vm_password.result

  section {
    label = "SSH Key"

    field {
      label = "private_key"
      type  = "CONCEALED"
      value = tls_private_key.wazuh_vm_key.private_key_pem
    }

    field {
      label = "public_key"
      value = tls_private_key.wazuh_vm_key.public_key_openssh
    }
  }
}

output "wazuh_vm_password" {
  value     = random_password.wazuh_vm_password.result
  sensitive = true
}

output "wazuh_vm_private_key" {
  value     = tls_private_key.wazuh_vm_key.private_key_pem
  sensitive = true
}

output "wazuh_vm_public_key" {
  value = tls_private_key.wazuh_vm_key.public_key_openssh
}

output "wazuh_vm_ip" {
  value       = "10.0.0.3"  # Configure: your Wazuh VM IP
  description = "The fixed IP of the Wazuh VM"
}

output "wazuh_vm_ssh" {
  value = {
    host        = "10.0.0.3"
    user        = "ubuntu"
    private_key = tls_private_key.wazuh_vm_key.private_key_pem
  }
  sensitive = true
}

resource "local_file" "wazuh_ansible_inventory" {
  content = <<-EOT
    [wazuh_server]
    wazuh_server ansible_host=10.0.0.3 ansible_user=ubuntu ansible_ssh_private_key_file=${abspath("${path.module}/wazuh_vm_key.pem")}
  EOT
  filename = "${path.module}/ansible_inventory.ini"
}

resource "null_resource" "wazuh_ansible" {
  depends_on = [
    proxmox_virtual_environment_vm.wazuh_server,
    local_file.wazuh_vm_private_key,
    local_file.wazuh_ansible_inventory,
  ]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.wazuh_server.id
  }

  connection {
    type        = "ssh"
    host        = "10.0.0.3"
    user        = "ubuntu"
    private_key = tls_private_key.wazuh_vm_key.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true"]
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ${local_file.wazuh_ansible_inventory.filename} ${abspath("${path.module}/../ansible-playbooks/wazuh/install_wazuh.yaml")}"
  }
}

resource "local_file" "wazuh_vm_private_key" {
  content         = tls_private_key.wazuh_vm_key.private_key_pem
  filename        = "${path.module}/wazuh_vm_key.pem"
  file_permission = "0600"
}
