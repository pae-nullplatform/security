# Comparativa de Modos de Deployment

Este documento analiza las diferencias entre los tres modos de deployment del authorizer para Amazon Verified Permissions.

## Resumen Ejecutivo

| Aspecto | `lambda` (ALB) | `lambda-proxy` (Nginx) | `in-cluster` (Pod) |
|---------|----------------|------------------------|---------------------|
| **Mejor para** | Simplicidad, serverless | Balance costo/latencia | Alto volumen, baja latencia |
| **Latencia P50** | ~40-60ms | ~30-50ms | ~15-25ms |
| **Costo fijo** | ~$16/mes (ALB) | ~$0 | ~$21/mes (pods) |
| **Costo variable** | ~$1.2/1M req | ~$1.2/1M req | $0 |
| **Cold starts** | Si | Si | No |
| **Escalado** | Automatico | Automatico + manual | Manual/HPA |
| **Complejidad** | Baja | Media | Media |

---

## Arquitectura por Modo

### Modo `lambda` (ALB → Lambda)

```
Istio Gateway
     │
     ▼
AuthorizationPolicy
     │
     ▼
┌─────────────────────┐
│   Internal ALB      │  ◄── Costo: ~$16/mes
│   (HTTP:80)         │
└─────────────────────┘
     │
     ▼
┌─────────────────────┐
│   Lambda Function   │  ◄── Costo: ~$1.2/1M requests
│   (via ALB invoke)  │
└─────────────────────┘
     │
     ▼
Amazon Verified Permissions
```

**Componentes AWS:**
- Application Load Balancer (interno)
- Lambda Function
- CloudWatch Logs
- IAM Role

### Modo `lambda-proxy` (Nginx → Lambda)

```
Istio Gateway
     │
     ▼
AuthorizationPolicy
     │
     ▼
┌─────────────────────┐
│   Nginx Proxy Pod   │  ◄── Costo: recursos del pod (~$2/mes)
│   (HTTP:80)         │
└─────────────────────┘
     │
     │ HTTPS (443)
     ▼
┌─────────────────────┐
│   Lambda Function   │  ◄── Costo: ~$1.2/1M requests
│   (via Function URL)│
└─────────────────────┘
     │
     ▼
Amazon Verified Permissions
```

**Componentes:**
- Nginx pods en Kubernetes (2 replicas default)
- Lambda Function + Function URL
- CloudWatch Logs
- IAM Role

### Modo `in-cluster` (Pod directo)

```
Istio Gateway
     │
     ▼
AuthorizationPolicy
     │
     ▼
┌─────────────────────┐
│   AVP Authorizer    │  ◄── Costo: ~$21/mes (pods)
│   Pod (HTTP:9191)   │
└─────────────────────┘
     │
     ▼
Amazon Verified Permissions
```

**Componentes:**
- Authorizer pods en Kubernetes (2 replicas default)
- ECR Repository
- IAM Role (IRSA)

---

## Comparativa Detallada

### 1. Latencia

| Componente | `lambda` | `lambda-proxy` | `in-cluster` |
|------------|----------|----------------|--------------|
| Network hop (Istio → servicio) | ~2ms | ~1ms | ~1ms |
| ALB processing | ~5-10ms | N/A | N/A |
| Nginx proxy | N/A | ~2-5ms | N/A |
| Lambda invoke (warm) | ~10-20ms | ~15-25ms | N/A |
| Lambda cold start | +100-300ms | +100-300ms | N/A |
| Pod processing | N/A | N/A | ~5-10ms |
| AVP API call | ~10-30ms | ~10-30ms | ~10-30ms |
| **Total (warm)** | **~30-60ms** | **~30-60ms** | **~15-40ms** |
| **Total (cold)** | **~150-400ms** | **~150-400ms** | **~15-40ms** |

**Ganador latencia:** `in-cluster` (sin cold starts, minimo network hops)

### 2. Costo

#### Costos fijos mensuales

| Componente | `lambda` | `lambda-proxy` | `in-cluster` |
|------------|----------|----------------|--------------|
| ALB (24/7) | ~$16.20 | $0 | $0 |
| Nginx pods (2x 50m CPU, 64Mi) | $0 | ~$2 | $0 |
| Authorizer pods (2x 100m CPU, 128Mi) | $0 | $0 | ~$5 |
| ECR storage | $0 | $0 | ~$1 |
| CloudWatch Logs | ~$0.50 | ~$0.50 | ~$0.50 |
| **Total fijo** | **~$16.70** | **~$2.50** | **~$6.50** |

#### Costos variables (por 1M requests)

| Componente | `lambda` | `lambda-proxy` | `in-cluster` |
|------------|----------|----------------|--------------|
| Lambda invocations | $0.20 | $0.20 | $0 |
| Lambda compute (256MB, 50ms avg) | ~$0.52 | ~$0.52 | $0 |
| Data transfer | ~$0.01 | ~$0.01 | $0 |
| **Total por 1M req** | **~$0.73** | **~$0.73** | **$0** |

#### Costo total mensual por volumen

| Requests/mes | `lambda` | `lambda-proxy` | `in-cluster` |
|--------------|----------|----------------|--------------|
| 100K | $16.77 | $2.57 | $6.50 |
| 1M | $17.43 | $3.23 | $6.50 |
| 5M | $20.35 | $6.15 | $6.50 |
| 10M | $24.00 | $9.80 | $6.50 |
| 20M | $31.30 | $17.10 | $6.50 |
| 50M | $53.20 | $39.00 | $6.50 |

**Punto de equilibrio:**
- `lambda-proxy` vs `in-cluster`: ~5.5M req/mes
- `lambda` vs `in-cluster`: ~13M req/mes

