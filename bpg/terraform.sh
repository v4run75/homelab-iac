#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REPO="git@github.com:v4run75/home-lab-tfstate.git"
GIT_REF="main"

usage() {
  cat <<'EOF'
Usage: ./terraform.sh <module> <terraform command> [args...]

Modules:
  base   - VM template and image download
  k3s    - K3S server VM
  wazuh  - Wazuh server VM
  vault     - HashiCorp Vault on K3S
  fleet        - FleetDM on K3S
  cert-manager - cert-manager + self-signed CA

Examples:
  ./terraform.sh base init
  ./terraform.sh base apply
  ./terraform.sh k3s init
  ./terraform.sh k3s plan
  ./terraform.sh wazuh apply
  ./terraform.sh vault plan
  ./terraform.sh fleet apply
  ./terraform.sh fleet plan
  ./terraform.sh cert-manager apply

The base module must be applied first. Child modules (k3s, wazuh)
automatically resolve the template VM ID from base state.

To override, export TF_VAR_template_vm_id before running.
EOF
  exit 1
}

[[ $# -lt 2 ]] && usage

MODULE="$1"; shift
TERRAFORM_ARGS=("$@")

BASE_STATE_PATH="proxmox/base/terraform.tfstate"

case "$MODULE" in
  base)
    WORK_DIR="${SCRIPT_DIR}"
    STATE_PATH="${BASE_STATE_PATH}"
    ;;
  k3s)
    WORK_DIR="${SCRIPT_DIR}/k3s"
    STATE_PATH="proxmox/k3s/terraform.tfstate"
    ;;
  wazuh)
    WORK_DIR="${SCRIPT_DIR}/wazuh"
    STATE_PATH="proxmox/wazuh/terraform.tfstate"
    ;;
  vault)
    WORK_DIR="${SCRIPT_DIR}/vault"
    STATE_PATH="proxmox/vault/terraform.tfstate"
    ;;
  fleet)
    WORK_DIR="${SCRIPT_DIR}/fleet"
    STATE_PATH="proxmox/fleet/terraform.tfstate"
    ;;
  cert-manager)
    WORK_DIR="${SCRIPT_DIR}/cert-manager"
    STATE_PATH="proxmox/cert-manager/terraform.tfstate"
    ;;
  *)
    echo "[!] Unknown module: ${MODULE}" >&2
    usage
    ;;
esac

run_terraform() {
  local dir="$1"; shift
  local state="$1"; shift
  terraform-backend-git git \
    -r "${GIT_REPO}" \
    -b "${GIT_REF}" \
    -s "$state" \
    -d "$dir" \
    terraform "$@"
}

resolve_base_dependency() {
  [[ "$MODULE" == "base" ]] && return
  [[ "$MODULE" == "vault" ]] && return
  [[ "$MODULE" == "fleet" ]] && return
  [[ "$MODULE" == "cert-manager" ]] && return

  if [[ -n "${TF_VAR_template_vm_id:-}" ]]; then
    echo "[+] Using template_vm_id from environment: ${TF_VAR_template_vm_id}" >&2
    return
  fi

  # Skip resolution for init — state doesn't exist yet
  if [[ "${TERRAFORM_ARGS[0]}" == "init" ]]; then
    return
  fi

  echo "[*] Resolving template_vm_id from base state..." >&2
  local vm_id
  vm_id=$(run_terraform "${SCRIPT_DIR}" "${BASE_STATE_PATH}" \
    output -raw template_vm_id 2>/dev/null) || {
    echo "[!] Could not resolve template_vm_id from base state." >&2
    echo "[!] Make sure you've run './terraform.sh base apply' first." >&2
    echo "[!] Or export TF_VAR_template_vm_id=<id> manually." >&2
    exit 1
  }

  export TF_VAR_template_vm_id="${vm_id}"
  echo "[+] Resolved template_vm_id=${vm_id}" >&2
}

resolve_base_dependency

echo "[*] module=${MODULE} | terraform ${TERRAFORM_ARGS[*]}" >&2
run_terraform "${WORK_DIR}" "${STATE_PATH}" "${TERRAFORM_ARGS[@]}"
