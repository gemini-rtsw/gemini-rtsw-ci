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

Steps 4-6 below (editing, schematics, and build checks) all happen **inside this container**, before you commit anything on the host. The container has the full EPICS toolchain already installed, so you don't need to set any of it up locally.

On macOS, before entering, allow the container to reach your host's X server (needed for TDCT's GUI in step 5):

```bash
xhost +
```

Then start the container:

```bash
./gemini-rtsw-ci/build_docker.sh        # build the dev image (first time / after a Dockerfile change)
./gemini-rtsw-ci/dev_environment.sh     # enter it (defaults to el8; --el 9 for EL9)
```

This drops you into a shell inside the container, with the repo mounted at `/repo`. Everything in steps 4-6 runs from there.

## 4. Modify code

Edit source as needed.

## 5. Modify schematics with TDCT (if applicable)

TDCT is a GUI tool; run it against the `schematics/` directory in the repo:

```bash
cd schematics
tdct -cfg tdct.cfg
```

## 6. Build and test locally (`make`)

Compile inside the container to check your change before committing — this is faster than a full RPM build.

## 7. Commit and push

Run from the host (or from inside the container — both share the same mounted repo):

```bash
git add <files>
git commit -m "<message>"
git push -u origin <your-branch-name>
```

## 8. Build the RPM locally

From the **project repo root** on the host (not inside the submodule):

```bash
./gemini-rtsw-ci/build_rpm.sh
```

Produces the package RPM in `rpms/`. See [README.md](README.md#local-builds) for prerequisites (Docker running, logged in to GHCR).
