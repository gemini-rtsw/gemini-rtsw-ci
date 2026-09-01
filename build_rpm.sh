#!/bin/bash

# Ensure script fails on any error
set -e

# Build the RPM(s) AND the dev image from ONE container environment.
#
# The build environment is created once (stage 1), snapshotted with
# `docker commit`, then reused to build the RPM (stage 2) and to produce the
# published dev image (stage 3). Previously the environment was built twice --
# once here from the spec BuildRequires, and once in a separate build-docker job
# from a Dockerfile that re-resolved everything through the -devel RPM runtime
# Requires. That second path could not see BuildRequires at all, so a package
# whose -devel had no epics deps got a dev image with no EPICS in it, and
# `make` inside it failed on a missing RULES_TOP.
#
# Why run+commit instead of `docker build`: the dependency repo is served by a
# container on a user-defined Docker network, and BuildKit cannot attach a build
# to one. `docker build --network` therefore needs DOCKER_BUILDKIT=0, i.e. the
# deprecated legacy builder. `docker run --network` has no such limitation, and
# committing the container we actually built in guarantees the published image
# IS the build environment rather than a reconstruction of it.

# RPM repo container settings. RPM_REPO_IMAGE is resolved AFTER arg parsing
# (it depends on EL_VERSION); see below.
RPM_REPO_CONTAINER="rpm-repo"
RPM_REPO_NETWORK="rpm-net"

# Target EL (RHEL/Rocky) major version. Defaults to 8 so existing single-target
# callers are unchanged; pass --el 9 (or EL_VERSION=9) to build for Rocky 9.
EL_VERSION="${EL_VERSION:-8}"
IS_PROD=false

# Build profile. "epics" is the historical behaviour and stays the default, so
# every existing caller is unchanged. "lightweight" is for packages that need
# none of the EPICS toolchain -- no gemini-ade, no rpm-repo dependency
# container, no EPEL/CRB, and no -devel subpackage requirement. Those packages
# (e.g. a noarch package shipping only config and a systemd unit) spend the
# whole build pulling a multi-GB image they never read.
PROFILE="${PROFILE:-epics}"

# Spec location, if it is neither ./*.spec nor SPECS/*.spec.
SPEC_PATH="${SPEC_PATH:-}"

# Suffix appended to the published dev image tags. Set to e.g. "-test" to try a
# pipeline change without overwriting a repo real :el<N>-latest-devel image.
DEV_IMAGE_SUFFIX="${DEV_IMAGE_SUFFIX:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --el) EL_VERSION="$2"; shift 2 ;;
        --el=*) EL_VERSION="${1#*=}"; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --spec) SPEC_PATH="$2"; shift 2 ;;
        --spec=*) SPEC_PATH="${1#*=}"; shift ;;
        -p|--prod) IS_PROD=true; shift ;;
        *) shift ;;
    esac
done
case "$PROFILE" in
    epics|lightweight) ;;
    *) echo "ERROR: unsupported --profile $PROFILE (expected epics or lightweight)" >&2; exit 1 ;;
esac
case "$EL_VERSION" in
    8|9) ;;
    *) echo "ERROR: unsupported --el '$EL_VERSION' (expected 8 or 9)" >&2; exit 1 ;;
esac
# BUILDER_IMAGE lets a package pin a slimmer or different base without another
# submodule bump. Defaults to the per-EL Rocky image, as before.
BASE_IMAGE="${BUILDER_IMAGE:-rockylinux:${EL_VERSION}}"
echo "Target: EL${EL_VERSION} (base image ${BASE_IMAGE}, profile ${PROFILE})"

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

# Named build containers, removed on exit alongside the repo container. They are
# NOT run with --rm because `docker commit` needs the stopped container.
ENV_CONTAINER="gem-build-env-$$"
DEV_CONTAINER="gem-build-dev-$$"

cleanup_containers() {
    echo "Cleaning up build containers, rpm-repo container and network..."
    docker rm -f "$ENV_CONTAINER" "$DEV_CONTAINER" 2>/dev/null || true
    docker rm -f "$RPM_REPO_CONTAINER" 2>/dev/null || true
    docker network rm "$RPM_REPO_NETWORK" 2>/dev/null || true
}

trap cleanup_containers EXIT

