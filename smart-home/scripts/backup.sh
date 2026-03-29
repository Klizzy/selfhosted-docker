#!/usr/bin/env bash
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/backup.log"
LOCK_FILE="/tmp/smart-home-backup.lock"
MAX_LOG_LINES=5000
KEEP_LOG_LINES=2000

# ── Parse flags ──────────────────────────────────────────────────────────────
MANUAL=false
if [[ "${1:-}" == "--manual" ]]; then
    MANUAL=true
fi

# ── Load .env ────────────────────────────────────────────────────────────────
ENV_FILE="${PROJECT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: ${ENV_FILE} not found" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

: "${BACKUP_DIR:?BACKUP_DIR not set in .env}"
: "${BACKUP_KEEP_COUNT:=8}"

# ── Logging ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

rotate_log() {
    if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > MAX_LOG_LINES )); then
        tail -n "$KEEP_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (kept last ${KEEP_LOG_LINES} lines)"
    fi
}

# ── NAS check ────────────────────────────────────────────────────────────────
check_nas() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log "ERROR: BACKUP_DIR does not exist: ${BACKUP_DIR}"
        exit 1
    fi
    if ! touch "${BACKUP_DIR}/.backup-write-test" 2>/dev/null; then
        log "ERROR: BACKUP_DIR is not writable: ${BACKUP_DIR}"
        exit 1
    fi
    rm -f "${BACKUP_DIR}/.backup-write-test"
}

# ── Cleanup trap — guarantees HA restart on failure ──────────────────────────
HA_STOPPED=false
cleanup() {
    if [[ "$HA_STOPPED" == "true" ]]; then
        log "SAFETY: Restarting homeassistant (cleanup trap)"
        cd "$PROJECT_DIR"
        docker compose start homeassistant 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Main ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
rotate_log

# Flock — prevent concurrent runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: backup already running"
    exit 0
fi

START_TIME=$(date +%s)
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

if [[ "$MANUAL" == "true" ]]; then
    BACKUP_NAME="smart-home-manual-${TIMESTAMP}.tar.gz"
else
    BACKUP_NAME="smart-home-backup-${TIMESTAMP}.tar.gz"
fi

BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

log "=== Backup started ($(if $MANUAL; then echo 'manual'; else echo 'auto'; fi)) ==="

# 1. Check NAS is reachable before touching containers
check_nas
log "NAS check passed: ${BACKUP_DIR}"

# 2. Stop Home Assistant for consistent SQLite backup
cd "$PROJECT_DIR"
log "Stopping homeassistant..."
docker compose stop --timeout 30 homeassistant
HA_STOPPED=true
log "homeassistant stopped"

# 3. Create tar.gz backup (relative paths from PROJECT_DIR)
log "Creating backup: ${BACKUP_NAME}"
sudo tar czf "$BACKUP_PATH" \
    --exclude='*.log' \
    --exclude='*.db-wal' \
    --exclude='*.db-shm' \
    --exclude='workdir' \
    --exclude='__pycache__' \
    --exclude='.mqtt_*_pass' \
    -C "$PROJECT_DIR" \
    zigbee2mqtt/confdir \
    homeassistant/confdir \
    mosquitto/confdir \
    .env \
    docker-compose.yml
sudo chown "$(id -u):$(id -g)" "$BACKUP_PATH"

# 4. Start Home Assistant immediately
log "Starting homeassistant..."
docker compose start homeassistant
HA_STOPPED=false
log "homeassistant started"

# 5. Validate backup
if ! tar tzf "$BACKUP_PATH" > /dev/null 2>&1; then
    log "ERROR: Backup archive is corrupt: ${BACKUP_PATH}"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
FILE_COUNT=$(tar tzf "$BACKUP_PATH" | wc -l)
log "Backup valid: ${FILE_COUNT} files, ${BACKUP_SIZE}"

# 6. Cleanup old auto-backups (skip for manual)
if [[ "$MANUAL" == "false" ]]; then
    # Only count auto-backups (not manual ones)
    mapfile -t OLD_BACKUPS < <(
        ls -1t "${BACKUP_DIR}"/smart-home-backup-*.tar.gz 2>/dev/null
    )
    if (( ${#OLD_BACKUPS[@]} > BACKUP_KEEP_COUNT )); then
        for (( i=BACKUP_KEEP_COUNT; i<${#OLD_BACKUPS[@]}; i++ )); do
            log "Removing old backup: $(basename "${OLD_BACKUPS[$i]}")"
            rm -f "${OLD_BACKUPS[$i]}"
        done
    fi
fi

# 7. Summary
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
REMAINING=$(find "$BACKUP_DIR" -maxdepth 1 -name 'smart-home-backup-*.tar.gz' 2>/dev/null | wc -l)
MANUAL_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name 'smart-home-manual-*.tar.gz' 2>/dev/null | wc -l)

log "Backup complete: ${BACKUP_NAME} (${BACKUP_SIZE}, ${DURATION}s)"
log "Backups on NAS: ${REMAINING} auto, ${MANUAL_COUNT} manual"
log "=== Backup finished ==="
