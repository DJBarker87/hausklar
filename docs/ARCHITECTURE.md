# Architecture

HausKlar uses a FastAPI application for JSON APIs and static PWA delivery, SQLite in WAL mode, and a private file store for documents/media. React/TypeScript and SwiftUI clients share the same domain workflows. Both clients support durable offline operations; server-side conflict resolution uses account priority and client timestamps, while history is retained before mutation.

Authentication uses short-lived JWT access tokens and rotating refresh tokens. Browsers use HttpOnly cookies; iOS uses Keychain. Sensitive modules apply family tenancy plus adult-owner boundaries. Optional integrations terminate at server-side adapters and are disabled when incomplete.

Assistant integrations receive bounded snapshots, return typed proposals, and never execute arbitrary tools. HausKlar validates and stores expiring proposals and requires a separate confirmation request for each mutation.
