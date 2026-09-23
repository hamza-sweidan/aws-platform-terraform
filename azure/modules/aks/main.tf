# Network-isolated private AKS cluster: the Azure counterpart of modules/eks.
#
# - outbound_type = "none": AKS sets up no egress path at all (no load
#   balancer SNAT, no NAT gateway). Nodes bootstrap by pulling AKS's own
#   system images from a private ACR through its cache rule
#   (bootstrap_profile.artifact_source = "Cache"), the way EKS nodes pull from
#   private ECR through VPC endpoints.
# - Private cluster: the API server is reachable only through a private
#   endpoint in the node subnet. kubectl from a laptop goes through
#   `az aks command invoke`, which runs it inside the cluster via the ARM API.
# - Entra ID only: local accounts are off and Kubernetes authorization is
#   Azure RBAC, like EKS access entries with no aws-auth ConfigMap.
# - Two user-assigned identities with the least they need: the control plane
#   manages the subnet and assigns the kubelet identity; the kubelet identity
#   can only pull from the one registry.

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Identities and their permissions
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name}-control-plane"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-${var.name}-kubelet"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# The cluster lives in our subnet (BYO VNet): the control plane joins node
# NICs and the API server private endpoint to it.
resource "azurerm_role_assignment" "control_plane_subnet" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AKS ${var.name}: manage node and API endpoint NICs in the node subnet"
}

# A custom kubelet identity must be assignable to the node VMs by the
# control plane.
resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AKS ${var.name}: attach the kubelet identity to nodes"
}

# The only thing the nodes' identity can do: pull from this registry.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = var.container_registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AKS ${var.name}: pull system (cache rule) and workload images"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_170:Free tier: no uptime SLA, fine for a lab. Standard adds $0.10/h.
  #checkov:skip=CKV_AZURE_4:Azure Monitor needs a Log Analytics workspace (billed per GB) and egress or a private link scope to reach it; this cluster has no egress.
  #checkov:skip=CKV_AZURE_116:The Azure Policy add-on (Gatekeeper) needs egress to the Azure Policy service. Governance is enforced at the ARM layer instead (tag policy, guardrails).
  #checkov:skip=CKV_AZURE_117:Customer-managed disk encryption needs a Key Vault and a disk encryption set. OS disks are encrypted at rest with platform-managed keys.
  #checkov:skip=CKV_AZURE_227:Encryption at host needs the EncryptionAtHost subscription feature registered. OS disks are encrypted at rest with platform-managed keys.
  #checkov:skip=CKV_AZURE_226:Ephemeral OS disks need a VM size with a local cache or temp disk; Standard_B2als_v2 has neither.
  #checkov:skip=CKV_AZURE_232:One node pool: the trial's vCPU quota has no room for a separate system pool, so system and workload pods share it.
  #checkov:skip=CKV_AZURE_171:Upgrades add a surge node the 4-vCPU trial quota can't fit; this lab cluster is rebuilt per session instead of auto-upgraded.
  #checkov:skip=CKV_AZURE_172:No Secrets Store CSI driver or Key Vault is used, so there's nothing to rotate.
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  node_resource_group = var.node_resource_group
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  private_cluster_enabled             = true
  private_dns_zone_id                 = "System"
  private_cluster_public_fqdn_enabled = false

  role_based_access_control_enabled = true
  local_account_disabled            = true
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  # Workload identity for future pods that need Azure access, without secrets.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # `az aks command invoke` runs kubectl inside the cluster through the ARM
  # API: the way in to a private API server without a jump host.
  run_command_enabled = true

  # Every upgrade adds a surge node, and a Free Trial subscription's 4-vCPU
  # quota is used up by two 2-vCPU nodes. Automatic upgrades stay off
  # (no automatic_upgrade_channel) in this lab, which is rebuilt per session.
  node_os_upgrade_channel = "None"

  # Manual: node pools are declared here (default_node_pool). "Auto" would be
  # Node Auto Provisioning (Karpenter) creating pools on demand.
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name            = "system"
    vm_size         = var.node_vm_size
    node_count      = var.node_count
    zones           = var.zones
    vnet_subnet_id  = var.subnet_id
    os_sku          = "AzureLinux"
    os_disk_type    = "Managed"
    os_disk_size_gb = var.os_disk_size_gb
    # Kubernetes' usual per-node density; overlay would allow 250, which a
    # 4 GiB node could never run.
    max_pods                    = 110
    node_public_ip_enabled      = false
    temporary_name_for_rotation = "rotation"

    upgrade_settings {
      max_surge = "1"
    }

    tags = var.tags
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  network_profile {
    # Azure CNI Overlay: pods get IPs from pod_cidr, not from the VNet, so a
    # /24 node subnet is enough. Cilium provides the dataplane and
    # NetworkPolicy enforcement.
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "none"
  }

  bootstrap_profile {
    artifact_source       = "Cache"
    container_registry_id = var.container_registry_id
  }

  tags = var.tags

  # Nodes pull their system images through the registry during creation, so
  # every permission has to be in place first.
  depends_on = [
    azurerm_role_assignment.control_plane_subnet,
    azurerm_role_assignment.control_plane_kubelet_operator,
    azurerm_role_assignment.kubelet_acr_pull,
  ]
}

# Local accounts are off, so Azure RBAC is the only way to use the cluster.
resource "azurerm_role_assignment" "cluster_admin" {
  for_each = toset(var.admin_principal_ids)

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  description          = "Cluster admin via Entra ID (local accounts disabled)"
}
