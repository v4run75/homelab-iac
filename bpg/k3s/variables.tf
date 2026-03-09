variable "op_vault_id" {
  type        = string
  description = "The 1Password vault ID or name for storing and reading secrets"
}

variable "template_vm_id" {
  type        = string
  description = "The VM ID of the Ubuntu Server template to clone from (resolved automatically by terraform.sh)"
}

variable "cpu_cores" {
  type        = number
  description = "Number of CPU cores"
  default     = 4
}

variable "cpu_sockets" {
  type        = number
  description = "Number of CPU sockets"
  default     = 1
}

variable "memory" {
  type        = number
  description = "Dedicated memory in MB"
  default     = 8192
}
