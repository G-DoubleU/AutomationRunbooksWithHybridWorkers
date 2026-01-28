terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  required_version = ">=1.1.0"
  backend "azurerm" { #remote state config
    resource_group_name  = "tfstate"
    storage_account_name = "tfstaterv1ss"
    container_name       = "tfstate"
    key                  = "aar-akv-pe-hw.tfstate"
  }
}

data "azurerm_client_config" "current" {} #needed so we can later reference things like tenant ID 

provider "azurerm" {
  features {}
  subscription_id = "e7cc5b12-3e04-4af0-a26f-30657aa9395f"
}

provider "random" {}

#----------------------------------------------------
# Core
#----------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "hybrid-worker-test-rg"
  location = "eastus"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "hybrid-worker-test-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "subnet" { #Doing this instead of inline subnet above ^ as it will be easier to reference later
  name                              = "hybrid-worker-test-subnet1"
  resource_group_name               = azurerm_resource_group.rg.name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = ["10.0.0.0/26"]
  private_endpoint_network_policies = "Disabled" #Check this if things don't work 
}

resource "random_uuid" "random" {}

#----------------------------------------------------
# Key Vault and IAM
#----------------------------------------------------
resource "azurerm_key_vault" "kv" {
  name                          = "hybrid-worker-test-kv"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id #Lets us pull information from our currently authenticated azure session, in this case tenant ID 
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
}

resource "azurerm_key_vault_secret" "secret" { #Just using this so I can later confirm that the hybrid worker can access the KV 
  name         = "test-secret"
  value        = "Hello there! "
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_role_assignment" "aa_vm" {
  scope                = azurerm_windows_virtual_machine.vm.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

resource "azurerm_role_assignment" "kv_self_admin" {
  scope                = azurerm_key_vault.kv.id #Terraform is smart enough to know that it map dependencies and do things in order
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id #This references whoever is currently authenticated to run this terraform 
}

resource "azurerm_role_assignment" "aa_secrets_reader" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
}

#----------------------------------------------------
# Compute
#----------------------------------------------------
resource "azurerm_windows_virtual_machine" "vm" {
  name                = "hybridworkertest-vm"
  computer_name       = "workervm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  zone                = "2"
  size                = "Standard_D2s_v3"
  admin_username      = "geoff" #Redact, ideally would do a more complex config like pull these from an existing KV 
  admin_password      = "West_micr16!"
  network_interface_ids = [
    azurerm_network_interface.vnic.id
  ]

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "windowsserver"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
  identity {
    type = "SystemAssigned"
  }


}

resource "azurerm_virtual_machine_extension" "powershell_modules" { #This part could not work, not sure
  name                 = "PowerShellModules"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -Command \"Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force; Install-Module Az.Accounts -Scope AllUsers -Force -AllowClobber; Install-Module Az.KeyVault -Scope AllUsers -Force -AllowClobber\""

  })

}

resource "azurerm_virtual_machine_extension" "hybridworkerextension" {
  name                 = "HybridWorkerExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm.id
  publisher            = "Microsoft.Azure.Automation.HybridWorker"
  type                 = "HybridWorkerForWindows"
  type_handler_version = "1.1"

  settings = jsonencode({
    "AutomationAccountURL" = azurerm_automation_account.aa.hybrid_service_url
  })
}

#----------------------------------------------------
# Networking
#----------------------------------------------------
resource "azurerm_network_interface" "vnic" {
  name                = "hybrid-worker-test-vnic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }

}

resource "azurerm_private_endpoint" "pe" {
  name                = "hybrid-worker-test-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet.id

  private_service_connection {
    name                           = "connection-to-kv"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
  }
}

#----------------------------------------------------
# Automation and Scheduling
#----------------------------------------------------
resource "azurerm_automation_account" "aa" {
  name                = "hybrid-worker-test-aa"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "Free"
  identity {
    type = "SystemAssigned" #Need this so we can give the AA access to retrieve KV secrets and such 
  }
}

resource "azurerm_automation_runbook" "testscript" {
  name                    = "HybridWorkerTestScript"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  log_verbose             = true
  log_progress            = true
  description             = "Test script to see if the hybrid worker workflow can successfully authenticate with the KV"
  runbook_type            = "PowerShell"

  content = <<-EOT
  Connect-AzAccount -Identity
  $secretName = "test-secret"
  $vaultName = "hybrid-worker-test-kv"

  try {
    $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText
    Write-Output "Success! $($secret)"
  }catch{
    Write-Error "Failed to retireve secretW"
  }

EOT

}

resource "azurerm_automation_runbook" "startvm" {
  name                    = "startvm"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  log_verbose             = true
  log_progress            = true
  description             = "Allocates VM before script runtime"
  runbook_type            = "PowerShell"

  content = <<-EOT
  Connect-AzAccount -Identity
  $vmName = "hybridworkertest-vm"
  $resourceGroup = "hybrid-worker-test-rg"

  Write-Output "Starting VM"
  Start-AzVM -ResourceGroupName $resourceGroup -Name $vmName
  EOT
}

resource "azurerm_automation_runbook" "deallocatevm" {
  name                    = "deallocatevm"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  log_verbose             = true
  log_progress            = true
  description             = "Deallocates VM after script runtime"
  runbook_type            = "PowerShell"

  content = <<-EOT
  Connect-AzAccount -Identity
  $vmName = "hybridworkertest-vm"
  $resourceGroup = "hybrid-worker-test-rg"

  Write-Output "Deallocating VM"
  Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force
  EOT
}

resource "azurerm_automation_schedule" "start_vm_schedule" {
  name                    = "Start-vm-schedule"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  frequency               = "OneTime"
  start_time              = "2026-01-24T15:25:00-06:00"
  timezone                = "America/Chicago"
}

resource "azurerm_automation_schedule" "test_script_schedule" {
  name                    = "test-script-schedule"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  frequency               = "OneTime"
  start_time              = "2026-01-24T15:33:00-06:00"
  timezone                = "America/Chicago"
}

resource "azurerm_automation_schedule" "deallo_vm_schedule" {
  name                    = "deallocate-vm-schedule"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  frequency               = "OneTime"
  start_time              = "2026-01-24T15:38:00-06:00"
  timezone                = "America/Chicago"
}

resource "azurerm_automation_job_schedule" "start_vm_job" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  runbook_name            = azurerm_automation_runbook.startvm.name
  schedule_name           = azurerm_automation_schedule.start_vm_schedule.name
}

resource "azurerm_automation_job_schedule" "test_script_job" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  runbook_name            = azurerm_automation_runbook.testscript.name
  schedule_name           = azurerm_automation_schedule.test_script_schedule.name
  run_on                  = azurerm_automation_hybrid_runbook_worker_group.hybridworkergroup.name
}

resource "azurerm_automation_job_schedule" "deallo_vm_job" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  runbook_name            = azurerm_automation_runbook.deallocatevm.name
  schedule_name           = azurerm_automation_schedule.deallo_vm_schedule.name
}


resource "azurerm_automation_hybrid_runbook_worker_group" "hybridworkergroup" {
  name                    = "hybrid-worker-workgroup1"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
}

resource "azurerm_automation_hybrid_runbook_worker" "hybridworker" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.aa.name
  worker_group_name       = azurerm_automation_hybrid_runbook_worker_group.hybridworkergroup.name
  vm_resource_id          = azurerm_windows_virtual_machine.vm.id
  worker_id               = random_uuid.random.result
}