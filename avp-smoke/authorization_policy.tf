# ============================================================================
# Istio Authorization Policy - Amazon Verified Permissions
# ============================================================================
# This policy configures Istio to use the AVP ext-authz Pod for
# authorization decisions on protected paths.
# ============================================================================

# ============================================================================
# Extension Provider Configuration (applied to Istio mesh config)
# ============================================================================

resource "kubernetes_config_map_v1_data" "istio_mesh_config" {
  metadata {
    name      = "istio"
    namespace = "istio-system"
  }

  data = {
    mesh = yamlencode({
      extensionProviders = [
        {
          name = "avp-ext-authz"
          envoyExtAuthzHttp = {
            service                      = "avp-ext-authz.${var.kubernetes_namespace}.svc.cluster.local"
            port                         = 9191
            includeRequestHeadersInCheck = ["authorization", "x-forwarded-for"]
            # Include original request attributes as headers for the authorizer
            includeAdditionalHeadersInCheck = {
              "x-original-method" = "%REQ(:METHOD)%"
              "x-original-uri"    = "%REQ(:PATH)%"
              "x-original-host"   = "%REQ(:AUTHORITY)%"
            }
            headersToUpstreamOnAllow  = ["x-user-id", "x-avp-decision", "x-validated-by"]
            headersToDownstreamOnDeny = ["x-avp-decision"]
          }
        }
      ]
    })
  }

  force = true
}

# ============================================================================
# Authorization Policy - Protect /smoke endpoints
# ============================================================================

resource "kubernetes_manifest" "avp_authz_policy" {
  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-smoke"
      namespace = var.kubernetes_namespace
    }

    spec = {
      # Apply to the gateway
      selector = {
        matchLabels = var.gateway_selector
      }

      # Use external authorization (AVP)
      action = "CUSTOM"
      provider = {
        name = "avp-ext-authz"
      }

      # Protect these paths
      rules = [
        {
          to = [
            {
              operation = {
                paths = var.protected_paths
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [kubernetes_config_map_v1_data.istio_mesh_config]
}

# ============================================================================
# ServiceAccount with IAM Role (IRSA)
# ============================================================================

resource "kubernetes_service_account_v1" "avp_ext_authz" {
  metadata {
    name      = "avp-ext-authz"
    namespace = var.kubernetes_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.avp_authorizer.arn
    }
    labels = {
      app = "avp-ext-authz"
    }
  }
}

# ============================================================================
# Deployment - AVP Authorizer Pod (gRPC native)
# ============================================================================

resource "kubernetes_deployment_v1" "avp_ext_authz" {
  metadata {
    name      = "avp-ext-authz"
    namespace = var.kubernetes_namespace
    labels = {
      app       = "avp-ext-authz"
      component = "authorization"
    }
  }

  spec {
    replicas = var.authorizer_replicas

    selector {
      match_labels = {
        app = "avp-ext-authz"
      }
    }

    template {
      metadata {
        labels = {
          app       = "avp-ext-authz"
          component = "authorization"
        }
        annotations = {
          # Disable Istio sidecar injection for the authorizer itself
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.avp_ext_authz.metadata[0].name

        container {
          name              = "authorizer"
          image             = docker_registry_image.authorizer.name
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 9191
            protocol       = "TCP"
          }

          env {
            name  = "POLICY_STORE_ID"
            value = aws_verifiedpermissions_policy_store.main.id
          }

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }

          env {
            name  = "HTTP_PORT"
            value = "9191"
          }

          env {
            name  = "LOG_LEVEL"
            value = var.log_level
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 9191
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 9191
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 1000
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # Anti-affinity for HA
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = {
                    app = "avp-ext-authz"
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
      }
    }
  }
}

# ============================================================================
# Service
# ============================================================================

resource "kubernetes_service_v1" "avp_ext_authz" {
  metadata {
    name      = "avp-ext-authz"
    namespace = var.kubernetes_namespace
    labels = {
      app = "avp-ext-authz"
    }
  }

  spec {
    type = "ClusterIP"

    port {
      name        = "http"
      port        = 9191
      target_port = 9191
      protocol    = "TCP"
    }

    selector = {
      app = "avp-ext-authz"
    }
  }
}
