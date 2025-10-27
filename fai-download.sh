#!/usr/bin/env bash
# FAI.me downloader: wait for “has been finished” on the job page, then wget ISO with progress.
# Usage:
#   ./fai-download.sh https://fai-project.org/myimages/7JK2F5M6/
#   ./fai-download.sh 7JK2F5M6
#   ./fai-download.sh    # reads submit_response.html for "statuspage: ..."

set -euo pipefail

# ---- Settings ----
POLL_INTERVAL=30            # seconds between checks
POLL_TIMEOUT=5400           # total wait time (90 minutes)
OUT_DIR="."
OUT_NAME_PREFIX="fai_bookworm"  # output: ${OUT_DIR}/${OUT_NAME_PREFIX}_YYYYmmdd_HHMMSS.iso

# ---- Helpers ----
ts(){ date +'%F %T'; }
log(){ printf '\n[%s] %s\n' "$(ts)" "$*"; }
die(){ printf '\n[%s] ERROR: %s\n' "$(ts)" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
http_code(){ curl -fsSLI -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"; }
content_len(){
  curl -fsSI "$1" 2>/dev/null | awk 'tolower($1$2) ~ /^content-length:/ { sub(/\r$/,"",$2); print $2 }' | head -n1
}
countdown(){
  local n="$1"
  while [ "$n" -gt 0 ]; do
    printf "\rNext check in %2ds..." "$n"
    sleep 1
    n=$((n-1))
  done
  printf "\r%-40s\r" ""
}
status_from_submit(){
  [ -f submit_response.html ] || return 1
  # Prefer explicit "statuspage: URL"
  if grep -qE '^statuspage:\s*https?://' submit_response.html; then
    grep -E '^statuspage:\s*https?://' submit_response.html | head -n1 | sed -E 's/^statuspage:\s*//' | tr -d '\r\n'
  else
    # Fallback: first /myimages/<JOBID>/ in the file
    grep -Eo 'https?://[^"[:space:]]+/myimages/[A-Z0-9]+/?' submit_response.html | head n=1 | tr -d '\r\n'
  fi
}

# ---- Resolve input ----
STATUS_URL="${1:-}"
if [ -z "$STATUS_URL" ]; then
  STATUS_URL="$(status_from_submit || true)"
fi
if [ -z "$STATUS_URL" ] && [ $# -ge 1 ]; then
  STATUS_URL="$1"
fi
# If only a bare job id was provided
if [ -n "$STATUS_URL" ] && printf '%s\n' "$STATUS_URL" | grep -Eq '^[A-Z0-9]{8}$'; then
  STATUS_URL="https://fai-project.org/myimages/${STATUS_URL}/"
fi
[ -n "$STATUS_URL" ] || die "No status URL or JOBID provided (and submit_response.html not found)."

need curl; need wget; need grep; need sed

log "Polling FAI.me status page: $STATUS_URL"
elapsed=0
ISO_URL=""
TMP_PAGE="$(mktemp -t fai_status_XXXXXX.html)"
trap 'rm -f "$TMP_PAGE"' EXIT

# ---- Poll until page reports "has been finished" and ISO is live ----
while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
  if ! curl -fsSL "$STATUS_URL" -o "$TMP_PAGE" 2>/dev/null; then
    log "Failed to fetch status page; retrying…"
    countdown "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    continue
  fi

  if grep -q 'has been finished' "$TMP_PAGE"; then
    # Extract ISO link (first one on the page)
    ISO_URL="$(grep -Eo 'https?://[^"[:space:]]+\.iso' "$TMP_PAGE" | head -n1 | tr -d '\r\n')"
    if [ -n "$ISO_URL" ]; then
      code="$(http_code "$ISO_URL")"
      size="$(content_len "$ISO_URL")"
      if [ "$code" = "200" ] && [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
        log "Build finished and ISO is ready: $ISO_URL (size: ${size} bytes)"
        break
      else
        log "Done page found but ISO not ready yet (HTTP $code, Content-Length: ${size:-0})."
      fi
    else
      log "Done page found but ISO link not yet present."
    fi
  else
    log "Still building… (${elapsed}s elapsed)."  # in-progress page text looks like “is currently being processed” :contentReference[oaicite:1]{index=1}
  fi

  countdown "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

[ -n "$ISO_URL" ] || die "Timed out after $POLL_TIMEOUT seconds without a ready ISO."

# ---- Resumable download with wget and size verification ----
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT_DIR%/}/${OUT_NAME_PREFIX}_${STAMP}.iso"
TMP="${OUT}.part"

log "Downloading ISO → $OUT"
# Loop until we reach Content-Length (avoids 0-byte or partial files)
target="$(content_len "$ISO_URL")"
[ -n "$target" ] || die "Server did not provide Content-Length; refusing blind download."
while : ; do
  # -c resumes; bar:force draws progress even if not a TTY
  wget -c --progress=bar:force -O "$TMP" "$ISO_URL" || true
  have="$(wc -c < "$TMP" 2>/dev/null || echo 0)"
  if [ "$have" -ge "$target" ] 2>/dev/null; then
    break
  fi
  log "Downloaded $have / $target bytes; will retry in ${POLL_INTERVAL}s…"
  countdown "$POLL_INTERVAL"
done

# Finalize
mv -f "$TMP" "$OUT"
[ -s "$OUT" ] || die "Downloaded file is empty (unexpected)."
log "Done: $OUT"
