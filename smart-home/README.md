# Smart Home — Home Assistant + Zigbee2MQTT

Centralized smart home control via Home Assistant with Zigbee device management through Zigbee2MQTT and an MQTT broker. Apple HomeKit integration via HA's HomeKit Bridge for Siri/Home app access through an Apple TV 4K Home Hub.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Raspberry Pi 4 (rp4)                                    │
│                                                          │
│  ┌─────────────┐  MQTT   ┌───────────────┐              │
│  │ Zigbee2MQTT │────────▶│   Mosquitto   │              │
│  │  port 8080  │         │  port 1883    │              │
│  └──────┬──────┘         └───────┬───────┘              │
│         │ USB                    │ MQTT                   │
│  ┌──────┴──────┐         ┌──────┴────────┐              │
│  │Sonoff Dongle│         │Home Assistant │              │
│  │   Max       │         │  port 8123    │              │
│  │(USB 2.0 +   │         │ network: host │              │
│  │ ext. cable) │         └───────────────┘              │
│  └─────────────┘                                         │
└──────────────────────────────────────────────────────────┘
```


| Component      | Image                                          | Network  | Port            | Role                              |
| -------------- | ---------------------------------------------- | -------- | --------------- | --------------------------------- |
| Network Check  | `alpine:3`                                     | **host** | —               | Boot-time network readiness gate  |
| Mosquitto      | `eclipse-mosquitto:2`                          | bridge   | 1883            | MQTT message broker               |
| Zigbee2MQTT    | `koenkk/zigbee2mqtt:latest`                    | bridge   | 8080 (frontend) | Zigbee coordinator to MQTT bridge |
| Home Assistant | `ghcr.io/home-assistant/home-assistant:stable` | **host** | 8123            | Smart home hub, HomeKit bridge    |

**Why host networking for HA:** HomeKit relies on mDNS (Bonjour) multicast which doesn't work through Docker's bridge NAT.

**Why privileged for HA:** Needed for Bluetooth, USB device access, and some integrations. Can be tightened later.

### Boot resilience

After a power outage, the Pi may boot before the router is ready. The `network-check` sidecar pings the gateway (`GATEWAY_IP` from `.env`) until it responds. Home Assistant's `depends_on` blocks startup until this check passes, ensuring the HomeKit bridge (which relies on mDNS multicast) initializes on a working network. All services also have healthchecks for proper startup ordering and `docker compose ps` visibility.

## Prerequisites

- Raspberry Pi 4 with Raspberry Pi OS Lite (64-bit, Bookworm)
- Docker with Compose v2
- Sonoff Zigbee 3.0 USB Dongle Max (EFR32MG24)
- USB 2.0 extension cable (1-2m) — Pi4's USB 3.0 generates 2.4 GHz RF interference that degrades Zigbee
- User in `dialout` group (`sudo usermod -a -G dialout $USER`)

## Setup

### 1. Configure environment

```bash
cp .env.dist .env
```

Edit `.env`:

```env
PUID=1000
PGID=1000
ZIGBEE_DEVICE=/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_...-if00-port0
GATEWAY_IP=192.168.68.1
```

- Find the device path with `ls -la /dev/serial/by-id/`. Always use `/dev/serial/by-id/` paths — never `/dev/ttyACM0` as that can change between reboots.
- Set `GATEWAY_IP` to your router/gateway IP. Used by the `network-check` container to verify network reachability on boot.

### 2. Start Mosquitto and create MQTT users

```bash
docker compose up -d mosquitto

# Create user for Home Assistant (-c creates the password file)
docker exec -it mosquitto mosquitto_passwd -c /mosquitto/config/password_file homeassistant

# Create user for Zigbee2MQTT (no -c — appends to existing file)
docker exec -it mosquitto mosquitto_passwd /mosquitto/config/password_file zigbee2mqtt

docker compose restart mosquitto
```

Save both passwords — needed for Z2M config and HA MQTT integration.

### 3. Configure Zigbee2MQTT

Create `zigbee2mqtt/confdir/configuration.yaml` and `zigbee2mqtt/confdir/secret.yaml` (see confdir contents below), then:

```bash
docker compose up -d zigbee2mqtt
docker compose logs -f zigbee2mqtt
# Watch for: "Zigbee2MQTT started!", "MQTT connected"
```

Verify frontend at `http://<pi-ip>:8080`.

