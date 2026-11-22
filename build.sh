#!/usr/bin/env bash
# AttackFrame OS — ISO build entry point (Docker + Docker Compose).
#
# Builds an Ubuntu-based live/install ISO inside a privileged builder container
# (docker-compose.yml). Kali and BlackArch are NOT installed on the host OS: each
# runs as its own Docker (distrobox) container. Their images are built here on
# your Docker daemon and shipped inside the ISO, so `kali <tool>` /
# `blackarch <tool>` work offline on the live system.
#
#   ./build.sh                          # TOOLSET=core   (curated Kali + BlackArch images)
#   TOOLSET=minimal ./build.sh          # no images; containers are pulled on first use
#   TOOLSET=large ./build.sh            # kali-linux-default + BlackArch groups in BA_GROUPS
#   UBUNTU_SUITE=resolute ./build.sh    # build on a different Ubuntu release
#
# Needs: docker + the compose plugin (`docker compose`) or docker-compose v1.
# Output: ./out/attackframe-<date>-amd64.iso
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

export TOOLSET="${TOOLSET:-core}"
export UBUNTU_SUITE="${UBUNTU_SUITE:-noble}"
case "$TOOLSET" in minimal|core|large) ;; *) echo "TOOLSET must be minimal|core|large" >&2; exit 1;; esac

command -v docker >/dev/null || { echo "docker is required: sudo apt install docker.io docker-buildx docker-compose-v2" >&2; exit 1; }

# talk to the daemon directly when we can (docker group), otherwise via sudo
if ! docker info >/dev/null 2>&1; then
  if (( EUID != 0 )); then
    echo ">> can't reach the Docker daemon as $(id -un) — re-running with sudo"
    echo "   (or: sudo usermod -aG docker $(id -un) and log in again)"
    exec sudo --preserve-env=TOOLSET,UBUNTU_SUITE,UBUNTU_MIRROR,KERNEL_PKG,KALI_IMAGE,BLACKARCH_BASE,KALI_META,BA_GROUPS,STRAP_SHA1,SQUASHFS_LEVEL \
      "$0" "$@"
  fi
  echo "the Docker daemon isn't running: sudo systemctl enable --now docker" >&2; exit 1
fi

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then COMPOSE=(docker-compose)
else echo "Docker Compose is required: sudo apt install docker-compose-v2" >&2; exit 1; fi

export HOST_UID="${SUDO_UID:-$(id -u)}" HOST_GID="${SUDO_GID:-$(id -g)}"
mkdir -p out .cache/apt .cache/debootstrap .cache/fonts .work
echo ">> AttackFrame build  base=ubuntu:$UBUNTU_SUITE  toolset=$TOOLSET  (${COMPOSE[*]})"

exec "${COMPOSE[@]}" -f "$HERE/docker-compose.yml" run --rm builder
