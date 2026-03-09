resource "proxmox_virtual_environment_vm" "ubuntu_server" {
  name        = "K3S-Server"
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
      keys     = [trimspace(tls_private_key.k3s_vm_key.public_key_openssh)]
      password = random_password.k3s_vm_password.result
      username = "ubuntu"
    }

    ip_config {
      ipv4 {
        address = "10.0.0.2/24"   # Configure: your K3s VM IP
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

resource "random_password" "k3s_vm_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

resource "tls_private_key" "k3s_vm_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "onepassword_item" "k3s_vm" {
  vault    = var.op_vault_id
  title    = "K3S VM"
  category = "login"

  url      = "ssh://10.0.0.2"  # Configure: your K3s VM IP
  username = "ubuntu"
  password = random_password.k3s_vm_password.result

  section {
    label = "SSH Key"

    field {
      label = "private_key"
      type  = "CONCEALED"
      value = tls_private_key.k3s_vm_key.private_key_pem
    }

    field {
      label = "public_key"
      value = tls_private_key.k3s_vm_key.public_key_openssh
    }
  }
}

output "k3s_vm_password" {
  value     = random_password.k3s_vm_password.result
  sensitive = true
}

output "k3s_vm_private_key" {
  value     = tls_private_key.k3s_vm_key.private_key_pem
  sensitive = true
}

output "k3s_vm_public_key" {
  value = tls_private_key.k3s_vm_key.public_key_openssh
}

output "k3s_vm_ip" {
  value       = "10.0.0.2"  # Configure: your K3s VM IP
  description = "The fixed IP of the K3S VM"
}

output "k3s_vm_ssh" {
  value = {
    host        = "10.0.0.2"
    user        = "ubuntu"
    private_key = tls_private_key.k3s_vm_key.private_key_pem
  }
  sensitive = true
}

resource "local_file" "k3s_ansible_inventory" {
  content = <<-EOT
    [k3s_server]
    k3s-master ansible_host=10.0.0.2 ansible_user=ubuntu ansible_ssh_private_key_file=${abspath("${path.module}/k3s_vm_key.pem")}
  EOT
  filename = "${path.module}/ansible_inventory.ini"
}

resource "null_resource" "k3s_ansible" {
  depends_on = [
    proxmox_virtual_environment_vm.ubuntu_server,
    local_file.k3s_vm_private_key,
    local_file.k3s_ansible_inventory,
  ]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.ubuntu_server.id
  }

  connection {
    type        = "ssh"
    host        = "10.0.0.2"
    user        = "ubuntu"
    private_key = tls_private_key.k3s_vm_key.private_key_pem
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true"]
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ${local_file.k3s_ansible_inventory.filename} ${abspath("${path.module}/../ansible-playbooks/k3s/install_k3s.yaml")}"
  }
}

resource "null_resource" "k3s_kubeconfig" {
  depends_on = [null_resource.k3s_ansible]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.ubuntu_server.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY_FILE=$(mktemp /tmp/tf-k3s-ssh-XXXXXXXX)
      KUBECONFIG_FILE=$(mktemp /tmp/tf-kubeconfig-XXXXXXXX)
      trap 'rm -f "$KEY_FILE" "$KUBECONFIG_FILE"' EXIT
      printenv TF_SSH_PRIVATE_KEY > "$KEY_FILE"
      chmod 600 "$KEY_FILE"
      ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@10.0.0.2 \
        "sudo cat /etc/rancher/k3s/k3s.yaml" | \
        sed 's/127\.0\.0\.1/10.0.0.2/g' > "$KUBECONFIG_FILE"
      op item edit "K3S VM" --vault "$OP_VAULT_ID" \
        "Kubeconfig.kubeconfig[concealed]=$(cat "$KUBECONFIG_FILE")"
    EOT
    environment = {
      TF_SSH_PRIVATE_KEY = tls_private_key.k3s_vm_key.private_key_pem
      OP_VAULT_ID        = var.op_vault_id
    }
  }
}

resource "local_file" "k3s_vm_private_key" {
  content         = tls_private_key.k3s_vm_key.private_key_pem
  filename        = "${path.module}/k3s_vm_key.pem"
  file_permission = "0600"
}
