# MongoDB Atlas — aprovisionamiento

Pasos para levantar desde cero el cluster que usa esta capa NoSQL. Ya se
hizo una vez para este proyecto; documentado aquí para poder reproducirlo
(otro integrante, otra cuenta, o si hay que recrearlo).

## 1. Crear el cluster

1. Entrar a [cloud.mongodb.com](https://cloud.mongodb.com) y crear/entrar a
   un proyecto.
2. "Create" → elegir el tier gratuito (M0) o el que corresponda — alcanza
   de sobra para el volumen de datos de este proyecto (~53k documentos en
   `sensor_logs`).
3. Elegir la región más cercana a Centroamérica disponible en el tier
   (normalmente `us-east-1`), para minimizar latencia — esto también
   alimenta el análisis de latencia de `docs/03_costo_beneficio.md`.

## 2. Usuario de base de datos con rol mínimo

Database Access → Add New Database User:
- Autenticación por password (no X.509 para esta demo).
- Rol: `readWrite` **solo** sobre la base `globalhealth`, no `readWriteAnyDatabase`.
- Nunca reutilizar el usuario/contraseña de administración del proyecto Atlas
  para la aplicación.

## 3. IP Access List

Network Access → Add IP Address:
- Para desarrollo local: la IP pública de cada integrante.
- **Nunca dejar `0.0.0.0/0` permanentemente** en la entrega final; se usó
  temporalmente solo para poder ejecutar los scripts de seed/verificación
  desde un entorno sin IP fija durante el desarrollo. Antes de la defensa,
  restringir a las IPs reales del aula/laptops.

## 4. Connection string (SRV) y TLS

Connect → Drivers → Node.js → copiar el URI:

```
mongodb+srv://<usuario>:<password>@<cluster>.mongodb.net/?retryWrites=true&w=majority
```

- TLS va implícito en `mongodb+srv://` (Atlas lo exige siempre, no es
  opcional).
- Verificar TLS real: `openssl s_client -connect <cluster>.mongodb.net:27017 -tls1_2` o simplemente confirmar que la conexión falla si se intenta `mongodb://` plano sin `+srv`.
- La URI completa (con password) va **solo** en `.env` → variable `MONGODB_URI`. Nunca en el repo, nunca en `mongo/*.js`.

## 5. Aplicar el esquema y los datos

Con `.env` completo en la raíz del repo:

```bash
set -a; . ./.env; set +a
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
  mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/01_schema_validators.js
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
  mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/02_seed.js
docker run --rm -v "$(pwd)/mongo:/mongo" mongo:7 \
  mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" /mongo/03_queries_agregacion.js
```

(No hace falta instalar `mongosh` localmente: se usa el contenido de la
imagen oficial `mongo:7`, que ya lo incluye.)

## 6. Verificación rápida de que todo quedó bien

```bash
docker run --rm mongo:7 mongosh "${MONGODB_URI}/${MONGODB_DB}?retryWrites=true&w=majority" --quiet --eval '
print("pacientes: " + db.pacientes.countDocuments());
print("sesiones: " + db.sesiones.countDocuments());
print("sensor_logs: " + db.sensor_logs.countDocuments());
'
```
