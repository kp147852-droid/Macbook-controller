# Project Brief: Macbook Controller

## Problem
Professionals often need secure remote access to their Mac while away from their desk. Existing tools can be expensive, opaque, or over-permissioned for simple personal workflows.

## Solution
Macbook Controller implements a secure remote-control workflow:
- Short-lived pairing codes
- Hardened relay server over HTTPS/WSS
- Native iOS/macOS clients
- App-layer end-to-end encrypted payloads for frames and control events

## Why this project matters
This project demonstrates end-to-end ownership across product, engineering, and operations:
- Requirement definition and user flow design
- Threat model and security controls
- Production deployment strategy
- Clear user onboarding and troubleshooting docs

## Technical highlights
- FastAPI WebSocket relay
- Caddy reverse proxy + TLS
- iOS/macOS SwiftUI native clients
- Curve25519 key agreement + HKDF + AES-GCM
- Fingerprint verification workflow
- Replay protection and timed/message-count rekeying

## Potential business/analytics extensions
- Session quality metrics (latency, frame throughput)
- Reliability KPIs and error budgets
- Feature telemetry for product prioritization
- Cost modeling for hosted relay deployments
