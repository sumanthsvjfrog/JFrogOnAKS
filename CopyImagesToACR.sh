#!/bin/bash
# migrate-images.sh
# Migrates JFrog Platform images to Azure Container Registry (ACR)
# Run on Linux/amd64 VM for correct architecture
#
# Prerequisites:
#   az login (or use service principal env vars below)
#   az acr login --name testacr
#
# To refresh image list, run:
#   helm template jfrog-platform jfrog/jfrog-platform \
#     --version 11.5.0 \
#     --set distribution.enabled=true \
#     --set catalog.enabled=false \
#     --set worker.enabled=true \
#     2>/dev/null | grep 'image:' | \
#     sed 's/.*image: *//;s/"//g;s/'"'"'//g;s/^ *//' | sort -u

SOURCE="releases-docker.jfrog.io"
TARGET="testacr.azurecr.io"
CHART_VERSION="11.5.0"

echo "========================================"
echo "JFrog Platform Image Migration"
echo "Chart Version: $CHART_VERSION"
echo "Source: $SOURCE"
echo "Target: $TARGET"
echo "========================================"

# ---------------------------------------------------------------------------
# Login to ACR (skip if already logged in)
# ---------------------------------------------------------------------------
echo ""
echo "Logging in to ACR: $TARGET"
if ! az acr login --name testacr; then
  echo "ERROR: Failed to login to ACR. Ensure 'az login' has been run first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Image list for chart version 11.5.0
# bitnami/rabbitmq:4.1.1-debian-12-r1 is intentionally kept alongside the
# older 3.x tag that the chart may still reference.
# ---------------------------------------------------------------------------
IMAGES=(
  "bitnami/kubectl:1.31.2"
  "bitnami/postgresql:17.6.0-debian-12-r2"
  "bitnami/rabbitmq:3.13.7-debian-12-r8"
  "bitnami/rabbitmq:4.1.1-debian-12-r1"
  "jfrog/artifactory-pro:7.146.7"
  "jfrog/distribution-distribution:2.38.0"
  "jfrog/nginx-artifactory-pro:7.146.7"
  "jfrog/observability:2.24.0"
  "jfrog/observability:2.31.0"
  "jfrog/observability:2.32.0"
  "jfrog/observability:2.33.0"
  "jfrog/router:7.193.7"
  "jfrog/router:7.205.10"
  "jfrog/router:7.320.7"
  "jfrog/worker:1.179.0"
  "jfrog/xray-analysis:3.137.27"
  "jfrog/xray-indexer:3.137.27"
  "jfrog/xray-persist:3.137.27"
  "jfrog/xray-policyenforcer:3.137.27"
  "jfrog/xray-server:3.137.27"
  "ubi9/ubi-minimal:9.7.1764794109"
  "ubi9/ubi-minimal:9.7.1773939694"
)

SUCCESS=0
FAILED=0
FAILED_IMAGES=""

echo ""
echo "Starting migration of ${#IMAGES[@]} images..."
echo "========================================"

for IMAGE in "${IMAGES[@]}"; do
  echo ""
  echo "Processing: $IMAGE"
  echo "----------------------------------------"

  SOURCE_IMAGE="$SOURCE/$IMAGE"
  TARGET_IMAGE="$TARGET/$IMAGE"

  # Pull from source (releases-docker.jfrog.io)
  if docker pull "$SOURCE_IMAGE"; then
    echo "  Pulled: $SOURCE_IMAGE"
  else
    echo "  FAILED to pull: $SOURCE_IMAGE"
    FAILED=$((FAILED + 1))
    FAILED_IMAGES="$FAILED_IMAGES\n  - $IMAGE"
    continue
  fi

  # Verify architecture
  ARCH=$(docker inspect "$SOURCE_IMAGE" --format '{{.Architecture}}' 2>/dev/null)
  echo "  Architecture: $ARCH"
  if [[ "$ARCH" != "amd64" ]]; then
    echo "  WARNING: Expected amd64, got $ARCH — verify this VM is linux/amd64"
  fi

  # Tag for ACR (no repo-prefix segment — ACR uses registry/image:tag)
  docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"

  # Push to ACR
  if docker push "$TARGET_IMAGE"; then
    echo "  Pushed: $TARGET_IMAGE"
    SUCCESS=$((SUCCESS + 1))
  else
    echo "  FAILED to push: $TARGET_IMAGE"
    FAILED=$((FAILED + 1))
    FAILED_IMAGES="$FAILED_IMAGES\n  - $IMAGE"
  fi

  # Cleanup local images to preserve disk space
  docker rmi "$SOURCE_IMAGE" "$TARGET_IMAGE" 2>/dev/null

done

echo ""
echo "========================================"
echo "Migration Summary"
echo "========================================"
echo "  Total images : ${#IMAGES[@]}"
echo "  Successful   : $SUCCESS"
echo "  Failed       : $FAILED"

if [ -n "$FAILED_IMAGES" ]; then
  echo ""
  echo "Failed images:"
  echo -e "$FAILED_IMAGES"
  exit 1
fi

echo ""
echo "========================================"
echo "Next Steps"
echo "========================================"
echo "1. Verify images in ACR:"
echo "   az acr repository list --name sumacr2 --output table"
echo ""
echo "2. Clean cached images from AKS nodes (if using node image cache)"
echo ""
echo "3. Deploy with:"
echo "   helm upgrade --install jfrog-platform jfrog/jfrog-platform \\"
echo "     --version $CHART_VERSION \\"
echo "     --set global.imageRegistry=$TARGET"
echo "========================================"
