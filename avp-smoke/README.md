# AVP Smoke - Amazon Verified Permissions Authorization

Este modulo implementa autorizacion de endpoints usando Amazon Verified Permissions (AVP) integrado con Istio Service Mesh.

## Arquitectura

```
+------------------------------------------------------------------+
|                        Request Flow                               |
+------------------------------------------------------------------+

    Cliente HTTP
         |
         | 1. GET/POST /smoke/ o /created
         |    Authorization: Bearer <JWT>
         v
+------------------+
|   AWS ALB        |
|   (HTTPS:443)    |
+--------+---------+
         |
         | 2. Forward to Istio Gateway
         v
+------------------+
| Istio Gateway    |
| (gateway-public) |
+--------+---------+
         |
         | 3. AuthorizationPolicy intercepta
         |    paths protegidos
         v
+------------------+
| AuthzPolicy      |
| (CUSTOM action)  |
+--------+---------+
         |
         | 4. Envia request a ext-authz
         |    Headers: x-original-method, x-original-uri
         v
+------------------+
| AVP Ext-Authz    |
| Pod (Python)     |
+--------+---------+
         |
         | 5. Decodifica JWT
         | 6. Valida expiracion
         | 7. Extrae grupos
         v
+------------------+
| Amazon Verified  |
| Permissions      |
| (IsAuthorized)   |
+--------+---------+
         |
         | 8. Evalua politicas Cedar
         v
+------------------+
| Decision:        |
| ALLOW / DENY     |
+--------+---------+
         |
         | 9a. ALLOW: Continua al backend
         | 9b. DENY: Retorna 401/403
         v
+------------------+
| Backend Pod      |
| (nginx-hello)    |
+------------------+
```

## Componentes

### 1. Amazon Verified Permissions (AVP)

```
+------------------------------------------------------------------+
|                    AVP Policy Store                               |
|                 (<policy-store-id>)                               |
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
|  |                   |  |                   |  |                | |
|  +-------------------+  +-------------------+  +----------------+ |
|                                                                   |
+------------------------------------------------------------------+
```

### 2. AVP Authorizer Pod

```
+------------------------------------------------------------------+
|                    AVP Ext-Authz Pod                              |
|                   (2 replicas, HA)                                |
+------------------------------------------------------------------+
|                                                                   |
|  +------------------------+    +-----------------------------+   |
|  |   HTTP Server          |    |   Authorization Logic       |   |
|  |   (Port 9191)          |    |                             |   |
|  +------------------------+    +-----------------------------+   |
|  |                        |    |                             |   |
|  | Endpoints:             |    | 1. Extract JWT from header  |   |
|  | - /health (healthz)    |    | 2. Decode payload (base64)  |   |
|  | - /* (auth check)      |    | 3. Check expiration         |   |
|  |                        |    | 4. Extract user & groups    |   |
|  | Headers recibidos:     |    | 5. Build AVP entities       |   |
|  | - authorization        |    | 6. Call IsAuthorized API    |   |
|  | - x-original-method    |    | 7. Return ALLOW/DENY        |   |
|  | - x-original-uri       |    |                             |   |
|  | - x-original-host      |    +-----------------------------+   |
|  |                        |                                      |
|  +------------------------+                                      |
|                                                                   |
|  +------------------------+    +-----------------------------+   |
|  |   IRSA (IAM Role)      |    |   Environment Variables     |   |
|  +------------------------+    +-----------------------------+   |
|  |                        |    |                             |   |
|  | Permisos:              |    | - POLICY_STORE_ID           |   |
|  | - verifiedpermissions: |    | - AWS_REGION                |   |
|  |   IsAuthorized         |    | - HTTP_PORT                 |   |
|  |   IsAuthorizedWithToken|    | - LOG_LEVEL                 |   |
|  |                        |    |                             |   |
|  +------------------------+    +-----------------------------+   |
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
|  |     service: avp-ext-authz.gateways.svc.cluster.local       |  |
|  |     port: 9191                                              |  |
|  |     includeRequestHeadersInCheck:                           |  |
|  |       - authorization                                       |  |
|  |       - x-forwarded-for                                     |  |
|  |     includeAdditionalHeadersInCheck:                        |  |
|  |       x-original-method: "%REQ(:METHOD)%"                   |  |
|  |       x-original-uri: "%REQ(:PATH)%"                        |  |
|  |       x-original-host: "%REQ(:AUTHORITY)%"                  |  |
|  |     headersToUpstreamOnAllow:                               |  |
|  |       - x-user-id                                           |  |
|  |       - x-avp-decision                                      |  |
|  |       - x-validated-by                                      |  |
|  +------------------------------------------------------------+  |
|                                                                   |
|  AuthorizationPolicy: avp-ext-authz-smoke (gateways)             |
|  +------------------------------------------------------------+  |
|  | spec:                                                       |  |
|  |   selector:                                                 |  |
|  |     matchLabels:                                            |  |
|  |       gateway.networking.k8s.io/gateway-name: gateway-public|  |
|  |   action: CUSTOM                                            |  |
|  |   provider:                                                 |  |
|  |     name: avp-ext-authz                                     |  |
|  |   rules:                                                    |  |
|  |   - to:                                                     |  |
|  |     - operation:                                            |  |
|  |         paths: ["/smoke", "/smoke/*", "/created", ...]      |  |
|  +------------------------------------------------------------+  |
|                                                                   |
+------------------------------------------------------------------+
```

