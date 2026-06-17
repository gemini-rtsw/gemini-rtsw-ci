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

No token setup needed -- `GITHUB_TOKEN` handles everything automatically. You do, however, need to grant the new repo access to the shared rpm-repo container (see next section).

## Required package access

The `ghcr.io/gemini-rtsw/rpm-repo` container is private to the org. Each project repo using this CI needs **Write** access to it: read so the build can pull dependencies, write so the build can publish its RPM (the publish runs `upload-rpm.sh`, which pushes the package's `rpm-*` tag and rebuilds `rpm-repo:latest`).

1. Open **github.com/orgs/gemini-rtsw/packages/container/rpm-repo/settings**
2. Under **Manage Actions access**, click **Add Repository** and add the new project repo
3. Set the role to **Write**

Common failure modes if this is missed:

- `docker: Error response from daemon: denied` during the `docker pull ghcr.io/gemini-rtsw/rpm-repo:latest` step -- no read access.
- `denied: permission_denied: write_package` during the publish step -- has read but not write. **Read alone is not enough**; the pipeline pushes the package's `rpm-*` tag and a new `rpm-repo:latest` at the end.

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

## Custom Dependency Setup

If your package has tricky dependencies (wrong versions, mixed repos, etc.), create a `custom-repo-setup.sh` in your repo root. It runs automatically before dependency resolution in both RPM and Docker builds. If the file doesn't exist, nothing happens.

```bash
#!/bin/bash
set -e
# Example: force-install a specific package
# dnf download some-package && rpm -ivh some-package.rpm --nodeps --force
```

## What the Pipeline Produces

- **RPMs** -- saved as GitHub Actions artifacts, and published to the rpm-repo
  via `upload-rpm.sh`: each package's RPM(s) are pushed as a per-package tag
  `ghcr.io/gemini-rtsw/rpm-repo:rpm-<pkgname>`, and `rpm-repo:latest` (the served
  yum repo) is rebuilt from all `rpm-*` tags. Per-package tags mean concurrent
  builds never clobber each other -- no publish lock needed. See the
  `gemini-rtsw-repo` README for details.
- **Docker dev image** -- pushed to `ghcr.io/gemini-rtsw/<repo-name>:latest-devel`

---

## Appendix: Proposed dependency-versioning model (DESIGN -- not implemented)

> Status: **draft for team discussion.** Nothing here is built yet. It documents
> a direction for replacing today's hand-pinned `BuildRequires` with an
> automated float-for-dev / lock-for-release scheme. Do not treat as current
> behavior.

### Problem this solves

Today every spec hard-pins its dependencies in-tree, e.g.:

```
BuildRequires: epics-base-devel = 7.0.7-0.git.<hash>%{?dist}
BuildRequires: sequencer-devel  = 2.2.9...-4.git.<hash>%{?dist}
```

This is both **manual** and **permanent in git**, so any time a low-level
package (rtems, epics-base, a support module) is rebuilt, every downstream spec
must be hand-edited to the new hash -- across ~20 repos, in dependency order.
That is error-prone (mistyped hashes, missed repos, stale pins) and slow.

The two requirements are in tension:

- **Development** wants dependencies to **float** -- pick up the latest build
  automatically, no manual pinning.
- **Releases** want dependencies **pinned** -- an exact, reproducible set we can
  return to later for fixes.

### Proposed model: float by default, lock at release

**1. Specs float (no version pins in dev).**
BuildRequires are written **unversioned**:

```
BuildRequires: epics-base-devel
BuildRequires: sequencer-devel
```

Each build resolves whatever is newest in `rpm-repo:latest`. No pinning, no
hand-edits. A rebuilt dependency simply flows downstream on the next build.

**2. (Optional) triggers keep the DAG current.**
When a low-level package publishes, a `repository_dispatch` can fan out to its
dependents so they rebuild against the new version automatically. Caveat: this
multiplies builds (one rtems publish -> ~20 dependent rebuilds, each ~90 min +
a large rpm-repo push), so triggers should likely **batch** (rebuild dependents
once after a set of low-level changes settles) rather than fire per-publish.

**3. Releases are locked by a GENERATED lockfile (never hand-edited).**
A `make-release` step:
  a. builds normally (against current latest),
  b. records the **exact NVR of every dependency that was actually resolved**
     (queried from the build container / rpm-repo) into a generated lockfile,
  c. commits the lockfile and tags the release.

Example generated `<pkg>.lock` (illustrative):

```
# GENERATED -- do not edit. Captured at release time from the live repo.
epics-base-devel = 7.0.7-0.git.1159d86
sequencer-devel  = 2.2.9.e5e3615-4.git.cc55bbd
slalib-devel     = 1.9.7-6.git.21692df
...
```

**4. Returning to a release rebuilds in "locked" mode.**
When a lockfile is present (i.e. building a release tag), `build_rpm.sh` builds
in locked mode: it injects each lockfile NVR as an exact pin **at build time**
(auto-generated into the spec / passed to dnf) -- the human never types a hash.
Same spec, two modes: floating (no lock) for dev, pinned (lock present) for
release.

### Why this removes human error

The lockfile is **read from reality, not authored** -- the generator records
what actually built, exactly as the one-time manual repin done by hand would,
but deterministically and every time. No transcribed hashes, no missed repos.

### Open questions for the team

- **Per-package lockfiles vs. one fleet-wide manifest.** A single
  release-wide manifest (pinning all packages together, tagged as a unit -- e.g.
  "2026q3") may model a coordinated release better than N per-IOC lockfiles.
- **Retention.** Locked rebuilds require the old RPMs to still exist in
  rpm-repo. Old NVRs must not be pruned (or release RPMs must be archived),
  or past releases become unbuildable.
- **Trigger batching / cost.** Given ~90 min builds and large rpm-repo pushes,
  decide whether/how to cascade rebuilds without build amplification.
- **Where locked-mode pinning is injected.** Generating a pinned spec from the
  floating spec + lock, vs. passing versions to `dnf`/`builddep` directly.
