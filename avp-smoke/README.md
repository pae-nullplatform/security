# AVP Smoke - Amazon Verified Permissions Authorization

Este modulo implementa autorizacion de endpoints usando Amazon Verified Permissions (AVP) integrado con Istio Service Mesh.

## Modos de Deployment

El authorizer soporta tres modos de deployment:

| Modo | Arquitectura | Uso recomendado |
|------|--------------|-----------------|
| **lambda** (default) | Istio → ALB (HTTP) → Lambda | Serverless, bajo/medio volumen |
| **lambda-proxy** | Istio → Nginx Pod → Lambda URL (HTTPS) | Sin costo ALB, latencia media |
| **in-cluster** | Istio → Pod Authorizer | Alta performance, alto volumen |

> Ver [COMPARATIVA.md](./COMPARATIVA.md) para un analisis detallado de cada modo.

## Arquitectura

### Modo `lambda` (ALB → Lambda)

```
Cliente HTTP
     |
     | Authorization: Bearer <JWT>
     v
Istio Gateway
     |
     v
AuthorizationPolicy (CUSTOM)
     |
     v
Internal ALB (HTTP:80)     <-- Workaround Istio #57676
     |
     v
Lambda Function
     |
     | IsAuthorized API
     v
Amazon Verified Permissions
     |
     v
ALLOW / DENY
```

### Modo `lambda-proxy` (Nginx → Lambda)

```
Cliente HTTP
     |
     | Authorization: Bearer <JWT>
     v
Istio Gateway
     |
     v
AuthorizationPolicy (CUSTOM)
     |
     v
Nginx Proxy Pod (HTTP:80)
     |
     | HTTPS (443)
     v
Lambda Function URL
     |
     | IsAuthorized API
     v
Amazon Verified Permissions
     |
     v
ALLOW / DENY
```

### Modo `in-cluster` (Pod directo)

```
Cliente HTTP
     |
     | Authorization: Bearer <JWT>
     v
Istio Gateway
     |
     v
AuthorizationPolicy (CUSTOM)
     |
     v
AVP Ext-Authz Pod (HTTP:9191)
     |
     | IsAuthorized API
     v
Amazon Verified Permissions
     |
     v
ALLOW / DENY
```

## Configuracion Rapida

### terraform.tfvars

```hcl
project              = "my-project"
environment          = "dev"
aws_region           = "us-east-1"
eks_cluster_name     = "my-cluster"
kubernetes_namespace = "gateways"

# Selector del gateway
gateway_selector = {
  "gateway.networking.k8s.io/gateway-name" = "gateway-public"
}

# Hosts y paths protegidos
protected_hosts = ["api.example.com"]
protected_paths = ["/api/*", "/admin/*"]

# Modo de deployment (ver COMPARATIVA.md para elegir)
authorizer_mode = "lambda"  # "lambda", "lambda-proxy", o "in-cluster"
```

### Comandos

```bash
# Inicializar
tofu init

# Ver plan
tofu plan

# Aplicar
tofu apply
```

## Variables Principales

### Configuracion General

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `authorizer_mode` | Modo: "lambda", "lambda-proxy", "in-cluster" | "lambda" |
| `project` | Nombre del proyecto | - |
| `environment` | Ambiente | - |
| `aws_region` | Region de AWS | - |
| `eks_cluster_name` | Nombre del cluster EKS | - |
| `kubernetes_namespace` | Namespace para recursos | - |

### Configuracion de Seguridad

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `gateway_selector` | Labels del gateway Istio | {} |
| `protected_hosts` | Hosts a proteger | [] |
| `protected_paths` | Paths a proteger | [] |
| `httproute_policies` | Policies por HTTPRoute (Istio 1.22+) | {} |

### Configuracion Lambda (modos `lambda` y `lambda-proxy`)

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `lambda_memory_size` | Memoria en MB | 256 |
| `lambda_timeout` | Timeout en segundos | 10 |
| `lambda_reserved_concurrency` | Concurrencia reservada (-1 = sin reserva) | -1 |
| `log_level` | Nivel de logs (DEBUG, INFO, WARNING, ERROR) | INFO |

### Configuracion Pod (modos `in-cluster` y `lambda-proxy`)

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `authorizer_replicas` | Numero de replicas | 2 |

## Estructura de Archivos

```
avp-smoke/
├── main.tf                           # Policy Store, Schema, Policies, IAM (in-cluster), ECR
├── lambda.tf                         # Lambda function (lambda y lambda-proxy)
├── lambda_alb.tf                     # ALB interno (solo lambda)
├── authorization_policy.tf           # ConfigMap Istio (todos los modos)
├── authorization_policy_in_cluster.tf    # Recursos in-cluster
├── authorization_policy_lambda.tf        # Recursos lambda (ALB)
├── authorization_policy_lambda_proxy.tf  # Recursos lambda-proxy (Nginx)
├── variables.tf                      # Variables de configuracion
├── outputs.tf                        # Outputs del modulo
├── providers.tf                      # AWS, Kubernetes, Docker providers
├── backend.tf                        # Backend S3
├── terraform.tfvars                  # Valores de variables
├── schema.json                       # Schema Cedar para AVP
├── policies/                         # Politicas Cedar
│   ├── allow_authenticated_read.cedar
│   ├── allow_smoke_access.cedar
│   └── deny_expired_tokens.cedar
├── authorizer/                       # Codigo del autorizador
│   ├── server.py                     # HTTP server (in-cluster)
│   ├── lambda_handler.py             # Lambda handler (lambda/lambda-proxy)
│   ├── Dockerfile                    # Imagen Docker (in-cluster)
│   └── requirements.txt              # Dependencias Python
├── COMPARATIVA.md                    # Comparativa detallada de modos
└── test-tokens.txt                   # Tokens JWT para pruebas
```

## Debugging

### Modo `lambda`

```bash
# Logs de Lambda
aws logs tail /aws/lambda/<project>-<env>-avp-authorizer --follow

# Estado del ALB
aws elbv2 describe-target-health --target-group-arn <arn>
```

### Modo `lambda-proxy`

```bash
# Logs del nginx proxy
kubectl logs -n <namespace> -l app=avp-nginx-proxy -f

# Logs de Lambda
aws logs tail /aws/lambda/<project>-<env>-avp-authorizer --follow
```

### Modo `in-cluster`

```bash
# Logs del pod
kubectl logs -n <namespace> -l app=avp-ext-authz -f

# Estado de pods
kubectl get pods -n <namespace> -l app=avp-ext-authz
```

### Istio

```bash
# AuthorizationPolicies
kubectl get authorizationpolicies -n <namespace>

# Extension providers
kubectl get cm istio -n istio-system -o yaml | grep -A20 extensionProviders
```

## Outputs

| Output | Descripcion |
|--------|-------------|
| `policy_store_id` | ID del Policy Store de AVP |
| `authorizer_mode` | Modo actual |
| `lambda_function_url` | URL de Lambda (lambda/lambda-proxy) |
| `lambda_alb_dns` | DNS del ALB interno (solo lambda) |
| `ecr_repository_url` | URL del ECR (solo in-cluster) |
| `ext_authz_service` | FQDN del servicio ext-authz |

## Migracion entre Modos

Cambiar de modo es simple - solo actualizar `authorizer_mode`:

```hcl
# Cambiar de lambda a lambda-proxy
authorizer_mode = "lambda-proxy"
```

```bash
tofu apply
```

> **Nota:** Durante la transicion habra un breve periodo donde las requests pueden fallar. Planificar en ventana de mantenimiento.
