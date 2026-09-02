#!/usr/bin/env bash
set -euo pipefail

nonroot_user=${NONROOT_USER:-devbox}

if ! id "$nonroot_user" >/dev/null 2>&1; then
  echo "Configured non-root user does not exist: $nonroot_user" >&2
  exit 1
fi

# The image starts as root only to configure mounted directories and Docker
# socket access, then permanently drops privileges. Nix is single-user.
if [ "$(id -u)" -eq 0 ]; then
  volume_mounts=${VOLUME_MOUNTS:-"/home/$nonroot_user/.devbox /Project/.devbox /home/$nonroot_user/.config/bash /home/$nonroot_user/.vscode-server /home/$nonroot_user/.local/share/modelcontextprotocol"}
  read -r -a volume_mount_array <<< "$volume_mounts"
  for directory in "${volume_mount_array[@]}"; do
    if [ -d "$directory" ]; then
      chown -R "$nonroot_user" "$directory"
    fi
  done

  # Docker Desktop/Linux hosts vary by socket GID. Prefer a validated explicit
  # override, otherwise discover the mounted socket's numeric group directly.
  docker_gid=${DOCKER_GID:-}
  if [ -z "$docker_gid" ] && [ -S /var/run/docker.sock ]; then
    docker_gid=$(stat --format='%g' /var/run/docker.sock)
  fi
  case "$docker_gid" in
    '') ;;
    *[!0-9]*)
      echo "DOCKER_GID is not numeric: '$docker_gid'" >&2
      exit 1
      ;;
    *)
      docker_group=$(getent group "$docker_gid" | cut -d: -f1 || true)
      if [ -z "$docker_group" ]; then
        docker_group="docker_host_$docker_gid"
        groupadd --gid "$docker_gid" "$docker_group"
      fi
      usermod --append --groups "$docker_group" "$nonroot_user"
      ;;
  esac

  user_uid=$(id -u "$nonroot_user")
  user_gid=$(id -g "$nonroot_user")
  exec setpriv --reuid="$user_uid" --regid="$user_gid" --init-groups -- "$@"
fi

exec "$@"
