terraform {
  required_providers {
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "onepassword" {}

data "onepassword_item" "k3s_vm" {
  vault = var.op_vault_id
  title = "K3S VM"
}

locals {
  kube_section   = [for s in data.onepassword_item.k3s_vm.section : s if s.label == "Kubeconfig"][0]
  kubeconfig_raw = [for f in local.kube_section.field : f.value if f.label == "kubeconfig"][0]
  kubeconfig     = yamldecode(local.kubeconfig_raw)
  k8s_host       = local.kubeconfig.clusters[0].cluster.server
  k8s_ca         = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  k8s_cert       = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
  k8s_key        = base64decode(local.kubeconfig.users[0].user["client-key-data"])
}

provider "helm" {
  kubernetes {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca
    client_certificate     = local.k8s_cert
    client_key             = local.k8s_key
  }
}

provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca
  client_certificate     = local.k8s_cert
  client_key             = local.k8s_key
}
