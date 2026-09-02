# Pipeline CI/CD en GCP: Cloud Run + Terraform + GitHub Actions

Proyecto personal de aprendizaje. Despliega una aplicación contenerizada en Google Cloud Run,
con infraestructura definida como código en Terraform y un pipeline de CI/CD en GitHub Actions
que incluye validación, escaneo de seguridad y aprobación manual antes de producción.

---

## Por qué existe este proyecto

Vengo del lado de infraestructura tradicional y GRC: administración de sistemas, gestión de
identidades, continuidad operativa y análisis de brechas contra ISO 27001. Quería entender
DevOps y DevSecOps desde la práctica, no desde la teoría — específicamente cómo se aplican los
controles de seguridad que conozco en papel dentro de un flujo de despliegue automatizado.

El objetivo no era construir una aplicación compleja. La app es deliberadamente mínima: lo que
importa es la infraestructura alrededor, cómo se automatiza y cómo se asegura.

**Herramientas que quería aprender y por qué:**

| Herramienta | Qué quería entender |
|---|---|
| **GCP** | Cómo se estructuran proyectos, permisos y servicios en un proveedor cloud |
| **Docker** | Empaquetado de aplicaciones, inmutabilidad de imágenes, registries |
| **Terraform** | Infraestructura como código: versionado, reproducibilidad, gestión de estado |
| **GitHub Actions** | Automatización del ciclo build → test → deploy |
| **Checkov / Trivy** | Escaneo de seguridad integrado al pipeline (DevSecOps) |
| **Workload Identity Federation** | Autenticación entre sistemas sin credenciales estáticas |

---

## Arquitectura

```
Código (main.py + Dockerfile)
        ↓
GitHub Actions (orquestador)
        ↓
   ┌────┴────┬──────────────┬─────────────┐
   ↓         ↓              ↓             ↓
validate  build+scan   terraform-plan   deploy
(Checkov)  (Trivy)     (comenta en PR)  (requiere aprobación)
                                          ↓
                              Artifact Registry → Cloud Run
```

**Recursos en GCP:**

- **Cloud Run** — ejecuta el contenedor, escala a cero sin tráfico
- **Artifact Registry** — almacena las imágenes Docker
- **Cloud Storage** — guarda el estado de Terraform (con versionado)
- **IAM + Workload Identity Federation** — identidad del pipeline sin claves fijas

---

## Proceso: primero manual, después automatizado

Decidí ejecutar todo el flujo manualmente antes de automatizarlo. La razón es práctica: si
después algo falla en el pipeline, puedo distinguir entre "no entiendo qué debería pasar" y
"el código de automatización tiene un error".

### Fase 1 — Manual (para entender)

```bash
# 1. Habilitar servicios (en GCP todo viene apagado por defecto)
gcloud services enable run.googleapis.com artifactregistry.googleapis.com

# 2. Crear el repositorio de imágenes
gcloud artifacts repositories create api-repo-jve \
  --repository-format=docker --location=us-central1

# 3. Construir y probar la imagen localmente
docker build -t api-local-jve .
docker run -p 8080:8080 api-local-jve

# 4. Autenticar Docker contra Artifact Registry y subir
gcloud auth configure-docker us-central1-docker.pkg.dev
docker tag api-local-jve us-central1-docker.pkg.dev/PROJECT_ID/api-repo-jve/demo-api:v1
docker push us-central1-docker.pkg.dev/PROJECT_ID/api-repo-jve/demo-api:v1

# 5. Desplegar a Cloud Run
gcloud run deploy demo-api-jve-local \
  --image=us-central1-docker.pkg.dev/PROJECT_ID/api-repo-jve/demo-api:v1 \
  --region=us-central1 --allow-unauthenticated
```

### Fase 2 — Terraform (misma infraestructura, como código)

