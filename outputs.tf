output "template_vm_id" {
  value       = proxmox_virtual_environment_vm.ubuntu_server_template.id
  description = "The VM ID of the Ubuntu Server template"
}
