resource "random_password" "mysql_password" {
  length  = 24
  special = false
}

resource "random_password" "mysql_root_password" {
  length  = 24
  special = false
}

resource "random_password" "redis_password" {
  length  = 24
  special = false
}

resource "kubernetes_namespace" "fleet" {
  metadata {
    name = "fleet"
  }
}

# --- MySQL (Bitnami) ---

resource "helm_release" "fleet_database" {
  name       = "fleet-database"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "mysql"
  namespace  = kubernetes_namespace.fleet.metadata[0].name
  timeout    = 600

  set {
    name  = "image.repository"
    value = "bitnamilegacy/mysql"
  }

  set {
    name  = "auth.username"
    value = "fleet"
  }

  set {
    name  = "auth.database"
    value = "fleet"
  }

  set_sensitive {
    name  = "auth.password"
    value = random_password.mysql_password.result
  }

  set_sensitive {
    name  = "auth.rootPassword"
    value = random_password.mysql_root_password.result
  }

  set {
    name  = "primary.nodeSelector.kubernetes\\.io/arch"
    value = "amd64"
  }
}

# --- Redis (Bitnami) ---

resource "helm_release" "fleet_cache" {
  name       = "fleet-cache"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "redis"
  namespace  = kubernetes_namespace.fleet.metadata[0].name
  timeout    = 600

  set {
    name  = "image.repository"
    value = "bitnamilegacy/redis"
  }

  set {
    name  = "auth.enabled"
    value = "true"
  }

  set_sensitive {
    name  = "auth.password"
    value = random_password.redis_password.result
  }

  set {
    name  = "replica.replicaCount"
    value = "0"
  }

  set {
    name  = "master.persistence.size"
    value = "8Gi"
  }

  set {
    name  = "master.nodeSelector.kubernetes\\.io/arch"
    value = "amd64"
  }
}

# --- Kubernetes secrets for Fleet to consume ---

resource "kubernetes_secret" "mysql" {
  metadata {
    name      = "fleet-mysql-creds"
    namespace = kubernetes_namespace.fleet.metadata[0].name
  }

  data = {
    password = random_password.mysql_password.result
  }
}

resource "kubernetes_secret" "redis" {
  metadata {
    name      = "fleet-redis-creds"
    namespace = kubernetes_namespace.fleet.metadata[0].name
  }

  data = {
    password = random_password.redis_password.result
  }
}

resource "kubernetes_secret" "fleet" {
  metadata {
    name      = "fleet"
    namespace = kubernetes_namespace.fleet.metadata[0].name
  }

  data = {}
}

# --- Fleet ---

resource "helm_release" "fleet" {
  name       = "fleet"
  repository = "https://fleetdm.github.io/fleet/charts"
  chart      = "fleet"
  namespace  = kubernetes_namespace.fleet.metadata[0].name
  timeout    = 600

  values = [file("${path.module}/values.yaml")]

  depends_on = [
    helm_release.fleet_database,
    helm_release.fleet_cache,
    kubernetes_secret.mysql,
    kubernetes_secret.redis,
    kubernetes_secret.fleet,
  ]
}

# --- Store credentials in 1Password ---

resource "null_resource" "store_fleet_creds" {
  depends_on = [
    random_password.mysql_password,
    random_password.redis_password,
  ]

  triggers = {
    mysql_password = random_password.mysql_password.result
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if op item get "Fleet Credentials" --vault "$OP_VAULT_ID" > /dev/null 2>&1; then
        op item edit "Fleet Credentials" --vault "$OP_VAULT_ID" \
          "mysql_password[concealed]=$MYSQL_PASSWORD" \
          "mysql_root_password[concealed]=$MYSQL_ROOT_PASSWORD" \
          "redis_password[concealed]=$REDIS_PASSWORD" \
          "fleet_url=$FLEET_URL"
      else
        op item create --vault "$OP_VAULT_ID" \
          --category "Secure Note" \
          --title "Fleet Credentials" \
          "mysql_password[concealed]=$MYSQL_PASSWORD" \
          "mysql_root_password[concealed]=$MYSQL_ROOT_PASSWORD" \
          "redis_password[concealed]=$REDIS_PASSWORD" \
          "fleet_url=$FLEET_URL"
      fi

      echo "Fleet credentials stored in 1Password."
    EOT

    environment = {
      MYSQL_PASSWORD      = random_password.mysql_password.result
      MYSQL_ROOT_PASSWORD = random_password.mysql_root_password.result
      REDIS_PASSWORD      = random_password.redis_password.result
      FLEET_URL           = "http://fleet.10.0.0.2.nip.io"
      OP_VAULT_ID         = var.op_vault_id
    }
  }
}
