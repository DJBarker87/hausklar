# HausKlar agent instructions

HausKlar is a self-hosted family organiser whose planner is the centrepiece. Keep routine actions calm, contextual, and quick while preserving correctness, privacy, offline behaviour, and auditability. The native iOS and PWA clients should expose the same core workflows.

Use generic household roles and data-driven account priorities. Offline conflicts are deterministic; never branch on names, email addresses, or fixed deployment IDs. Generate UUID v4 identifiers client-side. Preserve record history before updates and use soft deletion.

Distinguish system timestamps from real-event timestamps. Medicine reminder checks use actual administration time, show warnings visibly, and never claim to provide medical advice.

Model output never mutates data directly. Validate typed proposals, allowlist actions, and require explicit confirmation. Never let a model choose SQL, URLs, shell commands, credentials, Home Assistant services, deletion, locks, alarms, or medicine actions. Adult Fitness and Finance information remains owner-scoped and opt-in.

Keep FastAPI routers thin and business logic in services. Keep browser and iOS integrations disabled unless explicitly configured. Never commit secrets, personal data, production endpoints, signing material, or local deployment state. Add and run proportionate backend, PWA, offline-sync, and iOS tests before considering work complete.

See `docs/ARCHITECTURE.md`, `docs/THREAT_MODEL.md`, and `CONTRIBUTING.md` for the public development contract.
