# Local development workflow

A step-by-step guide to making and testing a change in an EPICS 7 repo built on this pipeline (e.g. `softTCS_mk`). For how the CI pipeline itself works, see [README.md](README.md).

## 1. Clone the repo

```bash
git clone --recurse-submodules <repo-url>
cd <repo-name>
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## 2. Create a branch

```bash
git checkout -b <your-branch-name>
```

## 3. Enter the Docker dev environment

Steps 5-6 below (TDCT and the build check) happen **inside this container** — it has the full EPICS toolchain already installed, so you don't need to set any of it up locally. Step 4 (editing code) can be done inside or outside the container.

On macOS, before entering, allow the container to reach your host's X server (needed for TDCT's GUI in step 5):

```bash
xhost +
```

Then start the container — this pulls the latest pre-built dev image from GHCR and drops you into a shell inside it, with the repo mounted at `/repo`:

```bash
./gemini-rtsw-ci/dev_environment.sh     # defaults to el8; --el 9 for EL9
```

## 4. Modify code

Edit source as needed, on the host or inside the container. For example, in `softTCS_mk` (SCS), application source lives under `scs-cp-iocApp/src/` (e.g. `scs-cp-iocApp/src/chopControl.h`).

## 5. Modify schematics with TDCT (if applicable)

TDCT is a GUI tool; run it from the package's `Db/` directory, against the `tdct.cfg` found there. For example, in `softTCS_mk` (SCS):

```bash
cd scs-cp-iocApp/Db
tdct -cfg ./tdct.cfg
```

## 6. Build and test locally (`make`)

Compile inside the container to check your change before committing — this is faster than a full RPM build. From the repo root (e.g. `scs_cp/`):

```bash
make
```

## 7. Commit and push

Run from the host (or from inside the container — both share the same mounted repo):

```bash
git add <files>
git commit -m "<message>"
git push -u origin <your-branch-name>
```

Pushing to GitHub triggers the CI pipeline (`ci.yml`) for that branch/PR: it builds the RPM, publishes it as a scratch tag (`ghcr.io/gemini-rtsw/rpm-repo:rpm-<pkgname>-el<N>`), and pushes a dev image. See [README.md](README.md#how-the-pipeline-works) for the full pipeline flow.

The built RPM is also uploaded as a **GitHub Actions artifact** on that workflow run (named `rpms-el<N>`). To grab it without pulling from rpm-repo, either open the run under the repo's **Actions** tab and download `rpms-el<N>` from the **Artifacts** section at the bottom of the run summary, or use the `gh` CLI:

```bash
gh run list --limit 5                       # find the run ID
gh run download <run-id> -n rpms-el8        # downloads into ./rpms-el8/
```

See [README.md](README.md#downloading-a-built-rpm-from-github-actions) for details.

## 8. Build the RPM locally

From the **project repo root** on the host (not inside the submodule):

```bash
./gemini-rtsw-ci/build_rpm.sh
```

Produces the package RPM(s) in `rpms/` in the repo root — these are the same RPMs CI builds and publishes, just built and kept on your machine instead of pushed to the rpm-repo. See [README.md](README.md#local-builds) for prerequisites (Docker running, logged in to GHCR).
