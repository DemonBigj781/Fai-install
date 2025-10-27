#!/usr/bin/env bash
# DemonBigj781 (2025). FAI.me submit + poll (countdown) + verified wget download.
# https://fai-project.org/FAIme/ — Version: v3.2

set -euo pipefail
current_directory="$(pwd)"

# ── USER CONFIG ──────────────────────────────────────────────────────────────
POSTINST="${current_directory}/postinst.sh"
[ -f "$POSTINST" ] || POSTINST="${current_directory}/postinit.sh"  # legacy fallback

SUITE="bookworm"
PARTITION="ONE"
DESKTOP=""                       # leave empty for headless image
USERNAME="debian"
USERPW="debian"
ROOTPW="root"
EMAIL=""                         # optional

# Wi-Fi tools + firmware only; GPU handled later by your hosted install.sh
ADD_PKGS="wpasupplicant wireless-tools iw ifupdown isc-dhcp-client ca-certificates curl wget rfkill \
firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-realtek"

FAIME_URL="https://fai-project.org/cgi/faime.cgi"
OUTPUT_DIR="$PWD"
ISO_NAME_PREFIX="fai_custom_${SUITE}"
POLL_INTERVAL=30                 # seconds between checks
POLL_TIMEOUT=5400                # 90 minutes

# First-boot classes
CL_BACKPORTS=1
CL_SSH_SERVER=1
CL_STANDARD=1
CL_NONFREE=1
CL_RECOMMENDS=1
END_ACTION="REBOOT"
RUN_POSTINST_ON_FIRSTBOOT=1

# ── HELPERS ─────────────────────────────────────────────────────────────────
ts(){ date +'%F %T'; }
log(){ printf '\n[%s] %s\n' "$(ts)" "$*"; }
die(){ printf '\n[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
check_deps(){ need curl; need grep; need sed; need awk; need wget; }
http_code(){ curl -fsSLI -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"; }
content_len(){ curl -fsSI "$1" 2>/dev/null | awk 'tolower($1$2)~/^content-length:/ {print $2;exit}' | tr -d '\r'; }
countdown(){ n=$1; while [ "$n" -gt 0 ]; do printf "\rNext check in %2ds..." "$n"; sleep 1; n=$((n-1)); done; printf "\r%-40s\r" ""; }

# Robust: return 0 only when server serves at least byte 0 OR reports a non-zero Content-Length
ready_iso(){
  local url="$1"
  if curl -fsS -r 0-0 -D - -o /dev/null "$url" 2>/dev/null | grep -qE '^HTTP/[^ ]+ (200|206) '; then
    return 0
  fi
  local len; len="$(content_len "$url")"
  [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null
}

# ── SUBMIT FAI JOB ──────────────────────────────────────────────────────────
submit_faime(){
  local cl1 cl5 cl6 cl7 cl9 rclocal
  [ "$CL_BACKPORTS"  -eq 1 ] && cl1='-F cl1=BACKPORTS'  || cl1=""
  [ "$CL_SSH_SERVER" -eq 1 ] && cl5='-F cl5=SSH_SERVER' || cl5=""
  [ "$CL_STANDARD"   -eq 1 ] && cl6='-F cl6=STANDARD'   || cl6=""
  [ "$CL_NONFREE"    -eq 1 ] && cl7='-F cl7=NONFREE'    || cl7=""
  [ "$CL_RECOMMENDS" -eq 1 ] && cl9='-F cl9=RECOMMENDS' || cl9=""
  [ "$RUN_POSTINST_ON_FIRSTBOOT" -eq 1 ] && rclocal='-F rclocal=1' || rclocal=""

  log "Checking FAI.me availability…"
  case "$(http_code "$FAIME_URL")" in 200|301|302) ;; *) die "FAI.me not reachable";; esac

  log "Submitting build to FAI.me (upload with progress)…"
  curl -fL --progress-bar -X POST "$FAIME_URL" \
    -F type=install \
    -F "username=${USERNAME}" \
    -F "userpw=${USERPW}" \
    -F "rootpw=${ROOTPW}" \
    -F "suite=${SUITE}" \
    -F "partition=${PARTITION}" \
    -F "desktop=${DESKTOP}" \
    -F "keyboard=us" \
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

# ── EXTRACT LINKS FROM FIRST REPLY ──────────────────────────────────────────
parse_links(){
  # First reply contains a statuspage and sometimes a future imageurl (may 404 if you hit it too early).
  local iso status
  iso="$(grep -Eo 'https?://[^"<>[:space:]]+\.iso' submit_response.html | head -n1 || true)"
  status="$(grep -Eo 'https?://[^"<>[:space:]]+/myimages/[A-Z0-9]+/?' submit_response.html | head -n1 || true)"
  printf '%s|%s\n' "${iso:-}" "${status:-}"
}

# ── POLL STATUS PAGE UNTIL IT SAYS “has been finished” AND ISO IS READY ─────
poll_status_page(){
  local status_url="$1" elapsed=0 iso_url="" len=""
  log "Polling job page: $status_url"
  while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    local pagefile; pagefile="$(mktemp)"
    if ! curl -fsSL "$status_url" -o "$pagefile" 2>/dev/null; then
      log "Failed to fetch status page; retrying…"
      rm -f "$pagefile"; countdown "$POLL_INTERVAL"; elapsed=$((elapsed + POLL_INTERVAL)); continue
    fi

    if grep -q 'has been finished' "$pagefile"; then
      iso_url="$(grep -Eo 'https?://[^"<>[:space:]]+\.iso' "$pagefile" | head -n1 || true)"
      rm -f "$pagefile"
      if [ -n "$iso_url" ] && ready_iso "$iso_url"; then
        echo "$iso_url"; return 0
      fi
      log "Done page detected; ISO not readable yet. Waiting…"
    else
      log "Still building… (${elapsed}s elapsed)."
      rm -f "$pagefile"
    fi

    countdown "$POLL_INTERVAL"
    elapsed=$((elapsed + $POLL_INTERVAL))
  done
  return 1
}
# ── MAIN ────────────────────────────────────────────────────────────────────
check_deps
[ -f "$POSTINST" ] || die "postinst not found at: $POSTINST"

submit_faime

read -r ISO_CAND STATUS_URL <<<"$(parse_links | awk -F'|' '{print $1, $2}')"

# Even if ISO URL was in the first reply, only accept it if it is actually readable.
if [ -n "$ISO_CAND" ] && ready_iso "$ISO_CAND"; then
  ISO_URL="$ISO_CAND"
else
  ISO_URL="$(poll_status_page "$STATUS_URL" || true)"
fi

[ -n "${ISO_URL:-}" ] || die "Timed out waiting for ISO to become available."



# Hand off to downloader once ISO is confirmed available

if [ -x "${current_directory}/fai-download.sh" ]; then

  log "ISO ready. Launching fai-download.sh for full download process..."

  exec "${current_directory}/fai-download.sh" "$STATUS_URL"

else

  log "ISO ready but fai-download.sh not found or not executable."

  echo "Download manually from: $ISO_URL"

fi
