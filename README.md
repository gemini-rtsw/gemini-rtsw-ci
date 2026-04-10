**ADE 2.1 Documentation**

## Overview

The GitLab pipeline is used to create two products: an RPM and a Docker image with the build environment installed.

These products can be created in two ways:

* Through the GitLab pipeline initiated by a git push. Both products will be pushed to the GitLab registry after the pipeline completes.  
* Locally, using the build\_rpm.sh script to build the RPM, which will be placed in the rpms subdirectory, and build\_docker.sh to build the development environment, which will be added to your local Docker registry.

The development environment can then be used with the dev\_environment.sh script.

## Usage

**Build the products with the pipeline**

1. git add and push

**Build the products locally**

Note: The scripts must be run from the repo root directory. The gemini-rtsw-ci repo is setup as a submodule, so commands must be run with the path shown below. 

1. ./gemini-rtsw-ci/build\_rpm.sh: This script is responsible for building the RPM package.
2. ./gemini-rtsw-ci/build\_docker.sh: This script builds the Docker build environment image.
3. ./gemini-rtsw-ci/dev\_environment.sh: This script sets up the development environment using the RPM and Docker image you just built.

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
* RPMs are saved as pipeline artifacts and can be downloaded directly from the GitLab pipeline interface
* Products are pushed to the GitLab package registry at https://gitlab.com/nsf-noirlab/gemini/rtsw/gemini-rtsw-repo/-/packages
* All packages are automatically mirrored to the internal Gemini repository every 15 minutes

## RPM Naming Convention

The RPM release number includes the git commit hash for better traceability.

## Set up the pipeline 

**First-Time Repo Setup**

Follow these steps if this is the first time you're setting up the repository and the necessary RPM and image files are not yet available in the GitLab registry:

1. Add the CI submodule: 
   ```bash
   git submodule add -b <target branch> git@gitlab.com:nsf-noirlab/gemini/rtsw/user-tools/gemini-rtsw-ci.git gemini-rtsw-ci
   git submodule update --init --recursive
   git add .gitmodules gemini-rtsw-ci
   ```
2. Create a `.gitlab-ci.yml` file in your repository root that includes the CI template:
   ```yaml
   variables:
     SCRIPTS_BRANCH: "<target branch>"
     CI_SCRIPTS_DIR: "gemini-rtsw-ci"
     GIT_SUBMODULE_FORCE_HTTPS: "true"
     GIT_SUBMODULE_STRATEGY: "recursive"

   include:
     - project: 'nsf-noirlab/gemini/rtsw/user-tools/gemini-rtsw-ci'
       ref: '<target branch>'
       file: '.imported-ci.yml'

   stages:
     - build
     - deploy
   ```
3. Create a spec file template for your package:
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
4. The `REGISTRY_TOKEN` CI/CD variable is inherited from the Gemini group level. No per-project token setup is needed — the pipeline uses this token for registry authentication, git credential setup, and RPM repository access.
5. Start Runners
   ![Runner Settings](docs/runner-settings.png)
7. Add devel section to spec

## Setting Up Repository on Rocky Linux

To install packages from this repository on a Rocky Linux system:

1. Create a repository configuration file for the GitLab RPM repository:
   ```bash
   # Replace TOKEN with your GitLab access token
   cat > /etc/yum.repos.d/gitlab-rpm-repo.repo << EOF
   [gitlab-rpm-repo]
   name=GitLab RPM Repository
   baseurl=https://oauth2:TOKEN@gitlab.com/api/v4/projects/66226575/packages/generic/rpm-repo/1.0/
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

Replace `TOKEN` with a valid GitLab access token (e.g., the `REGISTRY_TOKEN` used by the pipeline) that has read access to the repository. Replace `PACKAGE_NAME` with the specific package you want to install.

## Remaining Tasks

The following tasks still need to be completed:

* **RPM Build:** The RPM build process should create a new container and install the required RPMs directly from the spec file using a command like \`dnf builddep \-y /tmp/ecs\_mk.spec\`.

**Key Points**

* **Development Environment:** The development environment provides a consistent and isolated space for building and testing your code.  
* **RPM and Docker Image:** These are essential components for packaging and deploying your application.  
* **GitLab Registry:** This stores the RPM and image files for easy access and sharing.  
* **Spec File:** This file defines the metadata and dependencies for the RPM package.  
* **CI/CD Pipeline:** This automates the build, test, and deployment process.
* **Git Hash in RPMs:** Each RPM includes the git commit hash in its release number for better traceability.

