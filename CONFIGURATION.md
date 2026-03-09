# Configuration Guide

This repository uses **placeholder values** for open-source distribution. Before deploying to your environment, you must replace these with your actual infrastructure details.

## Placeholder Values to Configure

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `10.0.0.2` | K3s master VM IP address | Your K3s node IP |
| `10.0.0.3` | Wazuh server VM IP address | Your Wazuh node IP |
| `10.0.0.1` | Network gateway | Your LAN gateway (e.g. router) |
| `proxmox-node` | Proxmox VE node name | Your Proxmox hostname |
| `local-lvm` | Proxmox datastore for VMs | Your storage (e.g. `local`, `data2`) |

## nip.io Hostnames

Services use [nip.io](https://nip.io) for local DNS resolution. Hostnames follow the pattern:

- `vault.10.0.0.2.nip.io` → Replace `10.0.0.2` with your K3s IP
- `fleet.10.0.0.2.nip.io`
- `authentik.10.0.0.2.nip.io`

## Files to Update

Search for `# Configure:` comments in the codebase to find values that need customization. Key locations:

- **Proxmox/VMs**: `vm-template.tf`, `k3s/k3s-vm.tf`, `wazuh/wazuh-vm.tf`
- **Ingress hostnames**: `vault/values.yaml`, `fleet/values.yaml`, `ansible-playbooks/authentik/values.yaml`
- **Ansible inventory**: `ansible-playbooks/k3s/hosts.ini`, `ansible-playbooks/wazuh/hosts.ini`

## Secrets

Credentials (passwords, API tokens, etc.) are managed via:

- **1Password** – Terraform uses the `op_vault_id` variable for storing VM credentials, Vault keys, and other secrets
- **Vault** – PKI and certificate signing

Never commit real secrets. Use `terraform.tfvars` (gitignored) or environment variables for `op_vault_id` and similar.
