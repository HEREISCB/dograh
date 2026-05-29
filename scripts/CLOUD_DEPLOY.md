# Deploy dograh on a fresh Linux cloud VM (no Docker)

`scripts/cloud_bootstrap.sh` stands up the entire self-hosted dograh stack on a
brand-new Ubuntu 22.04/24.04 VM and makes a browser voice call work end-to-end —
without Docker. It automates the exact steps proven by hand: Postgres + pgvector,
Redis, MinIO, Python deps, DB migrations, `api/.env` (with generated secrets),
Caddy (auto-HTTPS), systemd services, and the firewall.

## Prerequisites

1. A fresh Ubuntu VM with a **public IP** (EC2, GCP, Hetzner, DigitalOcean, …).
2. A **domain name** pointed at that IP (an A record). Browsers only grant
   microphone access over valid HTTPS, and Caddy needs the domain to issue a
   cert. A subdomain like `agent.example.com` is fine.
3. **Cloudflare Realtime TURN** key (recommended): Cloudflare dashboard →
   Realtime → **TURN** → create a key → copy the *Turn Token ID* and *API Token*.
   On a public-IP VM direct WebRTC can work without it, but TURN makes
   connectivity reliable for users behind strict NATs/firewalls. (The repo's
   `api/routes/turn_credentials.py` is already patched to use the TCP/TLS relay,
   which traverses HTTPS-only egress.)

## Run it

As a normal sudo-capable user (not root), from the repo root:

```bash
git clone https://github.com/HEREISCB/dograh.git
cd dograh
DOMAIN=agent.example.com \
CLOUDFLARE_TURN_KEY_ID=xxxxxxxx \
CLOUDFLARE_TURN_API_TOKEN=yyyyyyyy \
bash scripts/cloud_bootstrap.sh
```

It's **idempotent** — re-run it any time. Secrets you don't pass (Redis/MinIO
passwords, `OSS_JWT_SECRET`) are generated and written into `api/.env`
(gitignored, unique to the box).

## After it finishes

1. Browse to `https://<DOMAIN>/auth/signup` and create an account.
2. In a workflow, add a **Local Models (Speaches)** TTS node pointing at one of
   the voicetts workers (e.g. `https://<tts-host>:8006/v1` for maya1, `:8007` for
   `orpheus_gguf`, `:8004` for the vLLM orpheus).
3. Start a call.

Verify services:

```bash
systemctl status dograh-backend dograh-ui caddy --no-pager | grep Active
curl -s localhost:8000/api/v1/health
```

## Why WebRTC "just works" here (unlike a Lightning Studio)

A normal VM has a public IP and real outbound networking, so the media path is
no longer fighting an HTTPS-only sandbox:

- The only inbound ports opened are **80/443** (Caddy/TLS + WSS signaling).
- WebRTC **media** is relayed by **Cloudflare TURN over TCP/443** (outbound),
  so you don't open any UDP range and don't depend on NAT behaviour.
- There's no IPv6-egress quirk to patch (that was specific to the Lightning
  sandbox).

## Services it installs (all systemd, reboot-safe)

| Service | What |
|---|---|
| `postgresql` | Postgres + pgvector, db `dograh` |
| `redis-server` | Redis with a generated password |
| `minio` | object storage on 127.0.0.1:9000, bucket `voice-audio` |
| `dograh-backend` | uvicorn `api.app:app` on 127.0.0.1:8000 |
| `dograh-arq` | background task worker |
| `dograh-ui` | Next.js UI on 127.0.0.1:3000 |
| `caddy` | TLS termination for `<DOMAIN>` → UI |

Telephony (`ari_manager`, `campaign_orchestrator`) is not enabled by default —
add those if you need inbound/outbound phone campaigns.

## Notes

- Python deps install into a `venv/` at the repo root, which
  `scripts/start_services_dev.sh` also auto-activates. (A venv is the right call
  on a dedicated VM — the earlier "no venv" guidance was specific to the
  single-environment Lightning Studio.)
- This script is a best-effort automation; validate on your target VM. If a step
  fails it stops with the error so you can see exactly where.
