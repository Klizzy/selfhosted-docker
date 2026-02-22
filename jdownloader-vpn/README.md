# JDownloader with NVMe Staging

Headless JDownloader2 with local NVMe staging — downloads and extracts on fast local storage, then automatically moves completed files to a NAS.

## How it works

```
Internet -> JDownloader (host network) -> NVMe write -> NVMe extract -> rsync to NAS (cron)
```

1. JDownloader downloads to a local `staging/` directory (NVMe SSD)
2. JD's **Event Scripter** creates `.ready_to_move` marker files when a download/extraction is complete
3. A **cron job** runs `jd-mover.sh` every minute, which rsyncs marked packages to the NAS and cleans up staging
4. Sample directories are automatically excluded and deleted

### Why not download directly to NAS?

Downloading and extracting over NFS to spinning HDDs caps out at ~50-60 MB/s. Using local NVMe for the write-heavy work and then moving the final files in one shot is significantly faster.

## Prerequisites

- Docker with Compose v2
- NAS mounted on the host (e.g. NFS mount)
- `rsync` installed on the host
- MyJDownloader account (for remote management)

## Setup

### 1. Configure environment

```bash
cp .env.dist .env
```

Edit `.env`:

```env
DOWNLOAD_VOLUME_PATH=./staging:/opt/JDownloader/Downloads
JDL_CONF_VOLUME_PATH=./confdir/jd/:/opt/JDownloader/cfg
VPN_CONF_VOLUME_PATH=./confdir/vpn:/vpn

# Mover script config
NAS_DIR=/path/to/your/nas/mount
COOLDOWN_SECONDS=120
MIN_FREE_GB=10
```

| Variable | Description |
|----------|-------------|
| `DOWNLOAD_VOLUME_PATH` | Maps local `staging/` to JD's download dir inside the container |
| `NAS_DIR` | Where completed files are moved to (must be a mounted filesystem) |
| `COOLDOWN_SECONDS` | Wait time after marker creation before moving (handles nested extractions) |
| `MIN_FREE_GB` | Logs a warning when free disk space drops below this threshold |

### 2. Start JDownloader

```bash
docker compose up -d jdownloader-vpn
```

On first start, configure your MyJDownloader credentials in the JD config or via the container logs.

### 3. Enable Event Scripter in MyJDownloader

This step **must be done manually** — the config files alone are not enough.

