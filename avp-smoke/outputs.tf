# ============================================================================
# Outputs
# ============================================================================

output "policy_store_id" {
  description = "Amazon Verified Permissions Policy Store ID"
  value       = aws_verifiedpermissions_policy_store.main.id
}

output "policy_store_arn" {
  description = "Amazon Verified Permissions Policy Store ARN"
  value       = aws_verifiedpermissions_policy_store.main.arn
}

# ============================================================================
# Authorizer Mode Outputs
# ============================================================================

output "authorizer_mode" {
  description = "Current authorizer deployment mode"
  value       = var.authorizer_mode
}

# Pod mode outputs
output "iam_role_arn" {
  description = "IAM Role ARN for the authorizer pod (IRSA) - only in pod mode"
  value       = var.authorizer_mode == "pod" ? aws_iam_role.avp_authorizer[0].arn : null
}

output "ecr_repository_url" {
  description = "ECR repository URL for authorizer image - only in pod mode"
  value       = var.authorizer_mode == "pod" ? aws_ecr_repository.authorizer[0].repository_url : null
}

output "ext_authz_service" {
  description = "Kubernetes service name for ext-authz"
  value = var.authorizer_mode == "pod" ? (
    "${kubernetes_service_v1.avp_ext_authz[0].metadata[0].name}.${var.kubernetes_namespace}.svc.cluster.local"
    ) : (
    "${kubernetes_service_v1.lambda_ext_authz[0].metadata[0].name}.${var.kubernetes_namespace}.svc.cluster.local"
  )
}

output "ext_authz_port" {
  description = "Port for ext-authz service"
  value       = var.authorizer_mode == "pod" ? 9191 : 443
}

# Lambda mode outputs
output "lambda_function_arn" {
  description = "Lambda function ARN - only in lambda mode"
  value       = var.authorizer_mode == "lambda" ? aws_lambda_function.authorizer[0].arn : null
}

output "lambda_function_url" {
  description = "Lambda Function URL - only in lambda mode"
  value       = var.authorizer_mode == "lambda" ? aws_lambda_function_url.authorizer[0].function_url : null
}

output "lambda_iam_role_arn" {
  description = "IAM Role ARN for the Lambda function - only in lambda mode"
  value       = var.authorizer_mode == "lambda" ? aws_iam_role.lambda_authorizer[0].arn : null
}

# ============================================================================
# HTTPRoute Policy Outputs
# ============================================================================

output "httproute_policies" {
  description = "Map of HTTPRoute-based authorization policies created"
  value = {
    for key, policy in var.httproute_policies : key => {
      policy_name         = "avp-ext-authz-${key}"
      httproute_name      = policy.httproute_name
      httproute_namespace = coalesce(policy.httproute_namespace, var.kubernetes_namespace)
      paths               = policy.paths
      methods             = policy.methods
    }
  }
}

output "authorization_config" {
  description = "Authorization configuration summary"
  value = {
    authorizer_mode             = var.authorizer_mode
    gateway_selector_enabled    = length(var.gateway_selector) > 0 && length(var.protected_paths) > 0
    httproute_targetref_enabled = length(var.httproute_policies) > 0
    httproute_policy_count      = length(var.httproute_policies)
  }
}

# ============================================================================
# Build & Deploy Instructions
# ============================================================================

output "build_instructions" {
  description = "Instructions for the deployed authorizer"
  value = <<-EOT

    ============================================================
    Amazon Verified Permissions Authorization
    ============================================================

    Authorizer Mode: ${upper(var.authorizer_mode)}
    Policy Store ID: ${aws_verifiedpermissions_policy_store.main.id}
    ${var.authorizer_mode == "pod" ? "ECR Repository:  ${aws_ecr_repository.authorizer[0].repository_url}" : "Lambda Function: ${aws_lambda_function.authorizer[0].function_name}"}
    ${var.authorizer_mode == "lambda" ? "Function URL:    ${aws_lambda_function_url.authorizer[0].function_url}" : ""}

    ============================================================
    Authorization Modes
    ============================================================

    1. Gateway Selector Mode (Legacy):
       Status: ${length(var.gateway_selector) > 0 && length(var.protected_paths) > 0 ? "ENABLED" : "DISABLED"}
       ${length(var.protected_paths) > 0 ? "Protected Paths: ${join(", ", var.protected_paths)}" : "No paths configured"}

    2. HTTPRoute targetRef Mode (Istio 1.22+):
       Status: ${length(var.httproute_policies) > 0 ? "ENABLED" : "DISABLED"}
       Policies: ${length(var.httproute_policies)} HTTPRoute(s) configured
       ${length(var.httproute_policies) > 0 ? join("\n       ", [for k, v in var.httproute_policies : "- ${k}: ${v.httproute_name} -> ${join(", ", v.paths)}"]) : "No HTTPRoute policies configured"}

    ============================================================
    Authorizer Details
    ============================================================
    ${var.authorizer_mode == "pod" ? <<-POD
    Mode: Kubernetes Pod (in-cluster)
    Service: avp-ext-authz.${var.kubernetes_namespace}.svc.cluster.local:9191
    Replicas: ${var.authorizer_replicas}

    # View pod logs
    kubectl logs -n ${var.kubernetes_namespace} -l app=avp-ext-authz -f

    # Check pod status
    kubectl get pods -n ${var.kubernetes_namespace} -l app=avp-ext-authz
    POD
  : <<-LAMBDA
    Mode: AWS Lambda (Function URL)
    Function: ${aws_lambda_function.authorizer[0].function_name}
    URL: ${aws_lambda_function_url.authorizer[0].function_url}
    Memory: ${var.lambda_memory_size}MB
    Timeout: ${var.lambda_timeout}s

    # View Lambda logs
    aws logs tail /aws/lambda/${aws_lambda_function.authorizer[0].function_name} --follow

    # Test Lambda directly
    curl -X POST ${aws_lambda_function_url.authorizer[0].function_url}health
    LAMBDA
}

    ============================================================
    Testing Commands
    ============================================================

    1. Access root (no auth required for /):
       curl -k https://hello.pae-infra.nullapps.io/

    2. Access protected path without token (should return 401):
       curl -k https://hello.pae-infra.nullapps.io/smoke

    3. Access protected path with valid JWT (should return 200):
       TOKEN="<your-jwt-token>"
       curl -k -H "Authorization: Bearer $TOKEN" \
         https://hello.pae-infra.nullapps.io/smoke

    ============================================================
    Debugging
    ============================================================

    # List all AuthorizationPolicies
    kubectl get authorizationpolicies -n ${var.kubernetes_namespace}

    # Check Istio extension providers
    kubectl get cm istio -n istio-system -o yaml | grep -A20 extensionProviders

    # Check Istio version (targetRef requires 1.22+)
    kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].spec.containers[0].image}'

    ============================================================
  EOT
}
