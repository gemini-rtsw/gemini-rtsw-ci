#!/bin/bash

# Ensure script fails on any error
set -e

# RPM repo container settings
RPM_REPO_IMAGE="ghcr.io/gemini-rtsw/rpm-repo:latest"
RPM_REPO_CONTAINER="rpm-repo"
RPM_REPO_NETWORK="rpm-net"

# Default repository path
REPO_PATH="rpm-repo/1.0"
IS_PROD=false

# Determine script directory for finding Dockerfile
if [ -n "$CI_SCRIPTS_DIR" ]; then
    # We're in the pipeline with CI_SCRIPTS_DIR set
    SCRIPT_DIR="$CI_SCRIPTS_DIR"
else
    # Local execution - get directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--prod)
      REPO_PATH="prod/1.0"
      IS_PROD=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Detect CI environment
if [ -n "$GITHUB_ACTIONS" ]; then
    RPM_REPO_MODE="network"
    IN_PIPELINE="true"
elif [ -n "$CI_REGISTRY" ]; then
    RPM_REPO_MODE="gitlab"
    IN_PIPELINE="true"
else
    RPM_REPO_MODE="network"
    IN_PIPELINE="false"
fi

echo "RPM repo mode: $RPM_REPO_MODE"
echo "In pipeline: $IN_PIPELINE"

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
    if [ "$RPM_REPO_MODE" = "network" ]; then
        echo "Cleaning up rpm-repo container and network..."
        docker rm -f "$RPM_REPO_CONTAINER" 2>/dev/null || true
        docker network rm "$RPM_REPO_NETWORK" 2>/dev/null || true
    fi
    # Clean up token file if it exists
    if [ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ]; then
        rm -f "$TOKEN_FILE" || true
    fi
}

trap cleanup_rpm_repo EXIT

# --- Determine registry image name ---

if [ -n "$GITHUB_ACTIONS" ]; then
    # GitHub Actions: use GHCR
    REGISTRY_IMAGE="ghcr.io/${GITHUB_REPOSITORY,,}"
elif [ -n "$CI_REGISTRY_IMAGE" ]; then
    # GitLab CI: already set
    REGISTRY_IMAGE="$CI_REGISTRY_IMAGE"
else
    # Local build: auto-detect from git remote
    REMOTE_URL=$(git config --get remote.origin.url)
    if echo "$REMOTE_URL" | grep -q "github.com"; then
        # GitHub remote -> GHCR
        GITHUB_PATH=$(echo "$REMOTE_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)(.*)\.git$#\2#')
        REGISTRY_IMAGE="ghcr.io/$(echo "$GITHUB_PATH" | tr '[:upper:]' '[:lower:]')"
    elif echo "$REMOTE_URL" | grep -q "gitlab.com"; then
        # GitLab remote -> GitLab registry
        GITLAB_URL=$(echo "$REMOTE_URL" | sed 's/.*gitlab.com[:\/]\(.*\)\.git/\1/')
        REGISTRY_IMAGE="registry.gitlab.com/${GITLAB_URL}"
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
echo "Using repository path: $REPO_PATH"

# Convert to lowercase for Docker compatibility
REGISTRY_IMAGE=$(echo "$REGISTRY_IMAGE" | tr '[:upper:]' '[:lower:]')

# Create rpms directory if it doesn't exist
# This ensures the COPY instruction in Dockerfile doesn't fail
mkdir -p rpms

# Enable BuildKit for Docker
export DOCKER_BUILDKIT=1

# Set image tags based on whether this is a production build
if [ "$IS_PROD" = true ]; then
    TAGS="-t ${REGISTRY_IMAGE}:prod-devel -t ${REGISTRY_IMAGE}:prod"
else
    TAGS="-t ${REGISTRY_IMAGE}:latest-devel -t ${REGISTRY_IMAGE}:latest"
fi

# --- Build the Docker image ---

if [ "$RPM_REPO_MODE" = "network" ]; then
    # GitHub / local: use rpm-repo container on Docker network
    start_rpm_repo

    docker build \
        --build-arg IN_PIPELINE="${IN_PIPELINE}" \
        --build-arg PACKAGE_NAME="${PACKAGE_NAME}" \
        --build-arg RPM_REPO_METHOD=network \
        --network "$RPM_REPO_NETWORK" \
        -f "${SCRIPT_DIR}/Dockerfile" \
        ${TAGS} .
else
    # GitLab: use BuildKit secret for token-based access
    TOKEN_FILE=$(mktemp)
    echo "${REGISTRY_TOKEN}" > "${TOKEN_FILE}"

    docker build \
        --build-arg IN_PIPELINE="${IN_PIPELINE}" \
        --build-arg PACKAGE_NAME="${PACKAGE_NAME}" \
        --build-arg REPO_PATH="${REPO_PATH}" \
        --build-arg RPM_REPO_METHOD=gitlab \
        --secret id=gitlab_token,src="${TOKEN_FILE}" \
        -f "${SCRIPT_DIR}/Dockerfile" \
        ${TAGS} .
fi

echo "Docker build completed"

# --- Push images if in CI pipeline ---

if [ -n "$GITHUB_ACTIONS" ]; then
    echo "Running in GitHub Actions, pushing images to GHCR..."

    if [ "$IS_PROD" = true ]; then
        docker push "${REGISTRY_IMAGE}:prod"
        docker push "${REGISTRY_IMAGE}:prod-devel"
    else
        docker push "${REGISTRY_IMAGE}:latest"
        docker push "${REGISTRY_IMAGE}:latest-devel"
    fi

    echo "Successfully pushed all images"
elif [ -n "$CI_REGISTRY" ]; then
    echo "Running in GitLab CI pipeline, pushing images..."

    if [ "$IS_PROD" = true ]; then
        docker push "${REGISTRY_IMAGE}:prod"
        docker push "${REGISTRY_IMAGE}:prod-devel"
    else
        docker push "${REGISTRY_IMAGE}:latest"
        docker push "${REGISTRY_IMAGE}:latest-devel"
    fi

    echo "Successfully pushed all images"
else
    echo
    echo "Images built successfully. To push them, run:"
    if [ "$IS_PROD" = true ]; then
        echo "docker push ${REGISTRY_IMAGE}:prod"
        echo "docker push ${REGISTRY_IMAGE}:prod-devel"
    else
        echo "docker push ${REGISTRY_IMAGE}:latest"
        echo "docker push ${REGISTRY_IMAGE}:latest-devel"
    fi
fi
