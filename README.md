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
