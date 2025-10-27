#!/usr/bin/env bash
# main-installer.sh  —  Debian 12 (Bookworm)
# Full multi-GPU desktop (NVIDIA + Intel HD + AMD RX 580 2048SP)
# Minimal GNOME on Xorg, Docker + NVIDIA CTK, Mono, Steam + Proton-GE, Bottles + Flatseal, extras.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf "\n[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
apt_install() { apt-get install -y "$@"; }
try_install() { apt-get install -y "$@" || true; }

MAIN_USER="${MAIN_USER:-}"

log "Updating APT…"
apt-get update -y
apt_install curl ca-certificates lsb-release gnupg

# -------------------------------------------------------------------
# Disable Nouveau
# -------------------------------------------------------------------
cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
update-initramfs -u

# -------------------------------------------------------------------
# Mesa / Vulkan stack (common to all GPUs)
# -------------------------------------------------------------------
apt_install libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers \
            vdpauinfo vainfo libvulkan1

# -------------------------------------------------------------------
# Intel + AMD (RX 580 2048SP, Samsung VRAM)
# -------------------------------------------------------------------
try_install intel-media-va-driver i965-va-driver
apt_install firmware-amd-graphics xserver-xorg-video-amdgpu \
            mesa-vulkan-drivers libgl1-mesa-dri vainfo vdpauinfo
cat >/etc/modprobe.d/blacklist-radeon.conf <<'EOF'
blacklist radeon
EOF
install -d -m 0755 /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/20-amdgpu.conf <<'EOF'
Section "Device"
    Identifier "AMDgpu"
    Driver "amdgpu"
    Option "TearFree" "true"
    Option "VariableRefresh" "true"
EndSection
EOF

# -------------------------------------------------------------------
# NVIDIA + CUDA + Legacy fallback
# -------------------------------------------------------------------
apt_install nvidia-driver firmware-misc-nonfree dkms nvidia-detect \
           nvidia-vulkan-icd vulkan-tools vulkan-validationlayers
try_install nvidia-cuda-toolkit
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  try_install nvidia-legacy-470xx-driver
  try_install nvidia-legacy-390xx-driver
fi
try_install nvidia-persistenced
systemctl enable nvidia-persistenced || true

# -------------------------------------------------------------------
# Minimal GNOME on Xorg
# -------------------------------------------------------------------
apt_install xorg gnome-core gdm3
install -d -m 0755 /etc/gdm3
sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf 2>/dev/null || \
echo -e "[daemon]\nWaylandEnable=false" >/etc/gdm3/custom.conf
echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections || true
systemctl enable gdm3 || true
systemctl set-default graphical.target || true
try_install gnome-tweaks gnome-shell-extensions gnome-system-monitor xdg-user-dirs-gtk

# -------------------------------------------------------------------
# Docker + NVIDIA Container Toolkit
# -------------------------------------------------------------------
apt_install docker.io docker-compose
mkdir -p /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  > /usr/share/keyrings/nvidia-container-toolkit-archive-keyring.gpg
DIST=$(. /etc/os-release; echo ${ID}${VERSION_ID})
curl -sSL https://nvidia.github.io/libnvidia-container/${DIST}/libnvidia-container.list \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -y
apt_install nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker || true
systemctl enable docker || true
systemctl restart docker || true
[ -n "$MAIN_USER" ] && id "$MAIN_USER" >/dev/null 2>&1 && usermod -aG docker "$MAIN_USER" || true

# -------------------------------------------------------------------
# Mono
# -------------------------------------------------------------------
apt_install mono-complete

# -------------------------------------------------------------------
# Extra toolchain
# -------------------------------------------------------------------
EXTRA_PKGS=(
  zram-tools nvidia-detect python3.13 python3.13-venv
  lynx kate nano wine winetricks
  git gzip unzip wget tig build-essential cmake pkg-config python3-pip diffutils ssh
  htop nvtop synaptic flatpak wine64 dxvk zip p7zip-full
  jq git-lfs openssh-server screen debian-archive-keyring firmware-iwlwifi firmware-linux-nonfree
)
for pkg in "${EXTRA_PKGS[@]}"; do
  apt-get install -y "$pkg" || true
done

# -------------------------------------------------------------------
# Flatpak + Flathub + Bottles + Flatseal
# -------------------------------------------------------------------
try_install flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
flatpak install -y flathub com.usebottles.bottles || true
flatpak install -y flathub com.github.tchx84.Flatseal || true

# -------------------------------------------------------------------
# Steam + Proton GE
# -------------------------------------------------------------------
dpkg --add-architecture i386
apt-get update -y
apt_install steam || try_install steam-installer
try_install libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 libvulkan1:i386
try_install nvidia-driver-libs:i386 nvidia-vulkan-icd:i386

log "Installing Proton GE (GloriousEggroll)…"
STEAM_COMPAT_DIR="/usr/share/steam/compatibilitytools.d"
mkdir -p "$STEAM_COMPAT_DIR"
LATEST_GE=$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
[ -z "$LATEST_GE" ] && LATEST_GE="GE-Proton8-32"   # fallback
curl -L -o /tmp/proton-ge.tar.gz \
  "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${LATEST_GE}/${LATEST_GE}.tar.gz" || true
tar -xzf /tmp/proton-ge.tar.gz -C "$STEAM_COMPAT_DIR" || true
log "Installed Proton GE: ${LATEST_GE}"

# -------------------------------------------------------------------
# CMP 170HX / Tesla V100 tuning (safe for display)
# -------------------------------------------------------------------
cat >/usr/local/sbin/nvidia-compute-tune.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nvidia-modprobe -u -c=0 || true
nvidia-smi -pm 1 || true
ACTIVE=$(nvidia-smi --query-gpu=display_active --format=csv,noheader 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
if echo "$ACTIVE" | grep -q "enabled"; then exit 0; fi
COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
for i in $(seq 0 $((COUNT-1))); do nvidia-smi -i "$i" -c EXCLUSIVE_PROCESS || true; done
EOF
chmod +x /usr/local/sbin/nvidia-compute-tune.sh

cat >/etc/systemd/system/nvidia-compute-tune.service <<'EOF'
[Unit]
Description=NVIDIA compute tuning (Persistence + conditional Exclusive Process)
After=nvidia-persistenced.service multi-user.target
Requires=nvidia-persistenced.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-compute-tune.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable nvidia-persistenced || true
systemctl enable nvidia-compute-tune.service || true

# -------------------------------------------------------------------
# GPU-in-container quick test
# -------------------------------------------------------------------
cat >/usr/local/bin/test-nvidia-docker <<'EOF'
#!/bin/sh
docker run --rm --gpus all nvidia/cuda:12.5.0-base-ubuntu24.04 nvidia-smi
EOF
chmod +x /usr/local/bin/test-nvidia-docker

log "✅ Installation complete. Reboot to load NVIDIA modules (Nouveau disabled)."
log "After login (GNOME on Xorg):"
log "  • GPU-Docker test:  test-nvidia-docker"
log "  • Steam + Proton GE ready (choose ${LATEST_GE} in game > Properties > Compatibility)"
log "  • Bottles:          flatpak run com.usebottles.bottles"
log "  • Flatseal:         flatpak run com.github.tchx84.Flatseal"