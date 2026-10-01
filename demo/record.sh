#!/usr/bin/env bash
# Record demo/agentmap.gif from demo/demo.tape with vhs running in docker.
#   No local vhs / ttyd / ffmpeg needed; only docker.
#   Neovim: the host's Neovim install folder is mounted read-only (NVIM_DIR, the folder that
#   contains bin/nvim and share/nvim). It must be a self-contained build (e.g. the official
#   nvim-linux-x86_64.tar.gz), not a distro package.
#
#   NVIM_DIR=/path/to/nvim-linux-x86_64 bash demo/record.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
: "${NVIM_DIR:?set NVIM_DIR to a Neovim install folder (contains bin/nvim)}"
image=${VHS_IMAGE:-ghcr.io/charmbracelet/vhs}

docker run --rm \
  -v "$repo":/repo -w /repo \
  -v "$NVIM_DIR":/opt/nvim:ro \
  -e PATH=/opt/nvim/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$image" demo/demo.tape

# vhs runs as root inside the container; give the file back to the current user
docker run --rm -v "$repo/demo":/out --entrypoint chown "$image" "$(id -u):$(id -g)" /out/agentmap.gif
ls -l "$repo/demo/agentmap.gif"
