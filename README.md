# dazel

> [!IMPORTANT]
> **dazel has moved to [ArmisSecurity/dazel](https://github.com/ArmisSecurity/dazel).** This repository
> is no longer maintained. New releases, issues and pull requests live there; the documentation below
> describes the current release. Existing `.dazelrc` files keep working; see
> [Upgrading from 0.0.x](https://github.com/ArmisSecurity/dazel#upgrading-from-00x).

[![CI](https://img.shields.io/github/actions/workflow/status/ArmisSecurity/dazel/ci.yml?branch=master&label=CI&color=0A66C2)](https://github.com/ArmisSecurity/dazel/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/dazel?color=0A66C2)](https://pypi.org/project/dazel/)
[![Python](https://img.shields.io/python/required-version-toml?tomlFilePath=https%3A%2F%2Fraw.githubusercontent.com%2FArmisSecurity%2Fdazel%2Fmaster%2Fpyproject.toml&label=python&color=0A66C2)](https://github.com/ArmisSecurity/dazel/blob/master/pyproject.toml)
[![License](https://img.shields.io/github/license/ArmisSecurity/dazel?color=0A66C2)](https://github.com/ArmisSecurity/dazel/blob/master/LICENSE)

Run [Bazel](https://bazel.build) inside a Docker container, as if it ran on your host.

Bazel builds are fast and reproducible, but only as reproducible as the machine they run on. dazel
defines the build environment as a Docker image and runs bazel in it through a transparent proxy:

```bash
dazel build //my/package/...
dazel test //my/package:tests
dazel run //my/package:binary -- --flag
```

The arguments go to bazel in the container unchanged (`docker exec`, as an argv list, never through a
shell). The workspace and bazel's output directories are bind mounted at the same paths, so `bazel-bin`,
`bazel-out` and the rest work on the host exactly as they would without dazel. The container is built,
started and restarted on demand.

dazel is maintained by [Armis](https://www.armis.com) open source. It was created by
[nadirizr](https://github.com/nadirizr) at [nadirizr/dazel](https://github.com/nadirizr/dazel), which
published the 0.0.x releases. [ArmisSecurity/dazel](https://github.com/ArmisSecurity/dazel) continues that project: 1.0 is a typed rewrite of the
original `dazel.py` that keeps its `.dazelrc` format, and the [changelog](https://github.com/ArmisSecurity/dazel/blob/master/CHANGELOG.md) covers the
whole history.

## Installation

```bash
uv tool install dazel     # or: pipx install dazel
```

dazel needs Python 3.11 or newer and Docker. Bazel itself does not need to be installed on the host.

## Quick start

1. Describe the build environment in a `Dockerfile.dazel` in the workspace root. The
   [`Dockerfile`](https://github.com/ArmisSecurity/dazel/blob/master/Dockerfile) in this repository is a good start: Debian with
   [Bazelisk](https://github.com/bazelbuild/bazelisk) installed as `bazel`, so the workspace's
   `.bazelversion` selects the Bazel release.
2. Optionally, add a `.dazelrc` next to it (see [Configuration](#configuration)):

   ```python
   DAZEL_REPOSITORY = "myproject"
   DAZEL_VOLUMES = ["$HOME/.ssh:/root/.ssh:ro"]
   DAZEL_PER_WORKSPACE_CONTAINER = True
   ```

3. Run `dazel build //...`. The first run builds the image and starts the container. Later runs reuse
   it. dazel restarts the container when the Dockerfile or an rc file changes.

If `DAZEL_DOCKERFILE` does not exist, dazel pulls `DAZEL_REPOSITORY/DAZEL_IMAGE_NAME` instead, so a team
can share a prebuilt image.

## How it works

### Starting the container

The first `dazel` command in a workspace, and any command after the container needs a restart, starts
the container. Start-up runs under a file lock (`<DAZEL_BAZEL_USER_OUTPUT_ROOT>/.dazel.lock`, or the
system temp directory when there's no output root), so concurrent dazels never race. A dazel that had to
wait checks again once it holds the lock, so the container is started once.

1. **Image.** If `DAZEL_DOCKERFILE` exists, dazel builds it:
   `docker build <DAZEL_DOCKER_BUILD_ARGS> -t <DAZEL_REPOSITORY>/<DAZEL_IMAGE_NAME> -f <DAZEL_DOCKERFILE> <DAZEL_BUILD_DIRECTORY>`.
   Otherwise it pulls `<DAZEL_REPOSITORY>/<DAZEL_IMAGE_NAME>`. If the pull fails but the image exists
   locally, dazel uses the local image.
2. **Services.** If `DAZEL_DOCKER_COMPOSE_FILE` is set and the compose command is installed, dazel runs
   `pull --ignore-pull-failures`, `build` and `up -d` for `DAZEL_DOCKER_COMPOSE_SERVICES`, with
   `COMPOSE_PROJECT_NAME` set. Outside per-workspace mode, `up` also gets `--force-recreate`.
   Otherwise dazel creates the `DAZEL_NETWORK` network if it is missing, and starts each
   `DAZEL_RUN_DEPS` container that isn't already running.
3. **Host directories.** dazel creates on the host the bazel output root, the mounted output
   directories and the disk cache directory, so Docker doesn't create them root-owned.
4. **Container.** dazel stops and removes any old container of the same name, then runs:

   ```text
   docker run -id --name=<container> --ulimit nofile=1048576:1048576
     [--platform=…] [--privileged] [--user=…] -w <workdir>
     -v <each mount> -p <each port> -e <each env var>
     [--gpus …] [--group-add …] [--shm-size=…] [--net=<network>]
     <image> <DAZEL_RUN_COMMAND>
   ```

5. **Run file.** dazel writes the container name to `DAZEL_RUN_FILE`.

### Mounts

The container always gets these mounts, in this order:

| Mount | Why |
|---|---|
| Each `DAZEL_VOLUMES` entry | Your extra mounts. |
| `<workdir>:<workdir>` | The workspace (or `DAZEL_DIRECTORY`), at the same path as on the host. |
| `<output base>/{external,action_cache,execroot,<workspace name>}` at the same paths | Bazel's outputs, so `bazel-*` symlinks resolve on the host and the cache survives restarts. `:delegated` unless `DAZEL_DELEGATED_VOLUME` is off. |
| `DAZEL_BAZEL_DISK_CACHE` | A shared disk cache, when configured. |

### Running a command

When the container is running, attached to the right network, with the workspace mounted, and nothing
calls for a restart, dazel runs:

```text
docker exec -i -e COLUMNS=… -e LINES=… -e TERM=… [-t] [--privileged] [--user=…] <container>
  <DAZEL_COMMAND> [--bazelrc=<DAZEL_BAZEL_RC_FILE>] [output flags] <your arguments>
```

`-t` is added when stdout is a terminal. The output flags are:

- **As root (the default):** `--output_user_root=/var/bazel/workspace/_bazel_<user> --output_base=<output base>`.
  The output base is `<DAZEL_BAZEL_USER_OUTPUT_ROOT>`, or `<DAZEL_BAZEL_USER_OUTPUT_ROOT>/<md5>` in the
  isolated modes.
- **With `DAZEL_USER`:** just `--output_user_root=<DAZEL_BAZEL_USER_OUTPUT_ROOT>`.

With an empty `DAZEL_COMMAND`, your arguments run as a command of their own:
`DAZEL_COMMAND= dazel ls /` lists the container's root directory.

### When the container restarts

dazel starts the container again when any of these is true:

- it isn't running;
- it doesn't have this workspace mounted;
- it isn't attached to the network;
- the run file is missing;
- the Dockerfile or any rc file that was read changed after the run file was written.

With an empty `DAZEL_RUN_FILE`, only the first three apply.

## Commands

All arguments are passed to bazel, except these, which dazel handles when they are the whole command
line:

| Command | Effect |
|---|---|
| `dazel --dazel-version` | Print the dazel version. |
| `dazel --dazel-container-name` | Print the container name for this workspace (useful in scripts). |
| `dazel --dazel-clean-workspace` | Remove this workspace's container, bazel output base and run file. This only works in per-workspace mode, because otherwise both are shared. |
| `dazel --dazel-clean-legacy [--yes]` | List, or with `--yes` delete, the shared output base left behind by dazel 0.0.x. See [Upgrading from 0.0.x](#upgrading-from-00x). |

A command killed by signal N exits with status `128 + N`, like a shell. Ctrl-C reaches bazel in the
container and does not produce a traceback.

## Parallel git worktrees

By default all workspaces share one container (`dazel`) and one bazel output base. The container is
recreated whenever a different workspace uses it, so builds in two git worktrees keep restarting each
other. Set `DAZEL_PER_WORKSPACE_CONTAINER = True` to give each workspace:

- **Its own container and output base**: `<DAZEL_INSTANCE_NAME>_<md5>` and
  `<DAZEL_BAZEL_USER_OUTPUT_ROOT>/<md5>`, keyed on the workspace's real path. dazel writes
  `WORKSPACE: <path>` into `<base>/README`, so a base whose worktree is gone can be identified and
  removed.
- **A shared image, compose project and network.** Compose runs with `--project-directory` set to the
  compose file's location in the *primary* checkout, so relative bind mounts resolve the same from every
  worktree and a new worktree never restarts the shared services.
- **Serialised start-up.** A file lock (`<output root>/.dazel.lock`) guards building the image and
  starting the services and the container. A dazel that waited checks again once it holds the lock, so
  concurrent commands start the container once.
- **Ports from the primary checkout only.** Linked worktrees publish no `DAZEL_PORTS`, so fixed ports
  don't collide (`DAZEL_PORTS_ONLY_PRIMARY`).

A per-workspace output base starts cold. Share work between them with a disk cache:
`DAZEL_BAZEL_DISK_CACHE = "~/.cache/bazel-disk:/root/.cache/bazel-disk"` mounts one host directory in
every container (creating it first, so Docker doesn't create it root-owned). Point bazel's `--disk_cache`
at the container path in your bazelrc. dazel passes no bazel flags of its own.

## Configuration

### Where settings come from

Settings come from four layers. Lowest precedence first:

1. `~/.dazelrc`: per-user defaults, e.g. your registry or extra mounts.
2. `.dazelrc` in the workspace root: the project configuration, committed to the repository. The
   `DAZEL_RC_FILE` environment variable reads a different file instead, e.g. a CI configuration.
3. `.dazelrc.local` in the workspace root: a developer's personal overrides. Add it to `.gitignore`.
4. `DAZEL_*` environment variables, e.g. `DAZEL_PLATFORM=linux/amd64 dazel build //...`.

rc files are **executed as Python**: every top-level name starting with `DAZEL_` is a setting, and
everything else is ignored, so you can compute values with ordinary code:

```python
import os

HOST_ARCH = "arm64" if os.uname().machine in ("arm64", "aarch64") else "amd64"
DAZEL_PLATFORM = f"linux/{HOST_ARCH}"
DAZEL_VOLUMES = [f"{os.path.expanduser('~')}/.netrc:/root/.netrc:ro"]
```

A later layer replaces a key's value whole; lists are not merged. Because rc files run as code, running
dazel in a repository means trusting that repository (see [SECURITY.md](https://github.com/ArmisSecurity/dazel/blob/master/SECURITY.md)).

The workspace root is the closest directory, starting from the current one (or from
`DAZEL_DIRECTORY`), that holds a `WORKSPACE`, `WORKSPACE.bazel` or `MODULE.bazel` file.

### Value types

| Type | Accepted values |
|---|---|
| text | Any string. A number is converted with `str()`. |
| list | A Python list or tuple, or a comma-separated string. Entries are stripped, and empty entries dropped. |
| flag | A boolean. From a string (e.g. an environment variable), `""`, `0`, `false`, `no` and `off` are false, case-insensitively; anything else is true. |
| path | Text that also expands a leading `~` to your home directory. A relative path resolves against the workspace root. |
| command | Text split into words like a shell would (`shlex`), or a list of words. Nothing is expanded. |

**Variable expansion.** `$VAR`, `${VAR}`, `${VAR-default}` (default when unset) and `${VAR:-default}`
(default when unset or empty) are expanded from the environment. An unset variable becomes the empty
string. In a value, `$PWD` is the directory dazel was started in.

Expansion happens only in `DAZEL_VOLUMES`, `DAZEL_PORTS`, `DAZEL_ENV_VARS` and the path settings.
Nothing is passed through a shell: `$(…)`, backticks, globs and `||` stay literal.

### Reference

#### Image

**`DAZEL_DOCKERFILE`**: path, default `Dockerfile.dazel`. The Dockerfile to build the image from. If
the file doesn't exist, dazel pulls the image instead, so a team can share a prebuilt image by
committing a `.dazelrc` without a Dockerfile. Editing the Dockerfile restarts the container on the next
command.

**`DAZEL_BUILD_DIRECTORY`**: path, default the workspace root. The `docker build` context. Set it when
the Dockerfile copies files relative to its own directory:

```python
DAZEL_DOCKERFILE = "tools/docker/Dockerfile"
DAZEL_BUILD_DIRECTORY = "tools/docker"
```

**`DAZEL_DOCKER_BUILD_ARGS`**: command, default empty. Extra `docker build` arguments, inserted before
`-t`:

```python
DAZEL_DOCKER_BUILD_ARGS = "--pull --build-arg BAZELISK_VERSION=v1.30.0 --cache-from registry.example.com/team/dazel"
```

**`DAZEL_REPOSITORY`**: text, default `dazel`. The repository part of the image reference
`<DAZEL_REPOSITORY>/<DAZEL_IMAGE_NAME>`. It may include a registry host (`registry.example.com/team`),
which is where a missing Dockerfile makes dazel pull from. Empty uses the image name alone.

**`DAZEL_IMAGE_NAME`**: text, default `dazel`. The image name. With `DAZEL_WORKSPACE_HEX`, a built
image gets the suffix `_<md5>`.

**`DAZEL_PLATFORM`**: text, default empty. Passed as `--platform` to `docker run`. To build for the
same platform, also add `--platform=…` to `DAZEL_DOCKER_BUILD_ARGS`. Use it to run `linux/amd64`
toolchains on Apple silicon, or to pin the architecture on mixed CI fleets.

#### Container

**`DAZEL_INSTANCE_NAME`**: text, default `dazel`. The container name. In the isolated modes it gets the
suffix `_<md5 of the workspace path>`. `dazel --dazel-container-name` prints the resolved name.

**`DAZEL_RUN_COMMAND`**: command, default `/bin/bash`. The container's main process, which only has to
stay alive (the container runs with `-id`). Use e.g. `sleep infinity` for images without bash.

**`DAZEL_DOCKER_COMMAND`**: command, default `docker`. The Docker CLI, e.g. `podman` or
`sudo docker`. dazel fails early if the first word isn't on `PATH`.

**`DAZEL_DOCKER_MACHINE`**: text, default empty. The name of a
[docker-machine](https://github.com/docker/machine). When set and `docker-machine` is installed, every
Docker command runs with the environment from `docker-machine env <name>`.

**`DAZEL_DOCKER_RUN_PRIVILEGED`**: flag, default `False`. Adds `--privileged` to `docker run`,
`docker exec` and run dependencies. Bazel's Linux sandbox needs it in most images. Without it, use
`--spawn_strategy=local` (or `processwrapper-sandbox`) in your bazelrc.

**`DAZEL_USER`**: text, default empty (the image's user, usually root). Passed as `--user` to
`docker run` and `docker exec`, e.g. `1000:1000`. bazel then gets
`--output_user_root=<DAZEL_BAZEL_USER_OUTPUT_ROOT>` instead of the root layout, so point the output
root at a directory that user owns.

**`DAZEL_GROUPS`**: list, default empty. One `--group-add` per entry, e.g. the group id of a mounted
Docker socket for a non-root user.

**`DAZEL_GPUS`**: list, default empty. Joined with commas and passed as `--gpus`: `all`, or
`device=0,1`. Needs the NVIDIA container toolkit.

**`DAZEL_SHM_SIZE`**: text, default empty. Passed as `--shm-size`, e.g. `2g`, for tests that need more
than Docker's 64 MB `/dev/shm`.

**`DAZEL_VOLUMES`**: list, expanded, default empty. Extra mounts in `docker run -v` syntax,
`host:container[:options]`, placed before dazel's own mounts:

```python
DAZEL_VOLUMES = ["$HOME/.ssh:/root/.ssh:ro", "/var/run/docker.sock:/var/run/docker.sock"]
```

**`DAZEL_PORTS`**: list, expanded, default empty. Published ports in `docker run -p` syntax,
`[interface:]host:container`, e.g. `127.0.0.1:8080:8080`. In per-workspace mode only the primary
checkout publishes them (see `DAZEL_PORTS_ONLY_PRIMARY`).

**`DAZEL_ENV_VARS`**: list, expanded, default empty. `NAME=value` entries passed with `-e` to
`docker run`, so they are set for every command in the container:

```python
DAZEL_ENV_VARS = ["CI=${CI:-}", "GIT_ASKPASS=$PWD/.git-askpass"]
```

**`DAZEL_DIRECTORY`**: text, default the workspace root. Mounts this directory and makes it the
container's working directory, instead of the workspace root. In the environment it is also where the
workspace search starts. Names and output bases stay keyed on the workspace root.

**`DAZEL_RUN_FILE`**: path, default `.dazel_run`. A file in which dazel records the container name
after each start; scripts can read it. Its timestamp also decides restarts: a Dockerfile or rc file
newer than it restarts the container. Empty disables it, and then a running container is never
restarted for changes.

**`DAZEL_RC_FILE`** (environment only): path, default `<workspace>/.dazelrc`. Reads this file as the
project rc instead. `~/.dazelrc` and `.dazelrc.local` still apply around it.

#### Bazel

**`DAZEL_COMMAND`**: command, default `/usr/bin/bazel`. The command run by `docker exec` before your
arguments. Use `/usr/local/bin/bazelisk`, or `bazel --noworkspace_rc` to ignore the workspace bazelrc.
Keep build flags in a bazelrc instead. Empty runs your arguments as the command.

**`DAZEL_BAZEL_RC_FILE`**: text, default empty. Passed to bazel as `--bazelrc=…`, a path as the
container sees it, typically relative to the workspace, e.g. `tools/ci.bazelrc`.

**`DAZEL_BAZEL_USER_OUTPUT_ROOT`**: text, default `~/.cache/bazel/_bazel_<user>`. The host directory
holding bazel's output bases. dazel creates it if it is missing. The output base inside it is mounted
into the container at the same path, so bazel's output symlinks resolve on the host. If empty, dazel
derives it from where the workspace's `bazel-out` symlink points.

**`DAZEL_BAZEL_DISK_CACHE`**: path, default empty. `host[:container]`, a bind mount for bazel's
[disk cache](https://bazel.build/remote/caching#disk-cache). The container path must be absolute and
defaults to the host path. dazel creates the host directory. dazel passes no `--disk_cache` flag, so
point your bazelrc's `--disk_cache` at the container path:

```python
DAZEL_BAZEL_DISK_CACHE = "~/.cache/bazel-disk:/root/.cache/bazel-disk"
```

**`DAZEL_DELEGATED_VOLUME`**: flag, default `True`. Adds `:delegated` to the output directory mounts,
which speeds up bind mounts on Docker Desktop for macOS and is ignored elsewhere.

#### Workspace isolation

**`DAZEL_PER_WORKSPACE_CONTAINER`**: flag, default `False`. One container and output base per
workspace. They are named and keyed on the md5 of the workspace's real path. The image, compose
project and network stay shared. See [Parallel git worktrees](#parallel-git-worktrees).

**`DAZEL_PORTS_ONLY_PRIMARY`**: flag, default `True` in per-workspace mode, `False` otherwise. When on,
a linked git worktree publishes no `DAZEL_PORTS`; only the primary checkout does. Turn it off to
publish everywhere, e.g. when each worktree uses its own ports.

**`DAZEL_WORKSPACE_HEX`**: flag, default `False`. The older isolation mode. Each workspace gets its own
container `<name>_<md5>`, compose project `<project><md5>`, output base and, when built from a
Dockerfile, image `<image>_<md5>`. Prefer `DAZEL_PER_WORKSPACE_CONTAINER`, which shares the image and
services.

#### Services

**`DAZEL_DOCKER_COMPOSE_FILE`**: path, default empty. A Compose file whose services start before the
container, e.g. a database the tests use.

**`DAZEL_DOCKER_COMPOSE_SERVICES`**: list, default all services. The services to pull, build and start.

**`DAZEL_DOCKER_COMPOSE_COMMAND`**: command, default `docker-compose`. The Compose CLI. Set it to
`docker compose` for the Compose v2 plugin. If the first word isn't installed, dazel falls back to
`DAZEL_RUN_DEPS`.

**`DAZEL_DOCKER_COMPOSE_PROJECT_NAME`**: text, default `dazel`. `COMPOSE_PROJECT_NAME` for the
compose commands.

**`DAZEL_NETWORK`**: text, default `dazel`. The network the container joins (`--net`). With a compose
file it is the compose network `<project>_<network>`. Without one, dazel creates it if it is missing.
Docker's built-in `host`, `bridge` and `none` are used as they are. Empty adds no `--net`.

**`DAZEL_RUN_DEPS`**: list, default empty. Containers to start on the network when there is no compose
file (or no compose command), as `image[:tag][::name]`. A container without an explicit name is called
`<network>_<image>`, with `/` and `:` replaced by `_`. One that is already running is left alone.

```python
DAZEL_RUN_DEPS = ["postgres:16::db", "redis:7"]
```

## Recipes

- **`$HOME` inside the container.** Variables are expanded on the host. To give the container your host
  home path, pass it explicitly: `DAZEL_ENV_VARS = ["HOME=$HOME"]`.
- **SSH agent.** Mount the socket and pass its path:
  `DAZEL_VOLUMES = ["$SSH_AUTH_SOCK:/ssh-agent"]` and `DAZEL_ENV_VARS = ["SSH_AUTH_SOCK=/ssh-agent"]`.
- **Docker from inside the container.** Mount `/var/run/docker.sock` through `DAZEL_VOLUMES`. When you run
  as a non-root user, also set `DAZEL_GROUPS` to the socket's group id.
- **Non-root containers.** With `DAZEL_USER`, set `DAZEL_BAZEL_USER_OUTPUT_ROOT` to a directory that user
  owns. Docker creates missing bind-mount sources as root.

## Examples

**A prebuilt image from a registry.** Commit no Dockerfile, and every developer pulls the same image:

```python
DAZEL_REPOSITORY = "registry.example.com/build"
DAZEL_IMAGE_NAME = "bazel-toolchain:2026.10"
DAZEL_DOCKERFILE = "/nonexistent"  # never build; always pull
DAZEL_DOCKER_RUN_PRIVILEGED = True
```

**Services for integration tests.** Start a database next to the build container, on a network the
tests can reach by service name:

```python
DAZEL_DOCKER_COMPOSE_FILE = "tools/dazel/docker-compose.yml"
DAZEL_DOCKER_COMPOSE_COMMAND = "docker compose"
DAZEL_DOCKER_COMPOSE_SERVICES = ["postgres"]
DAZEL_NETWORK = "default"  # joins <project>_default, compose's own network
```

**A developer laptop with many worktrees.**

```python
import os

DAZEL_PER_WORKSPACE_CONTAINER = True
DAZEL_BAZEL_DISK_CACHE = "~/.cache/bazel-disk:/root/.cache/bazel-disk"
DAZEL_PORTS = ["127.0.0.1:8080:8080"]
DAZEL_PLATFORM = "linux/arm64" if os.uname().machine == "arm64" else "linux/amd64"
DAZEL_DOCKER_BUILD_ARGS = f"--platform={DAZEL_PLATFORM}"
```

**CI.** Select a CI rc file through the environment and keep it free of laptop-only settings:

```bash
DAZEL_RC_FILE=tools/ci.dazelrc dazel test //...
```

```python
# tools/ci.dazelrc
DAZEL_DOCKERFILE = "tools/dazel/Dockerfile"
DAZEL_DOCKER_RUN_PRIVILEGED = True
DAZEL_COMMAND = "/usr/bin/bazel --noworkspace_rc"
DAZEL_BAZEL_RC_FILE = "tools/ci.bazelrc"
DAZEL_VOLUMES = ["/var/run/docker.sock:/var/run/docker.sock", "/mnt/cache:/mnt/cache"]
DAZEL_SHM_SIZE = "1g"
```

**GPUs.**

```python
DAZEL_GPUS = ["all"]
DAZEL_ENV_VARS = ["NVIDIA_DRIVER_CAPABILITIES=compute,utility"]
```

## Troubleshooting

**`No WORKSPACE or WORKSPACE.bazel or MODULE.bazel file found above …`.** dazel didn't find a
workspace from the current directory. Run it inside the workspace, or set `DAZEL_DIRECTORY`.

**`ERROR: Docker executable could not be found!`.** The first word of `DAZEL_DOCKER_COMMAND` isn't on
`PATH`.

**The container keeps restarting.** Something touches the Dockerfile or an rc file after every start,
or two workspaces share one container. For the second case, use `DAZEL_PER_WORKSPACE_CONTAINER`. To see
which container a workspace uses, run `dazel --dazel-container-name`.

**`bazel-bin` symlinks are broken on the host.** The output root moved, or the container runs as a
different user. Keep `DAZEL_BAZEL_USER_OUTPUT_ROOT` stable. With `DAZEL_USER`, point it at a directory
that user can write.

**Permission errors on Linux when cleaning.** The container runs as root, so its outputs are
root-owned. `dazel --dazel-clean-workspace` removes them through a throw-away container. You can do the
same by hand: `docker run --rm -v <dir>:/x alpine rm -rf /x/<path>`.

**Mounts are empty with Docker Desktop or colima.** These share only parts of the host filesystem with
their VM, usually your home directory. Keep workspaces, output roots and caches under shared paths.

**A shell feature in a value stops working after upgrading.** 1.0 no longer passes values through a
shell. Compute the value in the rc file, which is Python, instead.

## Upgrading from 0.0.x

1.0 reads the same `.dazelrc` keys. These things behave differently:

- **No shell.** Commands run as argv lists. Values are no longer passed through the host shell, so
  command substitution, `||`, globs and arithmetic in values are gone; only the variable forms listed in
  [Configuration](#configuration) are expanded. Compute anything else in the rc file, which is Python, or
  in the calling script.
- **Paths.** Relative `DAZEL_DOCKERFILE`, `DAZEL_DOCKER_COMPOSE_FILE` and `DAZEL_RUN_FILE` resolve against
  the workspace root, not the current directory.
- **Exit status.** A command killed by a signal exits with `128 + N` instead of raising an exception.
- **Workspaces.** `WORKSPACE.bazel` and `MODULE.bazel` mark a workspace too. Windows support was dropped.
- **New in 1.0.**
  - Per-workspace containers, the disk cache mount, the `--dazel-*` commands.
  - `~/.dazelrc` and `.dazelrc.local`.
  - `DAZEL_BUILD_DIRECTORY` and `DAZEL_GROUPS`.
  - Restarting the container when an rc file changes.

After switching to `DAZEL_PER_WORKSPACE_CONTAINER`, start dazel once (it removes the old shared `dazel`
container), then run `dazel --dazel-clean-legacy` to see the shared output base 0.0.x left under the
output root, and `dazel --dazel-clean-legacy --yes` to delete it. Scripts that hard-code the container name
`dazel` should read `.dazel_run` or call `dazel --dazel-container-name`.

On Linux the container runs as root, so files it writes into bind-mounted directories are root-owned.
When dazel can't remove them, it retries through a throw-away container of the same image. If that also
fails, it prints the command to run.

## Development

```bash
uv sync            # create .venv with dazel and the dev tools
prek install       # install the pre-commit and commit-msg hooks
uv run pytest      # unit tests with coverage
uv run pytest -m integration --no-cov   # lifecycle tests against a real docker daemon
prek run --all-files                    # ruff, pyrefly, uv.lock and file hygiene
```

Commit messages and pull request titles follow [Conventional Commits](https://www.conventionalcommits.org).
[gitfluff](https://github.com/Goldziher/gitfluff) checks them in the `commit-msg` hook and in CI.

Releases are cut by pushing a `v<version>` tag that matches `pyproject.toml`. The release workflow then
publishes to PyPI through trusted publishing.

## License

[MIT](https://github.com/ArmisSecurity/dazel/blob/master/LICENSE). Copyright (c) 2016 nadirizr; copyright (c) 2026 Armis Security.
