terraform {
  backend "azurerm" { #remote state config
    resource_group_name  = "tfstate"
    storage_account_name = "tfstaterv1ss"
    container_name       = "tfstate"
    key                  = "aar-akv-pe-hw.tfstate"
  }
}