## Politicas Cedar

### Schema (`schema.json`)

Define los tipos de entidades y acciones permitidas:

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

#### `deny_expired_tokens.cedar`
```cedar
// Placeholder - la expiracion se valida en el authorizer
forbid (
    principal,
    action,
    resource
)
when { false };
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
|  Endpoint: /created                                              |
|  +------------------+-------+-------+-------+-------+-------+    |
|  | Principal/Action | GET   | POST  | PUT   | DELETE| PATCH |    |
|  +------------------+-------+-------+-------+-------+-------+    |
|  | No token         | 401   | 401   | 401   | 401   | 401   |    |
|  | Token expirado   | 401   | 401   | 401   | 401   | 401   |    |
|  | User (any group) | 200   | 403   | 403   | 403   | 403   |    |
|  | smoke-testers    | 200   | 204   | 403   | 403   | 403   |    |
|  +------------------+-------+-------+-------+-------+-------+    |
|                                                                   |
+------------------------------------------------------------------+
```

## Estructura de Archivos

```
avp-smoke/
├── main.tf                 # Policy Store, Schema, Policies, IAM, ECR
├── authorization_policy.tf # Istio mesh config, AuthzPolicy, Deployment
├── variables.tf            # Variables de configuracion
├── outputs.tf              # Outputs del modulo
├── providers.tf            # AWS y Kubernetes providers
├── backend.tf              # Backend S3
├── terraform.tfvars        # Valores de variables
├── schema.json             # Schema Cedar para AVP
├── policies/               # Politicas Cedar
│   ├── allow_authenticated_read.cedar
│   ├── allow_smoke_access.cedar
│   └── deny_expired_tokens.cedar
├── authorizer/             # Codigo del autorizador
│   ├── server.py           # HTTP server Python
│   ├── Dockerfile          # Imagen Docker
│   └── requirements.txt    # Dependencias Python
└── test-tokens.txt         # Tokens JWT para pruebas
```

## Configuracion

### Variables Principales

| Variable | Descripcion | Default |
|----------|-------------|---------|
| `project` | Nombre del proyecto | `pae` |
| `environment` | Ambiente | `smoke` |
| `eks_cluster_name` | Nombre del cluster EKS | - |
| `kubernetes_namespace` | Namespace para el authorizer | `gateways` |
| `protected_paths` | Paths a proteger | `["/smoke", "/smoke/*"]` |
| `jwt_issuer` | Issuer del JWT | `https://testing.secure.istio.io` |
| `gateway_selector` | Labels del gateway | `{gateway.networking.k8s.io/gateway-name: gateway-public}` |
| `authorizer_image` | Imagen del authorizer | ECR URL |
| `authorizer_replicas` | Numero de replicas | `2` |
| `log_level` | Nivel de logs | `INFO` |

### Tokens JWT de Prueba

Los tokens se encuentran en `test-tokens.txt`:

```bash
# Cargar tokens
source test-tokens.txt

# Token expirado (401)
echo $TOKEN_EXPIRED

# Token valido sin grupo smoke-testers (GET: 200, POST: 403)
echo $TOKEN_VALID_NO_GROUP

# Token valido con grupo smoke-testers (GET/POST: 200)
echo $TOKEN_VALID_SMOKE
```

Estructura del payload JWT:
```json
{
  "sub": "test-user-smoke",
  "iss": "https://testing.secure.istio.io",
  "iat": 1767388951,
  "exp": 1767392551,
  "groups": ["smoke-testers"]
}
```

## Despliegue

### 1. Inicializar y aplicar

