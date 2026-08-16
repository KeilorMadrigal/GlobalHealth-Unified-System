# Análisis costo/beneficio — Self-hosted vs. MongoDB Atlas

> ⚠️ **Antes de defender este documento:** las cifras de este documento se
> tomaron de búsquedas web en agosto de 2026 (ver fuentes al pie de cada
> tabla) y son indicativas. Los precios de nube cambian con frecuencia y
> varían por región/promoción. **Verifiquen los números marcados
> `[VERIFICAR]` directamente en las páginas oficiales el día antes de
> entregar** — presentar una cifra desactualizada como si fuera exacta es
> exactamente el tipo de cosa que se pincha en la defensa.

## 1. Costos mensuales comparados

Escenario: 3 nodos equivalentes a los de este proyecto (1 réplica de
escritura + 1 de lectura + almacenamiento de metadatos, dimensionado para
una carga pequeña/mediana como la de un piloto regional — no producción a
gran escala).

| Concepto | Self-hosted (VM propia) | MongoDB Atlas | Fuente / nota |
|---|---|---|---|
| Cómputo/instancia mensual | 3 × Droplet 2 vCPU / 4 GB ≈ 3 × $24 = **$72/mes** | Cluster dedicado tier **M10** ≈ **$57/mes** (~$0.08/hora, 24/7) | DigitalOcean Droplet pricing; MongoDB Atlas pricing — `[VERIFICAR]` tier y región exactos el día de la entrega |
| Almacenamiento | Incluido hasta ~80 GB en el Droplet base; extra por GB/mes si se excede | Incluido en el tier M10 hasta el límite del disco contratado; IOPS y storage adicional se facturan aparte | `[VERIFICAR]` cotización de storage adicional si el volumen de `sensor_logs` crece más allá de lo estimado |
| Transferencia de salida | 4000 GiB incluidos en el Droplet base, $0.01/GiB adicional | Primeros GB de salida gratis según tier, luego tarifa por GB | `[VERIFICAR]` |
| Backups | Snapshots manuales o programados: costo adicional (~20% del costo del droplet en DigitalOcean si se activa) | Backups continuos incluidos o con costo adicional según tier | `[VERIFICAR]` |
| **Horas de operación (DBA)** | Estimado: 4 h/mes de mantenimiento (parches, monitoreo, troubleshooting de réplicas) × $15/h estimado = **$60/mes** | ≈ 0 (gestionado por Atlas: parches, failover, backups automatizados) | Estimación propia — ajustar a la tarifa real del equipo |
| **Costo de una hora de caída** | Depende del caso de uso: para un sistema clínico regional, estimar (usuarios activos simultáneos) × (costo de indisponibilidad por usuario/hora). Ejemplo ilustrativo: 50 usuarios × $2/hora = **$100/hora de caída** | Igual base de cálculo, pero con SLA de Atlas (99.95% en clusters dedicados) reduciendo la probabilidad esperada de incidente | `[VERIFICAR]` el SLA exacto del tier contratado |
| **TCO 12 meses (solo cómputo + DBA)** | ($72 + $60) × 12 = **$1,584/año** | $57 × 12 = **$684/año** | Sin contar backups/transferencia adicional (ver filas de arriba) |

## 2. Punto de equilibrio

Con las cifras de la tabla, el self-hosted parte **más caro** que Atlas M10
en este dimensionamiento (por las horas de DBA), así que no hay un punto de
equilibrio "a favor" del self-hosted en el rango pequeño — Atlas conviene
desde el inicio a esta escala. El cruce típico ocurre en sentido contrario:
Atlas deja de convenir cuando el volumen de datos/tráfico crece lo
suficiente como para necesitar tiers altos (M40+), donde el costo por nodo
de un clúster gestionado con 3 réplicas de voto supera claramente el costo
de operar VMs propias con un DBA ya contratado a tiempo completo (cuyo
costo marginal por hora adicional de mantenimiento tiende a cero). Fórmula
general para estimarlo caso por caso:

```
GB_equilibrio = (costo_DBA_mensual_self_hosted) / (costo_Atlas_por_GB - costo_self_hosted_por_GB)
```

`[VERIFICAR]` con cifras reales de storage por GB de ambos lados antes de
presentar un número concreto de GB de equilibrio.

## 3. Latencia por región centroamericana

MongoDB Atlas permite elegir región de despliegue (AWS/GCP/Azure); la más
cercana a Centroamérica sin salir de Norteamérica suele ser `us-east-1`
(Virginia). Un datacenter propio contratado localmente en Centroamérica
tendría menor latencia teórica, pero:

- Los proveedores de VM económicos con presencia real *en* Centroamérica
  son escasos; la mayoría de "regiones cercanas" siguen siendo EE.UU. o
  México.
- La diferencia de latencia entre `us-east-1` y un datacenter local para
  operaciones CRUD normales (no *streaming* de video ni juegos en tiempo
  real) es del orden de decenas de milisegundos — aceptable para
  telemetría clínica con la cadencia de este proyecto (lecturas cada pocos
  segundos, no en tiempo real estricto).

`[VERIFICAR]` con una medición real: `ping cluster0.xxxxx.mongodb.net` y
comparar contra la latencia a un droplet en la misma región desde la red
del aula.

## 4. Riesgos

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| *Vendor lock-in* con Atlas (agregaciones, `$jsonSchema`, Atlas Search) | Media | Medio | El driver de MongoDB es estándar; migrar a un Mongo self-hosted es factible (`mongodump`/`mongorestore`), aunque se pierden features gestionadas (backups continuos, Atlas Search). |
| Soberanía de datos médicos (datos de pacientes centroamericanos en un datacenter de EE.UU.) | Media | Alto | Revisar la normativa de protección de datos de salud de cada país (CR/GT/HN) antes de producción real; para este proyecto académico no aplica, pero es un punto que el profesor puede preguntar directamente. |
| Cumplimiento normativo (HIPAA-like, según país) | Baja (proyecto académico) / Alta (producción real) | Alto | Atlas ofrece configuraciones para cumplimiento (cifrado en reposo, auditoría) en tiers pagos; se necesitaría contratarlas explícitamente. |
| Costo elástico impredecible si el tráfico crece sin control | Baja a esta escala | Medio | Configurar alertas de facturación en Atlas; el self-hosted tiene costo fijo más predecible pero no escala automáticamente. |
| Dependencia de conectividad a Internet para la capa NoSQL | Media | Alto (afecta telemetría, no MOR/XML que quedan en la red local) | El backend degrada explícitamente: `/health` reporta Atlas caído por separado, sin tumbar el resto del sistema (ver Fase 6). |

## Fuentes usadas para las cifras indicativas de este documento

- [MongoDB Pricing Explained: A 2026 Guide (CloudZero)](https://www.cloudzero.com/blog/mongodb-pricing/)
- [Droplet Pricing — DigitalOcean](https://www.digitalocean.com/pricing/droplets)
