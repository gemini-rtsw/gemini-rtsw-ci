#!/bin/bash
# build_app_image.sh -- build and push a repo's APPLICATION image.
#
# Not the same thing as build_docker.sh. That builds a *developer* container
# (toolchain plus -devel RPMs) for dev_environment.sh. This builds the container
# the repo actually ships: a Python service, a web gateway, anything whose
# product is the image rather than the RPM.
#
#   ./gemini-rtsw-ci/build_app_image.sh                     # Dockerfile, push
#   ./gemini-rtsw-ci/build_app_image.sh --no-push           # build only
#   ./gemini-rtsw-ci/build_app_image.sh --dockerfile Dockerfile.app
#
# THE TAG COMES FROM THE SPEC, never from an argument. build_rpm.sh writes the
# version it resolved to rpms/.version, and this script tags the image with it,
# so the RPM and the image cannot drift apart. That is what makes deploying a
# container by RPM meaningful: the unit pins <image>:<version>, `rpm -q` names
# what is running, and `dnf downgrade` is a real rollback.
#
# Run AFTER build_rpm.sh, and before the RPM is registered -- an RPM that is
# published before its image exists points at nothing, and the failure only
# shows up at the next restart on the deployed host.
set -euo pipefail

DOCKERFILE="Dockerfile"
PLATFORM="${APP_IMAGE_PLATFORM:-linux/amd64}"
IMAGE="${APP_IMAGE:-}"
PUSH=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dockerfile) DOCKERFILE="$2"; shift 2 ;;
        --dockerfile=*) DOCKERFILE="${1#*=}"; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        --image=*) IMAGE="${1#*=}"; shift ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --no-push) PUSH=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -f "$DOCKERFILE" ] || { echo "ERROR: no such Dockerfile: $DOCKERFILE" >&2; exit 1; }

# Written by build_rpm.sh. Its absence means this ran first, which would defeat
# the point -- the tag has to be the version the RPM was actually built with.
if [ ! -f rpms/.version ]; then
    echo "ERROR: rpms/.version not found -- run build_rpm.sh first." >&2
    echo "       The image tag is taken from the version that build resolved," >&2
    echo "       so that the RPM and the image can never disagree." >&2
    exit 1
fi
VERSION=$(cat rpms/.version)
GIT_HASH=$(cat rpms/.githash 2>/dev/null || echo nogit)
[ -n "$VERSION" ] || { echo "ERROR: rpms/.version is empty" >&2; exit 1; }

# ghcr.io/<owner>/<repo>, matching how the dev image is named.
if [ -z "$IMAGE" ]; then
    if [ -n "${GITHUB_REPOSITORY:-}" ]; then
        IMAGE="ghcr.io/${GITHUB_REPOSITORY}"
    else
        origin=$(git config --get remote.origin.url || true)
        [ -n "$origin" ] || { echo "ERROR: cannot infer image name; pass --image" >&2; exit 1; }
        IMAGE="ghcr.io/$(echo "$origin" | sed -E 's#(git@|https://)github.com[:/]##; s#\.git$##')"
    fi
fi
IMAGE=$(echo "$IMAGE" | tr '[:upper:]' '[:lower:]')   # registries reject uppercase

# :<version>            what a unit pins, and what a human reads
# :<version>-git<hash>  1:1 with the RPM NVR, so a rebuild of the same version
#                       is still distinguishable
# :latest               convenience only; never pin it in a unit
TAGS="-t ${IMAGE}:${VERSION} -t ${IMAGE}:${VERSION}-git${GIT_HASH} -t ${IMAGE}:latest"

echo "Building application image ${IMAGE}:${VERSION} (${PLATFORM}) from ${DOCKERFILE}"
# shellcheck disable=SC2086
docker build --platform "$PLATFORM" -f "$DOCKERFILE" $TAGS .

if [ "$PUSH" -eq 1 ]; then
    for t in "${VERSION}" "${VERSION}-git${GIT_HASH}" latest; do
        echo "Pushing ${IMAGE}:${t}"
        docker push "${IMAGE}:${t}"
    done
else
    echo "--no-push: built only"
fi

echo "Application image complete: ${IMAGE}:${VERSION}"
