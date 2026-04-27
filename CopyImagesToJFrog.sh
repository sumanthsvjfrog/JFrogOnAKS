#!/bin/bash
# migrate-images.sh
# Migrates JFrog Platform images to local repo
# Run on Linux/amd64 VM for correct architecture

Run the command below before running script and get details and update the IMAGES section, please make sure to keep bitnami/rabbitmq:4.1.1-debian-12-r1 
#helm template jfrog-platform jfrog/jfrog-platform   --version 11.5.0   --set distribution.enabled=true   --set catalog.enabled=false   --set worker.enabled=true   2>/dev/null | grep 'image:' |   sed 's/.*image: *//;s/"//g;s/'"'"'//g;s/^ *//' | sort -u

SOURCE="releases-docker.jfrog.io"
TARGET="testacr.azurecr.io"
TARGET_REPO="testacr-docker-local"
CHART_VERSION="11.5.0"

echo "========================================"
echo "JFrog Platform Image Migration"
echo "Chart Version: $CHART_VERSION"
echo "Source: $SOURCE"
echo "Target: $TARGET/$TARGET_REPO"
echo "========================================"

# Check required env vars

# Image list for chart version 11.5.0
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

  # Pull from source
  if docker pull "$SOURCE/$IMAGE"; then
    echo "Pulled: $SOURCE/$IMAGE"
  else
    echo "FAILED to pull: $IMAGE"
    FAILED=$((FAILED + 1))
    FAILED_IMAGES="$FAILED_IMAGES\n  - $IMAGE"
    continue
  fi

  # Verify architecture
  ARCH=$(docker inspect "$SOURCE/$IMAGE" --format '{{.Architecture}}' 2>/dev/null)
  echo "Architecture: $ARCH"

  # Tag for target
  docker tag "$SOURCE/$IMAGE" "$TARGET/$TARGET_REPO/$IMAGE"

  # Push to target
  if docker push "$TARGET/$TARGET_REPO/$IMAGE"; then
    echo "Pushed: $TARGET/$TARGET_REPO/$IMAGE"
    SUCCESS=$((SUCCESS + 1))
  else
    echo "FAILED to push: $IMAGE"
    FAILED=$((FAILED + 1))
    FAILED_IMAGES="$FAILED_IMAGES\n  - $IMAGE"
  fi

  # Cleanup local images
  docker rmi "$SOURCE/$IMAGE" "$TARGET/$TARGET_REPO/$IMAGE" 2>/dev/null

done

echo ""
echo "========================================"
echo "Migration Summary"
echo "========================================"
echo "Successful: $SUCCESS"
echo "Failed: $FAILED"

if [ -n "$FAILED_IMAGES" ]; then
  echo ""
  echo "Failed images:"
  echo -e "$FAILED_IMAGES"
fi

echo ""
echo "========================================"
echo "Next Steps:"
echo "1. Clean cached images from AKS nodes"
echo "2. Deploy with: helm upgrade --install jfrog-platform jfrog/jfrog-platform --version $CHART_VERSION"

