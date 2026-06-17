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

## Appendix: Dependency-versioning model (DESIGN -- not yet adopted)

> Status: **documented direction, not current practice.** Today we still pin
> dependencies by hand in each spec as we build up the stack ("pin as we go").
> This appendix describes where we intend to take it. The plan is **entirely
> spec-defined** -- no lockfiles, no extra file formats -- and the dev/release
> split is a **release policy**, not a pipeline feature.

### Problem this solves

Every spec hard-pins its dependencies in-tree, e.g.:

```
BuildRequires: epics-base-devel = 7.0.7-0.git.<hash>%{?dist}
BuildRequires: sequencer-devel  = 2.2.9...-4.git.<hash>%{?dist}
```

Because the RPM Release embeds the source git hash, **every rebuild of a
low-level package moves its hash**, so every downstream spec must be hand-edited
to the new hash -- across ~20 repos, in dependency order. Error-prone (mistyped
hashes, missed repos, stale pins) and slow.

The two requirements are in tension:

- **Development** wants dependencies to **float** -- pick up the latest build,
  no manual pinning, no hash chasing.
- **Releases** want dependencies **pinned** -- an exact, reproducible set we can
  return to later for fixes.

### The model: spec-defined, float on dev, pin at release

The spec is the **single source of truth** for versions in both states. There is
no separate lockfile; the pins live in the `.spec` so the shipped RPM is
self-describing -- `rpm -q --requires <pkg>` on a production box shows the exact
dependency set, no digging through repos.

**1. `main` (dev) carries FLOATING dependencies.**
BuildRequires are written **unversioned**:

```
BuildRequires: epics-base-devel
BuildRequires: sequencer-devel
```

Each build resolves whatever is newest in the rpm-repo. No pinning, no
hand-edits, no hash treadmill. A rebuilt dependency simply flows downstream on
the next build.

**2. A release is a TAG/branch with PINNED dependencies in the spec.**
Cutting a release is a deliberate act:
  a. reach a known-good point on `main`,
  b. create a release branch/tag,
  c. on that release branch, the spec's BuildRequires are written as exact NVRs
     (`epics-base-devel = 7.0.7-0.git.<hash>%{?dist}`),
  d. commit + tag.

The release tag *is* the pinned spec. To rebuild a release, check out its
tag -- the exact pins are right there in the spec. Nothing else to consult.

**3. Pins are filled FROM REALITY, not typed by hand.**
To remove transcription error, a small helper writes the resolved NVRs back into
the spec at release time (the human reviews the `git diff`, then commits):
  - build once (floating) on the release branch,
  - query the exact NVR of each dependency that actually resolved (from the
    build container, or the rpm-repo), and
  - rewrite each `BuildRequires`/`Requires` line in the spec to that NVR.

Same "read from reality, deterministic, no typos" property as a generated
lockfile -- but the result lands **in the spec**, where ops can read it off the
installed RPM.

**4. After a release is tagged, `main` goes back to floating.**
The pins live only on the release branch/tag. `main` strips them so development
keeps floating. (This is exactly the workflow we plan to adopt: pin as we
build up the current stack, tag a release branch once it's solid, then remove
the pins from `main`.)

### Why this beats the lockfile approach

- **No new file format**, no "locked mode" build logic, no lockfile-vs-spec
  dual source. One source of truth: the spec.
- **No pipeline changes** -- the pipeline already builds whatever the spec says.
  Floating spec -> floating build; pinned spec -> pinned build. It never needs
  to know which mode it is in.
- **Production provenance is in the artifact.** `rpm -q --requires` / `rpm -qV`
  on the box tells you the exact versions -- no repo archaeology.
- The only new tooling is the optional **release-time pin helper**; pinning can
  always be done by hand as a fallback.

### Open questions for the team

- **Where the helper reads NVRs from.** Querying the build container after a
  build (most accurate -- it's literally what linked) vs. querying the rpm-repo
  at pin time (simpler, slightly less precise if the repo moved meanwhile).
- **Per-package vs. fleet-wide release.** Tagging each repo's release branch
  independently vs. a coordinated fleet release (e.g. "2026q3") where all specs
  are pinned and tagged together as a unit.
- **Retention.** Rebuilding an old release needs its old RPMs to still exist in
  the rpm-repo. Old NVRs must not be pruned (or release RPMs archived), or past
  releases become unbuildable.
- **Optional dependency triggers.** Whether a low-level publish should fan out
  rebuilds to dependents on `main`; if so, batch them (one rtems publish ->
  ~20 dependents, each ~90 min) rather than firing per-publish.
