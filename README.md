# gemini-rtsw-ci

Shared CI scripts for building RPMs and Docker dev environments. Used as a git submodule in each project repo. On every push, the pipeline builds the package's RPM, publishes it to the shared rpm-repo, and pushes a Docker dev image to GHCR.

## How the pipeline works

RPM dependencies are served by `ghcr.io/gemini-rtsw/rpm-repo:latest` — an nginx container hosting a yum repo of ~500 RPMs over plain HTTP. Each build:

1. Pulls and starts the rpm-repo container on a Docker network, points `dnf` at it, builds, then cleans up.
2. **Publishes** the resulting RPM via `upload-rpm.sh`: each package is pushed as a per-package tag `ghcr.io/gemini-rtsw/rpm-repo:rpm-<pkgname>`, and `rpm-repo:latest` is rebuilt from all `rpm-*` tags. Per-package tags mean concurrent builds never clobber each other.
3. **Pushes a dev image** to `ghcr.io/gemini-rtsw/<repo-name>:el<N>-latest-devel`, EL-scoped per matrix leg (e.g. `el8-latest-devel`, `el9-latest-devel`).

No tokens are needed for RPM access — the repo is served over plain HTTP; GHCR login is only to pull the container image. `GITHUB_TOKEN` covers everything in CI.

## Set up a new repo

1. **Add the submodule:**
   ```bash
   git submodule add -b main https://github.com/gemini-rtsw/gemini-rtsw-ci.git gemini-rtsw-ci
   git submodule update --init --recursive
   git add .gitmodules gemini-rtsw-ci
   ```

2. **Add `.github/workflows/ci.yml`:**
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

3. **Add a `.spec` file** in the repo root or `SPECS/`.

4. **Grant the repo Write access to `rpm-repo`** (required — the build reads dependencies *and* publishes its RPM):
   - Open **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings**
   - Under **Manage Actions access** → **Add Repository**, add the new repo, role **Write**.

5. **Push.** Common failures if step 4 is missed:
   - `docker: ... denied` pulling `rpm-repo:latest` — no read access.
   - `denied: permission_denied: write_package` at publish — has read but not write.

## Local builds

Prerequisites: Docker running, logged in to GHCR (`docker login ghcr.io` with a PAT that has `read:packages`). Run from the **project repo root**, not inside the submodule:

```bash
./gemini-rtsw-ci/build_rpm.sh                 # Build RPM -> rpms/
./gemini-rtsw-ci/build_docker.sh              # Build dev Docker image
./gemini-rtsw-ci/dev_environment.sh           # el8-latest-devel (default)
./gemini-rtsw-ci/dev_environment.sh --el 9    # el9-latest-devel
./gemini-rtsw-ci/dev_environment.sh --prod    # el8-prod-devel
```

## Custom dependency setup

If your package has tricky dependencies (wrong versions, mixed repos), add a `custom-repo-setup.sh` in your repo root. It runs automatically before dependency resolution in both RPM and Docker builds; if absent, nothing happens.

```bash
#!/bin/bash
set -e
# Example: force-install a specific package
# dnf download some-package && rpm -ivh some-package.rpm --nodeps --force
```
