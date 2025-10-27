#!/usr/bin/env bash
# First-boot WPA + GitHub installer fetch/exec for FAI.me
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

# Your hosted installer (raw link)
INSTALL_URL="https://raw.githubusercontent.com/DemonBigj781/Fai-install/refs/heads/Main/install.sh"
INSTALL_SHA256=""                 # optional; leave empty to skip
INSTALL_PATH="/tmp/install.sh"
COUNTRY="US"                      # change if needed
HIDDEN=0                          # 1 if SSID hidden
WPA3=0                            # 1 to prefer WPA3-SAE + WPA2 fallback

ts(){ date +'%F %T'; } ; log(){ printf "\n[%s] %s\n" "$(ts)" "$*"; }
die(){ printf "\n[%s] ERROR: %s\n" "$(ts)" "$*" >&2; exit 1; }

# Tools should be preinstalled by addpkgs; keep best-effort refresh
apt-get update -y >/dev/null || true
apt-get install -y --no-install-recommends \
  wpasupplicant wireless-tools iw ifupdown isc-dhcp-client ca-certificates \
  curl wget rfkill >/dev/null || true

# Unblock Wi-Fi just in case
rfkill unblock all || true

# Detect Wi-Fi interface
IFACE="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')"
[ -n "${IFACE}" ] || die "No Wi-Fi interface found."

# Ask only for SSID & pass
printf "\nEnter Wi-Fi SSID: "
read -r SSID
[ -n "$SSID" ] || die "SSID required."

printf "Enter passphrase for '%s': " "$SSID"
stty -echo; read -r PASS; stty echo; printf "\n"
[ -n "$PASS" ] || die "Passphrase required."

# Hashed PSK config
TMP="/tmp/wpa_${IFACE}.conf"
wpa_passphrase "$SSID" "$PASS" > "$TMP"
chmod 600 "$TMP"

CONF_DIR="/etc/wpa_supplicant"
CONF_PATH="${CONF_DIR}/wpa_supplicant-${IFACE}.conf"
install -d -m 0755 "$CONF_DIR"
{
  echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
  echo "update_config=0"
  echo "country=${COUNTRY}"
  echo "network={"
  echo "    ssid=\"${SSID}\""
  [ "${HIDDEN}" -eq 1 ] && echo "    scan_ssid=1"
  if [ "${WPA3}" -eq 1 ]; then
    echo "    key_mgmt=SAE WPA-PSK"
    echo "    ieee80211w=2"
  else
    echo "    key_mgmt=WPA-PSK"
    echo "    ieee80211w=1"
  fi
  awk -F= '/^[[:space:]]*psk=([0-9a-fA-F]{64})$/ {print "    psk="$2}' "$TMP"
  echo "    proto=RSN"
  echo "}"
} > "${CONF_PATH}"
chmod 600 "${CONF_PATH}"
rm -f "${TMP}"

# DHCP stanza
install -d -m 0755 /etc/network/interfaces.d
cat > "/etc/network/interfaces.d/${IFACE}" <<EOF
allow-hotplug ${IFACE}
iface ${IFACE} inet dhcp
    wpa-conf ${CONF_PATH}
EOF

# Connect now
systemctl enable "wpa_supplicant@${IFACE}.service" >/dev/null 2>&1 || true
log "Connecting Wi-Fi on ${IFACE}…"
pkill -f "wpa_supplicant.*${IFACE}" >/dev/null 2>&1 || true
wpa_supplicant -B -i "${IFACE}" -c "${CONF_PATH}" >/dev/null 2>&1 || true
dhclient -nw "${IFACE}" >/dev/null 2>&1 || true
sleep 5

# Fetch & run your installer (non-interactive)
[ -n "${INSTALL_URL}" ] || die "INSTALL_URL not set."
log "Fetching installer: ${INSTALL_URL}"
if command -v curl >/dev/null; then
  curl -fsSL --retry 5 --retry-delay 2 -o "${INSTALL_PATH}.part" "${INSTALL_URL}"
else
  wget -qO "${INSTALL_PATH}.part" "${INSTALL_URL}"
fi
mv -f "${INSTALL_PATH}.part" "${INSTALL_PATH}"
chmod +x "${INSTALL_PATH}"

[ -z "$INSTALL_SHA256" ] || echo "${INSTALL_SHA256}  ${INSTALL_PATH}" | sha256sum -c - || die "SHA-256 mismatch."

log "Executing installer (non-interactive)…"
exec "${INSTALL_PATH}"