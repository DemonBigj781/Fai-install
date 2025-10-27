#!/usr/bin/env bash
# Source → Link → Checked (UTC) → Version (APA7-style)
# DemonBigj781 (2025). Non-interactive multi-GPU system setup for Debian 12/13. — Checked 2025-10-27Z. Version: v1.0.

set -euo pipefail

# ───────────────────────── Non-interactive APT/DPKG ─────────────────────────
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
APT_FLAGS=(-y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef)

# ─────────────────────────── Defaults (edit if desired) ─────────────────────
INSTALL_DOCKER=1          # 1=install docker.io and enable service
INSTALL_MONO=0            # 1=install mono-complete
INSTALL_FLATPAK=0         # 1=install flatpak + flathub + (no apps by default)
INSTALL_STEAM=0           # 1=enable i386 + install steam (desktop targets)
FORCE_XORG_FOR_NVIDIA=1   # 1=disable GNOME Wayland if gdm present
REBOOT=1                  # 1=reboot automatically if a GPU driver was installed

# Add the interactive user to 'docker' group if we can infer them:
MAIN_USER="${SUDO_USER:-}"

# ───────────────────────────── Helpers ───────────────────────────────────────
ts(){ date +'%F %T'; }
log(){ printf "\n[%s] %s\n" "$(ts)" "$*"; }
die(){ printf "\n[%s] ERROR: %s\n" "$(ts)" "$*" >&2; exit 1; }
asroot(){ [ "$EUID" -eq 0 ] || die "Run as root (sudo -s)."; }

# ───────────────────────────── Preamble ──────────────────────────────────────
asroot
. /etc/os-release || true
log "Starting install (ID=${ID:-unknown} VER=${VERSION_ID:-unknown})"

apt-get update -y
apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
  curl ca-certificates gnupg lsb-release software-properties-common >/dev/null

# ───────────────────────── GPU detection ─────────────────────────────────────
GPU="unknown"
if command -v lspci >/dev/null 2>&1; then
  LP="$(lspci -nnk 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if   grep -q 'nvidia' <<<"$LP"; then GPU="nvidia"
  elif grep -Eq 'amd|radeon|advanced micro devices' <<<"$LP"; then GPU="amd"
  elif grep -q 'intel.*(uhd|iris|graphics|vga)' <<<"$LP"; then GPU="intel"
  fi
fi
log "Detected GPU: ${GPU}"

# ───────────────────── Common Mesa/Vulkan userland ───────────────────────────
apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
  libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers \
  libvulkan1 vdpauinfo vainfo vulkan-tools vulkan-validationlayers || true

# ───────────────────────────── GPU stacks ────────────────────────────────────
DRIVER_INSTALLED=0

# NVIDIA path
if [ "$GPU" = "nvidia" ]; then
  log "Installing NVIDIA driver + CUDA + persistenced"
  # Disable nouveau
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u || true

  # Driver & CUDA runtime/toolkit
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
    firmware-misc-nonfree dkms nvidia-detect nvidia-driver \
    nvidia-cuda-toolkit nvidia-vulkan-icd || true

  # Persistence daemon
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends nvidia-persistenced || true
  systemctl enable nvidia-persistenced || true

  DRIVER_INSTALLED=1

  # Force GNOME on Xorg if GDM present (Wayland off) for NVIDIA stability
  if [ "$FORCE_XORG_FOR_NVIDIA" -eq 1 ] && command -v gdm3 >/dev/null 2>&1; then
    log "Forcing GNOME on Xorg (disabling Wayland)"
    install -d -m 0755 /etc/gdm3
    sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf 2>/dev/null || \
      printf "[daemon]\nWaylandEnable=false\n" >/etc/gdm3/custom.conf
  fi
fi

# AMD path
if [ "$GPU" = "amd" ]; then
  log "Installing AMD GPU userspace & firmware"
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
    firmware-amd-graphics xserver-xorg-video-amdgpu || true

  # Optional ROCm OpenCL (best-effort; availability varies by Debian suite)
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends rocm-opencl-runtime || true
fi

# Intel path
if [ "$GPU" = "intel" ]; then
  log "Installing Intel media VA-API"
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
    intel-media-va-driver-non-free || true
fi

# ───────────────────────── Docker + NVIDIA CTK ───────────────────────────────
if [ "$INSTALL_DOCKER" -eq 1 ]; then
  log "Installing Docker engine"
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends docker.io
  systemctl enable docker || true
  systemctl restart docker || true

  if [ "$GPU" = "nvidia" ]; then
    log "Adding NVIDIA Container Toolkit"
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      -o /usr/share/keyrings/nvidia-container-toolkit-archive-keyring.gpg || true
    DIST=$(. /etc/os-release; echo ${ID}${VERSION_ID})
    curl -fsSL "https://nvidia.github.io/libnvidia-container/${DIST}/libnvidia-container.list" \
      -o /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
    apt-get update -y || true
    apt-get install "${APT_FLAGS[@]}" --no-install-recommends nvidia-container-toolkit || true
    nvidia-ctk runtime configure --runtime=docker || true
    systemctl restart docker || true

    # simple test helper
    cat >/usr/local/bin/test-nvidia-docker <<'EOF'
#!/bin/sh
exec docker run --rm --gpus all nvidia/cuda:12.5.0-base-ubuntu24.04 nvidia-smi
EOF
    chmod +x /usr/local/bin/test-nvidia-docker
  fi

  # Add interactive user to docker group
  if [ -n "${MAIN_USER}" ] && id "${MAIN_USER}" >/dev/null 2>&1; then
    usermod -aG docker "${MAIN_USER}" || true
    log "User '${MAIN_USER}' added to 'docker' group (re-login needed)"
  fi
fi

# ───────────────────────── Optional stacks ───────────────────────────────────
[ "$INSTALL_MONO"   -eq 1 ] && apt-get install "${APT_FLAGS[@]}" --no-install-recommends mono-complete || true

if [ "$INSTALL_FLATPAK" -eq 1 ]; then
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends flatpak || true
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi

if [ "$INSTALL_STEAM" -eq 1 ]; then
  dpkg --add-architecture i386
  apt-get update -y
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends steam || \
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends steam-installer || true
  apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
    libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 libvulkan1:i386 || true
  [ "$GPU" = "nvidia" ] && apt-get install "${APT_FLAGS[@]}" --no-install-recommends \
    nvidia-driver-libs:i386 nvidia-vulkan-icd:i386 || true
fi

# ───────────────────────── Summary / Reboot ──────────────────────────────────
log "Install complete (non-interactive)."

if [ "$REBOOT" -eq 1 ] && [ "$DRIVER_INSTALLED" -eq 1 ]; then
  log "Rebooting to load new GPU modules…"
  exec /sbin/reboot
fi

# If not rebooting automatically, print useful hints:
if [ "$DRIVER_INSTALLED" -eq 1 ]; then
  echo "GPU driver installed. Reboot recommended."
fi
if [ "$INSTALL_DOCKER" -eq 1 ]; then
  echo "Docker installed. Try: docker run hello-world"
  [ "$GPU" = "nvidia" ] && echo "GPU test: test-nvidia-docker"
fi