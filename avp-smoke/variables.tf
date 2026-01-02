# ============================================================================
# Variables
# ============================================================================

variable "project" {
  description = "Project name"
  type        = string
  default     = "pae"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "smoke"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# ============================================================================
# EKS Configuration
# ============================================================================

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

# ============================================================================
# JWT Configuration
# ============================================================================

variable "jwt_issuer" {
  description = "JWT issuer URL (OIDC issuer)"
  type        = string
  default     = "https://testing.secure.istio.io"
}

variable "jwt_audiences" {
  description = "List of valid JWT audiences"
  type        = list(string)
  default     = ["api.pae-infra.nullapps.io"]
}

variable "jwt_groups_claim" {
  description = "JWT claim containing user groups"
  type        = string
  default     = "groups"
}

# ============================================================================
# Kubernetes Configuration
# ============================================================================

variable "kubernetes_namespace" {
  description = "Namespace for ext-authz deployment"
  type        = string
  default     = "gateway"
}

variable "gateway_selector" {
  description = "Label selector for the gateway"
  type        = map(string)
  default = {
    app = "gateway-public"
  }
}

variable "protected_paths" {
  description = "List of paths to protect with AVP authorization"
  type        = list(string)
  default     = ["/smoke", "/smoke/*"]
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
