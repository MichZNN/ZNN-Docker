#!/usr/bin/env bash
#
# znn.sh - build, run, update and roll back go-zenon (znnd) in Docker.
#
# Every node is an "instance" with its own data dir, ports and version,
# stored in instances/<name>/.env. Images are tagged per version
# (go-zenon:v0.0.9-alphanet), so switching versions is instant.
#
# Run ./znn.sh help for all commands.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT}/instances"
BACKUP_DIR="${ROOT}/backups"
COMPOSE_FILE="${ROOT}/docker-compose.yml"
IMAGE_NAME="go-zenon"
ZNN_REPO="${ZNN_REPO:-https://github.com/zenon-network/go-zenon.git}"
ZNN_UID="${ZNN_UID:-1000}"
ZNN_GID="${ZNN_GID:-1000}"

# ---------- helpers ---------------------------------------------------------

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

instance_dir() { echo "${INSTANCES_DIR}/$1"; }
env_file()     { echo "$(instance_dir "$1")/.env"; }

require_instance() {
  [[ -n "${1:-}" ]] || die "instance name required"
  [[ -f "$(env_file "$1")" ]] || die "instance '$1' does not exist (run: ./znn.sh init $1)"
}

valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "instance name may only contain a-z, 0-9, - and _"
}

get_env() { # get_env <instance> <KEY>
  grep -E "^$2=" "$(env_file "$1")" | tail -n1 | cut -d= -f2- || true
}

set_env() { # set_env <instance> <KEY> <VALUE>
  local f; f="$(env_file "$1")"
  if grep -qE "^$2=" "$f"; then
    sed -i "s|^$2=.*|$2=$3|" "$f"
  else
    echo "$2=$3" >> "$f"
  fi
}

compose() { # compose <instance> <args...>
  local name="$1"; shift
  docker compose -p "znn-${name}" --env-file "$(env_file "${name}")" -f "${COMPOSE_FILE}" "$@"
}

latest_version() {
  need git
  git ls-remote --tags --refs "${ZNN_REPO}" \
    | awk -F/ '{print $3}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V | tail -n1
}

resolve_version() { # "latest" or empty -> newest tag
  local v="${1:-latest}"
  if [[ "$v" == "latest" ]]; then
    v="$(latest_version)"
    [[ -n "$v" ]] || die "could not determine latest go-zenon version"
  fi
  echo "$v"
}

image_exists() { docker image inspect "${IMAGE_NAME}:$1" >/dev/null 2>&1; }

ensure_image() {
  image_exists "$1" || cmd_build "$1"
}

fix_perms() { # make the data dir writable for the container user
  local dir="$1" version="$2"
  docker run --rm -u 0 --entrypoint chown \
    -v "${dir}:/home/znn/.znn" "${IMAGE_NAME}:${version}" \
    -R "${ZNN_UID}:${ZNN_GID}" /home/znn/.znn
}

# ---------- commands --------------------------------------------------------

cmd_latest() { latest_version; }

cmd_versions() {
  need git
  git ls-remote --tags --refs "${ZNN_REPO}" | awk -F/ '{print $3}' | sort -V
}

cmd_build() {
  need docker
  local v; v="$(resolve_version "${1:-}")"
  info "Building ${IMAGE_NAME}:${v} from ${ZNN_REPO}"
  docker build \
    --build-arg "ZNN_VERSION=${v}" \
    --build-arg "ZNN_REPO=${ZNN_REPO}" \
    --build-arg "ZNN_UID=${ZNN_UID}" \
    --build-arg "ZNN_GID=${ZNN_GID}" \
    -t "${IMAGE_NAME}:${v}" "${ROOT}"
  info "Built ${IMAGE_NAME}:${v}"
}

cmd_init() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: ./znn.sh init <name> [--version V] [--p2p-port N] [--http-port N] [--ws-port N] [--rpc-addr A]"
  valid_name "$name"
  [[ ! -f "$(env_file "$name")" ]] || die "instance '$name' already exists"

  local version="latest" p2p=35995 http=35997 ws=35998 rpc="127.0.0.1"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)   version="$2"; shift 2 ;;
      --p2p-port)  p2p="$2";     shift 2 ;;
      --http-port) http="$2";    shift 2 ;;
      --ws-port)   ws="$2";      shift 2 ;;
      --rpc-addr)  rpc="$2";     shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  version="$(resolve_version "$version")"

  local dir; dir="$(instance_dir "$name")"
  mkdir -p "${dir}/data"
  cat > "${dir}/.env" <<EOF
INSTANCE=${name}
ZNN_VERSION=${version}
ZNN_PREVIOUS_VERSION=
DATA_DIR=${dir}/data
P2P_PORT=${p2p}
HTTP_PORT=${http}
WS_PORT=${ws}
RPC_ADDR=${rpc}
EOF
  info "Instance '${name}' created in ${dir}"
  echo "    version: ${version}  p2p: ${p2p}  http: ${rpc}:${http}  ws: ${rpc}:${ws}"
  echo "    Put existing chain data / config.json in ${dir}/data before 'up' if you have them."
}

cmd_up() {
  require_instance "${1:-}"
  local v; v="$(get_env "$1" ZNN_VERSION)"
  ensure_image "$v"
  fix_perms "$(get_env "$1" DATA_DIR)" "$v"
  compose "$1" up -d
  info "Instance '$1' running ${IMAGE_NAME}:${v}"
}

