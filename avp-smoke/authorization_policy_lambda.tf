# ============================================================================
# Istio Authorization - Lambda Mode Configuration (ALB)
# ============================================================================
# This file contains all resources specific to running the AVP authorizer
# as an AWS Lambda function external to the cluster via an internal ALB.
#
# Architecture: Istio Gateway -> HTTP -> Internal ALB -> Lambda
#
# Note: This uses an internal ALB as a workaround for Istio issue #57676
# where ext_authz only supports HTTP protocol, but Lambda Function URLs
# require HTTPS.
#
# For the nginx proxy alternative (no ALB cost), see:
# - authorization_policy_lambda_proxy.tf (lambda-proxy mode)
#
# Note: The Istio mesh config (extensionProviders) is now consolidated in
# authorization_policy.tf to prevent empty configmap during mode switches.
# ============================================================================

locals {
  # ALB DNS name for ext_authz (HTTP on port 80)
  # This is used by the consolidated mesh config in authorization_policy.tf
  lambda_alb_host = var.authorizer_mode == "lambda" ? aws_lb.lambda_authorizer[0].dns_name : ""
}

# ============================================================================
# ServiceEntry for ALB (Lambda mode only)
# ============================================================================
# This allows Istio to route traffic to the internal ALB
# The ServiceEntry registers the ALB as an external service in the mesh

resource "kubernetes_manifest" "lambda_service_entry" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  manifest = {
    apiVersion = "networking.istio.io/v1"
    kind       = "ServiceEntry"

    metadata = {
      name      = "avp-lambda-ext-authz"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
      }
    }

    spec = {
      hosts = [local.lambda_alb_host]
      ports = [
        {
          number   = 80
          name     = "http"
          protocol = "HTTP"
        }
      ]
      location   = "MESH_EXTERNAL"
      resolution = "DNS"
    }
  }

  depends_on = [aws_lb.lambda_authorizer]
}

# ============================================================================
# DestinationRule for ALB (Lambda mode only)
# ============================================================================
# No TLS required - ALB uses HTTP internally

resource "kubernetes_manifest" "lambda_destination_rule" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  manifest = {
    apiVersion = "networking.istio.io/v1"
    kind       = "DestinationRule"

    metadata = {
      name      = "avp-lambda-ext-authz"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
      }
    }

    spec = {
      host = local.lambda_alb_host
      trafficPolicy = {
        connectionPool = {
          http = {
            h2UpgradePolicy = "DO_NOT_UPGRADE"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.lambda_service_entry]
}

# ============================================================================
# Kubernetes Service for ALB (ExternalName)
# ============================================================================
# Creates a service that points to the internal ALB
# This allows the ext_authz filter to reference the ALB as a K8s service

resource "kubernetes_service_v1" "lambda_ext_authz" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  metadata {
    name      = "avp-lambda-ext-authz"
    namespace = var.kubernetes_namespace
    labels = {
      app = "avp-ext-authz"
    }
  }

  spec {
    type          = "ExternalName"
    external_name = local.lambda_alb_host
  }

  depends_on = [aws_lb.lambda_authorizer]
}

# ============================================================================
# AuthorizationPolicy CUSTOM for Lambda Mode
# ============================================================================
# This uses Istio's native AuthorizationPolicy with CUSTOM action to delegate
# authorization decisions to the Lambda function via the internal ALB.
#
# Flow: Request -> Istio Gateway -> ext_authz -> ALB (HTTP:80) -> Lambda

resource "kubernetes_manifest" "lambda_authz_policy" {
  count = var.authorizer_mode == "lambda" && length(var.gateway_selector) > 0 && length(var.protected_paths) > 0 ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-lambda"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
        "authorizer-mode"              = "lambda"
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
    aws_lb.lambda_authorizer,
    aws_lb_listener.http,
    kubernetes_config_map_v1_data.istio_mesh_config,
    kubernetes_manifest.lambda_service_entry,
    kubernetes_manifest.lambda_destination_rule
  ]
}
