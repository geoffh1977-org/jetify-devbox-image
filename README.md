# Jetify Devbox container image

A development container image that installs [Jetify Devbox](https://www.jetify.com/devbox) with a non-root user and a single-user Nix installation.

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

### One-shot named-volume ownership migration

If named-volume state was previously created as root, run a separate one-shot
initializer before starting the `devbox` service. It mounts only the named
volumes selected in the Compose declaration at neutral paths and changes only
those paths. It does not mount the Docker socket or any host bind path.

Use this generic Compose pattern, substituting the UID:GID and named volumes
used by your service:

```yaml
services:
  init-devbox-volumes:
    image: geoffh1977/jetify-devbox:latest
    user: "0:0"
    entrypoint: ["/bin/bash", "-ceu", "chown -R -- 502:20 /managed/.devbox /managed/.vscode-server"]
    volumes:
      - devbox-state:/managed/.devbox
      - vscode-state:/managed/.vscode-server

  devbox:
    environment:
      DEVBOX_UID: "502"
      DEVBOX_GID: "20"
    volumes:
      - devbox-state:/home/devbox/.devbox
      - vscode-state:/home/devbox/.vscode-server
volumes:
  devbox-state:
  vscode-state:
```

Run `docker compose run --rm init-devbox-volumes` once, then start `devbox`
normally. Do not add host bind mounts to the initializer; migration scope is
the exact list of named-volume declarations above. For a direct equivalent:

```sh
docker run --rm \
  -v devbox-state:/managed/.devbox \
  -v vscode-state:/managed/.vscode-server \
  ubuntu:24.04 \
  chown -R -- 502:20 /managed/.devbox /managed/.vscode-server
```

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
