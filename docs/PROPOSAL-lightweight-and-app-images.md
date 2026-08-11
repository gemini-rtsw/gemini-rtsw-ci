# Proposal: lightweight builds and versioned application images

Three gaps, one theme: the pipeline assumes every package is an EPICS package
that ships a `-devel` RPM and a developer container. Repos that ship a *runtime*
container — Python services, web gateways — have no path today.

Everything below defaults to current behaviour. An existing caller that changes
nothing gets the same build it gets now.

## What a caller writes

```yaml
jobs:
  build:
    uses: gemini-rtsw/gemini-rtsw-ci/.github/workflows/ci.yml@main
    secrets: inherit
    with:
      scripts_dir: gemini-rtsw-ci
      el_version: '9'
      profile: lightweight                    # 1. no EPICS toolchain
      app_image: Dockerfile                   # 2. build+push the product image
      spec_path: packaging/tsrs-screen.spec
      verify_cmd: ./packaging/verify-rpm.sh
  publish:
    needs: build
    uses: gemini-rtsw/gemini-rtsw-ci/.github/workflows/publish.yml@main
    secrets: inherit
```

Five lines describe the whole difference. Omit them and nothing changes.

## 1. `profile: lightweight`

**Problem.** A noarch package shipping a systemd unit and some config pays for
the entire EPICS build: the multi-GB `rpm-repo` dependency container, EPEL/CRB,
rclone, `gemini-ade`, a required `-devel` subpackage, and a dev image it will
never run. That is the whole build for such a package.

**Change.** `profile` (`epics` default | `lightweight`). Lightweight skips the
rpm-repo container and its network, installs only
`rpm-build dnf-plugins-core git`, drops the `-devel` requirement, and skips the
`free-disk-space` step and the `build-docker` job.

**Supporting inputs:** `builder_image` (pin a different base), `spec_path` (a
spec that is neither `./*.spec` nor `SPECS/*.spec`), `verify_cmd` (package
checks the generic build cannot make).

**Also fixed:** the version is read with `rpmspec` instead of grepping
`^Version:`, which falls back to `1.0` whenever the version comes from a macro
and then names the tarball something the spec cannot find. Any package keeping
its version in one `%global` hits this today.

*Status: implemented on the `lightweight` branch. tsrs_screen builds and passes
its own verification through it.*

## 2. `app_image`

**Problem.** `build_docker.sh` builds a **developer** container: toolchain plus
`-devel` RPMs, for `dev_environment.sh`. There is no way to say "this repo's
product is a container that ships to production". Repos that ship one must
hand-roll a second workflow, which is exactly what the shared pipeline exists to
prevent.

**Change.** `app_image: <Dockerfile path>` builds and pushes that Dockerfile as
the repo's application image. Same login and GHCR machinery as the dev image;
different tag namespace and no `-devel` dependency.

Pushed only when the build is not a pull request, and only after `verify_cmd`
passes, so an image never ships ahead of its checks.

## 3. Versioned images, deployed by RPM

**Problem — the interesting one.** An RPM can pin the exact container a host
runs, which gives ITOps `rpm -q` to see what is deployed and `dnf downgrade` to
roll it back. That only holds if the image tag and the RPM version cannot drift
apart. Nothing enforces that today, and the failure is silent: the RPM installs,
`dnf` reports success, and the panel dies at the next restart on a missing
image.

**Change.** The image tag is *derived from the spec*, never typed:

```
ghcr.io/gemini-rtsw/<repo>:<version>              # what the unit pins
ghcr.io/gemini-rtsw/<repo>:<version>-git<hash>    # 1:1 with the RPM NVR
ghcr.io/gemini-rtsw/<repo>:latest
```

`<version>` comes from `rpmspec -q --queryformat "%{version}"` on the same spec
the RPM is built from, so one value drives the RPM version, the image tag and
the unit's pin.

**Ordering is the guarantee.** Within the build job:

```
build RPM  →  verify_cmd  →  push app image  →  push RPM scratch tag  →  publish :latest
```

The RPM is registered only after its image exists. A published RPM can therefore
never point at an image that was never pushed — which is the failure mode this
whole item is about.

Optional `app_image_require_pin: true` fails the build when the spec pins an
image tag that does not match what this run pushed, catching a spec edited out
of step with the pipeline.

## Compatibility and risk

| Change | Default | Reaches other repos |
|---|---|---|
| `profile`, `builder_image`, `spec_path`, `verify_cmd`, `app_image` | off / current behaviour | only if they opt in |
| `ci.yml` edits (inputs, `if:` guards) | — | immediately, live from `@main` |
| `build_rpm.sh` edits | — | only when a repo bumps its submodule |

The script half is gated behind each repo's submodule pin, so a bad script
change cannot break every repo at once. The live surface is the workflow YAML.

**Verification done:** the container script was extracted from `main` and from
the branch and run in a Rocky container with `dnf`/`rpmbuild` stubbed — with
`profile: epics` the effective commands are identical to `main`. The embedded
`bash -c` block was syntax-checked after editing, since an unbalanced `if` there
would break every caller.

**Verification still required before merge:** one real EPICS package built on
both EL8 and EL9 legs. EL8 uses `powertools` and EL9 `crb`, so they can fail
differently, and no amount of tracing substitutes for a real build.

## Suggested rollout

1. Merge `lightweight` (item 1) after the EPICS regression run — tsrs_screen
   already depends on it.
2. Add items 2 and 3 on the same branch; tsrs_screen is the first consumer and
   currently has no CI-built image at all.
3. Point tsrs_screen at `@main` and bump its submodule.
