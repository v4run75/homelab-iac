resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  timeout          = 600

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "null_resource" "vault_issuer_setup" {
  depends_on = [helm_release.cert_manager]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp /tmp/tf-cm-kubeconfig-XXXXXXXX)
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT
      echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"

      echo "Waiting for cert-manager webhook to be ready..."
      kubectl wait --for=condition=available deployment/cert-manager-webhook \
        -n cert-manager --timeout=120s

      sleep 5

      echo "Cleaning up old self-signed CA resources..."
      kubectl delete clusterissuer selfsigned-issuer homelab-ca-issuer --ignore-not-found
      kubectl delete certificate homelab-ca -n cert-manager --ignore-not-found
      kubectl delete secret homelab-ca-secret -n cert-manager --ignore-not-found

      echo "Creating Vault PKI ClusterIssuer..."
      kubectl apply -f - <<'MANIFEST'
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: vault-pki
      spec:
        vault:
          server: http://vault.vault.svc:8200
          path: pki/sign/homelab
          auth:
            kubernetes:
              role: cert-manager
              mountPath: /v1/auth/kubernetes
              serviceAccountRef:
                name: cert-manager
      MANIFEST

      echo "Vault PKI ClusterIssuer created (will become Ready once Vault PKI is configured)."
    EOT

    environment = {
      KUBECONFIG_CONTENT = local.kubeconfig_raw
    }
  }
}
