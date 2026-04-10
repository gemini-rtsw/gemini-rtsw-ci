#!/bin/bash

# Ensure script fails on any error
set -e

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

# Determine if we're in pipeline
IN_PIPELINE="false"
if [ -n "$CI_REGISTRY" ]; then
    IN_PIPELINE="true"
fi

# Get registry URL from git remote when building locally
if [ -z "$CI_REGISTRY_IMAGE" ]; then
    # Extract gitlab registry URL from git remote
    GITLAB_URL=$(git config --get remote.origin.url | sed 's/.*gitlab.com[:\/]\(.*\)\.git/\1/')
    if [ -n "$GITLAB_URL" ]; then
        CI_REGISTRY_IMAGE="registry.gitlab.com/${GITLAB_URL}"
    else
        CI_REGISTRY_IMAGE="local/$(basename $(pwd) | tr '[:upper:]' '[:lower:]')"
        echo "Warning: Could not determine GitLab registry URL, using default: ${CI_REGISTRY_IMAGE}"
    fi
fi

# Get package name from git repo if not set
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME=$(basename $(git rev-parse --show-toplevel))
fi

# Debug output
echo "PACKAGE_NAME before: ${PACKAGE_NAME}"
echo "Current directory: $(pwd)"
echo "Basename: $(basename $(pwd))"
echo "Using repository path: $REPO_PATH"

# Convert CI_REGISTRY_IMAGE to lowercase for Docker compatibility
CI_REGISTRY_IMAGE=$(echo "$CI_REGISTRY_IMAGE" | tr '[:upper:]' '[:lower:]')

# Create rpms directory if it doesn't exist
# This ensures the COPY instruction in Dockerfile doesn't fail
mkdir -p rpms

# Create a temporary file to store the token
TOKEN_FILE=$(mktemp)
echo "${REGISTRY_TOKEN}" > "${TOKEN_FILE}"

# Enable BuildKit for Docker
export DOCKER_BUILDKIT=1

# Set image tags based on whether this is a production build
if [ "$IS_PROD" = true ]; then
    # Production tags
    TAGS="-t ${CI_REGISTRY_IMAGE}:prod-devel -t ${CI_REGISTRY_IMAGE}:prod"
else
    # Default tags
    TAGS="-t ${CI_REGISTRY_IMAGE}:latest-devel -t ${CI_REGISTRY_IMAGE}:latest"
fi

# Build the development image using BuildKit secrets
docker build \
    --build-arg IN_PIPELINE="${IN_PIPELINE}" \
    --build-arg PACKAGE_NAME="${PACKAGE_NAME}" \
    --build-arg REPO_PATH="${REPO_PATH}" \
    --secret id=gitlab_token,src="${TOKEN_FILE}" \
    -f "${SCRIPT_DIR}/Dockerfile" \
    ${TAGS} .

# Remove the temporary token file - don't fail if it's already gone
if [ -f "${TOKEN_FILE}" ]; then
    rm -f "${TOKEN_FILE}" || true
fi

echo "DEBUG: Docker build completed"


# Push the images if in pipeline
if [ -n "$CI_REGISTRY" ]; then
    echo "Running in CI pipeline, attempting to push images..."
    
    # We're already logged in via .docker-login in .gitlab-ci.yml
    # No need to login again
    
    # Push the images based on whether this is a production build
    if [ "$IS_PROD" = true ]; then
        echo "Pushing image: ${CI_REGISTRY_IMAGE}:prod"
        if ! docker push "${CI_REGISTRY_IMAGE}:prod"; then
            echo "ERROR: Failed to push ${CI_REGISTRY_IMAGE}:prod"
            exit 1
        fi
        
        echo "Pushing image: ${CI_REGISTRY_IMAGE}:prod-devel"
        if ! docker push "${CI_REGISTRY_IMAGE}:prod-devel"; then
            echo "ERROR: Failed to push ${CI_REGISTRY_IMAGE}:prod-devel"
            exit 1
        fi
    else
        echo "Pushing image: ${CI_REGISTRY_IMAGE}:latest"
        if ! docker push "${CI_REGISTRY_IMAGE}:latest"; then
            echo "ERROR: Failed to push ${CI_REGISTRY_IMAGE}:latest"
            exit 1
        fi
        
        echo "Pushing image: ${CI_REGISTRY_IMAGE}:latest-devel"
        if ! docker push "${CI_REGISTRY_IMAGE}:latest-devel"; then
            echo "ERROR: Failed to push ${CI_REGISTRY_IMAGE}:latest-devel"
            exit 1
        fi
    fi
    
    echo "Successfully pushed all images"
else
    # Local push - make it optional
    echo
    echo "Images built successfully. To push them, run:"
    if [ "$IS_PROD" = true ]; then
        echo "docker push ${CI_REGISTRY_IMAGE}:prod"
        echo "docker push ${CI_REGISTRY_IMAGE}:prod-devel"
    else
        echo "docker push ${CI_REGISTRY_IMAGE}:latest"
        echo "docker push ${CI_REGISTRY_IMAGE}:latest-devel"
    fi
fi 

