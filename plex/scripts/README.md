# Plex Scripts

## mount-checker.sh

Monitors the NFS media mount and automatically recovers from boot race conditions where the NUC starts before the NAS has its encrypted disks ready.

### What it does

1. Checks if `$MEDIA_PATH` is mounted (via `mountpoint -q`)
2. If mounted — exits silently (no log output)
3. If not mounted — attempts `sudo mount $MEDIA_PATH` (uses `/etc/fstab` options)
4. If mount succeeds — restarts the Plex Docker container
5. Logs only when action is taken

### Prerequisites

**Sudoers entry** — the script needs passwordless `sudo` for the `mount` command:

```bash
# Edit sudoers (use visudo for safety)
sudo visudo -f /etc/sudoers.d/mount-checker

# Add this line (replace <user> and <mount-path> with actual values):
<user> ALL=(ALL) NOPASSWD: /usr/bin/mount <mount-path>
```

**Environment** — `MEDIA_PATH` must be set in `plex/.env` (see `.env.dist`).

**fstab** — the mount point must have an entry in `/etc/fstab`. The script delegates all mount options to fstab.

### Setup

Add a cron entry (runs every 5 minutes):

```bash
crontab -e

# Add this line (replace <repo-path> with actual path):
*/5 * * * * <repo-path>/plex/scripts/mount-checker.sh
```

### Logs

- Location: `plex/scripts/logs/mount-checker.log`
- Rotation: auto-truncates to 2000 lines when exceeding 5000
- Only writes entries during mount recovery attempts

### Manual testing

```bash
# Dry run — check if the script detects the mount correctly:
mountpoint -q $MEDIA_PATH && echo "mounted" || echo "not mounted"

# Run the script manually:
./plex/scripts/mount-checker.sh

# Check the log:
cat plex/scripts/logs/mount-checker.log
```