### 4. Start Home Assistant

```bash
docker compose up -d homeassistant
# Wait ~2 minutes for first boot
docker compose logs -f homeassistant
# Watch for: "Home Assistant initialized"
```

Open `http://<pi-ip>:8123` for onboarding (create admin account, set location/timezone).

### 5. Wire MQTT integration in HA

1. Settings > Devices & Services > Add Integration > **MQTT**
2. Broker: `127.0.0.1` (HA on host network reaches Mosquitto's published port)
3. Port: `1883`
4. Username: `homeassistant`
5. Password: (from step 2)
6. Z2M devices auto-appear via MQTT discovery

### 6. HomeKit Bridge setup

1. Settings > Devices & Services > Add Integration > **HomeKit Bridge** (not "HomeKit Controller")
2. HA shows a QR code — scan with iPhone Apple Home app
3. Apple TV 4K handles remote access and automation relay
4. Configure exposed entities: Settings > Devices & Services > HomeKit Bridge > Configure
   - Expose: lights, switches, covers, climate, temp/humidity sensors
   - Skip: automations, binary sensors (too noisy)

### 7. Pair first Zigbee device

1. Z2M frontend > "Permit join (All)"
2. Put device in pairing mode (varies by manufacturer)
3. Z2M shows "Interview completed"
4. Device auto-appears in HA and HomeKit

**Mesh tip:** Pair mains-powered devices first (bulbs, plugs) — they act as Zigbee routers. Then add battery devices.

## Confdir contents

The `confdir/` directories are gitignored. All config files that need to be created on the Pi4 are documented here.

### Mosquitto

**File:** `mosquitto/confdir/mosquitto.conf`

```
persistence true
persistence_location /mosquitto/data/

log_dest stdout
log_type warning
log_type error
log_type notice

listener 1883
allow_anonymous false
password_file /mosquitto/config/password_file
```

**File:** `mosquitto/confdir/password_file` — generated by `mosquitto_passwd` (step 2 above)

### Zigbee2MQTT

**File:** `zigbee2mqtt/confdir/configuration.yaml`

```yaml
homeassistant: true

mqtt:
    base_topic: zigbee2mqtt
    server: mqtt://mosquitto:1883
    user: zigbee2mqtt
    password: '!secret mqtt_password'

serial:
    port: /dev/ttyACM0
    adapter: ember
    baudrate: 115200

frontend:
    port: 8080

advanced:
    homeassistant_legacy_entity_attributes: false
    legacy_api: false
    legacy_availability_payload: false
    log_level: info
    channel: 15

availability: true

ota:
    update_available_for_new_devices: true
```

Key points:

- `adapter: ember` is **required** for Sonoff Dongle Max (EFR32MG24). The old `ezsp` driver is deprecated.
- MQTT server uses Docker service name `mosquitto` (bridge network)
- Channel 15 avoids most Wi-Fi interference (alternatives: 20, 25)
- `network_key` is auto-generated on first start — **back it up immediately**

**File:** `zigbee2mqtt/confdir/stack_config.json`

```json
{
  "MULTICAST_TABLE_SIZE": 32
}
```

Overrides the Ember coordinator's default multicast table limit (~16 slots). Without this, groups beyond the limit fall back from Zigbee multicast (single broadcast, all devices react simultaneously) to unicast (sequential per-device commands). Symptoms: `Failed to register group in multicast table with status=INVALID_STATE` errors in Z2M logs. Groups still work via unicast fallback, but multicast is faster. Set to 32 — safe for the EFR32MG24's 256KB RAM. Increase to 64 only if you exceed 30+ groups.

**File:** `zigbee2mqtt/confdir/secret.yaml`

```yaml
mqtt_password: '<the-z2m-mqtt-password-from-step-2>'
```

### Home Assistant

**File:** `homeassistant/confdir/configuration.yaml` — auto-generated on first start. Add recorder optimization for SD card setups:

```yaml
recorder:
    purge_keep_days: 5
    commit_interval: 10
    exclude:
        domains:
            - automation
            - updater
        entity_globs:
            - sensor.last_boot
            - sensor.date*
```

## Verification

```bash
# Mosquitto running
docker compose ps mosquitto

# MQTT connectivity (install mosquitto-clients first)
mosquitto_pub -h 127.0.0.1 -u homeassistant -P '<pw>' -t 'test' -m 'hello'
mosquitto_sub -h 127.0.0.1 -u homeassistant -P '<pw>' -t 'test' -C 1

# Z2M started and connected
docker compose logs zigbee2mqtt | grep -E "started|MQTT|firmware"
curl -sI http://127.0.0.1:8080

# HA initialized
docker compose logs homeassistant | grep "initialized"
curl -sI http://127.0.0.1:8123

# HomeKit bridge visible on network
sudo apt install -y avahi-utils
avahi-browse -a | grep -i homekit
```

## Backup


| Path                     | Contents                                      | Priority          |
| ------------------------ | --------------------------------------------- | ----------------- |
| `zigbee2mqtt/confdir/`   | Z2M config +**network key** + device database | **CRITICAL**      |
| `homeassistant/confdir/` | HA config, automations, scenes, recorder DB   | HIGH              |
| `mosquitto/confdir/`     | MQTT credentials (`password_file`)            | MEDIUM            |
| `.env`                   | Environment variables                         | LOW (recreatable) |
| `docker-compose.yml`     | Service definitions                           | LOW (in git)      |

**The Z2M network key is the most important backup.** Losing it means re-pairing every Zigbee device.

### Automated backup (`scripts/backup.sh`)

Runs weekly via cron (Sunday 4 AM). Creates timestamped tar.gz snapshots on the NAS.

**How it works:**

1. Checks NAS mount is writable (fails early if unreachable)
2. Stops Home Assistant (~10-15s) for consistent SQLite checkpoint
3. Creates `smart-home-backup-YYYYMMDD-HHMMSS.tar.gz` on NAS
4. Restarts Home Assistant (also guaranteed by EXIT trap on failure)
5. Validates the archive and cleans up old backups

**Excluded from backup:** `*.log`, `*.db-wal`, `*.db-shm`, `workdir/`, `__pycache__/`, `.mqtt_*_pass`

```bash
# Manual backup (before upgrades, experiments, etc.)
./scripts/backup.sh --manual

# Check backup log
cat scripts/logs/backup.log

# List backups
ls -lh $BACKUP_DIR/
```

**Config** (in `.env`):

- `BACKUP_DIR` — destination directory for backup archives
- `BACKUP_KEEP_COUNT` — auto-backups to retain (default: 8, ~2 months)

Manual backups (`--manual`) are never auto-deleted.

**Cron** (example):

```
0 4 * * 0 <project-dir>/scripts/backup.sh
```

### Restore procedure

```bash
cd ~/projects/selfhosted-docker/smart-home
docker compose down

# Rename current (broken) config directories
mv homeassistant/confdir homeassistant/confdir.broken
mv zigbee2mqtt/confdir zigbee2mqtt/confdir.broken
mv mosquitto/confdir mosquitto/confdir.broken

# Extract chosen backup
tar xzf $BACKUP_DIR/smart-home-backup-YYYYMMDD-HHMMSS.tar.gz

docker compose up -d

# Verify: HA :8123, Z2M :8080, devices reporting
```

## Updating

```bash
docker compose pull && docker compose up -d
```

Always check Z2M and HA release notes before major version updates.

## File overview

```
smart-home/
├── docker-compose.yml
├── .env.dist                     # Template — copy to .env
├── .env                          # Pi4-specific config (gitignored)
├── README.md
├── scripts/
│   ├── backup.sh                 # Automated backup to NAS (cron + manual)
│   └── logs/                     # gitignored — backup log output
│       └── .gitkeep
├── mosquitto/
│   ├── confdir/                  # gitignored — see "Confdir contents" above
│   │   ├── .gitkeep
│   │   ├── mosquitto.conf
│   │   └── password_file         # generated by mosquitto_passwd
│   └── workdir/                  # gitignored — Mosquitto persistence data
│       └── .gitkeep
├── zigbee2mqtt/
│   ├── confdir/                  # gitignored — see "Confdir contents" above
│   │   ├── .gitkeep
│   │   ├── configuration.yaml
│   │   └── secret.yaml
│   └── workdir/                  # gitignored — unused (Z2M data in confdir)
│       └── .gitkeep
└── homeassistant/
    ├── confdir/                  # gitignored — HA config dir
    │   └── .gitkeep
    └── workdir/                  # gitignored — unused
        └── .gitkeep
```
