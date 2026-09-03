#!/usr/bin/env bash
# Safely migrate root-owned named-volume data to a numeric container identity.
set -u -o pipefail

usage() {
  cat <<'USAGE'
Usage: chown-volumes -u UID -g GID [-R] [-t|--include-root] TOP_LEVEL_DIR

Safely migrates root-owned named-volume directories below TOP_LEVEL_DIR.

Options:
  -u UID                Required numeric target UID.
  -g GID                Required numeric target GID.
  -R                    Recursively migrate each selected directory and its descendants.
  -t, --include-root    Include TOP_LEVEL_DIR itself as a migration target.
  -h, -?                Show this help text.

Without --include-root, only immediate child directories of TOP_LEVEL_DIR are
selected. Symlinks are never selected or followed. A selected directory already
owned by UID:GID is skipped. Only root:root paths are changed; any other
ownership is reported as an error and causes a nonzero exit status.
USAGE
}

error() {
  printf 'chown-volumes: %s\n' "$*" >&2
}

ownership() {
  stat --format='%u:%g' -- "$1"
}

uid=''
gid=''
recursive=false
include_root=false
top_level=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    -u)
      [ "$#" -ge 2 ] || { error '-u requires a UID'; usage >&2; exit 2; }
      uid=$2
      shift 2
      ;;
    -g)
      [ "$#" -ge 2 ] || { error '-g requires a GID'; usage >&2; exit 2; }
      gid=$2
      shift 2
      ;;
    -R)
      recursive=true
      shift
      ;;
    -t|--include-root)
      include_root=true
      shift
      ;;
    -h|-\?)
      usage
      exit 0
      ;;
    --)
      shift
      if [ "$#" -ne 1 ] || [ -n "$top_level" ]; then
        error 'exactly one top-level directory is required'
        usage >&2
        exit 2
      fi
      top_level=$1
      shift
      ;;
    -*)
      error "unknown option: $1"
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$top_level" ]; then
        error 'exactly one top-level directory is required'
        usage >&2
        exit 2
      fi
      top_level=$1
      shift
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  if [ -n "$top_level" ]; then
    error 'exactly one top-level directory is required'
  else
    error "unexpected argument: $1"
  fi
  usage >&2
  exit 2
fi

if [ -z "$uid" ] || [ -z "$gid" ]; then
  error '-u UID and -g GID are both required'
  usage >&2
  exit 2
fi
if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
  error "UID must be numeric: $uid"
  exit 2
fi
if ! [[ "$gid" =~ ^[0-9]+$ ]]; then
  error "GID must be numeric: $gid"
  exit 2
fi
if [ -z "$top_level" ]; then
  error 'exactly one top-level directory is required'
  usage >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  error 'must run as root'
  exit 1
fi
if [ -L "$top_level" ] || [ ! -d "$top_level" ]; then
  error "top-level directory must be an existing non-symlink directory: $top_level"
  exit 2
fi

# Canonicalization closes spelling variants such as /tmp/../ and rejects a root
# directory reached through a symlink-free alternate path.
top_level=$(realpath --canonicalize-existing -- "$top_level") || {
  error "cannot resolve top-level directory: $top_level"
  exit 2
}
if [ "$top_level" = / ]; then
  error 'refusing unsafe top-level directory: /'
  exit 2
fi

target_owner="$uid:$gid"
root_owner='0:0'
had_error=false
changed=0
skipped=0

ensure_recursive_tree_is_safe() {
  local target=$1
  local path
  local path_owner

  while IFS= read -r -d '' path; do
    if ! path_owner=$(ownership "$path"); then
      error "cannot determine ownership of $path"
      return 1
    fi
    case "$path_owner" in
      "$root_owner"|"$target_owner") ;;
      *)
        error "refusing to change $target: $path is owned by $path_owner, not root:root or $target_owner"
        return 1
        ;;
    esac
  done < <(find -P "$target" -print0)
}

verify_target() {
  local target=$1
  local path
  local path_owner

  if [ "$recursive" = true ]; then
    while IFS= read -r -d '' path; do
      if ! path_owner=$(ownership "$path"); then
        error "cannot verify ownership of $path after changing $target"
        return 1
      fi
      if [ "$path_owner" != "$target_owner" ]; then
        error "ownership verification failed for $path after changing $target: expected $target_owner, found $path_owner"
        return 1
      fi
    done < <(find -P "$target" -print0)
  else
    if ! path_owner=$(ownership "$target"); then
      error "cannot verify ownership of $target after changing it"
      return 1
    fi
    if [ "$path_owner" != "$target_owner" ]; then
      error "ownership verification failed for $target: expected $target_owner, found $path_owner"
      return 1
    fi
  fi
}

migrate_target() {
  local target=$1
  local current_owner

  if ! current_owner=$(ownership "$target"); then
    error "cannot determine ownership of $target"
    return 1
  fi
  if [ "$current_owner" = "$target_owner" ]; then
    printf 'Skipping %s: already owned by %s\n' "$target" "$target_owner"
    skipped=$((skipped + 1))
    return 0
  fi
  if [ "$current_owner" != "$root_owner" ]; then
    error "refusing to change $target: owned by $current_owner, not root:root or $target_owner"
    return 1
  fi
  if [ "$recursive" = true ] && ! ensure_recursive_tree_is_safe "$target"; then
    return 1
  fi

  if [ "$recursive" = true ]; then
    if ! chown --recursive --no-dereference -- "$target_owner" "$target"; then
      error "failed to recursively change ownership of $target to $target_owner"
      return 1
    fi
  elif ! chown --no-dereference -- "$target_owner" "$target"; then
    error "failed to change ownership of $target to $target_owner"
    return 1
  fi

  if ! verify_target "$target"; then
    return 1
  fi
  printf 'Migrated %s to %s%s\n' "$target" "$target_owner" "$([ "$recursive" = true ] && printf ' recursively')"
  changed=$((changed + 1))
}

targets=()
if [ "$include_root" = true ]; then
  targets+=("$top_level")
fi
while IFS= read -r -d '' target; do
  targets+=("$target")
done < <(find -P "$top_level" -mindepth 1 -maxdepth 1 -type d -print0)

for target in "${targets[@]}"; do
  if ! migrate_target "$target"; then
    had_error=true
  fi
done

printf 'chown-volumes: migrated=%d skipped=%d errors=%s\n' "$changed" "$skipped" "$had_error"
if [ "$had_error" = true ]; then
  exit 1
fi
