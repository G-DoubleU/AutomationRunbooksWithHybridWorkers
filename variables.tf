variable "location" {
    type = string
    default = "eastus"
}

variable "start_vm_time" {
    type = string
    description = "What time the VM will start"
}

variable "script_start_time" {
    type = string
    description = "What time the test script should start"
}

variable "deallocate_vm_time" {
    type = string
    description = "What time the vm should deallocate after script runs"
}

variable "vm_admin_un"{
    type = string
    sensitive = true
}

variable "vm_admin_pw" {
    type = string
    sensitive = true
}

variable "vm_size" {
  type = string
  default = "Standard_D2s_v3"
}

variable "vm_zone" {
  type = string 
  default = 2
}

variable "automation_account_sku" {
  type = string
  default = "Free"
}