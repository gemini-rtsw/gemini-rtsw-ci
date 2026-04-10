**ADE 2.1 Documentation**

## Overview

The CI pipeline is used to create two products: an RPM and a Docker image with the build environment installed.

These products can be created in two ways:

* Through the GitHub Actions pipeline initiated by a git push. Both products will be pushed to GHCR after the pipeline completes.
* Locally, using the build\_rpm.sh script to build the RPM, which will be placed in the rpms subdirectory, and build\_docker.sh to build the development environment, which will be added to your local Docker registry.

The development environment can then be used with the dev\_environment.sh script.

## RPM Repository

RPMs are served from a Docker container on GHCR: `ghcr.io/gemini-rtsw/rpm-repo:latest`

* Runs nginx on port 8080
* RPMs + repodata accessible at `http://<host>:8080/rpm-repo/`
* Build scripts automatically start the rpm-repo container on a Docker network
* No token needed to access RPMs at runtime — the container serves over plain HTTP
* A GHCR login is required to **pull** the container image (private package)

## Usage

**Build the products with the pipeline**

1. git add and push to your repository
2. The GitHub Actions workflow will build the RPM and Docker image automatically

**Build the products locally**

Note: The scripts must be run from the repo root directory. The gemini-rtsw-ci repo is setup as a submodule, so commands must be run with the path shown below.

Prerequisites:
* Docker must be running
* You must be logged in to GHCR: `docker login ghcr.io` (requires a PAT with `read:packages` scope)

1. ./gemini-rtsw-ci/build\_rpm.sh: This script builds the RPM package.
2. ./gemini-rtsw-ci/build\_docker.sh: This script builds the Docker build environment image.
3. ./gemini-rtsw-ci/dev\_environment.sh: This script sets up the development environment.

## Custom Repository Setup Script

The `custom-repo-setup.sh` script is an optional, customizable script used to handle dependency resolution issues that can occur when building packages. This script is automatically detected and used by both the RPM build and Docker build processes.

### What it does

The script is completely customizable and can perform any setup steps needed for your specific package. Common use cases include:

1. **Installing problematic dependencies** that DNF rejects due to repository restrictions
2. **Pre-installing packages** from different repositories or versions
3. **Setting up custom environment variables** or configuration
4. **Downloading and installing packages** using `rpm --force` to bypass DNF restrictions
5. **Any other custom setup** required before the main build process

### Why it might be needed

Some packages may require:
- **Specific package versions** not available in standard repositories
- **Mixed el7/el9 dependencies** that DNF refuses to install due to "distupgrade repository" restrictions
- **Custom libraries or tools** that need to be pre-installed
- **Environment setup** that needs to happen before dependency resolution

### How it's used

- **RPM builds**: The `build_rpm.sh` script automatically checks for and runs `custom-repo-setup.sh` before running `dnf builddep`
- **Docker builds**: The Dockerfile copies and runs the script before installing the built RPMs
- **Automatic execution**: If the script doesn't exist, the build processes continue normally without it

### Creating your custom script

To create a custom setup script for your package:

1. **Create the script** in your repository root:
   ```bash
   touch custom-repo-setup.sh
   chmod +x custom-repo-setup.sh
   ```

2. **Add your custom setup logic**:
   ```bash
   #!/bin/bash
   set -e
   echo "=== Custom Repository Setup ==="
   
   # Your custom setup steps here
   # Example: Install specific packages
   # dnf download package-name
   # rpm -ivh package-name.rpm --nodeps --force
   
   echo "=== Custom setup complete ==="
   ```

3. **Test locally** before committing:
   ```bash
   ./custom-repo-setup.sh
   ```

This script ensures that both RPM and Docker builds have access to the same custom dependency environment, resolving any package conflicts or special requirements your build may have.

## Pipeline Artifacts

When the pipeline runs successfully:
* RPMs are saved as pipeline artifacts and can be downloaded from the GitHub Actions interface
* Docker images are pushed to GHCR

## RPM Naming Convention