```bash
cd security/avp-smoke

# Inicializar Terraform
tofu init

# Ver plan
AWS_PROFILE=<aws-profile> tofu plan

# Aplicar
AWS_PROFILE=<aws-profile> tofu apply
```

### 2. Build y push del authorizer (si es necesario)

```bash
cd authorizer

# Login a ECR (usar el ECR repository URL del output de terraform)
aws ecr get-login-password --region <aws-region> --profile <aws-profile> | \
  docker login --username AWS --password-stdin <ecr-repository-url>

# Build
docker build -t <ecr-repository-url>:latest .

# Push
docker push <ecr-repository-url>:latest

# Restart pods para usar nueva imagen
kubectl rollout restart deployment avp-ext-authz -n gateways
```

> **Nota:** El `<ecr-repository-url>` se obtiene del output `ecr_repository_url` despues de aplicar Terraform.

## Modificar Politicas y Endpoints

### Agregar un nuevo endpoint protegido

Para proteger un nuevo endpoint (ej: `/api/users`):

```
+------------------------------------------------------------------+
|                    Proceso de Modificacion                        |
+------------------------------------------------------------------+
|                                                                   |
|  1. terraform.tfvars          2. tofu apply                      |
|  +---------------------+      +---------------------+             |
|  | protected_paths = [ |  --> | AuthorizationPolicy |             |
|  |   "/smoke/*",       |      | actualizada con     |             |
|  |   "/api/users/*"    |      | nuevos paths        |             |
|  | ]                   |      +---------------------+             |
|  +---------------------+                                          |
|                                                                   |
+------------------------------------------------------------------+
```

**Pasos:**

1. Editar `terraform.tfvars`:
```hcl
protected_paths = [
  "/smoke",
  "/smoke/*",
  "/created",
  "/created/*",
  "/api/users",      # Nuevo endpoint
  "/api/users/*"     # Incluir sub-rutas
]
```

2. Aplicar cambios:
```bash
AWS_PROFILE=<aws-profile> tofu apply
```

> **Nota:** No es necesario reiniciar pods. Istio detecta automaticamente los cambios en AuthorizationPolicy.

---

### Agregar un nuevo metodo HTTP

Para permitir nuevos metodos (ej: `PUT`, `DELETE`), modificar el schema y las politicas:

```
+------------------------------------------------------------------+
|                    Archivos a Modificar                           |
+------------------------------------------------------------------+
|                                                                   |
|  1. schema.json       2. policies/*.cedar    3. tofu apply       |
|  +--------------+     +------------------+   +----------------+   |
|  | actions:     | --> | permit (         |-->| Politicas      |   |
|  |   GET, POST, |     |   action in [    |   | actualizadas   |   |
|  |   PUT, DELETE|     |     PUT, DELETE  |   | en AVP         |   |
|  | )            |     |   ]              |   +----------------+   |
|  +--------------+     +------------------+                        |
|                                                                   |
+------------------------------------------------------------------+
```

**Pasos:**

1. Verificar que el metodo existe en `schema.json` (ya incluye GET, POST, PUT, DELETE, PATCH)

2. Crear o modificar politica Cedar en `policies/`:
```cedar
// policies/allow_admin_write.cedar
// Permite PUT/DELETE solo a usuarios del grupo admin
permit (
    principal in ApiAccess::Group::"admin",
    action in [ApiAccess::Action::"PUT", ApiAccess::Action::"DELETE"],
    resource
);
```

3. Registrar la politica en `main.tf`:
```hcl
resource "aws_verifiedpermissions_policy" "allow_admin_write" {
  policy_store_id = aws_verifiedpermissions_policy_store.main.id

  definition {
    static {
      description = "Allow admin group to modify resources"
      statement   = file("${path.module}/policies/allow_admin_write.cedar")
    }
  }

  depends_on = [aws_verifiedpermissions_schema.main]
}
```

4. Aplicar cambios:
```bash
AWS_PROFILE=<aws-profile> tofu apply
```

---

### Agregar un nuevo grupo de usuarios

Para crear permisos basados en un nuevo grupo (ej: `developers`):

```
+------------------------------------------------------------------+
|                    Flujo de Autorizacion por Grupo                |
+------------------------------------------------------------------+
|                                                                   |
|  JWT Token                    AVP Policy                          |
|  +------------------+         +---------------------------+       |
|  | {                |         | permit (                  |       |
|  |   "sub": "user1",|  -----> |   principal in            |       |
|  |   "groups": [    |         |     ApiAccess::Group::    |       |
|  |     "developers" |         |       "developers",       |       |
|  |   ]              |         |   action == ...           |       |
|  | }                |         | );                        |       |
|  +------------------+         +---------------------------+       |
|                                                                   |
+------------------------------------------------------------------+
```

