# Optional integrations

All integrations are disabled by default and must fail closed when configuration is absent.

- Home Assistant: configure a server URL, encrypted token storage, safe entity mapping, and bounded action allowlist. Model-selected arbitrary services are prohibited.
- Inbound email: requires provider credentials, exact recipient lookup, active-family sender checks, signature verification, MIME/size limits, and deduplication.
- Assistants: configure a private or external adapter only after reviewing data flow. Responses are typed proposals requiring validation and confirmation.
- Fitness and health providers: adult-owned OAuth connections and webhooks are opt-in and owner-scoped.
- Finance providers: informational only; credentials remain server-side and records are adult-owner scoped.
- Notifications, weather, media, and calendar sources: supply operator-owned endpoints and credentials; no live endpoint is included in source.