The RPM release number includes the git commit hash for better traceability.

## Set up the pipeline

**First-Time Repo Setup**

1. Add the CI submodule:
   ```bash
   git submodule add -b main https://github.com/gemini-rtsw/gemini-rtsw-ci.git gemini-rtsw-ci
   git submodule update --init --recursive
   git add .gitmodules gemini-rtsw-ci
   ```

2. Create a `.github/workflows/ci.yml` file in your repository root:
   ```yaml
   name: Build

   on:
     push:
       branches: [main]
     pull_request:
       branches: [main]

   jobs:
     build:
       uses: gemini-rtsw/gemini-rtsw-ci/.github/workflows/ci.yml@main
       with:
         scripts_dir: gemini-rtsw-ci
   ```

3. Create a spec file template for your package (see spec file section below).

4. The `GITHUB_TOKEN` automatically has read access to packages in the same organization — no manual token setup is needed.

## Spec File Template

```spec
%define debug_package %{nil}
%define _build_id_links none
%define name your-package-name
%define gemopt opt
%define version 1.0.0
%define release 1
%define repository gemini
%define _prefix /gemsoft

Summary: %{name} Package
Name: %{name}
Version: %{version}
Release: %{release}%{?dist}.%{repository}
License: Your License
Group: Gemini
BuildRoot: /var/tmp/%{name}-%{version}-root
Source0: %{name}-%{version}.tar.gz
BuildArch: x86_64
Prefix: %{_prefix}

BuildRequires: required-build-dependencies
Requires: required-runtime-dependencies
Provides: your-provided-libraries

%description
Description of your package.

%package devel
Summary: Development files for %{name}
Group: Development/Gemini
Requires: %{name} = %{version}-%{release}
Requires: development-dependencies

%description devel
Development files for %{name}. This package contains header files and other development files.

%prep
%setup -n %{name}-%{version}

%if %{__isa_bits} == 64
%define host_arch linux-x86_64
%else
%define host_arch linux-x86
%endif

%build
# Build commands here
make

%install
%define __os_install_post %{nil}
rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/%{_prefix}/%{gemopt}/path/to/installation
# Copy files to build root

%postun
if [ "$1" = "0" ] ; then
  rm -rf /%{_prefix}/%{gemopt}/path/to/installation
fi

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
# List files for main package

%files devel
%defattr(-,root,root)
# List files for devel package

%changelog
* Wed May 22 2024 Your Name <your.email@example.com> - 1.0.0-1
- Initial release
```

## Setting Up Repository on Rocky Linux

To install packages from this repository on a Rocky Linux system using the rpm-repo container:

1. Pull and run the rpm-repo container:
   ```bash
   docker login ghcr.io
   docker pull ghcr.io/gemini-rtsw/rpm-repo:latest
   docker run -d --name rpm-repo -p 8080:8080 ghcr.io/gemini-rtsw/rpm-repo:latest
   ```

2. Create a repository configuration file:
   ```bash
   cat > /etc/yum.repos.d/rpm-repo.repo << EOF
   [rpm-repo]
   name=RPM Repository
   baseurl=http://localhost:8080/rpm-repo/
   enabled=1
   gpgcheck=0
   EOF
   ```

3. Update the package cache:
   ```bash
   dnf makecache --refresh
   ```

4. Install packages using dnf:
   ```bash
   dnf install -y PACKAGE_NAME
   ```

## Key Points

* **Development Environment:** The development environment provides a consistent and isolated space for building and testing your code.
* **RPM and Docker Image:** These are essential components for packaging and deploying your application.
* **Container Registry:** Docker images are stored on GHCR (GitHub Container Registry).
* **RPM Repository:** RPMs are served from the rpm-repo Docker container.
* **Spec File:** This file defines the metadata and dependencies for the RPM package.
* **CI/CD Pipeline:** GitHub Actions automates the build, test, and deployment process.
* **Git Hash in RPMs:** Each RPM includes the git commit hash in its release number for better traceability.
