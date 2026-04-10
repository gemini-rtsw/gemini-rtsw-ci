# gemini-rtsw-ci

CI scripts for building RPMs and Docker dev environments. Used as a git submodule in each project repo.

## Quick Start: Set Up a New Repo

1. **Add the submodule:**
   ```bash
   git submodule add -b main https://github.com/gemini-rtsw/gemini-rtsw-ci.git gemini-rtsw-ci
   git submodule update --init --recursive
   git add .gitmodules gemini-rtsw-ci
   ```

2. **Create `.github/workflows/ci.yml`:**
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

3. **Make sure you have a `.spec` file** in the repo root or `SPECS/` directory.

4. **Push.** The pipeline builds the RPM, uploads it to the rpm-repo, then builds and pushes the Docker dev image to GHCR.

No token setup needed -- `GITHUB_TOKEN` handles everything automatically.

## Local Builds

Prerequisites: Docker running, logged in to GHCR (`docker login ghcr.io` with a PAT that has `read:packages`).

Run from the **project repo root** (not from inside the submodule):

```bash
./gemini-rtsw-ci/build_rpm.sh          # Build RPM -> rpms/
./gemini-rtsw-ci/build_docker.sh       # Build dev Docker image
./gemini-rtsw-ci/dev_environment.sh    # Enter dev container
```

## How It Works

RPM dependencies come from `ghcr.io/gemini-rtsw/rpm-repo:latest` -- a Docker container running nginx that serves ~500 RPMs over HTTP. The build scripts automatically:

1. Pull and start the rpm-repo container on a Docker network
2. Run the build on the same network
3. Clean up when done

No tokens needed for RPM access -- the container serves over plain HTTP. GHCR login is only needed to pull the container image itself.

## Production Builds

Pass `--prod` to any script:

```bash
./gemini-rtsw-ci/build_rpm.sh --prod
./gemini-rtsw-ci/build_docker.sh --prod
./gemini-rtsw-ci/dev_environment.sh --prod
```

## Custom Dependency Setup

If your package has tricky dependencies (wrong versions, mixed repos, etc.), create a `custom-repo-setup.sh` in your repo root. It runs automatically before dependency resolution in both RPM and Docker builds. If the file doesn't exist, nothing happens.

```bash
#!/bin/bash
set -e
# Example: force-install a specific package
# dnf download some-package && rpm -ivh some-package.rpm --nodeps --force
```

## What the Pipeline Produces

- **RPMs** -- saved as GitHub Actions artifacts, uploaded to the rpm-repo
- **Docker dev image** -- pushed to `ghcr.io/gemini-rtsw/<repo-name>:latest-devel`
