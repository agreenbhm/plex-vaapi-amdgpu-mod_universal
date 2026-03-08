# Plex AMD VAAPI Host Installer (Alpine MUSL bundle)

This repository provides a **host-side installer** for Plex Media Server on Linux VMs/LXC/bare metal.

It is specifically designed to mimic the original Docker-mod behavior by extracting **MUSL-built** userspace VAAPI libraries from Alpine edge and injecting them into Plex runtime startup.

## Why this approach

Plex bundles MUSL-linked components and has hardcoded expectations around its GPU userspace stack. In some environments, using distro-native glibc Mesa/libva packages alone is not sufficient for newer AMD GPUs.

So this installer follows the same functional strategy as the original mod:

1. Acquire modern `mesa-va-gallium`, `libva`, and `libdrm` from **Alpine edge**.
2. Copy required libraries, dependencies, and `amdgpu.ids` into a local bundle.
3. Wrap `Plex Media Server` and `Plex Transcoder` to force that bundle via `LD_LIBRARY_PATH` and `LIBVA_*`.
4. Symlink VA drivers into Plex VA cache.
5. Symlink hardcoded `amdgpu.ids` paths found in Plex binaries.

## What gets installed

By default, extracted files are installed under:

- `/opt/plex-amd-vaapi/vaapi-amdgpu/lib`
- `/opt/plex-amd-vaapi/vaapi-amdgpu/lib/dri`
- `/opt/plex-amd-vaapi/usr/share/libdrm/amdgpu.ids`

## Requirements

- Plex installed at `/usr/lib/plexmediaserver`
- Root access
- `docker` or `podman` installed (used to extract Alpine files)
- AMD GPU available to host/LXC (`/dev/dri`)

## Install

```bash
cd /path/to/plex-vaapi-amdgpu-mod_universal
sudo ./install-plex-amd-vaapi.sh
```

## Options

```text
--dry-run               Print actions only
--no-restart            Do not restart plexmediaserver
--skip-bundle-refresh   Reuse existing extracted bundle
--bundle-root PATH      Override bundle root (default /opt/plex-amd-vaapi)
--alpine-image IMAGE    Override Alpine image (default alpine:edge)
```

## Verify

1. Confirm bundle exists:

```bash
ls /opt/plex-amd-vaapi/vaapi-amdgpu/lib | head
```

2. Confirm wrappers were installed:

```bash
head -n 12 /usr/lib/plexmediaserver/Plex\ Transcoder
head -n 12 /usr/lib/plexmediaserver/Plex\ Media\ Server
```

3. Run a transcode and inspect Plex logs for:

```text
final decoder: vaapi, final encoder: vaapi
```

4. In Plex dashboard, active transcodes should show `(hw)`.

## Re-run behavior

- If Plex updates overwrite `Plex Media Server` / `Plex Transcoder`, rerun installer.
- If you want fresh Alpine edge libraries, rerun without `--skip-bundle-refresh`.
