# Glances System Monitoring

Lightweight system monitoring with REST API, consumed by Homarr's native System Health and System Resources widgets.

## Port

`61208` (host network)

## Deployment

Same compose file can be deployed on multiple hosts (multi-arch image supports x86_64 and ARM64). Each host gets its own standalone `glances/` directory.

## Setup

```bash
docker compose up -d
```

No `.env` or configuration needed -- runs with sensible defaults.

## Key options

| Option | Purpose |
|--------|---------|
| `pid: host` | Sees real host CPU/memory, not just container namespace |
| `network_mode: host` | Full visibility into network interfaces |
| `--disable-process` | Skips per-process tracking, reduces CPU usage on headless servers |
| `-w` | Starts the web server / REST API on port 61208 |
| `128M memory limit` | Glances Alpine is ~80MB; cap prevents creep |

## Verification

```bash
# Status check
curl -s http://localhost:61208/api/4/status

# Quick system overview
curl -s http://localhost:61208/api/4/quicklook | python3 -m json.tool
```

## Update

```bash
docker compose pull && docker compose up -d
```
