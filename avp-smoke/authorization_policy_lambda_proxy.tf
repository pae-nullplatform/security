# ============================================================================
# Istio Authorization - Lambda Proxy Mode Configuration
# ============================================================================
# This file contains all resources specific to running the AVP authorizer
# via Lambda with an nginx proxy in the cluster.
#
# Architecture: Istio Gateway -> HTTP -> Nginx Proxy Pod -> HTTPS -> Lambda Function URL
#
# This mode provides:
# - No ALB cost (unlike "lambda" mode)
# - Lower latency than ALB mode (no extra network hop to AWS ALB)
# - Works around Istio issue #57676 (ext_authz only supports HTTP)
#
# Note: The Istio mesh config (extensionProviders) is now consolidated in
# authorization_policy.tf to prevent empty configmap during mode switches.
# ============================================================================

locals {
  # Extract Lambda Function URL host (remove https:// and trailing /)
  lambda_function_url_host = var.authorizer_mode == "lambda-proxy" ? (
    trimsuffix(trimprefix(aws_lambda_function_url.authorizer[0].function_url, "https://"), "/")
  ) : ""
}

# ============================================================================
# ConfigMap - Nginx Configuration
# ============================================================================

resource "kubernetes_config_map_v1" "nginx_proxy_config" {
  count = var.authorizer_mode == "lambda-proxy" ? 1 : 0

  metadata {
    name      = "avp-nginx-proxy-config"
    namespace = var.kubernetes_namespace
    labels = {
      app = "avp-nginx-proxy"
    }
  }

  data = {
    "nginx.conf" = <<-EOF
      worker_processes auto;
      error_log /dev/stderr warn;
      pid /tmp/nginx.pid;

      events {
        worker_connections 1024;
      }

      http {
        log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                        '$status $body_bytes_sent "$http_referer" '
                        '"$http_user_agent" rt=$request_time';

        access_log /dev/stdout main;

        # Temp paths for non-root
        client_body_temp_path /tmp/client_temp;
        proxy_temp_path /tmp/proxy_temp;
        fastcgi_temp_path /tmp/fastcgi_temp;
        uwsgi_temp_path /tmp/uwsgi_temp;
        scgi_temp_path /tmp/scgi_temp;

        upstream lambda {
          server ${local.lambda_function_url_host}:443;
          keepalive 10;
        }

        server {
          listen 8080;

          location /health {
            return 200 'OK';
            add_header Content-Type text/plain;
          }

          location / {
            proxy_pass https://lambda;
            proxy_ssl_server_name on;
            proxy_ssl_name ${local.lambda_function_url_host};

            proxy_http_version 1.1;
            proxy_set_header Host ${local.lambda_function_url_host};
            proxy_set_header Connection "";

            # Pass through all headers from Istio
            proxy_pass_request_headers on;

            # Timeouts
            proxy_connect_timeout 5s;
            proxy_send_timeout 10s;
            proxy_read_timeout 10s;
          }
        }
      }
    EOF
  }
}

# ============================================================================
# Deployment - Nginx Proxy
# ============================================================================

resource "kubernetes_deployment_v1" "nginx_proxy" {
  count = var.authorizer_mode == "lambda-proxy" ? 1 : 0

  metadata {
    name      = "avp-nginx-proxy"
    namespace = var.kubernetes_namespace
    labels = {
      app       = "avp-nginx-proxy"
      component = "authorization"
    }
  }

  spec {
    replicas = var.authorizer_replicas

    selector {
      match_labels = {
        app = "avp-nginx-proxy"
      }
    }

    template {
      metadata {
        labels = {
          app       = "avp-nginx-proxy"
          component = "authorization"
        }
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.25-alpine"

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 101 # nginx user
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.nginx_proxy_config[0].metadata[0].name
          }
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = {
                    app = "avp-nginx-proxy"
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

  depends_on = [kubernetes_config_map_v1.nginx_proxy_config]
}

# ============================================================================
# Service - Nginx Proxy
# ============================================================================

resource "kubernetes_service_v1" "nginx_proxy" {
  count = var.authorizer_mode == "lambda-proxy" ? 1 : 0

  metadata {
    name      = "avp-lambda-proxy"
    namespace = var.kubernetes_namespace
    labels = {
      app = "avp-nginx-proxy"
    }
  }

  spec {
    type = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    selector = {
      app = "avp-nginx-proxy"
    }
  }
}

# ============================================================================
# AuthorizationPolicy CUSTOM for Lambda Proxy Mode
# ============================================================================

resource "kubernetes_manifest" "lambda_proxy_authz_policy" {
  count = var.authorizer_mode == "lambda-proxy" && length(var.gateway_selector) > 0 && length(var.protected_paths) > 0 ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1"
    kind       = "AuthorizationPolicy"

    metadata = {
      name      = "avp-ext-authz-lambda-proxy"
      namespace = var.kubernetes_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "authorization"
        "authorizer-mode"              = "lambda-proxy"
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
    kubernetes_config_map_v1_data.istio_mesh_config,
    kubernetes_service_v1.nginx_proxy,
    kubernetes_deployment_v1.nginx_proxy
  ]
}