```
terraform/
├── providers.tf      # Plugin de Google Cloud
├── variables.tf      # Declaración de variables
├── main.tf           # Los recursos (Artifact Registry, Cloud Run, IAM)
├── outputs.tf        # URL del servicio al terminar
├── backend.tf        # Estado remoto en Cloud Storage
└── terraform.tfvars  # Valores reales (no versionado)
```

Como el repositorio de Artifact Registry ya existía (creado a mano en la Fase 1), usé
`terraform import` para que Terraform lo adoptara sin recrearlo:

```bash
terraform import google_artifact_registry_repository.repo \
  projects/PROJECT_ID/locations/us-central1/repositories/api-repo-jve
```

### Fase 3 — Estado remoto

El `.tfstate` vivía solo en mi máquina, así que el pipeline no sabía qué recursos ya existían
y quería recrearlos todos. Lo moví a un bucket de Cloud Storage con versionado activado:

```bash
gcloud storage buckets create gs://tfstate-jve-demo-gcp --location=us-central1
gcloud storage buckets update gs://tfstate-jve-demo-gcp --versioning
terraform init -migrate-state
```

### Fase 4 — Autenticación sin claves fijas

En vez de guardar una clave de service account en GitHub Secrets, configuré Workload Identity
Federation: GitHub emite un token OIDC temporal en cada ejecución, GCP lo valida contra reglas
que restringen el acceso a un repositorio específico, y presta los permisos de la service
account solo mientras dura el pipeline.

