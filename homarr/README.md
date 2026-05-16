# Homarr v1 Dashboard

Modern, widget-based home lab dashboard with native integrations for DNS blockers, media servers, system monitoring, and more.

## Port

`7575` (bridge network)

## Prerequisites

- Docker with Compose v2

## Setup

### 1. Configure environment

```bash
cp .env.dist .env
```

Generate the encryption key (do this **once**, never regenerate):

```bash
echo "SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> .env
```

> **Warning:** `SECRET_ENCRYPTION_KEY` encrypts all stored integration passwords in Homarr's SQLite DB. Back it up immediately. Losing it means reconfiguring all integrations from scratch.

### 2. Start Homarr

```bash
docker compose up -d
```

### 3. First-run wizard

Open `http://<host-ip>:7575` and create an admin account. This is the only step that cannot be automated.

### 4. Generate an API key

Go to **Management > Tools > API Keys** and create a key. Format: `<id>.<token>`. This key is used by the integration setup script.

### 5. Set up integrations

Export credentials as env vars and run the setup script:

```bash
# See script header for required env vars
./scripts/setup-integrations.sh
```

The script creates integrations via Homarr's tRPC API. See `scripts/setup-integrations.sh` for the full list of supported integrations and required credentials.

## Docker socket

The Docker socket is mounted read-only for container discovery. Only containers on the same host are visible.

## Update

```bash
docker compose pull && docker compose up -d
```

## confdir/ contents

Homarr stores all state under `/appdata` (mapped to `confdir/`):

| File | Purpose |
|------|---------|
| `db.sqlite` | All config, integrations, boards, widgets |
| `icons/` | Uploaded app icons |

## File overview

```
homarr/
├── docker-compose.yml
├── .env.dist              # Template -- copy to .env
├── .env                   # Host-specific config (gitignored)
├── README.md
├── scripts/
│   └── setup-integrations.sh  # Automated integration setup via tRPC API
└── confdir/               # Homarr appdata (gitignored)
    └── .gitkeep
```
