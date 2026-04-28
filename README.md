# JFrog Platform on AKS – Deployment Repository

This repository contains Helm values files and utility scripts for deploying the **JFrog Platform** (Artifactory + Xray) on Azure Kubernetes Service (AKS) with Azure Container Registry (ACR) and Azure Blob Storage.

---

## Repository Structure

| File | Purpose |
|------|---------|
| `values_nginx_ingress_external.yml` | Production Helm values – external-facing deployment with full HA |
| `values_nginx_ingress_internal.yml` | Test/dev Helm values – internal deployment with self-signed TLS |
| `CopyImagesToACR.sh` | Migrates JFrog Platform container images from JFrog's public registry to your ACR |
| `CopyImagesToJFrog.sh` | Migrates JFrog Platform container images from JFrog's public registry to a local JFrog repository |

---

## Values Files – Key Differences

| Setting | `external` (Production) | `internal` (Dev/Test) |
|---------|------------------------|-----------------------|
| `artifactory.replicaCount` | `2` | `1` |
| `xray.replicaCount` | `2` | `1` |
| **TLS certificate** | Valid cert — no insecure flags | Self-signed nip.io cert |
| `xray.router.serviceRegistry.insecure` | Not set (secure) | `true` — required for Xray to trust self-signed cert |
| `global.security.allowInsecureImages` | Not set | `true` |
| `serviceAccount.create` | `true` | `false` (SA must pre-exist) |
| `imagePullSecrets` | None (AKS-ACR integration) | `jfrog-registry-secret2` |
| **DB secrets method** | K8s secrets referenced directly | Azure Key Vault CSI Driver (`customVolumes` / `customVolumeMounts`) |
| `preUpgradeHook.enabled` | `true` | `false` |
| Persistence size | `480Gi` / maxCacheSize 200GB | `120Gi` / maxCacheSize 5GB |

> **Critical — `xray.router.serviceRegistry.insecure: true`:** Must be set whenever Artifactory is exposed over a self-signed or untrusted TLS certificate. Without it, Xray's router rejects the TLS handshake during service registration and Xray will fail to connect to Artifactory entirely.

> **Critical — ingress block placement:** In the external file, `ingress` is a child of the `artifactory` top-level key (`artifactory.ingress`). In the internal file it sits as a sibling of `artifactory.artifactory` at the same nesting level. This structural difference must be preserved exactly as the Helm chart resolves ingress config differently depending on placement.

---

## File Descriptions

### `values_nginx_ingress_external.yml`
Production-grade Helm values for the `jfrog-platform` chart targeting an external (internet-facing) AKS cluster.

**Key characteristics:**
- **Artifactory**: 2 replicas with pod anti-affinity across nodes, Azure Blob Storage V2 (direct) binary store (`480Gi`, `maxCacheSize: 200GB`), Azure Workload Identity for passwordless blob access
- **Xray**: 2 replicas with dedicated node pool affinity
- **RabbitMQ**: Single replica with HA Quorum enabled, dedicated node toleration
- **Ingress**: Defined as `artifactory.ingress` (nested inside the `artifactory` top-level block). NGINX ingress controller with trusted TLS cert from `artifactory-tls` secret — no insecure flags needed
- **TLS**: Valid certificate; Xray's router communicates securely with no special overrides
- **Secrets**: Database credentials sourced directly from pre-existing Kubernetes secrets (`artifactory-db-secret`, `xray-db-secret`) — no Key Vault CSI volume mounts required
- **Service Account**: `serviceAccount.create: true` — the SA is created by the chart
- **Image registry**: Private ACR (`acrregistry`), no explicit `imagePullSecrets` needed (relies on AKS-ACR integration)
- **PostgreSQL**: External (chart-managed PostgreSQL is disabled)
- **Pre-upgrade hook**: Enabled (`preUpgradeHook.enabled: true`)

**Before deploying**, update:
- `global.jfrogUrl` → your actual domain
- `artifactory.serviceAccount.annotations.azure.workload.identity/client-id` → your UAMI client ID
- `artifactory.artifactory.persistence.azureBlob.endpoint` → your storage account endpoint
- `global.joinKeySecretName` / `global.masterKeySecretName` → your key secret names

---

### `values_nginx_ingress_internal.yml`
Development/test Helm values for an internal AKS cluster using a self-signed (nip.io) certificate.

**Key characteristics:**
- **Artifactory**: 1 replica, Azure Blob Storage V2 (direct) binary store (`120Gi`, `maxCacheSize: 5GB`), Azure Workload Identity
- **Xray**: 1 replica. Critically, `xray.router.serviceRegistry.insecure: true` is set — this tells Xray's router to accept the self-signed certificate when communicating with Artifactory. **Without this, Xray will fail to register against Artifactory over a self-signed TLS endpoint.**
- **RabbitMQ**: Single replica with HA Quorum enabled
- **Ingress**: Defined at the `artifactory` top level (as a sibling of `artifactory.artifactory`, not nested inside it — structural difference from external). Uses a `nip.io` IP-based hostname with self-signed TLS cert
- **TLS**: Self-signed cert via `nip.io` wildcard hostname; `global.security.allowInsecureImages: true` permits pulling images without signature verification
- **Secrets**: Uses **Azure Key Vault CSI Driver** — both Artifactory and Xray have `customVolumes` / `customVolumeMounts` that mount the `jfrog-db-secrets` SecretProviderClass into `/mnt/secrets-store`. The `SecretProviderClass` must be applied to the cluster before `helm install`
- **Service Account**: `serviceAccount.create: false` — the SA must already exist in the namespace
- **Image registry**: `sumacr2.azurecr.io` with explicit `imagePullSecrets: [jfrog-registry-secret2]`
- **PostgreSQL**: External (chart-managed PostgreSQL is disabled)
- **Pre-upgrade hook**: Disabled (`preUpgradeHook.enabled: false`) for faster test iterations

