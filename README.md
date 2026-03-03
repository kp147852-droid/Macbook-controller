# Macbook Controller

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/kp147852-droid/Macbook-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/kp147852-droid/Macbook-controller/actions/workflows/ci.yml)

Secure remote-control platform that lets an iPhone control a Mac over the internet using a hardened relay, native clients, and app-layer end-to-end encryption.

This project demonstrates practical engineering for roles in AI, data, and business-facing technical product work: requirements definition, threat modeling, system design, reliability, and documentation for adoption.

## Recruiter Snapshot
- Domain: remote systems, secure communications, cross-platform app development
- Business value: secure remote access workflow with production deployment path
- Engineering strengths shown: architecture, security hardening, mobile + desktop client integration, operational docs
- Collaboration maturity: onboarding docs, troubleshooting, CI, contribution and security policies

## Skills Demonstrated
- Product/System Design: distributed architecture, pairing workflow, secure session lifecycle
- Security Engineering: TLS/WSS, Curve25519 key exchange, HKDF, AES-GCM, replay defense, periodic rekeying
- Backend/API: FastAPI relay, WebSocket routing, rate limiting, origin controls
- Client Development: SwiftUI on iOS/macOS, WebSocket clients, UI trust gating, permission handling
- DevOps: Caddy reverse proxy, Docker Compose deployment, GitHub Actions CI
- Business Analyst Lens: clear user flows, risk controls, measurable acceptance criteria, stakeholder-ready docs

## Architecture
1. macOS app creates a short-lived pairing code from the relay API.
2. iOS and macOS apps connect via WSS to the relay.
3. Native clients establish E2E session keys via ephemeral Curve25519 handshake.
4. Fingerprints are compared and explicitly trusted before stream/control is enabled.
5. Encrypted frames/events flow through relay as ciphertext only.
6. Replay attempts are dropped using monotonic sequence checks.
7. Session keys automatically rotate every 5 minutes or 300 encrypted messages.

## What is in this repo
- `relay/` FastAPI relay server (pair code API + WebSocket bridge + hardening)
- `apps/macos/MacbookControllerMac` native macOS agent app
- `apps/ios/MacbookControlleriOS` native iPhone controller app
- `deploy/` HTTPS/WSS deployment files (Caddy + docker compose)
- `controller/` fallback web controller (non-native)
- `docs/` recruiter-facing summaries and supporting material

## Quick Start
### 1) Run relay (local)
```bash
cd relay
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Recommended local `.env` values:
```env
MAC_DEVICE_TOKEN=replace-with-long-random-token
PAIR_CODE_TTL_SECONDS=300
ALLOWED_ORIGINS=
REQUIRE_HTTPS=false
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_CREATE_CODE=15
RATE_LIMIT_CHECK_CODE=120
```

Start:
```bash
uvicorn relay_server:app --host 0.0.0.0 --port 8787
```

### 2) Run native apps
Open:
- `apps/MacbookController.xcodeproj`

If needed, regenerate from spec:
```bash
brew install xcodegen
cd apps
xcodegen generate
```

In Xcode:
1. Run `MacbookControllerMac` on Mac
2. Run `MacbookControlleriOS` on iPhone
3. Set Signing Team for both targets if prompted

### 3) Grant macOS permissions
- Screen Recording
- Accessibility

Then fully restart the macOS app.

### 4) Pair and trust
1. Start session on Mac app and note 6-digit code + fingerprint
2. Connect from iPhone app with the code
3. Compare fingerprints on both devices
4. Press **Trust** on both
5. Remote stream/control goes live

## Production Deployment (HTTPS/WSS)
Use `deploy/Caddyfile` and `deploy/docker-compose.yml`.

Set real domains in `deploy/Caddyfile` and set:
```env
REQUIRE_HTTPS=true
ALLOWED_ORIGINS=https://controller.yourdomain.com
```

Then:
```bash
cd deploy
docker compose up -d
```

## For Employers and Collaborators
- Project brief: [docs/PROJECT_BRIEF.md](docs/PROJECT_BRIEF.md)
- Portfolio bullets: [docs/PORTFOLIO_BULLETS.md](docs/PORTFOLIO_BULLETS.md)
- Native app details: [apps/README.md](apps/README.md)

## Troubleshooting
- No stream after connect: fingerprint trust not confirmed on one side
- No control input: macOS Accessibility permission missing
- Blank frames: macOS Screen Recording permission missing
- Remote connect failures: check DNS/TLS and ensure `wss://` is used
