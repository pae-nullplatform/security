# ============================================================================
# Istio Authorization Policy - Amazon Verified Permissions
# ============================================================================
# This file contains the common AuthorizationPolicy resources that are used
# by all authorizer modes. Mode-specific resources are in:
# - authorization_policy_in_cluster.tf   (in-cluster mode - Pod deployment)
# - authorization_policy_lambda.tf       (lambda mode - ALB → Lambda)
# - authorization_policy_lambda_proxy.tf (lambda-proxy mode - Nginx → Lambda)
# ============================================================================

# ============================================================================
# Extension Provider Configuration - Consolidated for all modes
# ============================================================================
# This resource always exists and changes its content based on authorizer_mode.
# This prevents the configmap from being empty during mode switches.

locals {
  # Helper booleans for mode checks
  use_in_cluster   = var.authorizer_mode == "in-cluster"
  use_lambda       = var.authorizer_mode == "lambda"
  use_lambda_proxy = var.authorizer_mode == "lambda-proxy"

  # Service endpoint depends on mode
  ext_authz_service = local.use_in_cluster ? (
    "avp-ext-authz.${var.kubernetes_namespace}.svc.cluster.local"
    ) : local.use_lambda_proxy ? (
    "avp-lambda-proxy.${var.kubernetes_namespace}.svc.cluster.local"
    ) : (
    local.lambda_alb_host # lambda mode uses ALB
  )

  ext_authz_port = local.use_in_cluster ? 9191 : 80
}

resource "kubernetes_config_map_v1_data" "istio_mesh_config" {
  metadata {
    name      = "istio"
    namespace = "istio-system"
  }

  data = {
    mesh = local.use_in_cluster ? (
      # in-cluster mode config - direct pod service
      <<-EOF
      extensionProviders:
      - name: avp-ext-authz
        envoyExtAuthzHttp:
          service: avp-ext-authz.${var.kubernetes_namespace}.svc.cluster.local
          port: 9191
          includeRequestHeadersInCheck:
          - authorization
          - x-forwarded-for
          includeAdditionalHeadersInCheck:
            x-original-method: "%REQ(:METHOD)%"
            x-original-uri: "%REQ(:PATH)%"
            x-original-host: "%REQ(:AUTHORITY)%"
          headersToUpstreamOnAllow:
          - x-user-id
          - x-avp-decision
          - x-validated-by
          headersToDownstreamOnDeny:
          - x-avp-decision
      EOF
      ) : local.use_lambda_proxy ? (
      # lambda-proxy mode config - nginx proxy in cluster → Lambda Function URL
      <<-EOF
      extensionProviders:
      - name: avp-ext-authz
        envoyExtAuthzHttp:
          service: avp-lambda-proxy.${var.kubernetes_namespace}.svc.cluster.local
          port: 80
          includeRequestHeadersInCheck:
          - authorization
          - x-forwarded-for
          includeAdditionalHeadersInCheck:
            x-original-method: "%REQ(:METHOD)%"
            x-original-uri: "%REQ(:PATH)%"
            x-original-host: "%REQ(:AUTHORITY)%"
          headersToUpstreamOnAllow:
          - x-user-id
          - x-avp-decision
          - x-validated-by
          headersToDownstreamOnDeny:
          - x-avp-decision
      EOF
      ) : (
      # lambda mode config - ALB → Lambda
      <<-EOF
      extensionProviders:
      - name: avp-ext-authz
        envoyExtAuthzHttp:
          service: ${local.lambda_alb_host}
          port: 80
          pathPrefix: /
          failureModeAllow: false
          statusOnError: "503"
          includeRequestHeadersInCheck:
          - authorization
          - x-forwarded-for
          includeAdditionalHeadersInCheck:
            x-original-method: "%REQ(:METHOD)%"
            x-original-uri: "%REQ(:PATH)%"
            x-original-host: "%REQ(:AUTHORITY)%"
          headersToUpstreamOnAllow:
          - x-user-id
          - x-avp-decision
          - x-validated-by
          headersToDownstreamOnAllow:
          - x-avp-decision
          headersToDownstreamOnDeny:
          - x-avp-decision
      EOF
    )
  }

  force = true

  # For Lambda mode, wait for ALB to be created
  depends_on = [aws_lb.lambda_authorizer]
}

# ============================================================================
# Authorization Policy - Gateway Selector (in-cluster mode)
# ============================================================================
# This policy applies to the gateway and filters by host.
# Used when backend pods don't have Istio sidecar.
# Note: Each mode has its own AuthorizationPolicy in its respective file.

resource "kubernetes_manifest" "avp_authz_policy" {
  count = local.use_in_cluster && length(var.gateway_selector) > 0 && length(var.protected_paths) > 0 ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-gateway"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
        "authorizer-mode"              = "in-cluster"
      }
    }

    spec = {
      selector = {
        matchLabels = var.gateway_selector
      }
      action = "CUSTOM"
      provider = {
        name = "avp-ext-authz"
      }
      rules = [
        {
          to = [
            {
              operation = merge(
                { paths = var.protected_paths },
                length(var.protected_hosts) > 0 ? { hosts = var.protected_hosts } : {}
              )
            }
          ]
        }
      ]
    }
  }

  depends_on = [kubernetes_config_map_v1_data.istio_mesh_config]
}

# ============================================================================
# Authorization Policy - HTTPRoute targetRef (Istio 1.22+)
# ============================================================================
# This policy targets specific Services directly.
# Requires backend pods to have Istio sidecar injected.

resource "kubernetes_manifest" "avp_authz_policy_httproute" {
  for_each = var.httproute_policies

  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-${each.key}"
      namespace = coalesce(each.value.httproute_namespace, var.kubernetes_namespace)
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
        "policy-mode"                  = "httproute-targetref"
        "policy-target"                = each.value.httproute_name
      }
    }

    spec = {
      targetRef = {
        group = ""
        kind  = "Service"
        name  = each.value.httproute_name
      }
      action = "CUSTOM"
      provider = {
        name = "avp-ext-authz"
      }
      rules = [
        {
          to = [
            {
              operation = merge(
                { paths = each.value.paths },
                length(each.value.methods) > 0 ? { methods = each.value.methods } : {}
              )
            }
          ]
        }
      ]
    }
  }

  depends_on = [kubernetes_config_map_v1_data.istio_mesh_config]
}
