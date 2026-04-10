#!/bin/bash

# Ensure the script fails on any error
set -e

# Default tag suffix
TAG_SUFFIX="latest-devel"
SKIP_PULL=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--prod)
      TAG_SUFFIX="prod-devel"
      shift
      ;;
    --no-pull|--skip-pull)
      SKIP_PULL=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Get the full repository path from git remote URL (excluding .git and the domain)
REMOTE_URL=$(git config --get remote.origin.url)
REPO_PATH=$(echo "$REMOTE_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)(.*)\.git$#\2#')
REPO_NAME=$(basename ${REPO_PATH})

# Convert repository path to lowercase for Docker compatibility
REPO_PATH_LOWERCASE=$(echo ${REPO_PATH} | tr '[:upper:]' '[:lower:]')

# Get the git root directory
GIT_ROOT=$(git rev-parse --show-toplevel)

# Check if docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Docker is not running. Please start Docker first."
    exit 1
fi

# Use GHCR for the container registry
IMAGE_NAME="${REPO_PATH_LOWERCASE}:${TAG_SUFFIX}"
FULL_IMAGE_PATH="ghcr.io/${IMAGE_NAME}"

echo "Detected repository path: ${REPO_PATH}"
echo "Using image: ${FULL_IMAGE_PATH}"

# Check for newer image version
if [ "$SKIP_PULL" = false ]; then
    echo "Checking for newer image version..."
    docker pull ${FULL_IMAGE_PATH}
else
    echo "Skipping image pull (using existing local image)"
fi

# Initialize X11 forwarding variables
X11_FORWARDING_ARGS=""
X11_ENV_ARGS=""

# Check if running on macOS
if [[ "$(uname)" == "Darwin" ]]; then
    # On macOS, we'll create the directory inside the container
    echo "Running on macOS - will create /gem_test inside container"
    MOUNT_GEM_TEST=""
    STARTUP_CMD="mkdir -p /gem_test && bash -l"

    # X11 forwarding on macOS (requires XQuartz)
    echo "Setting up X11 forwarding for macOS..."
    echo "Note: Make sure XQuartz is installed and running, and that 'Allow connections from network clients' is enabled in XQuartz preferences."

    # Check if XQuartz is running
    if pgrep -f "XQuartz" > /dev/null || [[ -S /tmp/.X11-unix/X0 ]]; then
        echo "XQuartz appears to be running."
        X11_ENV_ARGS="-e DISPLAY=host.docker.internal:0"
        # Try to mount X11 socket if it exists
        if [[ -S /tmp/.X11-unix/X0 ]]; then
            X11_FORWARDING_ARGS="-v /tmp/.X11-unix:/tmp/.X11-unix:rw"
        fi
    else
        echo "Warning: XQuartz not detected. X11 forwarding may not work."
        echo "Install XQuartz from https://www.xquartz.org/ and start it before running this script."
        X11_ENV_ARGS="-e DISPLAY=host.docker.internal:0"
    fi
else
    # On Linux, try to mount external directory
    if [ ! -d "/gem_test" ]; then
        echo "Creating /gem_test directory..."
        sudo mkdir -p /gem_test
    fi
    MOUNT_GEM_TEST="-v /gem_test:/gem_test"
    STARTUP_CMD="bash -l"

    # X11 forwarding on Linux
    echo "Setting up X11 forwarding for Linux..."

    if [[ -n "$DISPLAY" ]]; then
        echo "DISPLAY is set to: $DISPLAY"
        X11_ENV_ARGS="-e DISPLAY=$DISPLAY"

        # Mount X11 socket
        if [[ -d "/tmp/.X11-unix" ]]; then
            X11_FORWARDING_ARGS="-v /tmp/.X11-unix:/tmp/.X11-unix:rw"
            echo "X11 socket mounted."
        fi

        # Allow container to access X server (add container to xhost)
        echo "Allowing Docker container to access X server..."
        xhost +local:docker 2>/dev/null || echo "Warning: Could not run 'xhost +local:docker'. X11 forwarding may not work."
    else
        echo "Warning: DISPLAY environment variable not set. X11 forwarding will not work."
    fi
fi

# Check for custom environment setup script
CUSTOM_ENV_ARGS=""
CUSTOM_ENV_SCRIPT="${GIT_ROOT}/custom_env_setup.sh"

# Helper function to filter env vars for Docker (defined outside $() to avoid bash 3.2 parser bug)
_filter_env_for_docker() {
    while IFS='=' read -r name value; do
        case "$name" in
            PATH|HOME|USER|SHELL|TERM|PWD|OLDPWD|SHLVL|PS1|PS2|BASH_*|FUNCNAME|COMP_*|HISTFILE|HISTSIZE|HISTCONTROL|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|PPID|EUID|UID|GROUPS|SHELLOPTS|BASHOPTS|BASH_EXECUTION_STRING|BASH_SUBSHELL|BASH_VERSINFO|BASH_VERSION|DIRSTACK|PIPESTATUS|RANDOM|SECONDS|LINENO)
                ;;
            *)
                if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    echo "-e $name=$value"
                fi
                ;;
        esac
    done
}

if [[ -f "$CUSTOM_ENV_SCRIPT" ]]; then
    echo "Found custom environment setup script: $CUSTOM_ENV_SCRIPT"
    echo "Loading custom environment variables..."

    # Source the custom script and capture environment variables
    # This approach lets users do whatever they need in their script
    CUSTOM_ENV_VARS=$(bash -c "source '$CUSTOM_ENV_SCRIPT' && env" | grep -v '^_=' | _filter_env_for_docker | tr '\n' ' ')

    CUSTOM_ENV_ARGS="$CUSTOM_ENV_VARS"
    echo "Custom environment variables loaded"
else
    echo "No custom environment setup script found (custom_env_setup.sh), proceeding with default settings"
fi

# Combine all Docker arguments
DOCKER_ARGS=""
if [[ -n "$MOUNT_GEM_TEST" ]]; then
    DOCKER_ARGS="$DOCKER_ARGS $MOUNT_GEM_TEST"
fi
if [[ -n "$X11_FORWARDING_ARGS" ]]; then
    DOCKER_ARGS="$DOCKER_ARGS $X11_FORWARDING_ARGS"
fi
if [[ -n "$X11_ENV_ARGS" ]]; then
    DOCKER_ARGS="$DOCKER_ARGS $X11_ENV_ARGS"
fi
if [[ -n "$CUSTOM_ENV_ARGS" ]]; then
    DOCKER_ARGS="$DOCKER_ARGS $CUSTOM_ENV_ARGS"
fi

echo "Starting container with X11 forwarding support..."

# Run the container with all necessary mounts and environment
docker run -it --rm \
    ${DOCKER_ARGS} \
    -v ${GIT_ROOT}:/repo \
    -v ${HOME}/.gitconfig:/root/.gitconfig \
    -v ${HOME}/.git-credentials:/root/.git-credentials \
    -v ${HOME}/.ssh:/root/.ssh \
    -v ${HOME}/.docker:/root/.docker \
    -w /repo \
    ${FULL_IMAGE_PATH} \
    bash -c "${STARTUP_CMD}"