```bash
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --attribute-condition="assertion.repository=='usuario/repositorio'" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

### Fase 5 — Pipeline

Cuatro jobs encadenados:

| Job | Cuándo corre | Qué hace |
|---|---|---|
| `validate` | Siempre | `terraform fmt`, `validate`, escaneo Checkov |
| `build-and-scan-image` | Siempre | Construye la imagen y la escanea con Trivy |
| `terraform-plan` | Solo en PRs | Genera el plan y lo comenta en el Pull Request |
| `deploy` | Solo en push a `main` | Build, push, apply y despliegue — requiere aprobación manual |

Un workflow separado (`destroy.yml`) permite destruir la infraestructura, pero solo de forma
manual y escribiendo una palabra de confirmación. Nunca se dispara automáticamente.

---

## Decisiones de seguridad y por qué

**Menor privilegio en IAM.** La service account del pipeline tiene solo los roles que necesita
(`run.admin`, `artifactregistry.writer`, `iam.serviceAccountUser`, `serviceusage.serviceUsageAdmin`),
no `Owner` ni `Editor`. Cada permiso se agregó cuando un error del pipeline lo pidió
explícitamente, no "por si acaso".

**Sin credenciales estáticas.** Workload Identity Federation elimina el riesgo de una clave
filtrada: no hay nada permanente que robar, y el acceso está restringido por condición al
repositorio autorizado.

**Aprobación humana antes de producción.** Aunque todas las validaciones automáticas pasen, el
deploy queda pausado esperando aprobación explícita, que queda registrada con usuario y
timestamp. Automatización no significa ausencia de control, significa control en el punto
correcto.

**El plan se revisa antes de aplicarse.** En cada Pull Request, el pipeline publica el
`terraform plan` como comentario. Nada llega a `main` sin que alguien haya visto qué va a
cambiar — en particular, qué se va a destruir.

**Protección del estado.** El `.tfstate` contiene el inventario detallado de la infraestructura.
Está en un bucket con acceso controlado por IAM y versionado activo, nunca en el repositorio.

---

## Hallazgo de Checkov: decisión documentada

El escaneo reporta `CKV_GCP_84`: Artifact Registry no usa claves de cifrado gestionadas por el
cliente (CMEK).

**Es un hallazgo válido.** Decidí no implementarlo porque CMEK requiere Cloud KMS (costo
adicional) y una política de rotación de claves que no se justifica para un proyecto demo sin
datos sensibles. En un entorno productivo con datos regulados, sí lo implementaría.

El pipeline usa `soft_fail: true` para que los hallazgos se reporten sin bloquear el flujo. En
producción usaría `false` con umbral de severidad, bloqueando ante hallazgos críticos.

---

## Sobre Kubernetes

El proyecto usa Cloud Run, no GKE. Fue una decisión, no una omisión.

Para una aplicación única, sin comunicación compleja entre servicios ni necesidad de control
granular sobre la orquestación, Cloud Run resuelve el problema con menos superficie de
mantenimiento y menor costo. Kubernetes tiene sentido cuando se necesita control directo sobre
nodos, pods, redes internas o múltiples microservicios interdependientes — nada de eso aplica aquí.

Cloud Run usa tecnología de orquestación de contenedores por debajo (Knative sobre Kubernetes),
pero de forma completamente administrada: no hay clúster que gestionar.

---

## Problemas encontrados y cómo se resolvieron

Documento esto porque el troubleshooting fue la parte más útil del proyecto.

| Problema | Causa | Solución |
|---|---|---|
| `PERMISSION_DENIED` al leer el bucket | Faltaba habilitar `iamcredentials.googleapis.com` | Habilitar la API; WIF la requiere de forma implícita |
| `SERVICE_DISABLED` en Cloud Resource Manager | Terraform necesita consultar servicios del proyecto | Habilitar `cloudresourcemanager` y `serviceusage` |
| `AUTH_PERMISSION_DENIED` en `serviceusage.services.list` | La service account no tenía ese permiso | Agregar rol `serviceusage.serviceUsageAdmin` |
| El pipeline quería recrear recursos existentes | Estado local, no compartido con el runner | Migrar el estado a Cloud Storage |
| `terraform: command not found` en el deploy | Cada job corre en una VM limpia; faltaba instalar Terraform en ese job | Agregar `hashicorp/setup-terraform` al job |
| Secret llegaba vacío | Typo en el nombre del secret (`GCP_PROJECTI_ID`) | Recrear con el nombre correcto |

El patrón común: mi usuario personal tenía permisos amplios de forma implícita; la service
account del pipeline necesitaba cada permiso de forma explícita. Eso es exactamente el
principio de menor privilegio funcionando.

---

## Stack utilizado

**Cloud:** Google Cloud Platform — Cloud Run, Artifact Registry, Cloud Storage, IAM, Workload Identity Federation
**IaC:** Terraform (provider `google`), backend remoto en GCS
**Contenedores:** Docker
**CI/CD:** GitHub Actions
**Seguridad:** Checkov (IaC), Trivy (imágenes), OIDC, RBAC granular
**Aplicación:** Python 3.12 + Flask

---

## Cómo reproducirlo

```bash
# Requisitos: gcloud CLI, Terraform, Docker, cuenta de GCP con facturación activa

# 1. Configurar el proyecto
gcloud config set project TU_PROJECT_ID
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com cloudresourcemanager.googleapis.com serviceusage.googleapis.com

# 2. Crear el bucket para el estado
gcloud storage buckets create gs://TU_BUCKET --location=us-central1
gcloud storage buckets update gs://TU_BUCKET --versioning

# 3. Ajustar backend.tf y terraform.tfvars con tus valores

# 4. Configurar Workload Identity Federation (ver Fase 4)

# 5. Cargar los secrets en GitHub: GCP_PROJECT_ID, WIF_PROVIDER, WIF_SERVICE_ACCOUNT

# 6. Desplegar
cd terraform && terraform init && terraform apply
```

**Para destruir todo:**
```bash
terraform destroy
```
O usar el workflow `destroy.yml` desde la interfaz de GitHub Actions.

---

## Qué sigue

- Gestionar los secrets de GitHub con el provider de Terraform para GitHub, en vez de configurarlos a mano
- Separar el bootstrap (WIF, service accounts) de la infraestructura de aplicación en stacks distintos
- Probar el mismo despliegue sobre GKE para comparar el modelo administrado contra la orquestación directa
