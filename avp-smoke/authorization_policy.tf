# ============================================================================
# Istio Authorization Policy - Amazon Verified Permissions
# ============================================================================
# This file contains the common AuthorizationPolicy resources that are used
# by both Pod and Lambda modes. Mode-specific resources are in:
# - authorization_policy_pod.tf    (Pod mode)
# - authorization_policy_lambda.tf (Lambda mode)
# ============================================================================

# ============================================================================
# Authorization Policy - Gateway Selector (Legacy/Compatible Mode)
# ============================================================================
# This policy applies to the gateway and filters by host.
# Used when backend pods don't have Istio sidecar.

resource "kubernetes_manifest" "avp_authz_policy" {
  count = length(var.gateway_selector) > 0 && length(var.protected_paths) > 0 ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-gateway"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
        "policy-mode"                  = "gateway-selector"
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

  depends_on = [
    kubernetes_config_map_v1_data.istio_mesh_config_pod,
    kubernetes_config_map_v1_data.istio_mesh_config_lambda
  ]
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

  depends_on = [
    kubernetes_config_map_v1_data.istio_mesh_config_pod,
    kubernetes_config_map_v1_data.istio_mesh_config_lambda
  ]
}
