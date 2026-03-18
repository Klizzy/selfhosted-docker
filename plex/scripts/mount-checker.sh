#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mount-checker.log"
LOCK_FILE="/tmp/mount-checker.lock"
MAX_LOG_LINES=5000

# Load config from .env (MEDIA_PATH)
ENV_FILE="${PROJECT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: ${ENV_FILE} not found" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required vars
: "${MEDIA_PATH:?MEDIA_PATH not set in .env}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

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

#=== Main ===#
mkdir -p "$LOG_DIR"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

# If already mounted, exit silently (zero work on happy path)
if mountpoint -q "$MEDIA_PATH" 2>/dev/null; then
    exit 0
fi

# Mount is missing — rotate log before writing, then attempt recovery
rotate_log
log "MOUNT MISSING: $MEDIA_PATH not mounted, attempting mount..."

sudo mount "$MEDIA_PATH" || true

# Verify mount succeeded
if mountpoint -q "$MEDIA_PATH" 2>/dev/null; then
    log "MOUNT OK: $MEDIA_PATH mounted successfully"
    log "PLEX RESTART: restarting plex container..."
    if docker compose -f "$PROJECT_DIR/docker-compose.yml" restart 2>> "$LOG_FILE"; then
        log "PLEX RESTART: done"
    else
        log "PLEX RESTART: failed (exit $?)"
    fi
else
    log "MOUNT FAILED: $MEDIA_PATH still not mounted after mount attempt"
fi
