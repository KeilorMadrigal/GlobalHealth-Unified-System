# GlobalHealth Unified System

## Caso de negocio

GlobalHealth es una red de clínicas centroamericanas que necesita unificar:
personal médico y clínicas (datos estructurados con relaciones complejas),
expedientes clínicos regulados (documentos semi-estructurados con esquema
normativo estricto), y telemetría de sensores de monitoreo/telemedicina
(alto volumen, escritura constante, esquema flexible). Un solo modelo de
datos no sirve para los tres dominios: de ahí la arquitectura híbrida.

## Stack elegido

| Capa | Tecnología |
|---|---|
| MOR (Objeto-Relacional) | PostgreSQL 16 (tipos compuestos, tablas tipadas, herencia) |
| XML + XSD | PostgreSQL 16 + PL/Python3u + lxml (XSD registrado y validado en el motor) |
| NoSQL | MongoDB Atlas (cluster real en la nube) |
| Replicación | Streaming replication nativa de PostgreSQL, maestro/esclavo en contenedores separados |
| Fragmentación | postgres_fdw + particionamiento declarativo en nodos separados (pg-norte / pg-sur) |
| Backend | Node.js + Express, con dos pools de conexión físicamente separados |
| Interfaz | HTML+JS simple, solo para demostrar el consumo de la API |

## Topología de contenedores

```
                        ┌────────────────────┐
   escrituras ────────► │  pg-master  :5432  │ ──WAL streaming──┐
                        │  MOR + XML + FDW   │                  │
                        │  (coordinador)     │                  ▼
                        └─────────┬──────────┘        ┌────────────────────┐
                                  │ postgres_fdw      │ pg-replica  :5433  │ ◄──── lecturas
                    ┌─────────────┴─────────────┐     │  HOT STANDBY (RO)  │
                    ▼                           ▼     └────────────────────┘
        ┌────────────────────┐      ┌────────────────────┐
        │ pg-norte    :5434  │      │ pg-sur      :5435  │
        │ frag. horizontal N │      │ frag. horizontal S │
        │ + frag. vertical   │      │ + frag. vertical   │
        └────────────────────┘      └────────────────────┘

        ┌────────────────────┐      ┌──────────────────────────┐
        │ api  :3000         │ ───► │ MongoDB Atlas (nube real) │
        │ poolMaster (W)     │      │ pacientes/sesiones/logs   │
        │ poolReplica (R)    │      └──────────────────────────┘
        │ mongoClient (Atlas)│
        └────────────────────┘
```

## RESTRICCIONES DURAS

Estas reglas existen porque violarlas hace fracasar el proyecto o pierde
puntos directamente en la cláusula anti-plagio de la rúbrica. No las
rompas aunque parezca más simple hacerlo.

1. **Nunca usar un solo pool de conexión para lecturas y escrituras.**
   El backend debe tener dos objetos `Pool` distintos, con host/puerto
   distintos, en archivos distintos (`pgMaster.js` / `pgReplica.js`).
   Nada de un solo pool con un `if`.

2. **Nunca insertar XML sin validación contra el XSD registrado en la BD.**
   La validación ocurre en el motor (PL/Python3u + lxml) vía trigger
   `BEFORE INSERT OR UPDATE`, no en la capa de aplicación. Insertar XML
   plano sin pasar por el XSD registrado pierde el apartado completo.

3. **`CREATE TABLE ... OF <tipo>` e `INHERITS` son incompatibles en
   PostgreSQL.** No intentar combinarlos. Solución: tablas tipadas para
   `clinica` y `equipo_medico`; herencia (`INHERITS`) para la jerarquía
   `persona → medico / enfermero / tecnico_laboratorio`.

4. **`plpython3u` no viene en la imagen oficial `postgres:16`.** Se
   construye una imagen propia con `postgresql-plpython3-16` y
   `python3-lxml`. Si no se puede instalar, usar el plan B (SQL Server
   2022 Express con `CREATE XML SCHEMA COLLECTION`) sin rehacer el resto.

5. **La réplica se crea con `pg_basebackup -R` y un replication slot**,
   nunca copiando el volumen a mano. Si `PGDATA` de la réplica no está
   vacío, `pg_basebackup` falla.

6. **El esclavo es read-only por el motor, no por la app.** Un `INSERT`
   en la réplica debe fallar con `cannot execute INSERT in a read-only
   transaction`. Ese error es evidencia a favor, no un bug a esconder.

7. **Nunca commitear credenciales de MongoDB Atlas.** Solo `.env`
   (excluido de git) + `.env.example` con placeholders. En Atlas: usuario
   con rol mínimo, IP Access List configurada, TLS obligatorio.

8. **Particiones foráneas requieren `postgres_fdw` con la opción
   `updatable`.** Verificar el enrutamiento de cada `INSERT` con
   `EXPLAIN`, no asumirlo.

9. **Fragmentación vertical: ambas tablas comparten exactamente la misma
   PK** (`id_paciente`). La reconstrucción es un `JOIN` por esa llave —
   debe poder mostrarse la consulta que reconstruye la relación completa.

10. **Ensayar el apagado del master varias veces.** Escenario esperado:
    `docker stop pg-master` → las lecturas siguen respondiendo → las
    escrituras fallan con un error controlado (503 desde la API, nunca
    un crash del backend).

## Estructura del repositorio

Ver `PLAN_GlobalHealth_Proyecto_Final.md` sección 0.3 para el árbol
completo de carpetas y su propósito.

## Cómo trabajar en este repo

- El proyecto avanza por fases (ver `PLAN_GlobalHealth_Proyecto_Final.md`).
  No adelantar contenido de una fase posterior mientras se trabaja en una
  anterior.
- Cada fase tiene criterios de aceptación explícitos en el plan: no se
  considera terminada hasta poder verificarlos.
- Todo el SQL de negocio vive en `sql/*.sql`, numerado por orden de
  ejecución.
- Las credenciales solo viven en variables de entorno (`.env`, nunca en
  el repo).