cmd_down()    { require_instance "${1:-}"; compose "$1" down; }
cmd_restart() { require_instance "${1:-}"; compose "$1" restart; }
cmd_logs()    { require_instance "${1:-}"; local n="$1"; shift; compose "$n" logs -f --tail="${1:-200}"; }

cmd_status() {
  require_instance "${1:-}"
  local name="$1" addr port
  addr="$(get_env "$name" RPC_ADDR)"; [[ "$addr" == "0.0.0.0" ]] && addr="127.0.0.1"
  port="$(get_env "$name" HTTP_PORT)"
  echo "Instance : ${name}"
  echo "Version  : $(get_env "$name" ZNN_VERSION) (previous: $(get_env "$name" ZNN_PREVIOUS_VERSION))"
  compose "$name" ps
  echo
  echo "Sync info (state 2 = synced):"
  curl -s --max-time 5 -X POST "http://${addr}:${port}" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"stats.syncInfo","params":[]}' || echo "  RPC not reachable on ${addr}:${port}"
  echo
}

cmd_update() {
  require_instance "${1:-}"
  local name="$1" new current
  new="$(resolve_version "${2:-latest}")"
  current="$(get_env "$name" ZNN_VERSION)"
  if [[ "$new" == "$current" ]]; then
    info "Instance '${name}' already runs ${current}"
    return 0
  fi
  ensure_image "$new"
  info "Updating '${name}': ${current} -> ${new}"
  set_env "$name" ZNN_PREVIOUS_VERSION "$current"
  set_env "$name" ZNN_VERSION "$new"
  compose "$name" up -d
  info "Done. Roll back with: ./znn.sh rollback ${name}"
}

cmd_rollback() {
  require_instance "${1:-}"
  local name="$1" prev current
  prev="$(get_env "$name" ZNN_PREVIOUS_VERSION)"
  current="$(get_env "$name" ZNN_VERSION)"
  [[ -n "$prev" ]] || die "no previous version recorded for '${name}'"
  ensure_image "$prev"
  info "Rolling back '${name}': ${current} -> ${prev}"
  set_env "$name" ZNN_VERSION "$prev"
  set_env "$name" ZNN_PREVIOUS_VERSION "$current"
  compose "$name" up -d
}

cmd_keygen() {
  require_instance "${1:-}"
  local name="$1"; shift
  local v dir
  v="$(get_env "$name" ZNN_VERSION)"
  dir="$(get_env "$name" DATA_DIR)"
  ensure_image "$v"
  fix_perms "$dir" "$v"
  docker run --rm -it --entrypoint producer-keygen \
    -v "${dir}:/home/znn/.znn" "${IMAGE_NAME}:${v}" \
    -data /home/znn/.znn "$@"
  echo
  echo "Restart the node to load the producer key:  ./znn.sh restart ${name}"
}

cmd_backup() {
  require_instance "${1:-}"
  local name="$1" dir file
  dir="$(get_env "$name" DATA_DIR)"
  mkdir -p "${BACKUP_DIR}"
  file="${BACKUP_DIR}/${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
  info "Stopping '${name}' for a consistent backup"
  compose "$name" stop
  tar -C "$dir" -czf "$file" . || { compose "$name" start; die "backup failed"; }
  compose "$name" start
  chmod 600 "$file"
  info "Backup written to ${file}"
}

cmd_list() {
  [[ -d "${INSTANCES_DIR}" ]] || { echo "no instances"; return; }
  printf "%-15s %-20s %-8s %-8s %-8s\n" INSTANCE VERSION P2P HTTP WS
  for f in "${INSTANCES_DIR}"/*/.env; do
    [[ -f "$f" ]] || continue
    local n; n="$(basename "$(dirname "$f")")"
    printf "%-15s %-20s %-8s %-8s %-8s\n" "$n" "$(get_env "$n" ZNN_VERSION)" \
      "$(get_env "$n" P2P_PORT)" "$(get_env "$n" HTTP_PORT)" "$(get_env "$n" WS_PORT)"
  done
}

cmd_help() {
  cat <<'EOF'
Usage: ./znn.sh <command> [args]

Versions & images
  latest                      show newest go-zenon release tag
  versions                    list all go-zenon tags
  build [version|latest]      build image go-zenon:<version>

Instances
  init <name> [options]       create an instance (data dir + .env)
        --version V            default: latest
        --p2p-port N           default: 35995
        --http-port N          default: 35997
        --ws-port N            default: 35998
        --rpc-addr A           default: 127.0.0.1 (RPC only reachable locally)
  list                        list instances
  up <name>                   start (builds the image if needed)
  down <name>                 stop and remove the container (data is kept)
  restart <name>              restart
  logs <name> [lines]         follow logs
  status <name>               container state + sync status

Maintenance
  update <name> [version]     switch to a newer version (default: latest)
  rollback <name>             go back to the previous version
  keygen <name> [flags]       create a producer keystore and write config.json
                              (flags: -name, -password-file, -update-config, -force)
  backup <name>               stop, tar the data dir to backups/, start again
EOF
}

# ---------- main ------------------------------------------------------------

cmd="${1:-help}"; shift || true
case "$cmd" in
  latest|versions|build|init|up|down|restart|logs|status|update|rollback|keygen|backup|list|help)
    "cmd_${cmd}" "$@" ;;
  -h|--help) cmd_help ;;
  *) die "unknown command '${cmd}' (see ./znn.sh help)" ;;
esac
