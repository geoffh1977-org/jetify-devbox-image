#!/usr/bin/env bash
set -euo pipefail

nonroot_user=${NONROOT_USER:-devbox}

managed_mount_roots=()

find_managed_mount_roots() {
  local managed_root=$1
  local mount_root

  while IFS= read -r mount_root; do
    if { [ "$mount_root" = "$managed_root" ] || [[ "$mount_root" == "$managed_root/"* ]]; } && [ "$mount_root" != "$managed_root" ]; then
      managed_mount_roots+=("$mount_root")
    fi
  done < <(findmnt --noheadings --raw --output TARGET --submounts --target "$managed_root")
}

find_args_for_mount() {
  local mount_root=$1
  local child_mount
  local first_child=true

  find_args=("$mount_root" -xdev)
  for child_mount in "${managed_mount_roots[@]}"; do
    if [ "$child_mount" != "$mount_root" ] && [[ "$child_mount" == "$mount_root/"* ]]; then
      if [ "$first_child" = true ]; then
        find_args+=(\()
        first_child=false
      else
        find_args+=(-o)
      fi
      find_args+=(-path "$child_mount")
    fi
  done
  if [ "$first_child" = false ]; then
    find_args+=(\) -prune -o)
  fi
}

mount_is_readonly() {
  findmnt --noheadings --raw --output OPTIONS --target "$1" | tr ',' '\n' | grep --quiet --line-regexp ro
}

repair_managed_mount() {
  local mount_root=$1
  local user_uid=$2
  local user_gid=$3
  local mismatched_path

  find_args_for_mount "$mount_root"
  mismatched_path=$(find "${find_args[@]}" \( ! -uid "$user_uid" -o ! -gid "$user_gid" \) -print -quit)
  if [ -z "$mismatched_path" ]; then
    return
  fi

  if mount_is_readonly "$mount_root"; then
    echo "Cannot repair ownership of $mount_root: it is read-only and is not owned by $user_uid:$user_gid. Mount it writable once to repair ownership, or mount it with UID:GID $user_uid:$user_gid." >&2
    exit 1
  fi

  if ! find "${find_args[@]}" -exec chown --no-dereference "$user_uid:$user_gid" {} + >/dev/null 2>&1; then
    echo "Cannot repair ownership of $mount_root for $user_uid:$user_gid. The managed mount must be writable before startup." >&2
    exit 1
  fi

  mismatched_path=$(find "${find_args[@]}" \( ! -uid "$user_uid" -o ! -gid "$user_gid" \) -print -quit)
  if [ -n "$mismatched_path" ]; then
    echo "Cannot repair ownership of $mount_root for $user_uid:$user_gid. The managed mount must be writable before startup." >&2
    exit 1
  fi
}

repair_managed_root() {
  local managed_root=$1
  local user_uid=$2
  local user_gid=$3
  local mount_root

  managed_mount_roots=("$managed_root")
  find_managed_mount_roots "$managed_root"
  for mount_root in "${managed_mount_roots[@]}"; do
    repair_managed_mount "$mount_root" "$user_uid" "$user_gid"
  done
}

set_runtime_identity() {
  local user_name=$1
  local user_uid=$2
  local user_gid=$3
  local temporary_passwd

  temporary_passwd=$(mktemp /etc/passwd.XXXXXX)
  if ! awk -F: -v OFS=: -v user_name="$user_name" -v user_uid="$user_uid" -v user_gid="$user_gid" '
    $1 == user_name {
      $3 = user_uid
      $4 = user_gid
      found = 1
    }
    { print }
    END { exit !found }
  ' /etc/passwd > "$temporary_passwd"; then
    rm -f "$temporary_passwd"
    echo "Failed to update runtime identity for $user_name" >&2
    exit 1
  fi
  chmod --reference=/etc/passwd "$temporary_passwd"
  chown --reference=/etc/passwd "$temporary_passwd"
  mv "$temporary_passwd" /etc/passwd
}

if ! id "$nonroot_user" >/dev/null 2>&1; then
  echo "Configured non-root user does not exist: $nonroot_user" >&2
  exit 1
fi

# The image starts as root only to configure mounted directories and Docker
# socket access, then permanently drops privileges. Nix is single-user.
if [ "$(id -u)" -eq 0 ]; then
  devbox_uid=${DEVBOX_UID:-}
  devbox_gid=${DEVBOX_GID:-}
  remap_requested=false
  if [ -n "$devbox_uid" ] || [ -n "$devbox_gid" ]; then
    remap_requested=true
    if [ -z "$devbox_uid" ] || [ -z "$devbox_gid" ]; then
      echo "DEVBOX_UID and DEVBOX_GID must be set together" >&2
      exit 1
    fi
    if ! [[ "$devbox_uid" =~ ^[1-9][0-9]*$ ]]; then
      echo "DEVBOX_UID must be a positive decimal integer: '$devbox_uid'" >&2
      exit 1
    fi
    if ! [[ "$devbox_uid" =~ ^([1-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|60000)$ ]]; then
      echo "DEVBOX_UID must be an integer between 1 and 60000: '$devbox_uid'" >&2
      exit 1
    fi
    if ! [[ "$devbox_gid" =~ ^[1-9][0-9]*$ ]]; then
      echo "DEVBOX_GID must be a positive decimal integer: '$devbox_gid'" >&2
      exit 1
    fi
    if ! [[ "$devbox_gid" =~ ^([1-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|60000)$ ]]; then
      echo "DEVBOX_GID must be an integer between 1 and 60000: '$devbox_gid'" >&2
      exit 1
    fi

    conflicting_user=$(getent passwd "$devbox_uid" | cut -d: -f1 || true)
    if [ -n "$conflicting_user" ] && [ "$conflicting_user" != "$nonroot_user" ]; then
      echo "DEVBOX_UID $devbox_uid is already assigned to $conflicting_user" >&2
      exit 1
    fi

    mapfile -t target_groups < <(getent group | awk -F: -v gid="$devbox_gid" '$3 == gid { print $1 }')
    if [ "${#target_groups[@]}" -gt 1 ]; then
      echo "DEVBOX_GID $devbox_gid resolves to multiple groups" >&2
      exit 1
    fi
    target_group=${target_groups[0]:-}
    if [ -z "$target_group" ]; then
      target_group="${nonroot_user}_gid_${devbox_gid}"
      if getent group "$target_group" >/dev/null; then
        echo "Cannot create group $target_group: name is already in use" >&2
        exit 1
      fi
      groupadd --gid "$devbox_gid" "$target_group"
    fi
  fi

  # Do not recursively change ownership of the project bind mount. Only the
  # image user's home and single-user Nix store need runtime ownership repair.
  user_uid=${devbox_uid:-$(id -u "$nonroot_user")}
  user_gid=${devbox_gid:-$(id -g "$nonroot_user")}
  repair_managed_root "/home/$nonroot_user" "$user_uid" "$user_gid"
  repair_managed_root /nix "$user_uid" "$user_gid"

  # usermod --uid recursively chowns the configured home directory. Update
  # the account record only after the fixed managed roots are verified, so a
  # correctly owned read-only mount can start without metadata writes.
  if [ "$remap_requested" = true ]; then
    set_runtime_identity "$nonroot_user" "$user_uid" "$user_gid"
  fi

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

  exec setpriv --reuid="$user_uid" --regid="$user_gid" --init-groups -- "$@"
fi

exec "$@"
