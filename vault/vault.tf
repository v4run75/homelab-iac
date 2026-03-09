resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  namespace        = "vault"
  create_namespace = true

  values = [file("${path.module}/values.yaml")]
}

resource "null_resource" "vault_init" {
  depends_on = [helm_release.vault]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp /tmp/tf-vault-kubeconfig-XXXXXXXX)
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT
      echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"

      echo "Waiting for vault-0 pod to be running..."
      kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n vault --timeout=300s

      echo "Waiting for Vault API to respond..."
      for i in $(seq 1 30); do
        if kubectl exec -n vault vault-0 -- sh -c 'vault status -format=json 2>&1' | grep -q '"initialized"'; then
          break
        fi
        sleep 5
      done

      set +e
      INIT_JSON=$(kubectl exec -n vault vault-0 -- \
        vault operator init \
          -key-shares=$${KEY_SHARES} \
          -key-threshold=$${KEY_THRESHOLD} \
          -format=json 2>&1)
      INIT_EXIT=$?
      set -e

      if [ $INIT_EXIT -ne 0 ]; then
        if echo "$INIT_JSON" | grep -qi "already initialized"; then
          echo "Vault is already initialized, skipping."
          exit 0
        fi
        echo "Error initializing Vault: $INIT_JSON" >&2
        exit 1
      fi

      ROOT_TOKEN=$(echo "$INIT_JSON" | jq -r '.root_token')
      UNSEAL_KEYS=$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64 | join(",")')

      if op item get "Vault Cluster Keys" --vault "$OP_VAULT_ID" > /dev/null 2>&1; then
        op item edit "Vault Cluster Keys" --vault "$OP_VAULT_ID" \
          "root_token[concealed]=$ROOT_TOKEN" \
          "unseal_keys[concealed]=$UNSEAL_KEYS" \
          "key_threshold=$KEY_THRESHOLD"
      else
        op item create --vault "$OP_VAULT_ID" \
          --category "Secure Note" \
          --title "Vault Cluster Keys" \
          "root_token[concealed]=$ROOT_TOKEN" \
          "unseal_keys[concealed]=$UNSEAL_KEYS" \
          "key_threshold=$KEY_THRESHOLD"
      fi

      echo "Vault initialized. Unseal keys stored in 1Password."

      echo "Auto-unsealing Vault..."
      for i in $(seq 0 $(($${KEY_THRESHOLD} - 1))); do
        KEY=$(echo "$INIT_JSON" | jq -r ".unseal_keys_b64[$i]")
        kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
      done
      echo "Vault unsealed."
    EOT

    environment = {
      KUBECONFIG_CONTENT = local.kubeconfig_raw
      KEY_SHARES         = var.vault_key_shares
      KEY_THRESHOLD      = var.vault_key_threshold
      OP_VAULT_ID        = var.op_vault_id
    }
  }
}

resource "null_resource" "vault_pki_setup" {
  depends_on = [null_resource.vault_init]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECONFIG_FILE=$(mktemp /tmp/tf-vault-pki-XXXXXXXX)
      trap 'rm -f "$KUBECONFIG_FILE"' EXIT
      echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"

      VAULT_EXEC="kubectl exec -n vault vault-0 --"

      SEALED=$($VAULT_EXEC vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
      if [ "$SEALED" == "true" ]; then
        echo "WARNING: Vault is sealed. PKI setup skipped. Unseal Vault and re-apply."
        exit 0
      fi

      ROOT_TOKEN=$(op item get "Vault Cluster Keys" --vault "$OP_VAULT_ID" --fields root_token --reveal 2>/dev/null || true)
      if [ -z "$ROOT_TOKEN" ]; then
        echo "ERROR: Could not retrieve root token from 1Password." >&2
        exit 1
      fi

      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault token lookup" > /dev/null 2>&1 || {
        echo "ERROR: Root token is invalid or Vault is not accessible." >&2
        exit 1
      }

      # --- Enable PKI secrets engine ---
      if $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault secrets list -format=json" | jq -e '."pki/"' > /dev/null 2>&1; then
        echo "PKI engine already enabled."
      else
        echo "Enabling PKI secrets engine..."
        $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault secrets enable pki"
        $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault secrets tune -max-lease-ttl=87600h pki"
      fi

      # --- Generate root CA (if not already present) ---
      EXISTING_CA=$($VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault read -field=certificate pki/cert/ca 2>/dev/null" || true)
      if [ -n "$EXISTING_CA" ]; then
        echo "Root CA already exists."
      else
        echo "Generating internal root CA..."
        $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault write pki/root/generate/internal \
          common_name='HomeLab Root CA' \
          organization='HomeLab' \
          ttl=87600h"
      fi

      # --- Configure PKI URLs ---
      echo "Configuring PKI URLs..."
      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault write pki/config/urls \
        issuing_certificates='http://vault.vault.svc:8200/v1/pki/ca' \
        crl_distribution_points='http://vault.vault.svc:8200/v1/pki/crl'"

      # --- Create/update PKI role ---
      echo "Configuring PKI role 'homelab'..."
      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault write pki/roles/homelab \
        allowed_domains='10.0.0.2.nip.io' \
        allow_subdomains=true \
        allow_bare_domains=false \
        server_flag=true \
        client_flag=false \
        max_ttl=2160h \
        require_cn=false \
        key_type=rsa \
        key_bits=2048"

      # --- Enable Kubernetes auth ---
      if $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault auth list -format=json" | jq -e '."kubernetes/"' > /dev/null 2>&1; then
        echo "Kubernetes auth already enabled."
      else
        echo "Enabling Kubernetes auth..."
        $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault auth enable kubernetes"
      fi

      echo "Configuring Kubernetes auth..."
      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault write auth/kubernetes/config \
        kubernetes_host='https://kubernetes.default.svc'"

      # --- Create policy for cert-manager ---
      echo "Writing pki-sign policy..."
      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault policy write pki-sign - <<'POLICY'
      path \"pki/sign/homelab\" {
        capabilities = [\"create\", \"update\"]
      }
      path \"pki/issuer/+/sign/homelab\" {
        capabilities = [\"create\", \"update\"]
      }
      POLICY"

      # --- Create Kubernetes auth role for cert-manager ---
      echo "Creating cert-manager K8s auth role..."
      $VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault write auth/kubernetes/role/cert-manager \
        bound_service_account_names=cert-manager \
        bound_service_account_namespaces=cert-manager \
        policies=pki-sign \
        ttl=1h"

      # --- Store CA cert in 1Password ---
      CA_CERT=$($VAULT_EXEC sh -c "export VAULT_TOKEN='$ROOT_TOKEN' && vault read -field=certificate pki/cert/ca")
      if op item get "Vault PKI Root CA" --vault "$OP_VAULT_ID" > /dev/null 2>&1; then
        op item edit "Vault PKI Root CA" --vault "$OP_VAULT_ID" \
          "certificate=$CA_CERT"
      else
        op item create --vault "$OP_VAULT_ID" \
          --category "Secure Note" \
          --title "Vault PKI Root CA" \
          "certificate=$CA_CERT"
      fi

      echo "Vault PKI setup complete. Root CA stored in 1Password."
    EOT

    environment = {
      KUBECONFIG_CONTENT = local.kubeconfig_raw
      OP_VAULT_ID        = var.op_vault_id
    }
  }
}
