# HausKlar

HausKlar is a self-hosted, offline-first family organiser with native iOS and web clients.

> **Public-source note:** HausKlar was developed and used privately before being open-sourced. This repository is a sanitised public export. Its original Git history is intentionally omitted because that history contains household and infrastructure information; the first public commit is a source-release boundary, not the beginning of the project.

HausKlar is a personal open-source project, not a hosted SaaS service. It has not been independently security-audited. Medicine features provide reminders only, not medical advice. Finance features are informational and are not financial advice.

## Features

- Planning: shared calendar, tasks, reminders, routines, commitments, birthdays, and household briefings.
- Family life: children, meals, grocery lists, inventory, pets, homework, documents, and reviewed capture.
- Offline clients: durable browser and native iOS queues with deterministic conflict handling.
- Optional private modules: Home Assistant, inbound email, Fitness, Finance, notifications, and bounded assistant proposals.

## Architecture

```text
iOS app + extensions ─┐
                      ├── HTTPS/JSON ── FastAPI ── SQLite + private file store
React installable PWA ┘                     │
                                            └── optional, operator-configured providers
```

All examples use fictional data and localhost. Optional integrations are blank and inactive by default.

## Quick start: local Docker demo

Requirements: Docker, Docker Compose, OpenSSL, and Make.

```sh
make demo
```

The script generates a local random demo password, prints it once, and binds the service to `127.0.0.1:8001`. Reset the fictional data with `make reset-demo`.

## Development

Backend (Python 3.12):

```sh
cd server
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e '.[dev]'
APP_ENV=development JWT_SECRET_KEY=development-only-change-me python -m uvicorn app.main:app --reload --port 8001
```

PWA:

```sh
cd server/web
npm ci
npm run dev
```

iOS simulator:

```sh
cd ios/HausKlar
cp Config/Local.xcconfig.example Config/Local.xcconfig
xcodegen
open HausKlar.xcodeproj
```

Set `HAUSKLAR_API_BASE_URL` in the local xcconfig when the simulator cannot use the default localhost URL. No Apple signing team is checked in.

## Configuration and privacy

Copy `.env.example` for development. Production mode fails closed when required secrets or URLs are insecure. Integrations are opt-in; external AI is disabled by default. Model output cannot directly change family data: actions are typed, allowlisted, validated, expired, and explicitly confirmed. Arbitrary SQL, URLs, shell commands, and Home Assistant services are prohibited. Fitness and Finance data are owner-private unless the owner deliberately shares a bounded result.

See [deployment](docs/DEPLOYMENT.md), [optional integrations](docs/OPTIONAL_INTEGRATIONS.md), [privacy](PRIVACY.md), [security](SECURITY.md), and the [threat model](docs/THREAT_MODEL.md).

## AI-assisted development

HausKlar was developed with extensive AI-agent assistance. The repository includes tests, safety constraints, and agent instructions used to review and evolve the system; it does not claim that every line was manually authored.

## Contributing and licence

Contributions are welcome under [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Licensed under [Apache-2.0](LICENSE). Copyright 2026 Dominic Barker / [@DJBarker87](https://github.com/DJBarker87).
