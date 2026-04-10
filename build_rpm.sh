#!/bin/bash

# Ensure script fails on any error
set -e

# Default repository path
REPO_PATH="rpm-repo/1.0"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--prod)
      REPO_PATH="prod/1.0"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

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

echo "Building package: $PACKAGE_NAME"
echo "Package version: $PACKAGE_VERSION"
echo "Using repository path: $REPO_PATH"
echo "Using spec file: $SPEC_FILE"

# Pull the container
echo "Pulling Rocky 9 base image..."
docker pull rockylinux:9

# Run the build in container
echo "Running build in container..."
docker run --rm -v $(pwd):/work -w /work \
    -e REGISTRY_TOKEN \
    rockylinux:9 \
    /bin/bash -c 'set -ex && \
        # Configure GitLab repository first
        echo "[gitlab-rpm-repo]
name=GitLab RPM Repository
baseurl=https://oauth2:${REGISTRY_TOKEN}@gitlab.com/api/v4/projects/66226575/packages/generic/'$REPO_PATH'/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/gitlab-rpm-repo.repo && \
        
        # Enable CRB (CodeReady Builder - formerly PowerTools) and EPEL repositories
        dnf install -y epel-release && \
        dnf install -y dnf-plugins-core && \
        dnf config-manager --set-enabled crb && \
        dnf makecache --refresh && \

        # Install gemini-ade package
        dnf install -y gemini-ade && \
        
        # Now we can source the ADE environment
        source /etc/profile.d/ade.sh && \
        
        # Install minimal build requirements
        dnf install -y rpm-build make gcc gcc-c++ re2c && \
        
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
        
        # Install build dependencies from spec file - with error handling
        echo "Installing build dependencies..." &&
        (dnf builddep -y $SPEC_FILE || echo "Warning: Some dependencies could not be installed, continuing anyway") &&

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
        
        # Build the RPM with specific flags to avoid errors
        rpmbuild -ba /root/rpmbuild/SPECS/$(basename $SPEC_FILE) --nodeps || exit 1 &&
        
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
