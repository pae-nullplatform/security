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
  description = "Label selector for the gateway (used with selector-based policy)"
  type        = map(string)
  default     = {}
}

variable "protected_paths" {
  description = "List of paths to protect with AVP authorization (used with selector-based policy)"
  type        = list(string)
  default     = []
}

variable "protected_hosts" {
  description = "List of hosts to protect with AVP authorization (used with selector-based policy)"
  type        = list(string)
  default     = []
}

# ============================================================================
# HTTPRoute-based Authorization Policies (Istio 1.22+)
# ============================================================================

variable "httproute_policies" {
  description = <<-EOT
    Map of HTTPRoute-based authorization policies using targetRef.
    This allows attaching policies directly to HTTPRoute resources instead of gateway pods.
    Requires Istio 1.22+.

    Example:
      httproute_policies = {
        smoke = {
          httproute_name = "smoke-route"
          paths          = ["/smoke", "/smoke/*"]
          methods        = ["GET", "POST"]
        }
        api = {
          httproute_name      = "api-route"
          httproute_namespace = "backend"
          paths               = ["/api/v1/*"]
        }
      }
  EOT
  type = map(object({
    httproute_name      = string
    httproute_namespace = optional(string)
    paths               = list(string)
    methods             = optional(list(string), [])
  }))
  default = {}
}

# ============================================================================
# Authorizer Deployment Configuration
# ============================================================================

variable "authorizer_mode" {
  description = <<-EOT
    Deployment mode for the authorizer:
    - "lambda" (default): Uses internal ALB (HTTP) → Lambda. Best for serverless, cost-effective at low traffic.
    - "lambda-proxy": Deploys nginx proxy pod in cluster that forwards HTTP to Lambda Function URL (HTTPS).
                      No ALB cost, lower latency than ALB mode.
    - "in-cluster": Deploys the authorizer directly as a Kubernetes Pod. Best for high traffic, lowest latency.
  EOT
  type        = string
  default     = "lambda"

  validation {
    condition     = contains(["lambda", "lambda-proxy", "in-cluster"], var.authorizer_mode)
    error_message = "authorizer_mode must be 'lambda', 'lambda-proxy', or 'in-cluster'"
  }
}

variable "authorizer_replicas" {
  description = "Number of authorizer pod replicas (used for 'in-cluster' mode and nginx proxy in 'lambda-proxy' mode)"
  type        = number
  default     = 2
}

variable "log_level" {
  description = "Log level for authorizer (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}

# ============================================================================
# Lambda Configuration (used when authorizer_mode = 'lambda' or 'lambda-proxy')
# ============================================================================

variable "lambda_memory_size" {
  description = "Memory size for Lambda function in MB"
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Timeout for Lambda function in seconds"
  type        = number
  default     = 10
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrent executions for Lambda (-1 for unreserved)"
  type        = number
  default     = -1
}

# ============================================================================
# Tags
# ============================================================================

variable "tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
