#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Plex AMD VAAPI host installer
# Mirrors the original docker-mod approach by extracting
# MUSL-built Mesa/libva/libdrm userspace from Alpine edge.
# ============================================================

PLEX_DIR="/usr/lib/plexmediaserver"
PLEX_LIB_DIR="$PLEX_DIR/lib"
PLEX_DATA_DIR="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
PLEX_CACHE_DIR="$PLEX_DATA_DIR/Cache"
PLEX_VA_CACHE="$PLEX_CACHE_DIR/va-dri-linux-x86_64"
MESA_SHADER_CACHE_DIR="$PLEX_CACHE_DIR/mesa-shader-cache"
SERVICE_NAME="plexmediaserver"

BUNDLE_ROOT="/opt/plex-amd-vaapi"
BUNDLE_DIR="$BUNDLE_ROOT/vaapi-amdgpu"
BUNDLE_AMDGPU_IDS="$BUNDLE_ROOT/usr/share/libdrm/amdgpu.ids"

ALPINE_IMAGE="alpine:edge"
RUNTIME=""

DRY_RUN=0
NO_RESTART=0
SKIP_BUNDLE_REFRESH=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

usage() {
  cat << USAGE
Usage: sudo ./install-plex-amd-vaapi.sh [options]

Options:
  --dry-run              Print actions only
  --no-restart           Do not restart plexmediaserver
  --skip-bundle-refresh  Reuse existing Alpine-extracted bundle
  --bundle-root PATH     Install extracted files under PATH (default: /opt/plex-amd-vaapi)
  --alpine-image IMAGE   Alpine source image (default: alpine:edge)
  -h, --help             Show this help
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
      --skip-bundle-refresh)
        SKIP_BUNDLE_REFRESH=1
        ;;
      --bundle-root)
        shift
        [[ $# -eq 0 ]] && { err "--bundle-root requires a path"; exit 1; }
        BUNDLE_ROOT="$1"
        BUNDLE_DIR="$BUNDLE_ROOT/vaapi-amdgpu"
        BUNDLE_AMDGPU_IDS="$BUNDLE_ROOT/usr/share/libdrm/amdgpu.ids"
        ;;
      --alpine-image)
        shift
        [[ $# -eq 0 ]] && { err "--alpine-image requires an image"; exit 1; }
        ALPINE_IMAGE="$1"
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

check_plex_paths() {
  if [[ ! -d "$PLEX_DIR" ]]; then
    err "Plex directory not found: $PLEX_DIR"
    exit 1
  fi

  if [[ ! -f "$PLEX_DIR/Plex Media Server" || ! -f "$PLEX_DIR/Plex Transcoder" ]]; then
    err "Expected Plex binaries not found under: $PLEX_DIR"
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

  err "Neither docker nor podman is installed. One is required to extract Alpine MUSL VAAPI libraries."
  exit 1
}

extract_alpine_bundle() {
  if [[ "$SKIP_BUNDLE_REFRESH" -eq 1 ]]; then
    log "Skipping Alpine bundle refresh (--skip-bundle-refresh)."
    return
  fi

  detect_runtime
  log "Using container runtime: $RUNTIME"
  log "Pulling Alpine source image: $ALPINE_IMAGE"
  run "$RUNTIME pull \"$ALPINE_IMAGE\""

  local cid=""
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
    printf '[DRY-RUN] %s create "%s" sh -lc "...extract bundle..."\n' "$RUNTIME" "$ALPINE_IMAGE"
    return
  fi

  cid=$($RUNTIME create "$ALPINE_IMAGE" sh -lc "$build_cmd")
  trap '$RUNTIME rm -f "$cid" >/dev/null 2>&1 || true' RETURN

  $RUNTIME start -a "$cid" >/dev/null
  rm -rf "$BUNDLE_ROOT"
  mkdir -p "$BUNDLE_ROOT"
  $RUNTIME cp "$cid:/source/." "$BUNDLE_ROOT/"
  $RUNTIME rm -f "$cid" >/dev/null 2>&1 || true
  trap - RETURN

  if [[ ! -f "$BUNDLE_DIR/lib/dri/radeonsi_drv_video.so" ]]; then
    err "Extraction failed: missing $BUNDLE_DIR/lib/dri/radeonsi_drv_video.so"
    exit 1
  fi

  log "Extracted Alpine MUSL VAAPI bundle to: $BUNDLE_ROOT"
}

link_hardcoded_amdgpu_ids() {
  if [[ ! -f "$BUNDLE_AMDGPU_IDS" ]]; then
    warn "amdgpu.ids missing from extracted bundle at $BUNDLE_AMDGPU_IDS"
    return
  fi

  log "Scanning Plex libraries for hardcoded amdgpu.ids paths..."
  local found
  found=$(grep -r -h -o -a '/home/runner[^"[:space:]]*amdgpu\.ids' "$PLEX_LIB_DIR" 2>/dev/null | sort -u || true)

  if [[ -z "$found" ]]; then
    log "No hardcoded amdgpu.ids paths found (cosmetic unknown-GPU naming may remain)."
    return
  fi

  while IFS= read -r ids_path; do
    [[ -z "$ids_path" ]] && continue
    log "Found hardcoded path: $ids_path"
    run "mkdir -p \"$(dirname "$ids_path")\""
    run "ln -sf \"$BUNDLE_AMDGPU_IDS\" \"$ids_path\""
  done <<< "$found"
}

write_wrapper() {
  local target="$1"
  local orig="$2"
  local exec_orig="$3"

  if [[ ! -f "$orig" ]]; then
    log "Backing up original binary: $target -> $orig"
    run "mv \"$target\" \"$orig\""
  else
    log "Wrapper already exists for: $target"
  fi

  local tmp_wrapper
  tmp_wrapper=$(mktemp)
  cat > "$tmp_wrapper" << WRAPPER
#!/usr/bin/env bash
set -euo pipefail

export LD_LIBRARY_PATH="$BUNDLE_DIR/lib:\${LD_LIBRARY_PATH:-}"
export LIBVA_DRIVERS_PATH="$BUNDLE_DIR/lib/dri"
export LIBVA_DRIVER_NAME="radeonsi"
export MESA_SHADER_CACHE_DIR="$MESA_SHADER_CACHE_DIR"
mkdir -p "\$MESA_SHADER_CACHE_DIR" 2>/dev/null || true

exec "$exec_orig" "\$@"
WRAPPER

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] install wrapper at %s\n' "$target"
    rm -f "$tmp_wrapper"
  else
    install -m 0755 "$tmp_wrapper" "$target"
    rm -f "$tmp_wrapper"
  fi
}

setup_wrappers() {
  log "Creating Plex wrappers to force Alpine MUSL VAAPI stack..."
  write_wrapper "$PLEX_DIR/Plex Transcoder" "$PLEX_DIR/Plex Transcoder.orig" "$PLEX_DIR/Plex Transcoder.orig"
  write_wrapper "$PLEX_DIR/Plex Media Server" "$PLEX_DIR/Plex Media Server.orig" "$PLEX_DIR/Plex Media Server.orig"
}

setup_va_cache() {
  local driver="$BUNDLE_DIR/lib/dri/radeonsi_drv_video.so"

  if [[ ! -f "$driver" ]]; then
    err "Missing driver in bundle: $driver"
    exit 1
  fi

  run "mkdir -p \"$PLEX_VA_CACHE\" \"$MESA_SHADER_CACHE_DIR\""
  run "rm -f \"$PLEX_VA_CACHE\"/*.so* 2>/dev/null || true"

  local so
  for so in "$BUNDLE_DIR"/lib/dri/*.so; do
    [[ -f "$so" ]] || continue
    run "ln -sf \"$so\" \"$PLEX_VA_CACHE/$(basename "$so")\""
    log "Linked driver: $(basename "$so")"
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

Recommended checks:
  1. Validate extracted runtime exists:
       ls "$BUNDLE_DIR/lib" | head
  2. Verify Plex wrappers are scripts:
       head -n 8 "$PLEX_DIR/Plex Transcoder"
       head -n 8 "$PLEX_DIR/Plex Media Server"
  3. Start a Plex transcode and inspect logs for:
       final decoder: vaapi, final encoder: vaapi

If Plex updates overwrite wrappers, rerun this installer.
OUT
}

main() {
  parse_args "$@"
  require_root
  check_plex_paths
  extract_alpine_bundle
  link_hardcoded_amdgpu_ids
  setup_wrappers
  setup_va_cache
  restart_plex
  print_next_steps
}

main "$@"
