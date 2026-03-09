terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.86.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 2.0"
    }
  }
}

provider "onepassword" {}

data "onepassword_item" "proxmox_api" {
  vault = var.op_vault_id
  title = "Proxmox API"
}

provider "proxmox" {
  endpoint  = data.onepassword_item.proxmox_api.url
  api_token = "${data.onepassword_item.proxmox_api.username}=${data.onepassword_item.proxmox_api.password}"
  insecure  = true
}
