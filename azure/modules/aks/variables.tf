variable "name" {
  description = "Cluster name, also used for its identities and DNS prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,52}[a-z0-9]$", var.name))
    error_message = "name must be 3-54 lowercase letters, digits and hyphens."
  }
}

variable "resource_group_name" {
  description = "Resource group for the cluster and its identities."
  type        = string
}

variable "node_resource_group" {
  description = "Name of the AKS-managed resource group for node VMs, disks and the API server private endpoint (created by AKS)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Pinned to the version AKS marks default in the region, so plans stay stable."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.35."
  }
}

variable "subnet_id" {
  description = "Subnet for the nodes (and the API server private endpoint AKS creates)."
  type        = string

  validation {
    condition     = can(regex("/subnets/[^/]+$", var.subnet_id))
    error_message = "subnet_id must be a subnet resource ID."
  }
}

variable "container_registry_id" {
  description = "Private ACR the cluster bootstraps from (outbound_type = none) and pulls workload images from. Must already have the aks-managed-mcr cache rule and a private endpoint in the cluster VNet."
  type        = string

  validation {
    condition     = can(regex("/providers/Microsoft.ContainerRegistry/registries/[^/]+$", var.container_registry_id))
    error_message = "container_registry_id must be a container registry resource ID."
  }
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR. Must not overlap any VNet the cluster can reach."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid IPv4 CIDR."
  }
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR. Chosen outside 10.0.0.0/8 so it can't collide with the AWS VPC or any hub/spoke range."
  type        = string
  default     = "172.16.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid IPv4 CIDR."
  }
}

variable "dns_service_ip" {
  description = "ClusterIP for CoreDNS; must be inside service_cidr."
  type        = string
  default     = "172.16.0.10"

  validation {
    condition     = can(cidrhost("${var.dns_service_ip}/32", 0))
    error_message = "dns_service_ip must be an IPv4 address."
  }
}

variable "node_vm_size" {
  description = "Node VM size. The default is the smallest size AKS accepts for a system pool (2 vCPU, 4 GiB)."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "node_count" {
  description = "Nodes in the system pool."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be 1-3 for this lab."
  }
}

variable "zones" {
  description = "Availability zones for the nodes. Empty for a regional (non-zonal) pool."
  type        = list(string)
  default     = ["1", "2"]

  validation {
    condition     = alltrue([for z in var.zones : contains(["1", "2", "3"], z)])
    error_message = "zones may only contain \"1\", \"2\" and \"3\"."
  }
}

variable "os_disk_size_gb" {
  description = "Managed OS disk size per node. 32 GB bills as a small Standard SSD tier instead of the 128 GB default."
  type        = number
  default     = 32

  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 256
    error_message = "os_disk_size_gb must be 30-256."
  }
}

variable "admin_principal_ids" {
  description = "Entra object IDs (users or groups) that get Azure Kubernetes Service RBAC Cluster Admin. Local accounts are disabled, so this is the only way in."
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_ids) > 0
    error_message = "At least one admin is required or nobody can use the cluster."
  }
}

variable "tags" {
  description = "Tags for the cluster, node pool and identities."
  type        = map(string)
  default     = {}
}