**Before deploying**, update:
- `global.jfrogUrl` → your nip.io or test domain IP
- `artifactory.serviceAccount.annotations.azure.workload.identity/client-id` → your UAMI client ID
- `artifactory.artifactory.persistence.azureBlob.endpoint` → your storage account endpoint

---

### `CopyImagesToACR.sh`
Bash script that pulls all required JFrog Platform container images from `releases-docker.jfrog.io` and pushes them to your Azure Container Registry.

**Use this script when:**
- Your AKS cluster nodes cannot reach the public internet
- You need to air-gap or pre-stage images in ACR before deployment

**Usage:**
```bash
# 1. Log in to both registries
docker login releases-docker.jfrog.io   # JFrog credentials
az acr login --name <your-acr-name>

# 2. (Optional) Refresh image list for your chart version
helm template jfrog-platform jfrog/jfrog-platform \
  --version 11.5.0 \
  --set distribution.enabled=true \
  --set catalog.enabled=false \
  --set worker.enabled=true \
  2>/dev/null | grep 'image:' | \
  sed 's/.*image: *//;s/"//g;s/'"'"'//g;s/^ *//' | sort -u

# 3. Update the IMAGES array in the script with the output above
#    (always keep bitnami/rabbitmq:4.1.1-debian-12-r1)

# 4. Run the script (must be on a Linux/amd64 VM for correct image architecture)
chmod +x CopyImagesToACR.sh
./CopyImagesToACR.sh
```

**What it does:**
1. Iterates over the defined `IMAGES` list
2. Pulls each image from `releases-docker.jfrog.io`
3. Re-tags it for `<TARGET>/<TARGET_REPO>/<image>`
4. Pushes it to your ACR
5. Cleans up local Docker layers
6. Prints a final summary of successes and failures

**Configuration (edit at the top of the script):**
| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE` | `releases-docker.jfrog.io` | Source registry |
| `TARGET` | `testacr.azurecr.io` | Your ACR hostname |
| `TARGET_REPO` | `testacr-docker-local` | Repository path in ACR |
| `CHART_VERSION` | `11.5.0` | JFrog Platform chart version |

> **Note:** Run on a **Linux/amd64** host. Running on Apple Silicon (ARM) will produce ARM images that won't run on standard AKS node pools.

---

### `CopyImagesToJFrog.sh`
Bash script that pulls all required JFrog Platform container images from `releases-docker.jfrog.io` and pushes them to a **local JFrog Artifactory** Docker repository.

**Use this script when:**
- You want to proxy/cache images through your own Artifactory instance instead of ACR
- You are setting up a fully self-hosted image distribution pipeline

**Usage:**
```bash
# 1. Log in to both registries
docker login releases-docker.jfrog.io   # JFrog credentials
docker login <your-artifactory-url>     # Your Artifactory credentials

# 2. (Optional) Refresh image list for your chart version
helm template jfrog-platform jfrog/jfrog-platform \
  --version 11.5.0 \
  --set distribution.enabled=true \
  --set catalog.enabled=false \
  --set worker.enabled=true \
  2>/dev/null | grep 'image:' | \
  sed 's/.*image: *//;s/"//g;s/'"'"'//g;s/^ *//' | sort -u

# 3. Update the IMAGES array in the script
#    (always keep bitnami/rabbitmq:4.1.1-debian-12-r1)

# 4. Run on a Linux/amd64 VM
chmod +x CopyImagesToJFrog.sh
./CopyImagesToJFrog.sh
```

**What it does:**
1. Iterates over the defined `IMAGES` list
2. Pulls each image from `releases-docker.jfrog.io`
3. Re-tags it for your local JFrog Docker repository
4. Pushes it to Artifactory
5. Cleans up local Docker layers
6. Prints a final migration summary

**Configuration (edit at the top of the script):**
| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE` | `releases-docker.jfrog.io` | Source registry |
| `TARGET` | `testacr.azurecr.io` | Your Artifactory hostname |
| `TARGET_REPO` | `testacr-docker-local` | Docker local repo name in Artifactory |
| `CHART_VERSION` | `11.5.0` | JFrog Platform chart version |

> **Note:** Run on a **Linux/amd64** host to ensure correct image architecture.

---

## Prerequisites

- AKS cluster with dedicated node pools: `artifactory`, `xray`, `rabbitmq` (and optionally `nginx`)
- Azure Container Registry (ACR) accessible from AKS
- Azure Storage Account with a container named `artifactory-binstore`
- User-Assigned Managed Identity (UAMI) with **Storage Blob Data Contributor** role on the storage account
- Kubernetes secrets pre-created:
  - `artifactory-db-secret` (keys: `db-user`, `db-password`, `db-url`)
  - `xray-db-secret` (keys: `db-user`, `db-password`, `db-url`)
  - `artifactory-tls` (TLS cert/key)
  - Join key and master key secrets (names configurable in values)
- `helm` CLI with the JFrog chart repository added:
  ```bash
  helm repo add jfrog https://charts.jfrog.io
  helm repo update
  ```

---

## Deployment

```bash
# Install / upgrade
helm upgrade --install jfrog-platform jfrog/jfrog-platform \
  --version 11.5.0 \
  --namespace jfrog \
  --create-namespace \
  -f values_nginx_ingress_external.yml \
  --set gaUpgradeReady=true
```

After deployment, if AKS nodes have cached stale images, drain and re-image the nodes or manually remove the old image layers.

---

## Chart Version

All files in this repository are validated against **JFrog Platform Helm chart version `11.5.0`** (Artifactory `7.146.7` / Xray `3.137.27`).