# Get package name from spec file, checking both root and SPECS directory
if [ -n "$SPEC_PATH" ]; then
    SPEC_FILE="$SPEC_PATH"
    [ -f "$SPEC_FILE" ] || { echo "ERROR: --spec $SPEC_FILE not found" >&2; exit 1; }
else
    SPEC_FILE=$(ls *.spec 2>/dev/null || ls SPECS/*.spec 2>/dev/null)
fi
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

# --- Image names -----------------------------------------------------------
# Local-only tag for the committed build environment. Docker requires lowercase
# repository names and several packages are camelCase (gemUtil, enetPLC5).
LOWER_NAME=$(echo "$PACKAGE_NAME" | tr '[:upper:]' '[:lower:]')
BUILDER_TAG="gem-builder-${LOWER_NAME}:el${EL_VERSION}"

# Published dev image name, resolved exactly as the old build_docker.sh did.
if [ -n "$GITHUB_ACTIONS" ]; then
    REGISTRY_IMAGE="ghcr.io/$(echo "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
else
    REMOTE_URL=$(git config --get remote.origin.url || true)
    if echo "$REMOTE_URL" | grep -q "github.com"; then
        GITHUB_PATH=$(echo "$REMOTE_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)(.*)\.git$#\2#')
        REGISTRY_IMAGE="ghcr.io/$(echo "$GITHUB_PATH" | tr '[:upper:]' '[:lower:]')"
    else
        REGISTRY_IMAGE="local/${LOWER_NAME}"
        echo "Warning: Could not determine registry URL, using default: ${REGISTRY_IMAGE}"
    fi
fi
if [ "$IS_PROD" = true ]; then
    DEV_TAG="${REGISTRY_IMAGE}:el${EL_VERSION}-prod-devel${DEV_IMAGE_SUFFIX}"
    ALT_TAG="${REGISTRY_IMAGE}:el${EL_VERSION}-prod${DEV_IMAGE_SUFFIX}"
else
    DEV_TAG="${REGISTRY_IMAGE}:el${EL_VERSION}-latest-devel${DEV_IMAGE_SUFFIX}"
    ALT_TAG="${REGISTRY_IMAGE}:el${EL_VERSION}-latest${DEV_IMAGE_SUFFIX}"
fi

# Pull the base image
echo "Pulling ${BASE_IMAGE} base image..."
docker pull "$BASE_IMAGE"

# Start the rpm-repo container. Only the epics profile installs anything from
# it, and pulling it is the single most expensive step in the build.
if [ "$PROFILE" = "epics" ]; then
    start_rpm_repo
    NETWORK_ARGS="--network $RPM_REPO_NETWORK"
else
    echo "Profile lightweight: skipping rpm-repo dependency container"
    NETWORK_ARGS=""
fi

# ===========================================================================
# STAGE 1 -- build the environment, then snapshot it.
# Everything here used to be the first half of one giant `docker run`. The
# steps and their order are unchanged; only the container lifetime differs.
# ===========================================================================
echo "=== Stage 1/3: building the build environment ==="
docker run --name "$ENV_CONTAINER" -v $(pwd):/work -w /work \
    $NETWORK_ARGS \
    -e GIT_HASH="$GIT_HASH" \
    -e GIT_BRANCH="$GIT_BRANCH" \
    -e EL_VERSION="$EL_VERSION" \
    -e PROFILE="$PROFILE" \
    -e SPEC_PATH="$SPEC_PATH" \
    "$BASE_IMAGE" \
    /bin/bash -c 'set -ex && \
        # The lightweight profile installs only what rpmbuild itself needs. No
        # rpm-repo, no EPEL/CRB, no ADE -- see --profile in this script.
        if [ "$PROFILE" = "lightweight" ]; then \
            dnf install -y rpm-build dnf-plugins-core git; \
        else \
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
        dnf install -y rpm-build make gcc gcc-c++ re2c git; \
        fi && \

        # Mark /work as safe for git (avoids dubious ownership errors
        # when the mounted volume UID differs from the container user).
        # This writes /root/.gitconfig, so it persists into the commit.
        git config --global --add safe.directory /work && \

        # Find the spec file
        if [ -n "$SPEC_PATH" ]; then
    SPEC_FILE="$SPEC_PATH"
    [ -f "$SPEC_FILE" ] || { echo "ERROR: --spec $SPEC_FILE not found" >&2; exit 1; }
else
    SPEC_FILE=$(ls *.spec 2>/dev/null || ls SPECS/*.spec 2>/dev/null)
fi &&
        echo "Found spec file: $SPEC_FILE" &&
        if [ -z "$SPEC_FILE" ]; then
            echo "No .spec file found in repository or SPECS directory" &&
            exit 1
        fi &&

        # --- 32-bit (i686) targets ---------------------------------------
        # rpm takes its build target from the PROCESS PERSONALITY, not from
        # the spec, so a spec saying BuildArch: i686 dies on an x86_64 host
        # with "No compatible architectures found for build" -- and rpmspec
        # and dnf builddep cannot even parse it. setarch i686 makes the
        # process report itself as i686 and rpm then accepts the target.
        # BUILD_ARCH below already reads BuildArch and finds RPMS/i686.
        SETARCH="" &&
        BUILDDEP_NOBEST="" &&
        if grep -qE "^BuildArch:[[:space:]]*i686" $SPEC_FILE; then
            SETARCH="setarch i686" &&
            BUILDDEP_NOBEST="--nobest" &&
            echo "32-bit target detected: running rpm tooling under $SETARCH" &&
            # Under an i686 personality dnf expands $basearch to i386, and
            # there are no i386 repos -- every URL 404s, including the EPEL
            # metalink (which carries arch=$basearch). Pin the repo files to
            # the host arch instead. This does NOT stop i686 packages being
            # installed: an x86_64 repo carries the i686 ones too, and the
            # spec selects them by explicit .i686 / (x86-32) names.
            sed -i "s/\$basearch/x86_64/g" /etc/yum.repos.d/*.repo
        fi &&

        # Show the spec file
        echo "Spec file contents:" &&
        cat $SPEC_FILE &&

        # --- Spec notes -------------------------------------------------------
        # A -devel subpackage is no longer required. It used to be: the dev
        # image was built by installing the -devel RPM and letting its runtime
        # Requires drag in a toolchain, so a spec without one produced an image
        # with nothing useful in it. The dev image now IS the build environment,
        # resolved from BuildRequires, and the install step already handles a
        # package that ships no -devel. A leaf package like ca-gateway has no
        # reason to invent one.
        #    NB: this whole script runs inside bash -c with SINGLE quotes, so
        #    NO single-quote characters are allowed anywhere below (even in
        #    comments) -- they would terminate the -c string.
        if [ "$PROFILE" != "lightweight" ] && ! grep -qE "^%package devel" $SPEC_FILE; then
            echo "Note: spec has no %package devel section. The dev image will"
            echo "      contain the build environment and this package, but no"
            echo "      headers for anything that wants to compile against it."
        fi &&
        # NB: we deliberately do NOT require BuildRequires to be mirrored in
        # Requires. Build deps are pinned (exact headers); runtime Requires are
        # intentionally loose or absent -- support modules and VME IOCs build
        # cross-compiled binaries that never run on this host, and pinning their
        # runtime deps would force version conflicts when many are co-installed.
        # The dev image gets its toolchain from BuildRequires below, NOT from
        # the -devel runtime Requires, so there is no reason to over-pin those.

        # Check for custom repo setup script and run it if found
        if [ -f "custom-repo-setup.sh" ]; then
            echo "Found custom repo setup script, running it..." &&
            chmod +x custom-repo-setup.sh &&
            ./custom-repo-setup.sh
        fi &&

        # Install build dependencies from spec file. Hard-fail if any pinned
        # dependency cannot be resolved -- a missing/incorrect NVR must turn the
        # pipeline red, not silently build against whatever happens to be
        # present. Checked explicitly: bash set -e ignores a failure in the
        # non-final position of an && list, so an unchecked builddep here used
        # to be swallowed and the build carried on with NO deps installed.
        echo "Installing build dependencies..." &&
        # $BUILDDEP_NOBEST is --nobest for 32-bit builds ONLY, and empty
        # otherwise. A 32-bit build installs pinned legacy i686 packages whose
        # x86_64 counterparts are excluded from the base repos, and dnf
        # refuses the whole transaction over the resulting "problem with
        # installed package" without it. It must NOT apply to normal builds:
        # it would let dnf settle for an older NVR instead of failing on an
        # unresolvable pin, which is the opposite of what the check below is
        # for.
        if ! $SETARCH dnf builddep -y $BUILDDEP_NOBEST $SPEC_FILE; then
            echo "ERROR: dnf builddep failed -- a BuildRequires could not be resolved." >&2 &&
            echo "       Fix the pin in $SPEC_FILE (or register the missing RPM) and re-run." >&2 &&
            exit 1
        fi &&

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

        # --- The build environment IS the dev image ---------------------------
        # If the spec builds against EPICS, the rules the build needs must be
        # present. A dev image without them looks fine until a developer runs
        # make and hits "No rule to make target .../configure/RULES_TOP".
        #
        # Ask rpm where that file is rather than hard-coding the path. There
        # are two EPICS layouts in the wild: epics-base 7.0.7 installs its
        # configure tree under /gem_base/epics/epics-base, while the legacy
        # 3.14.12 base that a few packages still pin -- see
        # BuildRequires epics-base-devel(x86-32) -- ships under /gemsoft. The
        # hard-coded /gem_base path failed the second layout even though the
        # toolchain was fully installed. Naming the package unqualified lists
        # every installed arch of it, so a multilib i686 + x86_64 install is
        # covered too.
        if grep -qE "^BuildRequires:.*epics-base-devel" $SPEC_FILE; then
            rules_top=$(rpm -ql epics-base-devel 2>/dev/null | grep -m1 -E "configure/RULES_TOP$" || true) &&
            { test -n "$rules_top" && test -f "$rules_top"; } || { \
                echo "ERROR: epics-base-devel resolved but RULES_TOP is missing." >&2 && \
                exit 1; } &&
            echo "Env check passed: EPICS build rules present at $rules_top"
        fi &&

        # Shrink the layer we are about to commit.
        dnf clean all &&
        rm -rf /var/cache/dnf
    '

echo "Snapshotting the build environment as ${BUILDER_TAG}"
docker commit "$ENV_CONTAINER" "$BUILDER_TAG" >/dev/null
docker rm -f "$ENV_CONTAINER" >/dev/null

# ===========================================================================
# STAGE 2 -- build the RPM inside that environment. Unchanged from the second
# half of the original single container run.
# ===========================================================================
echo "=== Stage 2/3: building the RPM ==="
docker run --rm -v $(pwd):/work -w /work \
    $NETWORK_ARGS \
    -e GIT_HASH="$GIT_HASH" \
    -e GIT_BRANCH="$GIT_BRANCH" \
    -e EL_VERSION="$EL_VERSION" \
    -e PROFILE="$PROFILE" \
    -e SPEC_PATH="$SPEC_PATH" \
    "$BUILDER_TAG" \
    /bin/bash -c 'set -ex && \
        # Restore the ADE environment (TDCT, EPICS_HOST_ARCH, GEM_*). It used to
        # be present in the rpmbuild environment for free, because the dependency
        # preamble and rpmbuild ran in ONE shell. The stages are separate
        # containers now and bash -c is non-login, so profile.d is never read --
        # and a spec whose %build does not source the profile itself (vmi5588,
        # for one) then builds with an empty $TDCT and fails generating its .db.
        if [ "$PROFILE" != "lightweight" ] && [ -f /etc/profile.d/ade.sh ]; then \
            source /etc/profile.d/ade.sh; \
        fi && \

        # Find the spec file
        if [ -n "$SPEC_PATH" ]; then
    SPEC_FILE="$SPEC_PATH"
    [ -f "$SPEC_FILE" ] || { echo "ERROR: --spec $SPEC_FILE not found" >&2; exit 1; }
else
    SPEC_FILE=$(ls *.spec 2>/dev/null || ls SPECS/*.spec 2>/dev/null)
fi &&
        echo "Using original spec file: $SPEC_FILE" &&

        # --- 32-bit (i686) targets ---------------------------------------
        # rpm takes its build target from the PROCESS PERSONALITY, not from
        # the spec, so a spec saying BuildArch: i686 dies on an x86_64 host
        # with "No compatible architectures found for build" -- and rpmspec
        # and dnf builddep cannot even parse it. setarch i686 makes the
        # process report itself as i686 and rpm then accepts the target.
        # BUILD_ARCH below already reads BuildArch and finds RPMS/i686.
        SETARCH="" &&
        BUILDDEP_NOBEST="" &&
        if grep -qE "^BuildArch:[[:space:]]*i686" $SPEC_FILE; then
            SETARCH="setarch i686" &&
            BUILDDEP_NOBEST="--nobest" &&
            echo "32-bit target detected: running rpm tooling under $SETARCH" &&
            # Under an i686 personality dnf expands $basearch to i386, and
            # there are no i386 repos -- every URL 404s, including the EPEL
            # metalink (which carries arch=$basearch). Pin the repo files to
            # the host arch instead. This does NOT stop i686 packages being
            # installed: an x86_64 repo carries the i686 ones too, and the
            # spec selects them by explicit .i686 / (x86-32) names.
            sed -i "s/\$basearch/x86_64/g" /etc/yum.repos.d/*.repo
        fi &&

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
        # rpmspec expands macros, so a spec whose Version is defined by a
        # %global (the version living in ONE place) resolves correctly instead
        # of falling back to 1.0 and naming the tarball something the spec
        # cannot find.
        if [ "$PROFILE" = "lightweight" ]; then
            PACKAGE_VERSION=$($SETARCH rpmspec -q --queryformat "%{version}\n" $SPEC_FILE | head -1)
        fi &&
        echo "Package version: $PACKAGE_VERSION" &&

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
        $SETARCH rpmbuild -ba /root/rpmbuild/SPECS/$(basename $SPEC_FILE) --nodeps \
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

        # Record the resolved version and commit for build_app_image.sh. The
        # version is written by the same code that built the RPM, so an image
        # tagged from it cannot disagree with the package -- which is the whole
        # point of deploying a container by RPM.
        printf "%s\n" "$PACKAGE_VERSION" > /work/rpms/.version &&
        printf "%s\n" "${GIT_HASH:-nogit}" > /work/rpms/.githash &&

        # Verify the copy worked
        echo "Contents of /work/rpms:" &&
        ls -l /work/rpms/
    '

echo "RPM build complete! RPMs can be found in the rpms/ directory:"
ls -l rpms/

# ===========================================================================
# STAGE 3 -- dev image = the build environment + this package installed.
# Replaces the separate build-docker job and its Dockerfile, which rebuilt the
# environment from scratch on a second runner (another rpm-repo pull, another
# free-disk-space) and resolved deps from the -devel runtime Requires instead
# of the spec BuildRequires.
#
# Every profile publishes one, lightweight included. A lightweight image is
# small (base + rpm-build + whatever builddep pulled + the package) and its
# value is a clean box with the package already installed -- check that the
# unit file landed where you expected, that %post did the right thing, or
# re-run rpmbuild in exactly the environment CI used. It also means
# dev_environment.sh works for every repo, with no "unless it is lightweight"
# exception to remember.
# ===========================================================================
echo "=== Stage 3/3: dev image ${DEV_TAG} ==="
docker run --name "$DEV_CONTAINER" -v $(pwd):/work -w /work \
    $NETWORK_ARGS \
    "$BUILDER_TAG" \
    /bin/bash -c 'set -ex && \
        if ls /work/rpms/*-devel*.rpm 1> /dev/null 2>&1; then \
            dnf install -y /work/rpms/*-devel*.rpm /work/rpms/*.rpm; \
        else \
            dnf install -y /work/rpms/*.rpm; \
        fi && \
        dnf clean all && \
        rm -rf /var/cache/dnf
    '

docker commit "$DEV_CONTAINER" "$DEV_TAG" >/dev/null
docker tag "$DEV_TAG" "$ALT_TAG"
docker rm -f "$DEV_CONTAINER" >/dev/null
echo "Built ${DEV_TAG}"
echo "Built ${ALT_TAG}"

# Push only from CI, and never from a pull request -- a PR build would
# otherwise overwrite the branch dev image with an unreviewed one.
if [ -z "$GITHUB_ACTIONS" ]; then
    echo
    echo "Dev image built locally. To push it, run:"
    echo "  docker push ${DEV_TAG}"
    echo "  docker push ${ALT_TAG}"
elif [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    echo "Pull request: dev image built but NOT pushed."
else
    echo "Pushing dev images to the registry..."
    docker push "$DEV_TAG"
    docker push "$ALT_TAG"
    echo "Successfully pushed dev images"
fi
