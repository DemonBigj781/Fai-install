#!/usr/bin/env bash
# Source → Link → Checked (UTC) → Version (APA7-style)
# DemonBigj781 (2025). FAI.me auto-submit, poll, and download ISO. https://fai-project.org/FAIme/ — Checked 2025-10-27Z. Version: v2.0.

set -euo pipefail

# ── USER CONFIG ────────────────────────────────────────────────────────────
POSTINST="postinst.sh"              # your first-boot script (SSID/PASS → fetch GitHub install.sh)
SUITE="bookworm"                    # Debian suite for FAI.me (e.g. bookworm)
PARTITION="ONE"                     # ONE | ONE_EFI | HOME | HOME_EFI | ONE_LVM | ONE_LVM_EFI
DESKTOP=""                          # "" for none; or gnome/xfce/etc.
USERNAME="debian"                   # installer user
USERPW="debian"
ROOTPW="root"
EMAIL=""                            # optional; leave empty if not used

# Wi-Fi tools + firmware ONLY (GPU etc. handled by your hosted install.sh)
ADD_PKGS="wpasupplicant wireless-tools iw ifupdown isc-dhcp-client ca-certificates curl wget rfkill \
firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-realtek"

# Build behavior
FAIME_URL="https://fai-project.org/cgi/faime.cgi"
OUTPUT_DIR="$PWD"
ISO_NAME_PREFIX="fai_custom_${SUITE}"
POLL_INTERVAL=30                    # seconds between status polls
POLL_TIMEOUT=5400                   # max seconds to wait (e.g. 90 min)

# First-boot FAI classes (keep postinst minimal)
CL_BACKPORTS=1
CL_SSH_SERVER=1
CL_STANDARD=1
CL_NONFREE=1
CL_RECOMMENDS=1
END_ACTION="REBOOT"                 # REBOOT | SHUTDOWN | WAIT
RUN_POSTINST_ON_FIRSTBOOT=1         # 1 => rclocal=1

# ── Helpers ────────────────────────────────────────────────────────────────
ts(){ date +'%F %T'; }
log(){ printf "\n[%s] %s\n" "$(ts)" "$*"; }
die(){ printf "\n[%s] ERROR: %s\n" "$(ts)" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

check_deps() { need curl; need grep; need awk; need sed; }

extract_links(){
  # Parse both bare URLs and href targets from an HTML blob
  # stdin: HTML, stdout: list of URLs
  cat \
  | grep -Eo 'https?://[^"<>[:space:]]+' \
  | sed -e 's/[")'\''[:space:]]*$//' \
  | awk '!seen[$0]++'
}

submit_faime(){
  local cl1 cl5 cl6 cl7 cl9 rclocal
  [ "$CL_BACKPORTS"  -eq 1 ] && cl1="-F cl1=BACKPORTS" || cl1=""
  [ "$CL_SSH_SERVER" -eq 1 ] && cl5="-F cl5=SSH_SERVER" || cl5=""
  [ "$CL_STANDARD"   -eq 1 ] && cl6="-F cl6=STANDARD"   || cl6=""
  [ "$CL_NONFREE"    -eq 1 ] && cl7="-F cl7=NONFREE"    || cl7=""
  [ "$CL_RECOMMENDS" -eq 1 ] && cl9="-F cl9=RECOMMENDS" || cl9=""
  [ "$RUN_POSTINST_ON_FIRSTBOOT" -eq 1 ] && rclocal="-F rclocal=1" || rclocal=""

  log "Checking FAI.me availability…"
  local http
  http="$(curl -fsSLI -o /dev/null -w '%{http_code}' "$FAIME_URL" || true)"
  case "$http" in 200|301|302) ;; *) die "FAI.me not reachable (HTTP $http)";; esac

  log "Submitting build to FAI.me (upload with progress)…"
  # --progress-bar shows upload progress for multipart form
  curl -fL --progress-bar -X POST "$FAIME_URL" \
    -F type=install \
    -F "username=${USERNAME}" \
    -F "userpw=${USERPW}" \
    -F "rootpw=${ROOTPW}" \
    -F "suite=${SUITE}" \
    -F "partition=${PARTITION}" \
    -F "desktop=${DESKTOP}" \
    -F "addpkgs=${ADD_PKGS}" \
    $cl1 $cl5 $cl6 $cl7 $cl9 \
    -F "cl8=${END_ACTION}" \
    $rclocal \
    -F "sbm=2" \
    ${EMAIL:+-F "email=${EMAIL}"} \
    -F "postinst=@${POSTINST}" \
    -o submit_response.html

  log "Submission complete → submit_response.html"
}

find_initial_links(){
  local iso="" status=""
  iso="$(grep -Eo 'https?://[^"<>[:space:]]+\.iso' submit_response.html | head -n1 || true)"
  if [ -n "$iso" ]; then
    printf "ISO|%s\n" "$iso"
    return
  fi
  status="$(cat submit_response.html | extract_links | grep -Ei 'fai|FAIme|cgi|status' | head -n1 || true)"
  if [ -n "$status" ]; then
    printf "STATUS|%s\n" "$status"
    return
  fi
  printf "NONE|\n"
}

poll_status_for_iso(){
  local status_url="$1" elapsed=0
  log "Polling status for ISO link: $status_url"
  while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    page="$(curl -fsSL "$status_url" || true)"
    iso="$(printf "%s" "$page" | grep -Eo 'https?://[^"<>[:space:]]+\.iso' | head -n1 || true)"
    if [ -n "$iso" ]; then
      echo "$iso"
      return 0
    fi
    log "Still building… (${elapsed}s elapsed). Next check in ${POLL_INTERVAL}s."
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  return 1
}

download_iso(){
  local url="$1" out="$2"
  log "Downloading ISO (resumable, progress bar): $url"
  mkdir -p "$(dirname "$out")"
  curl -fL --progress-bar -C - -o "${out}.part" "$url"
  mv -f "${out}.part" "$out"
  [ -s "$out" ] || die "Downloaded ISO is empty."
  log "Saved: $out"
}

# ── Main ────────────────────────────────────────────────────────────────────
check_deps
[ -f "$POSTINST" ] || die "postinst not found at: $POSTINST"

submit_faime

# Decide what we have (ISO or STATUS or NONE)
kind_and_url="$(find_initial_links)"
kind="${kind_and_url%%|*}"
url="${kind_and_url##*|}"

ISO_URL=""
case "$kind" in
  ISO)    ISO_URL="$url" ;;
  STATUS) ISO_URL="$(poll_status_for_iso "$url" || true)" ;;
  NONE)   die "No ISO or status link found in submit_response.html" ;;
esac

[ -n "$ISO_URL" ] || die "Timed out waiting for ISO link."

STAMP="$(date +%Y%m%d_%H%M%S)"
ISO_OUT="${OUTPUT_DIR}/${ISO_NAME_PREFIX}_${STAMP}.iso"
download_iso "$ISO_URL" "$ISO_OUT"

log "FAI.me build complete."
echo "ISO: $ISO_OUT"
