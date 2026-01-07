# Comparativa: Pod vs Lambda como Authorizer

Este documento analiza las diferencias entre usar un Pod de Kubernetes o una Lambda de AWS como authorizer para Amazon Verified Permissions.

## Resumen Ejecutivo

| Aspecto | Pod | Lambda |
|---------|-----|--------|
| **Mejor para** | Alto volumen, baja latencia | Trafico variable, costo optimizado |
| **Latencia** | 1-5ms | 10-100ms (+ cold start) |
| **Costo** | Fijo (pods running 24/7) | Variable (por invocacion) |
| **Escalado** | Manual/HPA | Automatico |
| **Complejidad** | Media | Baja |

---

## Comparativa Detallada

### Latencia

```
+------------------------------------------------------------------+
|                    Latencia por Modo                              |
+------------------------------------------------------------------+
|                                                                   |
|  Pod Mode:                                                        |
|  +------------------+                                             |
|  | Request          | ~1-5ms (in-cluster network)                 |
|  | AVP API call     | ~10-30ms                                    |
|  | Total            | ~15-35ms                                    |
|  +------------------+                                             |
|                                                                   |
|  Lambda Mode:                                                     |
|  +------------------+                                             |
|  | Request          | ~5-20ms (external HTTPS)                    |
|  | Cold start       | 100-500ms (primera invocacion)              |
|  | AVP API call     | ~10-30ms                                    |
|  | Total (warm)     | ~20-50ms                                    |
|  | Total (cold)     | ~150-550ms                                  |
|  +------------------+                                             |
|                                                                   |
+------------------------------------------------------------------+
```

| Escenario | Pod | Lambda (warm) | Lambda (cold) |
|-----------|-----|---------------|---------------|
| P50 | ~20ms | ~30ms | ~200ms |
| P95 | ~35ms | ~60ms | ~400ms |
| P99 | ~50ms | ~100ms | ~550ms |

**Ganador:** Pod (si la latencia es critica)

---

### Costo

```
+------------------------------------------------------------------+
|                    Modelo de Costos                               |
+------------------------------------------------------------------+
|                                                                   |
|  Pod Mode (2 replicas, t3.small equivalent):                      |
|  +------------------+                                             |
|  | CPU: 200m        | ~$15/mes (reservado)                        |
|  | Memory: 256Mi    | ~$5/mes                                     |
|  | ECR storage      | ~$1/mes                                     |
|  | Total fijo       | ~$21/mes                                    |
|  +------------------+                                             |
|                                                                   |
|  Lambda Mode (256MB, 50ms avg):                                   |
|  +------------------+                                             |
|  | 1M requests      | $0.20                                       |
|  | Compute          | $0.52 (1M x 50ms x 256MB)                   |
|  | Function URL     | Gratis                                      |
|  | CloudWatch       | ~$0.50/mes                                  |
|  | Total variable   | ~$1.22/1M requests                          |
|  +------------------+                                             |
|                                                                   |
+------------------------------------------------------------------+
```

| Volumen mensual | Costo Pod | Costo Lambda | Diferencia |
|-----------------|-----------|--------------|------------|
| 100K requests | $21 | $0.12 | Pod +$20.88 |
| 1M requests | $21 | $1.22 | Pod +$19.78 |
| 10M requests | $21 | $12.20 | Pod +$8.80 |
| 20M requests | $21 | $24.40 | Lambda +$3.40 |
| 50M requests | $21 | $61.00 | Lambda +$40 |

**Punto de equilibrio:** ~17M requests/mes

**Ganador:**
- < 17M req/mes: Lambda
- > 17M req/mes: Pod

---

### Escalado

```
+------------------------------------------------------------------+
|                    Comportamiento de Escalado                     |
+------------------------------------------------------------------+
|                                                                   |
|  Pod Mode:                                                        |
|  +------------------+                                             |
|  | Replicas fijas   | 2 (configurable)                            |
|  | HPA              | Requiere configuracion adicional            |
|  | Tiempo escalar   | 30-60s (crear nuevos pods)                  |
|  | Limite           | Recursos del cluster                        |
|  +------------------+                                             |
|                                                                   |
|  Lambda Mode:                                                     |
|  +------------------+                                             |
|  | Concurrencia     | Automatica (hasta 1000 por defecto)         |
|  | Reservada        | Configurable                                |
|  | Tiempo escalar   | Instantaneo (nuevas instancias)             |
|  | Limite           | Cuota de cuenta AWS                         |
|  +------------------+                                             |
|                                                                   |
+------------------------------------------------------------------+
```

| Caracteristica | Pod | Lambda |
|----------------|-----|--------|
| Escalado automatico | No (requiere HPA) | Si |
| Tiempo de escalado | 30-60s | Instantaneo |
| Scale to zero | No | Si |
| Configuracion | Manual | Automatica |

**Ganador:** Lambda (para cargas variables)

---

### Operaciones

```
+------------------------------------------------------------------+
|                    Complejidad Operacional                        |
+------------------------------------------------------------------+
|                                                                   |
|  Pod Mode:                                                        |
|  +------------------+                                             |
|  | Deploy           | Build imagen -> Push ECR -> Update K8s     |
|  | Logs             | kubectl logs                                |
|  | Metricas         | Prometheus/Grafana                          |
|  | Networking       | In-cluster (simple)                         |
|  | Secrets          | IRSA + ServiceAccount                       |
|  +------------------+                                             |
|                                                                   |
|  Lambda Mode:                                                     |
|  +------------------+                                             |
|  | Deploy           | Zip -> Upload Lambda                        |
|  | Logs             | CloudWatch Logs                             |
|  | Metricas         | CloudWatch Metrics                          |
|  | Networking       | ServiceEntry + DestinationRule (complejo)   |
|  | Secrets          | IAM Role directo                            |
|  +------------------+                                             |
|                                                                   |
+------------------------------------------------------------------+
```

