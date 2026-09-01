# Threat model

Protected assets include family and child records, health and medicine history, financial records, credentials, uploaded documents/media, audit history, and backups.

Key threats include account or session theft, cross-family/owner access, malicious uploads, integration compromise, local-network or Home Assistant control abuse, assistant prompt injection, unsafe proposals, stolen devices, exposed backups, and denial of service. Controls include tenancy checks, owner scoping, short access tokens and rotating refresh tokens, bounded uploads and parsers, server-side integration credentials, opt-in adapters, allowlisted confirmed assistant actions, offline cache ownership, soft deletes, and audit history.

Residual trust remains in the operator, host, reverse proxy, device OS, configured providers, dependency supply chain, and backup custody. Self-hosting does not itself provide compliance, certification, or independent assurance. Uploaded content and prompts remain hostile inputs; deployments should be monitored, patched, isolated, and restored in drills.
