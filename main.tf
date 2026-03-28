
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

resource "azurerm_resource_group" "main" {
  name     = "RG-EDJ-Enterprise-LMS-Application"
  location = "CentralUS"
}

data "azurerm_client_config" "current" {}

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

# --- 1. Network Prep for App Gateway ---
resource "azurerm_public_ip" "pip" {
  name                = "appgw-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_subnet" "gw_subnet" {
  name                 = "gw-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# --- 2. Fixed Application Gateway ---
resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-ingress"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-config"
    subnet_id = azurerm_subnet.gw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.pip.id
  }

  backend_address_pool {
    name = "app-backend-pool"
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule1"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "app-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 1
  }
}


# --- 3. Fixed AKS Cluster ---
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aksapp"

  # Identity block must be OUTSIDE the default_node_pool
  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                = "system"
    vm_size             = "standard_b2als_v2"
    # 1. Enable autoscaling
    auto_scaling_enabled = true

    # 2. Define the scaling range
    min_count            = 1
    max_count            = 3

    # 3. Optional: Set initial node count (must be between min and max)
    node_count           = 1 
  }
  # Ensure the cluster type supports autoscaling
  # (Requires standard SKU load balancer and VirtualMachineScaleSets type)
  network_profile {
    # Add this line - "azure" is standard for AKS CNI
    network_plugin     = "azure" 
    load_balancer_sku = "standard"
  }
}

# --- 4. Fixed Secondary Node Pool ---
resource "azurerm_kubernetes_cluster_node_pool" "user_apps" {
  name                  = "userapps"
  # FIXED: Reference changed from .main.id to .aks.id
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_DS2_v3"
  #node_count            = 1
  auto_scaling_enabled   = true
  min_count             = 1
  max_count             = 5
   lifecycle {
    ignore_changes = [node_count]
  }
}

############## Azure Databases MY SQL for Flexible server ##########

# 3. MySQL Flexible Server
resource "azurerm_mysql_flexible_server" "example" {
  name                   = "unique-mysql-server-40"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  administrator_login    = "mysqladmin"
  administrator_password = "ComplexPassword123!" # Use a secret manager for production
  
  # Available SKU in East US 2 (verified from your previous error)
  sku_name               = "GP_Standard_D2ds_v4"
  version                = "8.0.21"

  # AzureRM 4.0 Naming: Use 'enabled' suffix
  #public_network_access_enabled = true
  
  storage {
    size_gb           = 20
    auto_grow_enabled = true
  }

  backup_retention_days = 7
}

# 4. MySQL Flexible Database
resource "azurerm_mysql_flexible_database" "example" {
  name                = "app_db"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.example.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

#################################

# 5. Databases: SQL & Cosmos DB
resource "azurerm_mssql_server" "sqlserver" {
  name                         = "sql-server-app"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = "centralus"
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