**Ganador costo bajo volumen (<5M):** `lambda-proxy`
**Ganador costo alto volumen (>10M):** `in-cluster`

### 3. Escalabilidad

| Aspecto | `lambda` | `lambda-proxy` | `in-cluster` |
|---------|----------|----------------|--------------|
| Escalado automatico | Si (Lambda) | Parcial (Lambda si, Nginx manual) | No (requiere HPA) |
| Concurrencia maxima | 1000+ | 1000+ (Lambda) | Limitado por pods |
| Scale to zero | No (ALB siempre activo) | No (Nginx siempre activo) | No |
| Tiempo de escalado | Instantaneo | Instantaneo (Lambda) | 30-60s (pods) |
| Burst handling | Excelente | Excelente | Requiere pre-scaling |

**Ganador escalabilidad:** `lambda` y `lambda-proxy` (empate)

### 4. Operaciones y Mantenimiento

| Aspecto | `lambda` | `lambda-proxy` | `in-cluster` |
|---------|----------|----------------|--------------|
| Deployment | Zip + upload | Zip + ConfigMap | Docker build + push |
| Actualizaciones | `tofu apply` | `tofu apply` | `tofu apply` + rollout |
| Logs | CloudWatch | kubectl + CloudWatch | kubectl |
| Metricas | CloudWatch | CloudWatch + Prometheus | Prometheus |
| Debugging | CloudWatch Insights | kubectl exec + CW | kubectl exec |
| Networking | ServiceEntry + ALB | ConfigMap nginx | Simple (ClusterIP) |

**Ganador simplicidad operacional:** `lambda` (menos componentes que manejar)

### 5. Resiliencia y Alta Disponibilidad

| Aspecto | `lambda` | `lambda-proxy` | `in-cluster` |
|---------|----------|----------------|--------------|
| HA built-in | Si (ALB + Lambda multi-AZ) | Parcial (Lambda si, pods manual) | Manual (replicas + anti-affinity) |
| SLA | 99.95% (Lambda) | 99.95% (Lambda) | Depende del cluster |
| Failover | Automatico | Automatico (Lambda) | Kubernetes |
| Single point of failure | ALB | Nginx pods | Authorizer pods |

**Ganador resiliencia:** `lambda` (managed services)

### 6. Cold Starts (solo modos Lambda)

| Factor | Impacto |
|--------|---------|
| Runtime Python 3.12 | ~100ms |
| Memoria 256MB | ~100ms adicional |
| Memoria 512MB | ~50ms adicional |
| Package size (boto3 built-in) | Minimo |
| VPC (no usado) | +200-500ms si se usara |

**Mitigaciones:**
1. **Provisioned Concurrency:** Elimina cold starts (~$15/mes por instancia)
2. **Keep-warm:** EventBridge cada 5 min (gratis)
3. **Mas memoria:** 512MB reduce cold start ~50ms

---

## Matriz de Decision

### Usar `lambda` cuando:

- [ ] Quieres maxima simplicidad operacional
- [ ] No tienes experiencia gestionando pods
- [ ] El trafico es bajo/medio (<10M req/mes)
- [ ] Cold starts ocasionales de ~200ms son aceptables
- [ ] Prefieres servicios managed de AWS

### Usar `lambda-proxy` cuando:

- [ ] Quieres evitar el costo del ALB (~$16/mes)
- [ ] El trafico es bajo/medio (<5M req/mes)
- [ ] Tienes experiencia basica con Kubernetes
- [ ] Cold starts ocasionales de ~200ms son aceptables
- [ ] Quieres el mejor balance costo/simplicidad

### Usar `in-cluster` cuando:

- [ ] La latencia <50ms es critica
- [ ] El trafico es alto (>10M req/mes)
- [ ] Ya tienes infraestructura K8s madura
- [ ] Quieres costo predecible sin sorpresas
- [ ] Los cold starts son inaceptables

---

## Configuracion Recomendada por Escenario

### Desarrollo / Staging

```hcl
authorizer_mode     = "lambda-proxy"  # Menor costo
lambda_memory_size  = 256
lambda_timeout      = 10
authorizer_replicas = 1               # Solo 1 replica en dev
log_level           = "DEBUG"
```

### Produccion - Bajo Volumen (<5M req/mes)

```hcl
authorizer_mode     = "lambda-proxy"
lambda_memory_size  = 512             # Reduce cold start
lambda_timeout      = 10
authorizer_replicas = 2
log_level           = "INFO"
```

### Produccion - Medio Volumen (5-15M req/mes)

```hcl
authorizer_mode     = "lambda"        # ALB mas robusto
lambda_memory_size  = 512
lambda_timeout      = 10
log_level           = "WARNING"
```

### Produccion - Alto Volumen (>15M req/mes)

```hcl
authorizer_mode     = "in-cluster"
authorizer_replicas = 3               # Mas replicas
log_level           = "WARNING"
```

### Produccion - Latencia Critica

```hcl
authorizer_mode     = "in-cluster"
authorizer_replicas = 4
log_level           = "ERROR"         # Minimo logging
```

---

## Resumen Final

| Criterio | Recomendacion |
|----------|---------------|
| **Startups / MVPs** | `lambda-proxy` |
| **Desarrollo local** | `in-cluster` (si tienes minikube) |
| **Produccion < 5M req/mes** | `lambda-proxy` |
| **Produccion 5-15M req/mes** | `lambda` |
| **Produccion > 15M req/mes** | `in-cluster` |
| **Latencia critica** | `in-cluster` |
| **Costo minimo** | `lambda-proxy` (bajo volumen) o `in-cluster` (alto volumen) |
| **Maxima simplicidad** | `lambda` |

**Recomendacion general:** Empezar con `lambda-proxy` y migrar a `in-cluster` si el volumen o latencia lo requieren.
