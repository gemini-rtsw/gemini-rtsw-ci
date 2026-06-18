#!/bin/bash

# Ensure script fails on any error
set -e

# RPM repo container settings. RPM_REPO_IMAGE is resolved AFTER arg parsing
# (it depends on EL_VERSION); see below.
RPM_REPO_CONTAINER="rpm-repo"
RPM_REPO_NETWORK="rpm-net"

# Target EL (RHEL/Rocky) major version. Defaults to 8 so existing single-target
# callers are unchanged; pass --el 9 (or EL_VERSION=9) to build for Rocky 9.
EL_VERSION="${EL_VERSION:-8}"
IS_PROD=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --el) EL_VERSION="$2"; shift 2 ;;
        --el=*) EL_VERSION="${1#*=}"; shift ;;
        -p|--prod) IS_PROD=true; shift ;;
        *) shift ;;
    esac
done
case "$EL_VERSION" in
    8|9) ;;
    *) echo "ERROR: unsupported --el '$EL_VERSION' (expected 8 or 9)" >&2; exit 1 ;;
esac
BASE_IMAGE="rockylinux:${EL_VERSION}"
echo "Target: EL${EL_VERSION} (base image ${BASE_IMAGE})"

# Pull the per-EL rpm-repo image (~half the size of the combined :latest, so
# the runner disk doesn't overflow). Overridable via the RPM_REPO_IMAGE env
# var, so CI/ops can repoint it without another submodule bump. Falls back to
# the combined :latest only if explicitly set that way.
RPM_REPO_IMAGE="${RPM_REPO_IMAGE:-ghcr.io/gemini-rtsw/rpm-repo:latest}"
echo "Using rpm-repo image: ${RPM_REPO_IMAGE}"

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