1. Open [my.jdownloader.org](https://my.jdownloader.org)
2. Go to **Einstellungen** (Settings) > **Extension Manager**
3. Click **Install** next to **Event Scripter**
4. JD will restart or reload the extension

After installation, the two scripts from `confdir/jd/...EventScripterExtension.scripts.json` are loaded automatically. On the first triggered event, MyJDownloader will show a **permission prompt** — click **Allow** to let Event Scripter access the filesystem.

You can verify the scripts are loaded under **Einstellungen > Event Scripter** — you should see:
- `NVMe staging: mark extracted archive for move` (trigger: ON_ARCHIVE_EXTRACTED)
- `NVMe staging: mark non-archive download for move` (trigger: ON_PACKAGE_FINISHED)

### 4. Set up the mover cron job

```bash
chmod +x scripts/jd-mover.sh
(crontab -l 2>/dev/null | grep -v jd-mover; echo "* * * * * $(pwd)/scripts/jd-mover.sh") | crontab -
```

This runs the mover every minute. `flock` prevents overlapping runs — if a transfer takes longer than 60s, the next invocation silently skips.

## Event Scripter scripts

Two scripts handle marker creation. The `confdir/jd/` directory is gitignored, so the full file contents are documented here. You need to create these files manually.

**Important:** JD's Event Scripter runs in a sandboxed Rhino JS engine. Direct Java class access (e.g. `java.io.File`) is blocked. Use JD's built-in functions like `writeFile()`, `deleteFile()`, `readFile()` instead.

### Extension config

**File:** `confdir/jd/org.jdownloader.extensions.eventscripter.EventScripterExtension.json`

```json
{"apipanelvisible":false,"freshinstall":false,"guienabled":false,"enabled":true}
```

### Scripts

**File:** `confdir/jd/org.jdownloader.extensions.eventscripter.EventScripterExtension.scripts.json`

```json
[
  {
    "eventTrigger": "ON_ARCHIVE_EXTRACTED",
    "enabled": true,
    "name": "NVMe staging: mark extracted archive for move",
    "script": "// see below",
    "eventTriggerSettings": {}
  },
  {
    "eventTrigger": "ON_PACKAGE_FINISHED",
    "enabled": true,
    "name": "NVMe staging: mark non-archive download for move",
    "script": "// see below",
    "eventTriggerSettings": {}
  }
]
```

#### ON_ARCHIVE_EXTRACTED

Triggered when JD finishes extracting an archive successfully. Deletes the source archive files (.rar, .zip, etc.) to free NVMe space, then creates a `.ready_to_move` marker in the extraction folder.

```javascript
// Delete archive source files to free NVMe space
var archiveFiles = archive.getArchiveFiles();
for (var i = 0; i < archiveFiles.length; i++) {
    deleteFile(archiveFiles[i].getFilePath(), false);
}

// Create .ready_to_move marker in extraction folder
var folder = archive.getFolder();
writeFile(folder + "/.ready_to_move", "", false);
log("Marker created: " + folder + "/.ready_to_move");
```

#### ON_PACKAGE_FINISHED

Triggered when all links in a download package are complete. Checks if the package contains archive files — if yes, skips (handled by the extraction script above). For non-archive downloads (direct .mkv, .mp4, etc.): creates a `.ready_to_move` marker.

```javascript
// Skip packages that contain archives (handled by ON_ARCHIVE_EXTRACTED)
var links = package.getDownloadLinks();
var archivePattern = /\.(rar|r\d{2,}|zip|7z|tar|gz|bz2|part\d+\.rar)$/i;
var hasArchive = false;
for (var i = 0; i < links.length; i++) {
    if (archivePattern.test(links[i].getName())) {
        hasArchive = true;
        break;
    }
}

if (!hasArchive) {
    var folder = package.getDownloadFolder();
    writeFile(folder + "/.ready_to_move", "", false);
    log("Marker created: " + folder + "/.ready_to_move");
}
```

### GeneralSettings overrides

**File:** `confdir/jd/org.jdownloader.settings.GeneralSettings.json`

The following settings should be changed from their defaults (the file contains many other settings — only modify these two):

| Key | Default | Set to | Purpose |
|-----|---------|--------|---------|
| `maxchunksperfile` | `1` | `8` | Parallel chunks per file — major speed boost with premium hosters |
| `forcedfreespaceondisk` | `128` | `2048` | JD pauses downloads if disk has < 2 GB free (protects root FS) |

## Mover script

`scripts/jd-mover.sh` is the host-side cron job that moves completed downloads to the NAS.

**What it does per run:**
1. Loads config from `.env`
2. Checks NAS is mounted and writable
3. Finds all `.ready_to_move` markers in `staging/`
4. Waits for the cooldown period (default 120s) to handle nested/multi-step extractions
5. Rsyncs the package directory to NAS, preserving the relative path structure
6. Deletes Sample directories (excluded from rsync)
7. Cleans up empty directories in staging

**Path preservation:**
```
JD saves to:       /opt/JDownloader/Downloads/Serien/ShowName/S01/
Host staging:      ./staging/Serien/ShowName/S01/
Mover copies to:   <NAS_DIR>/Serien/ShowName/S01/
```

**Logging:** `staging/logs/mover.log` (auto-rotated at 5000 lines)

## "Save to" paths in MyJDownloader

Container-internal paths remain unchanged. From MyJDownloader, you select paths like:
- `/opt/JDownloader/Downloads/Filme`
- `/opt/JDownloader/Downloads/Serien/ShowName`
- `/opt/JDownloader/Downloads/Software`

The staging volume mount transparently maps these to the local NVMe.

## VPN mode

The VPN service is included but disabled by default. To enable:

1. Place your OpenVPN config in `confdir/vpn/`
2. In `docker-compose.yml`, swap the network mode:
   ```yaml
   #  network_mode: host
     network_mode: "service:vpn"
   ```
3. Uncomment the `depends_on` block:
   ```yaml
     depends_on:
       - vpn
   ```
4. Restart: `docker compose up -d`

## Monitoring

```bash
# Watch mover log
tail -f staging/logs/mover.log

# Check staging contents
find staging/ -not -path "*/logs*" -ls

# Check cron is running
crontab -l | grep jd-mover

# JD container logs
docker compose logs -f jdownloader-vpn

# Event Scripter logs (inside container)
docker exec jdownloader-vpn cat /opt/JDownloader/logs/*/EventScripterExtension.log.0
```

## Error handling

| Scenario | Behavior |
|----------|----------|
| NAS unreachable | Mover logs error, files stay safe on NVMe, retried next minute |
| NVMe filling up | Warning logged at < `MIN_FREE_GB`; JD pauses at < 2 GB |
| JD crashes mid-extraction | No marker created, files stay on NVMe, JD resumes on restart |
| Mover overlaps | `flock` prevents concurrent runs |
| rsync fails mid-transfer | Only successfully transferred files are removed from source |

## File overview

```
jdownloader-vpn/
├── docker-compose.yml
├── .env.dist                          # Template — copy to .env
├── .env                               # Host-specific config (gitignored)
├── .gitignore
├── README.md
├── confdir/                           # contents gitignored — base conf files will be generated on jd start, see sections above
│   ├── jd/                            # JD config (mounted as /opt/JDownloader/cfg)
│   │   ├── org.jdownloader.settings.GeneralSettings.json
│   │   ├── org.jdownloader.extensions.eventscripter.EventScripterExtension.json
│   │   ├── org.jdownloader.extensions.eventscripter.EventScripterExtension.scripts.json
│   │   └── ...
│   └── vpn/                           # OpenVPN config (if using VPN mode)
├── scripts/
│   └── jd-mover.sh                    # Cron job: staging -> NAS
└── staging/                           # Local NVMe download dir (contents gitignored)
    ├── .gitkeep
    └── logs/
        ├── .gitkeep
        └── mover.log                  # gitignored
```
