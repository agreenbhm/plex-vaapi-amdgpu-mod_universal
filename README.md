# Plex AMD VAAPI Host Installer (in-place Plex library replacement)

This repository provides a host-side installer that **replaces Plex-used libraries in place** with Alpine edge MUSL VAAPI components.

Instead of maintaining a separate runtime folder and redirecting Plex with custom library paths, this approach installs Alpine userspace files directly into Plex's own library locations.

## What this installer does

`install-plex-amd-vaapi.sh` now performs these steps:

1. Pulls an Alpine image (`alpine:edge` by default) using `docker` or `podman`.
2. Extracts MUSL VAAPI stack components similar to the original Docker mod build process:
   - `radeonsi_drv_video.so`
   - `libva*.so*`
   - transitive library dependencies
   - musl loader / musl libc
   - `amdgpu.ids`
3. Overwrites matching files in Plex library directories:
   - `/usr/lib/plexmediaserver/lib`
   - `/usr/lib/plexmediaserver/lib/dri`
4. Replaces `/usr/share/libdrm/amdgpu.ids` with the Alpine version.
5. Scans Plex libraries for hardcoded `amdgpu.ids` paths and symlinks them.
6. Rebuilds Plex VA cache symlinks and optionally restarts `plexmediaserver`.

## Safety / backups

Before replacing any existing target file, the installer creates a one-time backup:

- `<target>.orig-amdvaapi`

These backups are retained so you can manually restore files if needed.

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
--dry-run            Print actions only
--no-restart         Do not restart plexmediaserver
--alpine-image IMG   Override source image (default: alpine:edge)
--keep-temp          Keep temporary extraction directory
```

## Verify

1. Confirm libraries/drivers are present in Plex directories:

```bash
ls /usr/lib/plexmediaserver/lib/libva*.so*
ls /usr/lib/plexmediaserver/lib/dri | head
```

2. Start a transcode and inspect Plex logs for:

```text
final decoder: vaapi, final encoder: vaapi
```

3. In Plex dashboard, active transcodes should show `(hw)`.

## Notes

- If Plex updates overwrite bundled libraries, rerun the installer.
- This intentionally mirrors the original Alpine MUSL extraction strategy while targeting non-Docker Plex installs.
