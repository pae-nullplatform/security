project     = "pae"
environment = "smoke"
aws_region  = "us-east-1"

# EKS Configuration
eks_cluster_name = "pae-infra"

# JWT Configuration
jwt_issuer       = "https://testing.secure.istio.io"
jwt_audiences    = ["api.pae-infra.nullapps.io"]
jwt_groups_claim = "groups"

# Kubernetes Configuration
kubernetes_namespace = "gateways"

gateway_selector = {
  "gateway.networking.k8s.io/gateway-name" = "gateway-public"
}

protected_paths = [
  "/smoke",
  "/smoke/*",
  "/created",
  "/created/*"
]

# Authorizer Pod Configuration
authorizer_image    = "235494813897.dkr.ecr.us-east-1.amazonaws.com/pae-smoke-avp-authorizer:latest"
authorizer_replicas = 2
log_level           = "INFO"

# Tags
tags = {
  owner = "pae-infra"
}