| Tarea | Pod | Lambda |
|-------|-----|--------|
| Deployment | Mas pasos | Menos pasos |
| Debugging | kubectl exec/logs | CloudWatch |
| Networking | Simple | Requiere Istio config |
| CI/CD | Docker build | Zip/SAM |

**Ganador:** Depende del equipo y herramientas existentes

---

### Resiliencia

```
+------------------------------------------------------------------+
|                    Modelo de Resiliencia                          |
+------------------------------------------------------------------+
|                                                                   |
|  Pod Mode:                                                        |
|  +------------------+                                             |
|  | HA               | Multi-replica + anti-affinity               |
|  | Failover         | Kubernetes maneja pod failures              |
|  | Health checks    | Liveness + Readiness probes                 |
|  | Dependencias     | EKS cluster debe estar healthy              |
|  +------------------+                                             |
|                                                                   |
|  Lambda Mode:                                                     |
|  +------------------+                                             |
|  | HA               | Multi-AZ automatico                         |
|  | Failover         | AWS maneja failures                         |
|  | Health checks    | Automatico                                  |
|  | Dependencias     | Solo Lambda + VPC (si aplica)               |
|  +------------------+                                             |
|                                                                   |
+------------------------------------------------------------------+
```

| Aspecto | Pod | Lambda |
|---------|-----|--------|
| Disponibilidad | 99.9% (con config) | 99.95% (SLA AWS) |
| Punto de falla | Cluster EKS | Servicio Lambda |
| Recovery | Manual/Auto (HPA) | Automatico |

**Ganador:** Lambda (para simplicidad de HA)

---

### Cold Starts

El cold start es la principal desventaja de Lambda:

```
+------------------------------------------------------------------+
|                    Impacto de Cold Starts                         |
+------------------------------------------------------------------+
|                                                                   |
|  Factores que afectan cold start:                                 |
|  +------------------+----------------------------------------+    |
|  | Factor           | Impacto                                |    |
|  +------------------+----------------------------------------+    |
|  | Runtime          | Python 3.12: ~100ms                    |    |
|  | Memory           | 256MB: ~100ms, 1024MB: ~50ms           |    |
|  | Package size     | boto3 built-in: minimo                 |    |
|  | VPC              | +200-500ms (no usado aqui)             |    |
|  +------------------+----------------------------------------+    |
|                                                                   |
|  Mitigaciones:                                                    |
|  +------------------+----------------------------------------+    |
|  | Provisioned      | Elimina cold starts ($)                |    |
|  | Keep-warm        | Ping periodico (cron)                  |    |
|  | Reserved conc.   | Garantiza capacidad                    |    |
|  +------------------+----------------------------------------+    |
|                                                                   |
+------------------------------------------------------------------+
```

**Estrategias de mitigacion:**

1. **Provisioned Concurrency** - Costo adicional pero elimina cold starts
2. **Keep-warm con EventBridge** - Invocar Lambda cada 5 min
3. **Memoria aumentada** - Mas memoria = CPU mas rapida = cold start menor

---

## Matriz de Decision

Use esta matriz para decidir que modo usar:

```
+------------------------------------------------------------------+
|                    Cuando usar cada modo                          |
+------------------------------------------------------------------+
|                                                                   |
|  USAR POD cuando:                                                 |
|  [ ] Latencia < 50ms es critica                                   |
|  [ ] Volumen > 20M requests/mes                                   |
|  [ ] Ya tienes infraestructura K8s madura                         |
|  [ ] Necesitas debugging con kubectl                              |
|  [ ] Quieres costo predecible                                     |
|                                                                   |
|  USAR LAMBDA cuando:                                              |
|  [ ] Trafico es variable/impredecible                             |
|  [ ] Volumen < 20M requests/mes                                   |
|  [ ] Quieres simplicidad operacional                              |
|  [ ] Prefieres pago por uso                                       |
|  [ ] Cold starts de ~200ms son aceptables                         |
|                                                                   |
+------------------------------------------------------------------+
```

---

## Configuracion Recomendada

### Para desarrollo/staging:
```hcl
authorizer_mode = "lambda"
lambda_memory_size = 256
lambda_timeout = 10
```

### Para produccion alto volumen:
```hcl
authorizer_mode = "pod"
authorizer_replicas = 3
log_level = "WARNING"
```

### Para produccion bajo/medio volumen:
```hcl
authorizer_mode = "lambda"
lambda_memory_size = 512  # Reduce cold start
lambda_timeout = 10
lambda_reserved_concurrency = 10  # Garantiza capacidad
```

---

## Migracion entre modos

Cambiar de Pod a Lambda (o viceversa) es simple:

```hcl
# Antes (Pod)
authorizer_mode = "pod"

# Despues (Lambda)
authorizer_mode = "lambda"
```

```bash
tofu apply
```

Terraform/OpenTofu manejara:
- Destruir recursos del modo anterior
- Crear recursos del nuevo modo
- Actualizar configuracion de Istio

> **Nota:** Habra un breve periodo donde las requests fallaran durante la transicion. Planificar en ventana de mantenimiento.

---

## Conclusiones

| Criterio | Recomendacion |
|----------|---------------|
| **Startups/MVPs** | Lambda |
| **Desarrollo local** | Pod (si tienes minikube/kind) |
| **Produccion < 20M req/mes** | Lambda |
| **Produccion > 20M req/mes** | Pod |
| **Latencia critica** | Pod |
| **Costo variable preferido** | Lambda |
| **Simplicidad operacional** | Lambda |

**Recomendacion general:** Empezar con Lambda y migrar a Pod si el volumen o latencia lo requieren.
