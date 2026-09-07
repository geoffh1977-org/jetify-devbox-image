# Jetify Devbox container image

A development container image that installs [Jetify Devbox](https://www.jetify.com/devbox) with a non-root user and a single-user Nix installation.

## Companion projects

- [Jetify Devbox Profiles](https://github.com/geoffh1977-org/jetify-devbox-profiles) provides ready-to-copy VS Code Dev Container and Compose templates built on this image.
- [Jetify Devbox Plugins](https://github.com/geoffh1977-org/jetify-devbox-plugins) provides reusable Devbox plugins, including a Zsh-based interactive shell environment.

## Features

- Ubuntu 24.04 base image with Devbox installed from its release archive.
- Published images support Linux `amd64` and `arm64` hosts.
- Common development utilities including Git, curl, direnv, Make, and OpenSSH client.
- Configurable non-root user and startup handling for mounted development directories and the Docker socket.

## Quick start

Pull and run the published image using its Docker Hub namespace:

```sh
docker pull geoffh1977/jetify-devbox:latest
docker run --rm -it geoffh1977/jetify-devbox:latest
```

Mount a project directory when working on a repository:

```sh
docker run --rm -it -v "$PWD:/Project" geoffh1977/jetify-devbox:latest
```

### Host identity mapping

By default the container runs as `devbox` with UID and GID `1000`. Set both
`DEVBOX_UID` and `DEVBOX_GID` to run as a different numeric identity, for
example when a mounted home directory or Nix volume belongs to your host user:

```sh
docker run --rm -it \
  -e DEVBOX_UID=502 \
  -e DEVBOX_GID=20 \
  -v devbox-nix:/nix \
  -v devbox-home:/home/devbox \
  geoffh1977/jetify-devbox:latest
```

Both variables are required together and must be decimal integers from `1`
through `60000`.
The image refuses a UID already assigned to another account. If the requested
GID already exists, `devbox` safely uses that group; otherwise the entrypoint
creates a dedicated group. At startup it repairs ownership of each fixed
managed root (`/home/devbox` and `/nix`) and its non-mounted content. The base
roots are ownership-managed, but every descendant mount is pruned before
ownership is checked or changed. Therefore arbitrary host bind mounts are never
ownership-managed—regardless of their source path, target path, or mountinfo
shape. `/Project` is never touched.

Named-volume descendants are also deliberately left untouched at runtime.
Docker mount metadata cannot safely distinguish a named volume from a bind mount
whose source was chosen to resemble a volume backing path. The entrypoint never
uses a Docker socket, container ID, hostname, cgroup data, or environment path
to override that rule. This keeps Docker Desktop and host bind mounts below
`/home/devbox` or `/nix` outside its recursive ownership traversal.

### Minimal Compose setup with named-volume initialization

Use this complete Compose file as a minimal persistent Devbox environment. It
matches the volume-initialization pattern used by the Devbox profile templates:
`init-volumes` mounts only the named `devbox-cache` volume at a neutral path,
then the `dev` service mounts it at its runtime location.

Save it as `compose.yaml` beside the project you want to mount:

```yaml
services:
  init-volumes:
    image: geoffh1977/jetify-devbox:latest
    user: "0:0"
    entrypoint:
      - /usr/local/bin/chown-volumes.sh
      - -u
      - "${DEVBOX_UID:-1000}"
      - -g
      - "${DEVBOX_GID:-1000}"
      - -R
      - /managed
    volumes:
      - devbox-cache:/managed/devbox-cache

  dev:
    image: geoffh1977/jetify-devbox:latest
    environment:
      DEVBOX_UID: "${DEVBOX_UID:-1000}"
      DEVBOX_GID: "${DEVBOX_GID:-1000}"
    volumes:
      - nix-store:/nix
      - devbox-cache:/home/devbox/.cache
      - ./:/Project:cached
    depends_on:
      init-volumes:
        condition: service_completed_successfully
    working_dir: /Project
    stdin_open: true
    tty: true

volumes:
  nix-store:
  devbox-cache:
```

Set the identity values in a local `.env` file when your host user is not
`1000:1000`:

```dotenv
DEVBOX_UID=502
DEVBOX_GID=20
```

Start an interactive Devbox shell with:

```sh
docker compose run --rm dev devbox shell
```

Or start the long-lived service for an IDE or another Compose consumer:

```sh
docker compose up -d dev
```

The initializer is deliberately run as root and executes
`/usr/local/bin/chown-volumes.sh` directly, bypassing the normal image
entrypoint. It selects the immediate directories under `/managed`, recursively
migrates only `root:root` content, skips content already owned by the requested
UID:GID, and fails rather than changing any other ownership. The direct
`nix-store:/nix` mount does not need to be added to the initializer: `/nix` is a
fixed runtime-managed root. Do not add host bind mounts—including `/Project`—to
`init-volumes`.

For additional persistent home-state volumes, add each named volume below
`/managed` in `init-volumes`, and mount that same volume at its final location in
`dev`. For example, a VS Code server volume could be mounted as
`vscode-server:/managed/vscode-server` in the initializer and
`vscode-server:/home/devbox/.vscode-server` in the `dev` service.

The runtime entrypoint continues to repair the base managed roots and their
non-mounted content. It prunes every descendant mount before checking or
changing ownership, so initialized named volumes are usable by the mapped user
while nested host bind mounts remain exactly as supplied. Base roots may be
read-only only when they already belong to the mapped UID:GID; otherwise startup
exits with an actionable error rather than continuing with a broken single-user
Nix or home directory. `VOLUME_MOUNTS` is not used for ownership changes:
arbitrary environment-provided paths are intentionally excluded.

## VS Code and devcontainers

Use the image in a `.devcontainer/devcontainer.json` file, replacing the namespace with the published Docker Hub namespace:

```json
{
  "image": "geoffh1977/jetify-devbox:latest",
  "workspaceFolder": "/Project"
}
```

For Docker commands from inside the container, mount the host Docker socket and ensure that granting this access is appropriate for your environment.

## Version updates

The Devbox release version is tracked in `.devbox-version`.

1. Run `task get-version` to refresh it from the latest Devbox release.
2. Run `task check` before publishing changes.
3. Build or publish with the tasks in `taskfile.yaml`; they consume `.devbox-version`.
