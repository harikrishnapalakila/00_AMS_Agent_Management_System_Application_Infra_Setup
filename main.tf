
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      # Version 4.0+ is recommended for latest OpenAI & Function App features
      version = "~> 4.0"
    }
    # ADD THIS: The Time Provider
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # Required for Cognitive Services (OpenAI)
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}
provider "time" {}


# 1. Provider and Resource Group
provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "RG-EDJ-Enterprise-LMS-Application
  location = "East US"
}

# 2. Key Vault (Secure credential storage)
resource "azurerm_key_vault" "kv" {
  name                = "kv-enterprise-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

# 3. Networking & Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-app"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-ingress"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  # configuration for frontend/backend/http_listener goes here
}

# 4. Azure Kubernetes Service (AKS)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aksapp"

  default_node_pool {
    name                = "system"
    node_count          = 2
    vm_size             = "Standard_DS2_v2"
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = true
    min_count           = 3
    max_count           = 5
    node_count          = 3 # Initial count

  identity {
    type = "SystemAssigned"
  }
}
}

resource "azurerm_kubernetes_cluster_node_pool" "user_apps" {
  name                  = "userapps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D4s_v5"
  # ... scaling and mode settings ...
  # Enable Autoscaling
  enable_auto_scaling   = true
  min_count             = 1
  max_count             = 10
  node_count            = 2
}

# 5. Databases: SQL & Cosmos DB
resource "azurerm_mssql_server" "sqlserver" {
  name                         = "sql-server-app"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladmin"
  administrator_login_password = "SecurePassword123!"
}

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "cosmos-db-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  consistency_policy {
    consistency_level = "Session"
  }
  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }
}

# 6. AI Services: OpenAI & Document Intelligence
resource "azurerm_cognitive_account" "openai" {
  name                = "openai-service"
  location            = "East US" # Check regional availability
  resource_group_name = azurerm_resource_group.main.name
  kind                = "OpenAI"
  sku_name            = "S0"
}

resource "azurerm_cognitive_account" "doc_intel" {
  name                = "doc-intelligence-service"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  kind                = "FormRecognizer" # Document Intelligence technical name
  sku_name            = "S0"
}

# 7. Storage & Messaging: Storage Account & Event Hub
resource "azurerm_storage_account" "storage" {
  name                     = "stenterpriseappdata"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_eventhub_namespace" "eh_ns" {
  name                = "evh-ns-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
}
