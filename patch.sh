#!/bin/bash
sed -i 's/if false; then/if is_shell_script "$PLEX_TRANSCODER" \&\& [ "$IS_AMD_GPU" -eq 1 ]; then/g' run.hevc
sed -i 's/if is_shell_script "$PLEX_TRANSCODER" \\&\\& \[ "$IS_AMD_GPU" -eq 1 \]; then/if is_shell_script "$PLEX_TRANSCODER"; then/g' run.hevc
