# ============================================================================
# Variables
# ============================================================================

variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = ""
}

# ============================================================================
# EKS Configuration
# ============================================================================

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

# ============================================================================
# Kubernetes Configuration
# ============================================================================

variable "kubernetes_namespace" {
  description = "Namespace for ext-authz deployment"
  type        = string
}

variable "gateway_selector" {
  description = "Label selector for the gateway"
  type        = map(string)
}

variable "protected_paths" {
  description = "List of paths to protect with AVP authorization"
  type        = list(string)
}

# ============================================================================
# Authorizer Pod Configuration
# ============================================================================

variable "authorizer_replicas" {
  description = "Number of authorizer pod replicas"
  type        = number
  default     = 2
}

variable "log_level" {
  description = "Log level for authorizer pod (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}

# ============================================================================
# Tags
# ============================================================================

variable "tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
