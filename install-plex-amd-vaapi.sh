#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Plex AMD VAAPI host installer
# Replaces Plex-bundled userspace libraries with Alpine edge
# MUSL Mesa/libva/libdrm components (no separate runtime dir).
# ============================================================

PLEX_DIR="/usr/lib/plexmediaserver"
PLEX_LIB_DIR="$PLEX_DIR/lib"
PLEX_DATA_DIR="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
PLEX_CACHE_DIR=""
PLEX_VA_CACHE=""
MESA_SHADER_CACHE_DIR=""
PLEX_DRIVERS_ROOT=""
SERVICE_NAME="plexmediaserver"

ALPINE_IMAGE="alpine:edge"
RUNTIME=""

DRY_RUN=0
NO_RESTART=0
KEEP_TEMP=0
ENV_ONLY=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

usage() {
  cat << USAGE
Usage: sudo ./install-plex-amd-vaapi.sh [options]

Options:
  --dry-run               Print actions only
  --no-restart            Do not restart plexmediaserver
  --alpine-image IMG      Override source image (default: alpine:edge)
  --service-name NAME     Override systemd unit name (default: plexmediaserver)
  --plex-data-dir PATH    Override Plex app support dir (skip systemd env detection)
  --keep-temp             Keep temporary extraction directory
  -h, --help              Show this help
USAGE
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
  else
    eval "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --no-restart)
        NO_RESTART=1
        ;;
      --alpine-image)
        shift
        [[ $# -eq 0 ]] && { err "--alpine-image requires an image"; exit 1; }
        ALPINE_IMAGE="$1"
        ;;
      --service-name)
        shift
        [[ $# -eq 0 ]] && { err "--service-name requires a unit name"; exit 1; }
        SERVICE_NAME="$1"
        ;;
      --plex-data-dir)
        shift
        [[ $# -eq 0 ]] && { err "--plex-data-dir requires a path"; exit 1; }
        PLEX_DATA_DIR="$1"
        ENV_ONLY=1
        ;;
      --keep-temp)
        KEEP_TEMP=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root (use sudo)."
    exit 1
  fi
}

resolve_plex_paths() {
  PLEX_CACHE_DIR="$PLEX_DATA_DIR/Cache"
  PLEX_VA_CACHE="$PLEX_CACHE_DIR/va-dri-linux-x86_64"
  MESA_SHADER_CACHE_DIR="$PLEX_CACHE_DIR/mesa-shader-cache"
  PLEX_DRIVERS_ROOT="$PLEX_DATA_DIR/Drivers"
}

resolve_plex_data_dir_from_systemd() {
  if [[ "$ENV_ONLY" -eq 1 ]]; then
    log "Using explicit --plex-data-dir override: $PLEX_DATA_DIR"
    resolve_plex_paths
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl unavailable; using default Plex data dir: $PLEX_DATA_DIR"
    resolve_plex_paths
    return
  fi

  local unit_env
  unit_env=$(systemctl show "$SERVICE_NAME" --property=Environment --value 2>/dev/null || true)
  if [[ -n "$unit_env" ]]; then
    # Environment output can contain shell-quoted assignments when values
    # include spaces, e.g.:
    # "PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/path/with spaces" FOO=bar
    # Use shlex-aware tokenization instead of splitting on plain spaces.
    local parsed
    parsed=$(python3 - << 'PY' "$unit_env"
import shlex, sys
for token in shlex.split(sys.argv[1]):
    if token.startswith("PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="):
        print(token.split("=", 1)[1])
        break
PY
)
    if [[ -n "$parsed" ]]; then
      PLEX_DATA_DIR="$parsed"
      log "Detected Plex data dir from systemd environment: $PLEX_DATA_DIR"
      resolve_plex_paths
      return
    fi
  fi

  local env_files
  env_files=$(systemctl show "$SERVICE_NAME" --property=EnvironmentFiles --value 2>/dev/null || true)
  if [[ -n "$env_files" ]]; then
    local env_file
    while IFS= read -r env_file; do
      env_file="${env_file#-}"
      env_file="${env_file%:*}"
      [[ -f "$env_file" ]] || continue
      local parsed
      parsed=$(awk -F= '/^[[:space:]]*PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR[[:space:]]*=/{sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "$env_file")
      if [[ -n "$parsed" ]]; then
        PLEX_DATA_DIR="$parsed"
        log "Detected Plex data dir from environment file ($env_file): $PLEX_DATA_DIR"
        resolve_plex_paths
        return
      fi
    done < <(printf '%s\n' "$env_files" | tr ' ' '\n')
  fi

  log "No systemd override found for Plex data dir; using default: $PLEX_DATA_DIR"
  resolve_plex_paths
}

check_plex_paths() {
  if [[ ! -d "$PLEX_DIR" ]]; then
    err "Plex directory not found: $PLEX_DIR"
    exit 1
  fi

  if [[ ! -f "$PLEX_DIR/Plex Media Server" || ! -f "$PLEX_DIR/Plex Transcoder" ]]; then
    err "Expected Plex binaries not found under: $PLEX_DIR"
    exit 1
  fi

  if [[ ! -d "$PLEX_LIB_DIR" ]]; then
    err "Plex library directory not found: $PLEX_LIB_DIR"
    exit 1
  fi
}

detect_runtime() {
  if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    return
  fi

  err "Neither docker nor podman is installed. One is required to extract Alpine MUSL libraries."
  exit 1
}

extract_alpine_payload() {
  local temp_dir="$1"

  detect_runtime
  log "Using container runtime: $RUNTIME"
  log "Pulling source image: $ALPINE_IMAGE"
  run "$RUNTIME pull \"$ALPINE_IMAGE\""

  local build_cmd
  build_cmd='set -e
apk add --no-cache mesa-va-gallium libva pax-utils libdrm >/dev/null
mkdir -p /source/vaapi-amdgpu/lib/dri /source/usr/share/libdrm
cp /usr/lib/dri/radeonsi_drv_video.so /source/vaapi-amdgpu/lib/dri/
cp -a /usr/lib/libva*.so* /source/vaapi-amdgpu/lib/
ldd /usr/lib/dri/radeonsi_drv_video.so | awk "{for(i=1;i<=NF;i++) if(\$i ~ /^\//) print \$i}" | grep -v "(0x" | sort -u | while read -r lib; do [ -f "\$lib" ] && cp -n "\$lib" /source/vaapi-amdgpu/lib/ 2>/dev/null || true; done
ldd /usr/lib/libva.so.2 | awk "{for(i=1;i<=NF;i++) if(\$i ~ /^\//) print \$i}" | grep -v "(0x" | sort -u | while read -r lib; do [ -f "\$lib" ] && cp -n "\$lib" /source/vaapi-amdgpu/lib/ 2>/dev/null || true; done
for f in /lib/ld-musl-*.so.1 /lib/libc.musl-*.so.1; do [ -f "\$f" ] && cp -nL "\$f" /source/vaapi-amdgpu/lib/ 2>/dev/null || true; done
[ -f /usr/share/libdrm/amdgpu.ids ] && cp /usr/share/libdrm/amdgpu.ids /source/usr/share/libdrm/ || true'

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s create "%s" sh -lc "...extract payload..."\n' "$RUNTIME" "$ALPINE_IMAGE"
    return
  fi

  local cid
  cid=$($RUNTIME create "$ALPINE_IMAGE" sh -lc "$build_cmd")
  trap '$RUNTIME rm -f "$cid" >/dev/null 2>&1 || true' RETURN

  $RUNTIME start -a "$cid" >/dev/null
  mkdir -p "$temp_dir"
  $RUNTIME cp "$cid:/source/." "$temp_dir/"
  $RUNTIME rm -f "$cid" >/dev/null 2>&1 || true
  trap - RETURN

  if [[ ! -f "$temp_dir/vaapi-amdgpu/lib/dri/radeonsi_drv_video.so" ]]; then
    err "Extraction failed: missing radeonsi_drv_video.so"
    exit 1
  fi
}

backup_then_copy() {
  local src="$1"
  local dst="$2"

  if [[ -e "$dst" && ! -e "$dst.orig-amdvaapi" ]]; then
    run "cp -a \"$dst\" \"$dst.orig-amdvaapi\""
    log "Backed up: $dst -> $dst.orig-amdvaapi"
  fi

  run "cp -a \"$src\" \"$dst\""
}

overwrite_plex_libraries() {
  local temp_dir="$1"
  local payload_lib="$temp_dir/vaapi-amdgpu/lib"

  log "Overwriting Plex libraries with Alpine MUSL versions..."

  local src
  for src in "$payload_lib"/*.so*; do
    [[ -f "$src" ]] || continue
    backup_then_copy "$src" "$PLEX_LIB_DIR/$(basename "$src")"
  done

  run "mkdir -p \"$PLEX_LIB_DIR/dri\""
  for src in "$payload_lib"/dri/*.so; do
    [[ -f "$src" ]] || continue
    backup_then_copy "$src" "$PLEX_LIB_DIR/dri/$(basename "$src")"
  done
}

install_amdgpu_ids() {
  local temp_dir="$1"
  local src_ids="$temp_dir/usr/share/libdrm/amdgpu.ids"
  local dst_ids="/usr/share/libdrm/amdgpu.ids"

  if [[ ! -f "$src_ids" ]]; then
    warn "Extracted amdgpu.ids not found; skipping amdgpu.ids replacement."
    return
  fi

  run "mkdir -p /usr/share/libdrm"
  backup_then_copy "$src_ids" "$dst_ids"
}

link_hardcoded_amdgpu_ids() {
  local ids_file="/usr/share/libdrm/amdgpu.ids"

  if [[ ! -f "$ids_file" ]]; then
    warn "No amdgpu.ids available at $ids_file"
    return
  fi

  log "Scanning Plex libraries for hardcoded amdgpu.ids paths..."
  local found
  found=$(grep -r -h -o -a '/home/runner[^"[:space:]]*amdgpu\.ids' "$PLEX_LIB_DIR" 2>/dev/null | sort -u || true)

  if [[ -z "$found" ]]; then
    log "No hardcoded amdgpu.ids paths found."
    return
  fi

  while IFS= read -r ids_path; do
    [[ -z "$ids_path" ]] && continue
    log "Found hardcoded path: $ids_path"
    run "mkdir -p \"$(dirname "$ids_path")\""
    run "ln -sf \"$ids_file\" \"$ids_path\""
  done <<< "$found"
}

install_driver_into_plex_drivers() {
  local temp_dir="$1"
  local src_driver="$temp_dir/vaapi-amdgpu/lib/dri/radeonsi_drv_video.so"

  if [[ ! -f "$src_driver" ]]; then
    err "Missing extracted driver: $src_driver"
    exit 1
  fi

  run "mkdir -p \"$PLEX_DRIVERS_ROOT\""

  local -a targets=()
  local existing
  while IFS= read -r existing; do
    [[ -n "$existing" ]] && targets+=("$existing")
  done < <(find "$PLEX_DRIVERS_ROOT" -type f -name 'radeonsi_drv_video.so' 2>/dev/null || true)

  if [[ ${#targets[@]} -eq 0 ]]; then
    targets+=("$PLEX_DRIVERS_ROOT/lib/dri/radeonsi_drv_video.so")
    run "mkdir -p \"$PLEX_DRIVERS_ROOT/lib/dri\""
  fi

  local dst
  for dst in "${targets[@]}"; do
    log "Installing driver into Plex Drivers tree: $dst"
    run "mkdir -p \"$(dirname "$dst")\""
    backup_then_copy "$src_driver" "$dst"
  done
}

setup_plex_va_cache() {
  log "Linking Plex VA cache to Plex-installed DRI drivers..."
  run "mkdir -p \"$PLEX_VA_CACHE\" \"$MESA_SHADER_CACHE_DIR\""
  run "rm -f \"$PLEX_VA_CACHE\"/*.so* 2>/dev/null || true"

  local driver
  for driver in "$PLEX_LIB_DIR"/dri/*.so; do
    [[ -f "$driver" ]] || continue
    run "ln -sf \"$driver\" \"$PLEX_VA_CACHE/$(basename "$driver")\""
    log "Linked driver: $(basename "$driver")"
  done

  for driver in "$PLEX_DRIVERS_ROOT"/*/dri/*.so "$PLEX_DRIVERS_ROOT"/dri/*.so; do
    [[ -f "$driver" ]] || continue
    run "ln -sf \"$driver\" \"$PLEX_VA_CACHE/$(basename "$driver")\""
    log "Linked driver from Drivers tree: $(basename "$driver")"
  done
}

restart_plex() {
  if [[ "$NO_RESTART" -eq 1 ]]; then
    log "Skipping restart (--no-restart)."
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available. Restart Plex manually."
    return
  fi

  if systemctl list-unit-files | grep -q "^$SERVICE_NAME\\.service"; then
    log "Restarting $SERVICE_NAME service..."
    run "systemctl restart $SERVICE_NAME"
  else
    warn "Service $SERVICE_NAME not found. Restart Plex manually."
  fi
}

print_next_steps() {
  cat << OUT

Installation complete.

Resolved paths:
  Plex data dir: $PLEX_DATA_DIR
  Plex Drivers:  $PLEX_DRIVERS_ROOT

Recommended checks:
  1. Verify Alpine libs are in Plex lib dir:
       ls "$PLEX_LIB_DIR"/libva*.so* 2>/dev/null || true
       ls "$PLEX_LIB_DIR/dri" | head
  2. Verify driver in Plex Drivers tree:
       find "$PLEX_DRIVERS_ROOT" -name radeonsi_drv_video.so
  3. Start a Plex transcode and inspect logs for:
       final decoder: vaapi, final encoder: vaapi

If Plex updates replace libraries, rerun this installer.
Backups are kept as *.orig-amdvaapi files.
OUT
}

main() {
  parse_args "$@"
  require_root
  resolve_plex_data_dir_from_systemd
  check_plex_paths

  local temp_dir
  temp_dir=$(mktemp -d)

  if [[ "$KEEP_TEMP" -eq 0 ]]; then
    trap 'rm -rf "$temp_dir"' EXIT
  else
    log "Keeping temporary directory: $temp_dir"
  fi

  extract_alpine_payload "$temp_dir"
  overwrite_plex_libraries "$temp_dir"
  install_amdgpu_ids "$temp_dir"
  link_hardcoded_amdgpu_ids
  install_driver_into_plex_drivers "$temp_dir"
  setup_plex_va_cache
  restart_plex
  print_next_steps
}

main "$@"
