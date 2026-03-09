# Plex AMD VAAPI Host Installer (in-place Plex library replacement)

This repository provides a host-side installer that **replaces Plex-used libraries in place** with Alpine edge MUSL VAAPI components.

## What this installer does

`install-plex-amd-vaapi.sh` performs these steps:

1. Detects Plex environment overrides from systemd (`Environment=` and `EnvironmentFile=`), including `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR`, unless you explicitly set `--plex-data-dir`.
2. Pulls Alpine (`alpine:edge` by default) via `docker` or `podman`.
3. Extracts MUSL VAAPI stack components:
   - `radeonsi_drv_video.so`
   - `libva*.so*`
   - transitive dependencies
   - musl loader / musl libc
   - `amdgpu.ids`
4. Overwrites matching files in:
   - `/usr/lib/plexmediaserver/lib`
   - `/usr/lib/plexmediaserver/lib/dri`
5. Replaces `/usr/share/libdrm/amdgpu.ids` with the Alpine version.
6. Scans Plex libraries for hardcoded `amdgpu.ids` paths and symlinks them.
7. Places `radeonsi_drv_video.so` inside Plex app-support `Drivers` tree (existing detected location(s), or creates `Drivers/lib/dri` fallback).
8. Rebuilds Plex VA cache symlinks and optionally restarts `plexmediaserver`.

## Safety / backups

Before replacing any existing target file, the installer creates a one-time backup:

- `<target>.orig-amdvaapi`

## Requirements

- Plex installed at `/usr/lib/plexmediaserver`
- Root access
- `docker` or `podman`
- AMD GPU exposed to host/LXC (`/dev/dri`)

## Install

```bash
cd /path/to/plex-vaapi-amdgpu-mod_universal
sudo ./install-plex-amd-vaapi.sh
```

## Options

```text
--dry-run               Print actions only
--no-restart            Do not restart plexmediaserver
--alpine-image IMG      Override source image (default: alpine:edge)
--service-name NAME     Override systemd unit name (default: plexmediaserver)
--plex-data-dir PATH    Override Plex app support dir (skip systemd env detection)
--keep-temp             Keep temporary extraction directory
```

## Verify

1. Confirm libraries/drivers are present in Plex locations:

```bash
ls /usr/lib/plexmediaserver/lib/libva*.so*
ls /usr/lib/plexmediaserver/lib/dri | head
```

2. Confirm driver is in Plex Drivers tree:

```bash
find "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Drivers" -name radeonsi_drv_video.so
```

(Use your custom app-support path if overridden via systemd/env.)

3. Start a transcode and inspect Plex logs for:

```text
final decoder: vaapi, final encoder: vaapi
```

## Notes

- If Plex updates overwrite bundled libraries, rerun the installer.
- If you use a custom systemd unit name, pass `--service-name`.
