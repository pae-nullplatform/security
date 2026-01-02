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

# Identity source commented out for smoke test (no real OIDC provider)
# output "identity_source_id" {
#   description = "AVP Identity Source ID for JWT validation"
#   value       = aws_verifiedpermissions_identity_source.jwt.id
# }

output "iam_role_arn" {
  description = "IAM Role ARN for the authorizer pod (IRSA)"
  value       = aws_iam_role.avp_authorizer.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for authorizer image"
  value       = aws_ecr_repository.authorizer.repository_url
}

output "ext_authz_service" {
  description = "Kubernetes service name for ext-authz"
  value       = "${kubernetes_service_v1.avp_ext_authz.metadata[0].name}.${var.kubernetes_namespace}.svc.cluster.local"
}

output "ext_authz_port" {
  description = "gRPC port for ext-authz service"
  value       = 9191
}

output "protected_paths" {
  description = "List of paths protected by AVP authorization"
  value       = var.protected_paths
}

# ============================================================================
# Build & Deploy Instructions
# ============================================================================

output "build_instructions" {
  description = "Instructions for building and deploying the authorizer"
  value       = <<-EOT

    ============================================================
    Amazon Verified Permissions Authorization - Pod Version
    ============================================================

    Policy Store ID: ${aws_verifiedpermissions_policy_store.main.id}
    ECR Repository:  ${aws_ecr_repository.authorizer.repository_url}

    Protected Paths: ${join(", ", var.protected_paths)}

    Build & Push Image:
    -------------------
    cd authorizer

    # Login to ECR
    aws ecr get-login-password --region ${var.aws_region} | \
      docker login --username AWS --password-stdin ${aws_ecr_repository.authorizer.repository_url}

    # Build and push
    docker build -t ${aws_ecr_repository.authorizer.repository_url}:latest .
    docker push ${aws_ecr_repository.authorizer.repository_url}:latest

    # Update Terraform with image
    # In terraform.tfvars:
    # authorizer_image = "${aws_ecr_repository.authorizer.repository_url}:latest"

    Testing Commands:
    -----------------

    1. Access root (no auth required for /):
       curl -k https://hello.pae-infra.nullapps.io/

    2. Access /smoke without token (should return 401):
       curl -k https://hello.pae-infra.nullapps.io/smoke

    3. Access /smoke with valid JWT (should return 200):
       TOKEN="<your-jwt-token>"
       curl -k -H "Authorization: Bearer $TOKEN" \
         https://hello.pae-infra.nullapps.io/smoke

    Debugging:
    ----------
    # Check authorizer pod logs
    kubectl logs -n ${var.kubernetes_namespace} -l app=avp-ext-authz -f

    # Check pod status
    kubectl get pods -n ${var.kubernetes_namespace} -l app=avp-ext-authz

    # Test gRPC connectivity
    kubectl run grpcurl --rm -it --image=fullstorydev/grpcurl -- \
      -plaintext avp-ext-authz.${var.kubernetes_namespace}:9191 list

    ============================================================
  EOT
}
