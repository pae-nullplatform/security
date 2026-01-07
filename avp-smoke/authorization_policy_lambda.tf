# ============================================================================
# Istio Authorization - Lambda Mode Configuration
# ============================================================================
# This file contains all resources specific to running the AVP authorizer
# as an AWS Lambda function external to the cluster.
# ============================================================================

locals {
  # Parse Lambda Function URL to extract host (remove https:// prefix and trailing /)
  lambda_function_url_host = var.authorizer_mode == "lambda" ? replace(
    replace(aws_lambda_function_url.authorizer[0].function_url, "https://", ""),
    "/", ""
  ) : ""
}

# ============================================================================
# Extension Provider Configuration - Lambda Mode
# ============================================================================
# Key difference from Pod mode: Uses HTTPS on port 443 with external service

resource "kubernetes_config_map_v1_data" "istio_mesh_config_lambda" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  metadata {
    name      = "istio"
    namespace = "istio-system"
  }

  data = {
    mesh = <<-EOF
      extensionProviders:
      - name: avp-ext-authz
        envoyExtAuthzHttp:
          service: ${local.lambda_function_url_host}
          port: 443
          pathPrefix: /
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
  }

  force = true
}

# ============================================================================
# ServiceEntry for Lambda Function URL (Lambda mode only)
# ============================================================================
# This allows Istio to route traffic to the external Lambda Function URL
# The ServiceEntry registers the external service in the mesh

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
      hosts = [local.lambda_function_url_host]
      ports = [
        {
          number   = 443
          name     = "https"
          protocol = "HTTPS"
        }
      ]
      location   = "MESH_EXTERNAL"
      resolution = "DNS"
    }
  }
}

# ============================================================================
# DestinationRule for Lambda TLS (Lambda mode only)
# ============================================================================
# This configures TLS origination for connections to the Lambda Function URL
# SNI is required for Lambda to correctly route the request

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
      host = local.lambda_function_url_host
      trafficPolicy = {
        tls = {
          mode = "SIMPLE"
          sni  = local.lambda_function_url_host
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.lambda_service_entry]
}

# DestinationRule for ExternalName service - ensures TLS is used
resource "kubernetes_manifest" "lambda_destination_rule_svc" {
  count = var.authorizer_mode == "lambda" ? 1 : 0

  manifest = {
    apiVersion = "networking.istio.io/v1"
    kind       = "DestinationRule"

    metadata = {
      name      = "avp-lambda-ext-authz-svc"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
      }
    }

    spec = {
      host = "avp-lambda-ext-authz.${var.kubernetes_namespace}.svc.cluster.local"
      trafficPolicy = {
        tls = {
          mode = "SIMPLE"
          sni  = local.lambda_function_url_host
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.lambda_ext_authz]
}

# ============================================================================
# Kubernetes Service for Lambda (ExternalName)
# ============================================================================
# Creates a service that points to the Lambda Function URL
# This allows the ext_authz filter to reference the Lambda as a K8s service

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
    external_name = local.lambda_function_url_host
  }
}