# Get package name from spec file, checking both root and SPECS directory
SPEC_FILE=$(ls *.spec 2>/dev/null || ls SPECS/*.spec 2>/dev/null)
if [ -z "$SPEC_FILE" ]; then
    echo "No .spec file found in repository or SPECS directory"
    exit 1
fi

# Try to get package name from spec file first (for pipeline)
# First check if there's a %define name statement
PACKAGE_NAME=$(grep "^%define name" $SPEC_FILE | awk '{print $3}')
# If not found, try the Name: field
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME=$(grep "^Name:" $SPEC_FILE | awk '{print $2}' | sed 's/%{name}/gis_mk/')
fi

# If package name is empty, try git (for local builds)
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME=$(basename -s .git $(git config --get remote.origin.url))
    if [ -z "$PACKAGE_NAME" ]; then
        echo "Could not determine package name from spec file or git"
        exit 1
    fi
fi

# Get the version directly from the spec file using grep
PACKAGE_VERSION=$(grep "^%define version" $SPEC_FILE | awk '{print $3}')
if [ -z "$PACKAGE_VERSION" ]; then
    PACKAGE_VERSION=$(grep "^Version:" $SPEC_FILE | awk '{print $2}')
fi

# Get git hash for the release
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
echo "Git hash: $GIT_HASH"

# Get git branch for the release.
# Resolve outside the container so detached-HEAD checkouts (typical in CI)
# still get a meaningful name. Order: symbolic-ref -> CI ref env vars ->
# any branch pointing at HEAD -> "nobranch". Sanitized for RPM-name use.
GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ -z "$GIT_BRANCH" ]; then
    GIT_BRANCH=${GITHUB_REF_NAME:-${CI_COMMIT_REF_NAME:-}}
fi
if [ -z "$GIT_BRANCH" ]; then
    GIT_BRANCH=$(git for-each-ref --format='%(refname:short)' --points-at HEAD refs/heads 2>/dev/null | head -1)
fi
GIT_BRANCH=${GIT_BRANCH:-nobranch}
GIT_BRANCH=$(echo "$GIT_BRANCH" | sed 's/[^a-zA-Z0-9]/_/g')
echo "Git branch: $GIT_BRANCH"

echo "Building package: $PACKAGE_NAME"
echo "Package version: $PACKAGE_VERSION"
echo "Using spec file: $SPEC_FILE"

# Pull the base image
echo "Pulling ${BASE_IMAGE} base image..."
docker pull "$BASE_IMAGE"

# Start the rpm-repo container
start_rpm_repo

# Run the build in container
echo "Running build in container..."
docker run --rm -v $(pwd):/work -w /work \
    --network "$RPM_REPO_NETWORK" \
    -e GIT_HASH="$GIT_HASH" \
    -e GIT_BRANCH="$GIT_BRANCH" \
    -e EL_VERSION="$EL_VERSION" \
    "$BASE_IMAGE" \
    /bin/bash -c 'set -ex && \
        # Configure RPM repository
        echo "[rpm-repo]
name=RPM Repository
baseurl=http://rpm-repo:8080/rpm-repo/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/rpm-repo.repo && \

        # Enable EPEL and the CodeReady Builder repo. On EL8 the CRB repo is
        # named "powertools"; on EL9 it is "crb". Pick by EL_VERSION.
        dnf install -y epel-release && \
        dnf install -y dnf-plugins-core && \
        if [ "${EL_VERSION:-8}" = "9" ]; then \
            dnf config-manager --set-enabled crb; \
        else \
            dnf config-manager --set-enabled powertools; \
        fi && \
        dnf makecache --refresh && \

        # Install rclone (required by gemini-ade; not in EPEL8). The upstream
        # static RPM works on both EL8 and EL9.
        dnf install -y https://downloads.rclone.org/rclone-current-linux-amd64.rpm && \

        # Install gemini-ade package
        dnf install -y gemini-ade && \

        # Now we can source the ADE environment
        source /etc/profile.d/ade.sh && \

        # Install minimal build requirements
        dnf install -y rpm-build make gcc gcc-c++ re2c git && \

        # Mark /work as safe for git (avoids dubious ownership errors
        # when the mounted volume UID differs from the container user)
        git config --global --add safe.directory /work && \

        # Find the spec file
        SPEC_FILE=$(ls *.spec 2>/dev/null || ls SPECS/*.spec 2>/dev/null) &&
        echo "Found spec file: $SPEC_FILE" &&
        if [ -z "$SPEC_FILE" ]; then
            echo "No .spec file found in repository or SPECS directory" &&
            exit 1
        fi &&

        # Use the original spec file directly
        echo "Using original spec file: $SPEC_FILE" &&

        # Show the spec file
        echo "Spec file contents:" &&
        cat $SPEC_FILE &&

        # --- Sanity checks on the spec ---------------------------------------
        # 1. The spec MUST declare a -devel subpackage. The dev container
        #    installs the -devel RPM to pull in the pinned deps; a spec with no
        #    -devel silently produces an incomplete dev image.
        #    NB: this whole script runs inside bash -c with SINGLE quotes, so
        #    NO single-quote characters are allowed anywhere below (even in
        #    comments) -- they would terminate the -c string.
        if ! grep -qE "^%package devel" $SPEC_FILE; then
            echo "ERROR: spec has no %package devel section; dev container needs the -devel RPM." &&
            exit 1
        fi &&
        # NB: we deliberately do NOT require BuildRequires to be mirrored in
        # Requires. Build deps are pinned (exact headers); runtime Requires are
        # intentionally loose or absent -- support modules and VME IOCs build
        # cross-compiled binaries that never run on this host, and pinning their
        # runtime deps would force version conflicts when many are co-installed.
        echo "Spec check passed: -devel subpackage present." &&

        # Get the version directly from the spec file using grep
        PACKAGE_VERSION=$(grep "^%define version" $SPEC_FILE | awk "{print \$3}") &&
        if [ -z "$PACKAGE_VERSION" ]; then
            PACKAGE_VERSION=$(grep "^Version:" $SPEC_FILE | awk "{print \$2}") &&
            # If the version contains macros, try to resolve them
            if [[ "$PACKAGE_VERSION" == *"%{"* ]]; then
                echo "Version contains macros, using default version 1.0" &&
                PACKAGE_VERSION="1.0"
            fi
        fi &&
        echo "Package version: $PACKAGE_VERSION" &&

        # Check for custom repo setup script and run it if found
        if [ -f "custom-repo-setup.sh" ]; then
            echo "Found custom repo setup script, running it..." &&
            chmod +x custom-repo-setup.sh &&
            ./custom-repo-setup.sh
        fi &&

        # Install build dependencies from spec file. Hard-fail if any pinned
        # dependency cannot be resolved -- a missing/incorrect NVR must turn the
        # pipeline red, not silently build against whatever happens to be present.
        echo "Installing build dependencies..." &&
        dnf builddep -y $SPEC_FILE &&

        # --- Report the EXACT versions this build resolved against -----------
        # Print every -devel build dependency that the spec named, with the
        # exact NVR that actually got installed, in copy-pasteable pin form.
        # Read the log of any build to see what to hard-pin in a release spec
        # (see the dependency-versioning appendix in README). No single quotes
        # below -- this whole block runs inside bash -c with single quotes.
        echo "========== BUILD DEPENDENCY VERSIONS (pin these) ==========" &&
        for dep in $(grep -hoE "^(BuildRequires|Requires):[^#]*" $SPEC_FILE | sed -E "s/^(BuildRequires|Requires)://" | tr "," " " | tr -s " " "\n" | grep -- "-devel" | sort -u); do
            nvr=$(rpm -q --queryformat "%{NAME} = %{VERSION}-%{RELEASE}" "$dep" 2>/dev/null || true);
            case "$nvr" in *" = "*) echo "  $nvr" ;; *) echo "  $dep (NOT INSTALLED)" ;; esac;
        done;
        echo "===========================================================" &&

        # Create rpmbuild SOURCES directory
        mkdir -p /root/rpmbuild/SOURCES &&

        # Check for existing source files in SOURCE directory
        if [ -d "SOURCES" ] && [ "$(ls -A SOURCES/*.t*z* 2>/dev/null)" ]; then
            echo "Found existing source files in SOURCES directory" &&
            cp SOURCES/* /root/rpmbuild/SOURCES/ &&
            ls -l /root/rpmbuild/SOURCES/
        else
            # Create tarball with correct structure if no source files exist
            PACKAGE_NAME=$(grep "^%define name" $SPEC_FILE | awk "{print \$3}") &&
            if [ -z "$PACKAGE_NAME" ]; then
                PACKAGE_NAME=$(grep "^Name:" $SPEC_FILE | awk "{print \$2}" | sed "s/%{name}/tcc/") &&
                if [ -z "$PACKAGE_NAME" ]; then
                    PACKAGE_NAME=$(basename $SPEC_FILE .spec)
                fi
            fi &&
            echo "Package name: $PACKAGE_NAME" &&

            dir_name="${PACKAGE_NAME}-${PACKAGE_VERSION}" &&
            echo "Creating tarball with name: $dir_name" &&
            # Create a temp directory for the source
            mkdir -p /tmp/$dir_name &&
            # Copy all files to the temp directory, excluding .git and rpms
            find . -name ".git*" -prune -o -name "rpms" -prune -o -type f -print | xargs -I{} cp --parents {} /tmp/$dir_name/ &&
            # Create the tarball
            tar -czf /root/rpmbuild/SOURCES/${dir_name}.tar.gz -C /tmp $dir_name &&
            ls -l /root/rpmbuild/SOURCES/
        fi &&

        # Create rpmbuild/SPECS directory and copy the spec file
        mkdir -p /root/rpmbuild/SPECS &&
        cp $SPEC_FILE /root/rpmbuild/SPECS/ &&

        # Build the RPM. Run from /work so spec git-rev-parse macros find
        # the working .git. Override git_branch via --define because under
        # detached HEAD checkouts the spec resolves the branch as nobranch.
        cd /work &&
        rpmbuild -ba /root/rpmbuild/SPECS/$(basename $SPEC_FILE) --nodeps \
            --define "git_branch ${GIT_BRANCH:-nobranch}" \
            || exit 1 &&

        # Determine the architecture directory based on the spec file
        BUILD_ARCH=$(grep "^BuildArch:" $SPEC_FILE | awk "{print \$2}") &&
        if [ -z "$BUILD_ARCH" ]; then
            BUILD_ARCH="x86_64"
        fi &&
        echo "Build architecture: $BUILD_ARCH" &&

        # Show what was built
        ls -l /root/rpmbuild/RPMS/$BUILD_ARCH/ &&

        # Copy RPMs to mounted volume
        mkdir -p /work/rpms &&
        cp /root/rpmbuild/RPMS/$BUILD_ARCH/*.rpm /work/rpms/ &&

        # Verify the copy worked
        echo "Contents of /work/rpms:" &&
        ls -l /work/rpms/
    '

echo "RPM build complete! RPMs can be found in the rpms/ directory:"
ls -l rpms/