**Pasos:**

1. Crear politica en `policies/allow_developers.cedar`:
```cedar
// Permite a developers hacer GET/POST en /api/*
permit (
    principal in ApiAccess::Group::"developers",
    action in [ApiAccess::Action::"GET", ApiAccess::Action::"POST"],
    resource
)
when {
    resource.path like "/api/*"
};
```

2. Registrar en `main.tf` y aplicar con `tofu apply`

3. Generar token de prueba con el grupo:
```python
payload = {
    "sub": "dev-user",
    "iss": "https://testing.secure.istio.io",
    "groups": ["developers"],  # Nuevo grupo
    "exp": int(time.time()) + 3600
}
```

---

### Modificar una politica existente

Para cambiar el comportamiento de una politica:

1. Editar el archivo `.cedar` correspondiente en `policies/`
2. Aplicar:
```bash
AWS_PROFILE=<aws-profile> tofu apply
```

> **Importante:** AVP valida las politicas contra el schema. Si la politica es invalida, Terraform fallara con un error de validacion.

---

### Resumen de archivos segun tipo de cambio

| Cambio | Archivos a modificar |
|--------|---------------------|
| Nuevo endpoint | `terraform.tfvars` (protected_paths) |
| Nuevo metodo HTTP | `schema.json` + `policies/*.cedar` + `main.tf` |
| Nuevo grupo | `policies/*.cedar` + `main.tf` |
| Modificar permisos | `policies/*.cedar` |
| Cambiar selector gateway | `terraform.tfvars` (gateway_selector) |

---

## Pruebas

### Ejecutar suite de pruebas

```bash
# Cargar tokens
source test-tokens.txt

# Dominio configurado en el HTTPRoute del pod de prueba (infrastructure/pod-test.yaml)
DOMAIN="<your-test-domain>"

# Test 1: Sin token (401)
curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN/smoke/"

# Test 2: Token expirado (401)
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_EXPIRED" \
  "https://$DOMAIN/smoke/"

# Test 3: GET con token valido (200)
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_VALID_NO_GROUP" \
  "https://$DOMAIN/smoke/"

# Test 4: POST sin grupo smoke-testers (403)
curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN_VALID_NO_GROUP" \
  "https://$DOMAIN/created"

# Test 5: POST con grupo smoke-testers (204)
curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN_VALID_SMOKE" \
  "https://$DOMAIN/created"
```

> **Nota:** El dominio debe estar configurado en el HTTPRoute del pod de prueba (`infrastructure/pod-test.yaml`) y External DNS debe haber creado el registro en Route53.

## Debugging

### Ver logs del authorizer

```bash
# Logs en tiempo real
kubectl logs -n gateways -l app=avp-ext-authz -f

# Ultimos 50 logs
kubectl logs -n gateways -l app=avp-ext-authz --tail=50
```

### Verificar recursos

```bash
# Pods
kubectl get pods -n gateways -l app=avp-ext-authz

# AuthorizationPolicy
kubectl describe authorizationpolicy avp-ext-authz-smoke -n gateways

# Mesh config
kubectl get configmap istio -n istio-system -o yaml | grep -A 20 extensionProviders
```

### Verificar AVP en AWS

```bash
# Policy Store (obtener el ID del output de terraform)
AWS_PROFILE=<aws-profile> aws verifiedpermissions list-policy-stores

# Politicas (usar policy_store_id del output)
AWS_PROFILE=<aws-profile> aws verifiedpermissions list-policies \
  --policy-store-id <policy-store-id>

# Test de autorizacion manual
AWS_PROFILE=<aws-profile> aws verifiedpermissions is-authorized \
  --policy-store-id <policy-store-id> \
  --principal 'entityType=ApiAccess::User,entityId=test-user' \
  --action 'actionType=ApiAccess::Action,actionId=GET' \
  --resource 'entityType=ApiAccess::Resource,entityId=resource:/smoke'
```

> **Nota:** El `<policy-store-id>` se obtiene del output `policy_store_id` despues de aplicar Terraform.

## Outputs

| Output | Descripcion |
|--------|-------------|
| `policy_store_id` | ID del Policy Store de AVP |
| `policy_store_arn` | ARN del Policy Store |
| `iam_role_arn` | ARN del IAM Role para IRSA |
| `ecr_repository_url` | URL del repositorio ECR |
| `ext_authz_service` | FQDN del servicio ext-authz |
| `protected_paths` | Lista de paths protegidos |
