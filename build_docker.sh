#!/bin/bash

# Ensure script fails on any error
set -e

# RPM repo container settings. RPM_REPO_IMAGE is resolved after arg parsing
# (depends on EL_VERSION); see below.
RPM_REPO_CONTAINER="rpm-repo"
RPM_REPO_NETWORK="rpm-net"

IS_PROD=false
# Target EL major version (default 8 so existing callers are unchanged).
EL_VERSION="${EL_VERSION:-8}"

# Determine script directory for finding Dockerfile
if [ -n "$CI_SCRIPTS_DIR" ]; then
    SCRIPT_DIR="$CI_SCRIPTS_DIR"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--prod)
      IS_PROD=true
      shift
      ;;
    --el)
      EL_VERSION="$2"
      shift 2
      ;;
    --el=*)
      EL_VERSION="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$EL_VERSION" in
    8|9) ;;
    *) echo "ERROR: unsupported --el '$EL_VERSION' (expected 8 or 9)" >&2; exit 1 ;;
esac
echo "Target: EL${EL_VERSION}"

# Pull the per-EL rpm-repo image (~half size, fits the runner disk).
# Overridable via RPM_REPO_IMAGE so CI/ops can repoint without a submodule bump.
RPM_REPO_IMAGE="${RPM_REPO_IMAGE:-ghcr.io/gemini-rtsw/rpm-repo:latest-el${EL_VERSION}}"
echo "Using rpm-repo image: ${RPM_REPO_IMAGE}"

# Detect if we're in a CI pipeline
IN_PIPELINE="false"
if [ -n "$GITHUB_ACTIONS" ]; then
    IN_PIPELINE="true"
fi

# --- Helper functions for rpm-repo container ---

start_rpm_repo() {
    echo "Setting up rpm-repo container on Docker network..."

    # Clean up any leftover resources from previous runs
    docker rm -f "$RPM_REPO_CONTAINER" 2>/dev/null || true
    docker network rm "$RPM_REPO_NETWORK" 2>/dev/null || true

    docker network create "$RPM_REPO_NETWORK"
    docker run -d --name "$RPM_REPO_CONTAINER" --network "$RPM_REPO_NETWORK" "$RPM_REPO_IMAGE"

    # Wait for nginx to be ready
    echo "Waiting for rpm-repo to be ready..."
    for i in $(seq 1 10); do
        if docker exec "$RPM_REPO_CONTAINER" curl -sf http://localhost:8080/rpm-repo/ > /dev/null 2>&1; then
            echo "rpm-repo is ready"
            return 0
        fi
        sleep 1
    done
    echo "Warning: rpm-repo may not be ready, continuing anyway"
}

cleanup_rpm_repo() {
    echo "Cleaning up rpm-repo container and network..."
    docker rm -f "$RPM_REPO_CONTAINER" 2>/dev/null || true
    docker network rm "$RPM_REPO_NETWORK" 2>/dev/null || true
}

trap cleanup_rpm_repo EXIT

# --- Determine registry image name ---

if [ -n "$GITHUB_ACTIONS" ]; then
    # GitHub Actions: use GHCR
    REGISTRY_IMAGE="ghcr.io/${GITHUB_REPOSITORY,,}"
else
    # Local build: auto-detect from git remote
    REMOTE_URL=$(git config --get remote.origin.url)
    if echo "$REMOTE_URL" | grep -q "github.com"; then
        GITHUB_PATH=$(echo "$REMOTE_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)(.*)\.git$#\2#')
        REGISTRY_IMAGE="ghcr.io/$(echo "$GITHUB_PATH" | tr '[:upper:]' '[:lower:]')"
    else
        REGISTRY_IMAGE="local/$(basename $(pwd) | tr '[:upper:]' '[:lower:]')"
        echo "Warning: Could not determine registry URL, using default: ${REGISTRY_IMAGE}"
    fi
fi

# Get package name from git repo if not set
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME=$(basename $(git rev-parse --show-toplevel))
fi

# Debug output
echo "PACKAGE_NAME: ${PACKAGE_NAME}"
echo "REGISTRY_IMAGE: ${REGISTRY_IMAGE}"
echo "Current directory: $(pwd)"
echo "In pipeline: $IN_PIPELINE"

# Convert to lowercase for Docker compatibility
REGISTRY_IMAGE=$(echo "$REGISTRY_IMAGE" | tr '[:upper:]' '[:lower:]')

# Ensure rpms dir exists so COPY instruction doesn't fail
mkdir -p rpms

# Stage custom-repo-setup.sh into a directory so COPY always succeeds
# (legacy builder doesn't support glob wildcards in COPY)
mkdir -p .custom-scripts
if [ -f "custom-repo-setup.sh" ]; then
    cp custom-repo-setup.sh .custom-scripts/
fi

# Set image tags based on whether this is a production build. Tags are scoped
# by EL (el8/el9/...) so the el8 and el9 matrix legs publish distinct dev images
# instead of clobbering one shared :latest-devel / :prod-devel tag.
if [ "$IS_PROD" = true ]; then
    TAGS="-t ${REGISTRY_IMAGE}:el${EL_VERSION}-prod-devel -t ${REGISTRY_IMAGE}:el${EL_VERSION}-prod"
else
    TAGS="-t ${REGISTRY_IMAGE}:el${EL_VERSION}-latest-devel -t ${REGISTRY_IMAGE}:el${EL_VERSION}-latest"
fi

# --- Build the Docker image ---

start_rpm_repo

# Disable BuildKit — legacy builder supports --network with custom Docker networks
DOCKER_BUILDKIT=0 docker build \
    --build-arg EL_VERSION="${EL_VERSION}" \
    --build-arg IN_PIPELINE="${IN_PIPELINE}" \
    --build-arg PACKAGE_NAME="${PACKAGE_NAME}" \
    --network "$RPM_REPO_NETWORK" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    ${TAGS} .

echo "Docker build completed"

# --- Push images if in CI pipeline ---

if [ -n "$GITHUB_ACTIONS" ]; then
    echo "Running in GitHub Actions, pushing images to GHCR..."

    if [ "$IS_PROD" = true ]; then
        docker push "${REGISTRY_IMAGE}:el${EL_VERSION}-prod"
        docker push "${REGISTRY_IMAGE}:el${EL_VERSION}-prod-devel"
    else
        docker push "${REGISTRY_IMAGE}:el${EL_VERSION}-latest"
        docker push "${REGISTRY_IMAGE}:el${EL_VERSION}-latest-devel"
    fi

    echo "Successfully pushed all images"
else
    echo
    echo "Images built successfully. To push them, run:"
    if [ "$IS_PROD" = true ]; then
        echo "docker push ${REGISTRY_IMAGE}:el${EL_VERSION}-prod"
        echo "docker push ${REGISTRY_IMAGE}:el${EL_VERSION}-prod-devel"
    else
        echo "docker push ${REGISTRY_IMAGE}:el${EL_VERSION}-latest"
        echo "docker push ${REGISTRY_IMAGE}:el${EL_VERSION}-latest-devel"
    fi
fi
