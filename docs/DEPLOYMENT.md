# Deployment

The Docker demo is intentionally localhost-only. For production, supply a strong random JWT secret, durable private volumes, HTTPS through a trusted reverse proxy, restrictive file permissions, patched container/host software, and encrypted tested backups. Do not reuse demo credentials or expose demo mode publicly.

Set all hostnames, callback URLs, storage paths, and integration credentials in deployment configuration. Production startup validation must pass before the service is exposed. This repository includes no SSH target, production domain, deployment account, or deployment workflow.
