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

## 3. Modify code

Edit source as needed.

## 4. Modify schematics with TDCT (if applicable)

TDCT is a GUI tool and runs **inside the Docker dev environment** (see step 7), against the `schematics/` directory in the repo.

On macOS, before entering the dev container, allow the container to reach your host's X server:

```bash
xhost +
```

Then, inside the dev container:

```bash
cd schematics
tdct -cfg tdct.cfg
```

## 5. Build and test locally (`make`)

Compile inside the dev environment to check your change before committing — this is faster than a full RPM/Docker build.

## 6. Commit and push

```bash
git add <files>
git commit -m "<message>"
git push -u origin <your-branch-name>
```

## 7. Build the RPM locally

From the **project repo root** (not inside the submodule):

```bash
./gemini-rtsw-ci/build_rpm.sh
```

Produces the package RPM in `rpms/`.

## 8. Build and enter the Docker dev environment locally

```bash
./gemini-rtsw-ci/build_docker.sh        # build the dev image
./gemini-rtsw-ci/dev_environment.sh     # enter it (defaults to el8; --el 9 for EL9)
```

See [README.md](README.md#local-builds) for prerequisites (Docker running, logged in to GHCR).
