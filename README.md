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
managed root (`/home/devbox` and `/nix`) **and its non-mounted content**. Every
descendant mount target is explicitly pruned before ownership is checked or
changed, so nested file or directory mounts such as `/home/devbox/devbox.lock`,
`/home/devbox/Projects`, `.devbox`, plugins, and data retain the
host/Docker-reported ownership. This preserves Docker Desktop and host sharing
boundaries while ensuring the base home directory itself remains traversable
when it has restrictive permissions.

The managed root mounts themselves may be read-only when they already belong to
the mapped UID:GID. If either root needs repair, mount that root writable for
one startup; the entrypoint exits with an actionable error rather than
continuing with a broken single-user Nix or home directory. `/Project` is never
touched. `VOLUME_MOUNTS` is not used for ownership changes: arbitrary
environment-provided paths are intentionally excluded.

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
