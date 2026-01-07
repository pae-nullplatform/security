# AVP Smoke - Amazon Verified Permissions Authorization

Este modulo implementa autorizacion de endpoints usando Amazon Verified Permissions (AVP) integrado con Istio Service Mesh.

## Modos de Deployment

El authorizer soporta dos modos de deployment:

| Modo | Descripcion | Uso recomendado |
|------|-------------|-----------------|
| **Pod** | Deployment de Kubernetes in-cluster | Baja latencia, alto volumen |
| **Lambda** | AWS Lambda con Function URL | Costo variable, serverless |

> Ver [COMPARATIVA.md](./COMPARATIVA.md) para un analisis detallado de cada modo.

## Arquitectura

### Modo Pod (in-cluster)

```
+------------------------------------------------------------------+
|                    Request Flow (Pod Mode)                        |
+------------------------------------------------------------------+

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
    AVP Ext-Authz Pod (Python:9191)
         |
         | IsAuthorized API
         v
    Amazon Verified Permissions
         |
         v
    ALLOW / DENY
```

### Modo Lambda (serverless)

```
+------------------------------------------------------------------+
|                    Request Flow (Lambda Mode)                     |
+------------------------------------------------------------------+

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
    ServiceEntry + DestinationRule
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

## Modos de AuthorizationPolicy

El modulo soporta dos formas de aplicar las policies de autorizacion:

### 1. Gateway Selector (Legacy)

Aplica la policy a todos los paths del gateway usando labels:

```hcl
gateway_selector = {
  "gateway.networking.k8s.io/gateway-name" = "gateway-public"
}
protected_paths = ["/smoke/*", "/api/*"]
```

### 2. HTTPRoute targetRef (Istio 1.22+)

Aplica la policy directamente a HTTPRoutes especificos:

```hcl
httproute_policies = {
  my-service = {
    httproute_name = "my-service"
    paths          = ["/smoke", "/smoke/*", "/api/*"]
    methods        = ["GET", "POST"]
  }
}
```

> **Recomendado:** HTTPRoute targetRef para control granular por servicio.

## Componentes

### 1. Amazon Verified Permissions (AVP)

```
+------------------------------------------------------------------+
|                    AVP Policy Store                               |
+------------------------------------------------------------------+
|                                                                   |
|  +-------------------+  +-------------------+  +----------------+ |
|  |      Schema       |  |     Policies      |  | Identity Source| |
|  +-------------------+  +-------------------+  +----------------+ |
|  |                   |  |                   |  |                | |
|  | - User            |  | - allow_auth_read |  | (Comentado     | |
|  | - Group           |  | - allow_smoke     |  |  para smoke    | |
|  | - Resource        |  | - deny_expired    |  |  test)         | |
|  | - Actions (CRUD)  |  |                   |  |                | |
|  +-------------------+  +-------------------+  +----------------+ |
+------------------------------------------------------------------+
```

### 2. AVP Authorizer (Pod o Lambda)

```
+------------------------------------------------------------------+
|                    AVP Authorizer Logic                           |
+------------------------------------------------------------------+
|                                                                   |
|  1. Extract JWT from Authorization header                         |
|  2. Decode payload (base64, no signature verification)            |
|  3. Check token expiration locally                                |
|  4. Extract user (sub) and groups                                 |
|  5. Build AVP entities (User, Group, Resource)                    |
|  6. Call IsAuthorized API                                         |
|  7. Return ALLOW (200) or DENY (401/403)                          |
|                                                                   |
|  Headers retornados:                                              |
|  - x-user-id: Subject del token                                   |
|  - x-avp-decision: ALLOW o DENY                                   |
|  - x-validated-by: amazon-verified-permissions                    |
|                                                                   |
+------------------------------------------------------------------+
```

### 3. Istio Integration

```
+------------------------------------------------------------------+
|                  Istio Configuration                              |
+------------------------------------------------------------------+
|                                                                   |
|  ConfigMap: istio (istio-system)                                 |
|  +------------------------------------------------------------+  |
|  | extensionProviders:                                         |  |
|  | - name: avp-ext-authz                                       |  |
|  |   envoyExtAuthzHttp:                                        |  |
|  |     service: <pod-service o lambda-externalname>            |  |
|  |     port: 9191 (pod) o 443 (lambda)                         |  |
|  |     includeRequestHeadersInCheck:                           |  |
|  |       - authorization                                       |  |
|  |       - x-forwarded-for                                     |  |
|  |     includeAdditionalHeadersInCheck:                        |  |
|  |       x-original-method: "%REQ(:METHOD)%"                   |  |
|  |       x-original-uri: "%REQ(:PATH)%"                        |  |
|  |       x-original-host: "%REQ(:AUTHORITY)%"                  |  |
|  +------------------------------------------------------------+  |
|                                                                   |
|  AuthorizationPolicy (HTTPRoute targetRef - Istio 1.22+)         |
|  +------------------------------------------------------------+  |
|  | spec:                                                       |  |
|  |   targetRef:                                                |  |
|  |     group: gateway.networking.k8s.io                        |  |
|  |     kind: HTTPRoute                                         |  |
|  |     name: my-httproute                                      |  |
|  |   action: CUSTOM                                            |  |
|  |   provider:                                                 |  |
|  |     name: avp-ext-authz                                     |  |
|  +------------------------------------------------------------+  |
|                                                                   |
+------------------------------------------------------------------+
```

## Politicas Cedar

### Schema (`schema.json`)

```
+------------------------------------------------------------------+
|                      Cedar Schema                                 |
+------------------------------------------------------------------+
|                                                                   |
|  Namespace: ApiAccess                                            |
|                                                                   |
|  +-------------------+  +-------------------+  +----------------+ |
|  |   Entity: User    |  |  Entity: Group    |  | Entity: Resource|
|  +-------------------+  +-------------------+  +----------------+ |
|  | Attributes:       |  | Attributes:       |  | Attributes:    | |
|  | - sub (String)    |  | - name (String)   |  | - path (String)| |
|  | - iss (String)    |  |                   |  | - method (Str) | |
|  | - email (String?) |  | memberOfTypes: [] |  | - host (String)| |
|  | - exp (Long?)     |  |                   |  |                | |
|  | - iat (Long?)     |  +-------------------+  +----------------+ |
|  |                   |                                           |
|  | memberOfTypes:    |                                           |
|  |   - Group         |                                           |
|  +-------------------+                                           |
|                                                                   |
|  Actions: GET, POST, PUT, DELETE, PATCH                          |
|  - appliesTo: User/Group -> Resource                             |
|                                                                   |
+------------------------------------------------------------------+
```

### Politicas

#### `allow_authenticated_read.cedar`
```cedar
// Permite GET a cualquier usuario autenticado
permit (
    principal,
    action == ApiAccess::Action::"GET",
    resource
);
```

#### `allow_smoke_access.cedar`
```cedar
// Permite GET/POST solo a usuarios del grupo smoke-testers
permit (
    principal in ApiAccess::Group::"smoke-testers",
    action in [ApiAccess::Action::"GET", ApiAccess::Action::"POST"],
    resource
);
```

## Matriz de Autorizacion

```
+------------------------------------------------------------------+
|                   Authorization Matrix                            |
+------------------------------------------------------------------+
|                                                                   |
|  Endpoint: /smoke/*                                              |
|  +------------------+-------+-------+-------+-------+-------+    |
|  | Principal/Action | GET   | POST  | PUT   | DELETE| PATCH |    |
|  +------------------+-------+-------+-------+-------+-------+    |
|  | No token         | 401   | 401   | 401   | 401   | 401   |    |
|  | Token expirado   | 401   | 401   | 401   | 401   | 401   |    |
|  | User (any group) | 200   | 403   | 403   | 403   | 403   |    |
|  | smoke-testers    | 200   | 200   | 403   | 403   | 403   |    |
|  +------------------+-------+-------+-------+-------+-------+    |
|                                                                   |
+------------------------------------------------------------------+
```

## Estructura de Archivos

```
avp-smoke/
├── main.tf                    # Policy Store, Schema, Policies, IAM, ECR
├── lambda.tf                  # Lambda function, Function URL, IAM
├── authorization_policy.tf    # Istio config (Pod/Lambda), AuthzPolicy
├── variables.tf               # Variables de configuracion
├── outputs.tf                 # Outputs del modulo
├── providers.tf               # AWS, Kubernetes, Docker, Archive providers
├── backend.tf                 # Backend S3
├── terraform.tfvars           # Valores de variables
├── schema.json                # Schema Cedar para AVP
├── policies/                  # Politicas Cedar
│   ├── allow_authenticated_read.cedar
│   ├── allow_smoke_access.cedar
│   └── deny_expired_tokens.cedar
├── authorizer/                # Codigo del autorizador
│   ├── server.py              # HTTP server Python (Pod mode)
│   ├── lambda_handler.py      # Lambda handler Python (Lambda mode)
│   ├── Dockerfile             # Imagen Docker (Pod mode)
│   └── requirements.txt       # Dependencias Python
├── COMPARATIVA.md             # Comparativa Pod vs Lambda
└── test-tokens.txt            # Tokens JWT para pruebas
```

## Configuracion

### Variables Principales

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `authorizer_mode` | Modo de deployment: "pod" o "lambda" | "pod" |
| `project` | Nombre del proyecto | - |
| `environment` | Ambiente | - |
| `aws_region` | Region de AWS | - |
| `eks_cluster_name` | Nombre del cluster EKS | - |
| `kubernetes_namespace` | Namespace para recursos | - |

### Variables HTTPRoute

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `httproute_policies` | Map de policies por HTTPRoute | {} |
| `gateway_selector` | Labels del gateway (legacy) | {} |
| `protected_paths` | Paths a proteger (legacy) | [] |

### Variables Pod Mode

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `authorizer_replicas` | Numero de replicas | 2 |
| `log_level` | Nivel de logs | "INFO" |

### Variables Lambda Mode

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `lambda_memory_size` | Memoria en MB | 256 |
| `lambda_timeout` | Timeout en segundos | 10 |
| `lambda_reserved_concurrency` | Concurrencia reservada (-1 = sin reserva) | -1 |

## Despliegue

### Configuracion minima (Lambda + HTTPRoute)

```hcl
# terraform.tfvars
project              = "my-project"
environment          = "dev"
aws_region           = "us-east-1"
eks_cluster_name     = "my-cluster"
kubernetes_namespace = "gateways"

# Authorizer mode
authorizer_mode = "lambda"

# HTTPRoute policies
httproute_policies = {
  my-service = {
    httproute_name = "my-service"
    paths          = ["/api/*"]
    methods        = ["GET", "POST"]
  }
}
```

### Comandos

```bash
cd security/avp-smoke

# Inicializar
tofu init

# Ver plan
tofu plan

# Aplicar
tofu apply
```

## Agregar Nuevos Servicios

Para proteger un nuevo HTTPRoute:

```hcl
httproute_policies = {
  # Servicio existente
  nginx-hello = {
    httproute_name = "nginx-hello"
    paths          = ["/smoke", "/smoke/*"]
    methods        = ["GET", "POST"]
  }

  # Nuevo servicio
  api-users = {
    httproute_name = "api-users"
    paths          = ["/users", "/users/*"]
    methods        = ["GET", "POST", "PUT", "DELETE"]
  }
}
```

Luego aplicar:
```bash
tofu apply
```

## Debugging

### Pod Mode

```bash
# Logs
kubectl logs -n <namespace> -l app=avp-ext-authz -f

# Status
kubectl get pods -n <namespace> -l app=avp-ext-authz
```

### Lambda Mode

```bash
# Logs
aws logs tail /aws/lambda/<project>-<env>-avp-authorizer --follow

# Test directo
curl https://<function-url>/health
```

### Istio

```bash
# AuthorizationPolicies
kubectl get authorizationpolicies -n <namespace>

# Extension providers
kubectl get cm istio -n istio-system -o yaml | grep -A20 extensionProviders

# Version (HTTPRoute targetRef requiere 1.22+)
kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Outputs

| Output | Descripcion |
|--------|-------------|
| `policy_store_id` | ID del Policy Store de AVP |
| `authorizer_mode` | Modo actual (pod/lambda) |
| `lambda_function_url` | URL de Lambda (solo lambda mode) |
| `ecr_repository_url` | URL del ECR (solo pod mode) |
| `ext_authz_service` | FQDN del servicio ext-authz |
| `httproute_policies` | Policies de HTTPRoute creadas |
