variable "op_vault_id" {
  type        = string
  description = "The 1Password vault ID or name for storing and reading secrets"
}

variable "vault_key_shares" {
  type        = number
  description = "Number of key shares for Vault initialization"
  default     = 5
}

variable "vault_key_threshold" {
  type        = number
  description = "Number of key shares required to unseal Vault"
  default     = 3
}
