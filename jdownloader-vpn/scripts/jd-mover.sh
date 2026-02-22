#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="${PROJECT_DIR}/staging"
LOG_DIR="${STAGING_DIR}/logs"
LOG_FILE="${LOG_DIR}/mover.log"
LOCK_FILE="/tmp/jd-mover.lock"
MAX_LOG_LINES=5000

# Load config from .env (NAS_DIR, COOLDOWN_SECONDS, MIN_FREE_GB)
ENV_FILE="${PROJECT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: ${ENV_FILE} not found" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required vars
: "${NAS_DIR:?NAS_DIR not set in .env}"
: "${COOLDOWN_SECONDS:=120}"
: "${MIN_FREE_GB:=10}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

check_nas() {
    if ! mountpoint -q "$NAS_DIR" 2>/dev/null; then
        log "ERROR: NAS not mounted at $NAS_DIR"
        return 1
    fi
    if ! touch "$NAS_DIR/.mover_health" 2>/dev/null; then
        log "ERROR: NAS not writable"
        return 1
    fi
    rm -f "$NAS_DIR/.mover_health"
}

check_disk() {
    local free_gb
    free_gb=$(df --output=avail "$STAGING_DIR" | tail -1 | awk '{print int($1/1048576)}')
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        log "WARNING: NVMe free space ${free_gb}GB (threshold: ${MIN_FREE_GB}GB)"
    fi
}

rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local lines
    lines=$(wc -l < "$LOG_FILE")
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (was $lines lines)"
    fi
}

move_package() {
    local marker="$1"
    local pkg_dir
    pkg_dir=$(dirname "$marker")

    local age=$(( $(date +%s) - $(stat -c %Y "$marker") ))
    if [ "$age" -lt "$COOLDOWN_SECONDS" ]; then
        log "SKIP: ${pkg_dir##*/} — marker ${age}s old (need ${COOLDOWN_SECONDS}s)"
        return 0
    fi

    # Preserve dir structure: staging/Filme/MovieName -> NAS_DIR/Filme/MovieName
    local rel="${pkg_dir#${STAGING_DIR}/}"
    local target="${NAS_DIR}/${rel}"

    log "MOVING: ${rel} -> ${target}"
    mkdir -p "$target"

    if rsync -ah --remove-source-files \
        --exclude=".ready_to_move" \
        --exclude="Sample/" --exclude="sample/" \
        --exclude="Samples/" --exclude="samples/" \
        "$pkg_dir/" "$target/" 2>> "$LOG_FILE"; then
        log "OK: ${rel}"
        rm -f "$marker"
        # Delete excluded sample dirs that rsync skipped (recursive search)
        while IFS= read -r -d '' d; do
            rm -rf "$d" && log "DELETED sample dir: ${d#${pkg_dir}/}"
        done < <(find "$pkg_dir" -type d \( -iname "sample" -o -iname "samples" \) -print0 2>/dev/null)
        find "$pkg_dir" -type d -empty -delete 2>/dev/null || true
    else
        log "FAIL: rsync error for ${rel}"
    fi
}

#=== Main ===#
mkdir -p "$LOG_DIR"
rotate_log
log "--- run started ---"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: already running"
    exit 0
fi

check_disk
check_nas || exit 1

count=0
while IFS= read -r -d '' marker; do
    move_package "$marker"
    ((count++))
done < <(find "$STAGING_DIR" -name ".ready_to_move" -print0 2>/dev/null)

[ "$count" -eq 0 ] && log "Nothing to move"

find "$STAGING_DIR" -mindepth 1 -not -path "${LOG_DIR}" -not -path "${LOG_DIR}/*" -type d -empty -delete 2>/dev/null || true

log "--- run finished ---"
