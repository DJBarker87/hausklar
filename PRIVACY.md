# Privacy

HausKlar is self-hosted. The project itself operates no analytics service and receives no household data from installations.

The server stores account, household, calendar, task, document, health, fitness, and finance records selected by its operator. Uploaded files remain in the configured private file store. Operators control retention, backups, users, and network exposure.

Optional providers receive data only when configured and used: email delivery/inbound email, push notifications, weather, fitness providers, banking providers, media services, and Home Assistant each have their own privacy terms. Optional AI services may receive a bounded family-data snapshot only after an authenticated user explicitly sends a request. AI is disabled by default, proposed mutations require confirmation, and chat is not persisted by default. Fitness conversation memory is owner-scoped and separately opt-in.

On supported iOS devices OCR and speech recognition are local by default where documented. Raw dictation audio is not sent to the HausKlar API. Browser speech recognition is provided by the browser/platform and may have different privacy behaviour.
