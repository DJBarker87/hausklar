from contextlib import asynccontextmanager
from pathlib import Path
import asyncio
import math
from typing import Any

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.background import BackgroundTask, BackgroundTasks

from app.auth import get_current_user
from app.config import settings, validate_security_configuration
from app.database import close_db_pool, init_db
from app.http_clients import close_http_clients
from app.middleware.request_security import RequestSecurityMiddleware
from app.middleware.idempotency import IdempotencyMiddleware
from app.routers import (
    artworks,
    adoption,
    assistant,
    auth,
    babysitter,
    birthdays,
    briefing,
    calendar,
    calendar_sync,
    capture,
    child_photos,
    children,
    commitments,
    coordination,
    cycles,
    dog,
    documents,
    facilities,
    finance,
    finance_account_settings,
    finance_capture,
    finance_coaching,
    finance_connections,
    finance_data_control,
    finance_import,
    finance_products_assets,
    finance_sharing,
    finance_understanding,
    fitness_core,
    fitness_analysis,
    fitness_coach,
    fitness_cycles,
    fitness_export,
    fitness_intervals,
    fitness_activity,
    fitness_maps,
    fitness_nutrition,
    fitness_plans,
    fitness_recovery,
    fitness_strength,
    fitness_strava,
    fitness_sync,
    fitness_withings,
    inbound_email,
    family,
    grocery,
    growth,
    health,
    health_dashboard,
    health_record,
    home,
    homework,
    illness,
    insights,
    library,
    meals,
    medicine,
    naps,
    photos,
    presents,
    prep_packs,
    renewals,
    routines,
    school_clubs,
    search,
    reminders,
    star_charts,
    sync,
    tasks,
    toast_club,
    yearbook,
)
from app.scheduler import start_scheduler, stop_scheduler
from app.services.documents import harden_document_store_permissions


@asynccontextmanager
async def lifespan(app: FastAPI):
    validate_security_configuration()
    await init_db()
    await asyncio.to_thread(harden_document_store_permissions)
    if settings.scheduler_enabled:
        start_scheduler()
    try:
        yield
    finally:
        if settings.scheduler_enabled:
            stop_scheduler()
        await close_http_clients()
        await close_db_pool()


_docs_kwargs = {}
if settings.app_env != "development":
    _docs_kwargs = {"docs_url": None, "redoc_url": None, "openapi_url": None}

app = FastAPI(
    title="HausKlar",
    description="Know what's happening today",
    version="1.0.0",
    lifespan=lifespan,
    **_docs_kwargs,
)
app.add_middleware(RequestSecurityMiddleware)
app.add_middleware(IdempotencyMiddleware)


def _finite_validation_content(value: Any) -> Any:
    """Make rejected non-finite JSON numbers safe to echo in a 422 response."""
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    if isinstance(value, dict):
        return {key: _finite_validation_content(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_finite_validation_content(item) for item in value]
    return value


@app.exception_handler(RequestValidationError)
async def request_validation_error_response(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    # Library-card bodies contain credentials. Pydantic validation errors
    # normally echo the rejected input, so keep this endpoint deliberately
    # generic even when malformed JSON reaches a field validator.
    if request.url.path == "/api/library/accounts":
        return JSONResponse(
            status_code=422,
            content={"detail": "Check the library card number, PIN and card name."},
        )
    # JSON permits neither NaN nor infinities. Pydantic correctly rejects these,
    # but its error details include the offending float, so FastAPI's stock
    # handler can otherwise fail while serializing the validation response.
    detail = jsonable_encoder({"detail": exc.errors()})
    return JSONResponse(status_code=422, content=_finite_validation_content(detail))


WEB_ROOT = Path(__file__).parent / "web"
WEB_CSP = "; ".join(
    (
        "default-src 'self'",
        "base-uri 'self'",
        "connect-src 'self'",
        "font-src 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "img-src 'self' data: blob:",
        "manifest-src 'self'",
        "media-src 'self' blob:",
        "object-src 'none'",
        "script-src 'self'",
        "style-src 'self'",
        "worker-src 'self'",
    )
)


def _is_document_content_path(path: str) -> bool:
    """Match only /api/documents/{id}/content, without matching child paths."""
    parts = path.split("/")
    return (
        len(parts) == 5
        and parts[:3] == ["", "api", "documents"]
        and bool(parts[3])
        and parts[4] == "content"
    )


@app.middleware("http")
async def add_web_security_headers(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    if _is_document_content_path(path) and response.status_code in {200, 206}:
        # The authenticated inline file endpoint is the sole frameable route.
        # Uploads are restricted to the document service's media-type allowlist.
        response.headers["X-Frame-Options"] = "SAMEORIGIN"
        response.headers["Content-Security-Policy"] = "frame-ancestors 'self'"
    if settings.app_env.strip().lower() == "production":
        response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
    if path.startswith("/api/"):
        # Sensitive JSON remains non-cacheable. Authenticated media endpoints
        # deliberately opt into private caching for immutable images.
        response.headers.setdefault("Cache-Control", "no-store")
    if (
        path == "/"
        or path.startswith(("/assets/", "/icons/"))
        or path
        in {
            "/hausklar-logo.png",
            "/manifest.webmanifest",
            "/sw.js",
        }
    ):
        response.headers["Content-Security-Policy"] = WEB_CSP
        response.headers["Permissions-Policy"] = (
            "camera=(self), microphone=(self), geolocation=(), payment=(), usb=()"
        )
        if path.startswith("/assets/"):
            response.headers["Cache-Control"] = "public, max-age=31536000, immutable"

    # Record only an allowlisted action after the adult has explicitly opted in.
    # The classifier receives no request/response body, query string, title,
    # name, note, amount or entity id.
    from app.services.adoption import (
        classify_action_request,
        record_completed_action,
        safe_client_metadata,
    )

    fact = classify_action_request(request.method, path, response.status_code)
    current_user = getattr(request.state, "current_user", None)
    if fact is not None and current_user is not None:
        source, version = safe_client_metadata(request.headers)

        async def record_safely() -> None:
            try:
                await record_completed_action(
                    user=current_user,
                    fact=fact,
                    entry_source=source,
                    app_version=version,
                )
            except Exception:
                # Usage history can never make the family action fail or expose
                # private context through logs.
                return

        tasks = BackgroundTasks()
        if response.background is not None:
            tasks.tasks.append(response.background)
        tasks.tasks.append(BackgroundTask(record_safely))
        response.background = tasks
    return response


app.mount(
    "/assets",
    StaticFiles(directory=WEB_ROOT / "assets", check_dir=False),
    name="web-assets",
)
app.mount(
    "/icons",
    StaticFiles(directory=WEB_ROOT / "icons", check_dir=False),
    name="web-icons",
)

# Routers
app.include_router(adoption.router, prefix="/api/usage-history", tags=["usage history"])
app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
app.include_router(assistant.router, prefix="/api/assistant", tags=["assistant"])
app.include_router(sync.router, prefix="/api/sync", tags=["sync"])
app.include_router(calendar_sync.router, prefix="/api/calendar", tags=["calendar sync"])
app.include_router(calendar.router, prefix="/api/calendar", tags=["calendar"])
app.include_router(capture.router, prefix="/api/capture", tags=["capture"])
app.include_router(commitments.router, prefix="/api/commitments", tags=["commitments"])
app.include_router(coordination.router, prefix="/api/coordination", tags=["coordination"])
app.include_router(cycles.router, prefix="/api/cycles", tags=["cycles"])
app.include_router(tasks.router, prefix="/api/tasks", tags=["tasks"])
app.include_router(naps.router, prefix="/api/naps", tags=["naps"])
app.include_router(dog.router, prefix="/api/dog", tags=["dog"])
app.include_router(documents.router, prefix="/api/documents", tags=["documents"])
app.include_router(facilities.router, prefix="/api/facilities", tags=["facilities"])
app.include_router(finance.router, prefix="/api/finance", tags=["finance"])
app.include_router(
    finance_data_control.router,
    prefix="/api/finance",
    tags=["finance data control"],
)
app.include_router(
    finance_account_settings.router,
    prefix="/api/finance",
    tags=["finance account settings"],
)
app.include_router(
    finance_connections.router,
    prefix="/api/finance",
    tags=["finance connections"],
)
app.include_router(finance_import.router, prefix="/api/finance", tags=["finance import"])
app.include_router(
    finance_capture.router,
    prefix="/api/finance",
    tags=["finance capture"],
)
app.include_router(
    finance_coaching.router,
    prefix="/api/finance",
    tags=["finance coaching"],
)
app.include_router(
    finance_products_assets.router,
    prefix="/api/finance",
    tags=["finance products and assets"],
)
app.include_router(
    finance_sharing.router,
    prefix="/api/finance",
    tags=["finance sharing"],
)
app.include_router(
    finance_understanding.router,
    prefix="/api/finance",
    tags=["finance understanding"],
)
app.include_router(inbound_email.router, prefix="/api/inbound-email", tags=["inbound email"])
app.include_router(medicine.router, prefix="/api/medicine", tags=["medicine"])
app.include_router(birthdays.router, prefix="/api/birthdays", tags=["birthdays"])
app.include_router(growth.router, prefix="/api/growth", tags=["growth"])
app.include_router(meals.router, prefix="/api/meals", tags=["meals"])
app.include_router(homework.router, prefix="/api/homework", tags=["homework"])
app.include_router(briefing.router, prefix="/api/briefing", tags=["briefing"])
app.include_router(health.router, prefix="/api/health", tags=["health"])
app.include_router(fitness_core.router, prefix="/api/fitness", tags=["fitness"])
app.include_router(fitness_activity.router, prefix="/api/fitness", tags=["fitness activities"])
app.include_router(fitness_analysis.router, prefix="/api/fitness", tags=["fitness analysis"])
app.include_router(fitness_coach.router, prefix="/api/fitness", tags=["fitness coach"])
app.include_router(fitness_cycles.router, prefix="/api/fitness", tags=["fitness cycles"])
app.include_router(fitness_export.router, prefix="/api/fitness", tags=["fitness export"])
app.include_router(fitness_intervals.router, prefix="/api/fitness", tags=["fitness Intervals.icu"])
app.include_router(fitness_strava.router, prefix="/api/fitness", tags=["fitness Strava"])
app.include_router(fitness_maps.router, prefix="/api/fitness", tags=["fitness private maps"])
app.include_router(fitness_plans.router, prefix="/api/fitness", tags=["fitness plans"])
app.include_router(
    fitness_activity.internal_router,
    prefix="/api/internal/fitness",
    tags=["internal fitness worker"],
)
app.include_router(fitness_nutrition.router, prefix="/api/fitness", tags=["fitness nutrition"])
app.include_router(fitness_strength.router, prefix="/api/fitness", tags=["fitness strength"])
app.include_router(fitness_recovery.router, prefix="/api/fitness", tags=["fitness recovery"])
app.include_router(fitness_sync.router, prefix="/api/fitness", tags=["fitness sync"])
app.include_router(fitness_withings.router, prefix="/api/fitness", tags=["fitness Withings"])
app.include_router(home.router, prefix="/api/home", tags=["home"])
app.include_router(
    health_dashboard.router, prefix="/api/health/dashboard", tags=["health-dashboard"]
)
app.include_router(babysitter.router, prefix="/api/babysitter", tags=["babysitter"])
app.include_router(children.router, prefix="/api/children", tags=["children"])
app.include_router(presents.router, prefix="/api/children/presents", tags=["children-presents"])
app.include_router(prep_packs.router, prefix="/api/prep-packs", tags=["preparation packs"])
app.include_router(family.router, prefix="/api/family", tags=["family"])
app.include_router(routines.router, prefix="/api/routines", tags=["routines"])
app.include_router(school_clubs.router, prefix="/api/clubs", tags=["school clubs"])
app.include_router(toast_club.router, prefix="/api/toast-club", tags=["Toast Club"])
app.include_router(search.router, prefix="/api/search", tags=["search"])
app.include_router(reminders.router, prefix="/api/reminders", tags=["reminders"])
app.include_router(illness.router, prefix="/api/illness", tags=["illness"])
app.include_router(health_record.router, prefix="/api/health-record", tags=["health-record"])
app.include_router(insights.router, prefix="/api/insights", tags=["insights"])
app.include_router(library.router, prefix="/api/library", tags=["library"])
app.include_router(photos.router, prefix="/api/photos", tags=["photos"])
app.include_router(artworks.router, prefix="/api/artworks", tags=["artworks"])
app.include_router(yearbook.router, prefix="/api/yearbook", tags=["yearbook"])
app.include_router(renewals.router, prefix="/api/renewals", tags=["renewals"])
app.include_router(child_photos.router, prefix="/api/child-photos", tags=["child-photos"])
app.include_router(star_charts.router, prefix="/api/star-charts", tags=["star-charts"])
app.include_router(grocery.router, prefix="/api/grocery", tags=["grocery"])


@app.get("/api/healthcheck")
async def health_check():
    if not settings.healthcheck_show_scheduler_details:
        return {"status": "ok"}

    from app.scheduler import get_scheduler_status

    return {"status": "ok", "scheduler": get_scheduler_status()}


def _web_file(relative_path: str, media_type: str, cache_control: str) -> FileResponse:
    file_path = WEB_ROOT / relative_path
    if not file_path.is_file():
        raise HTTPException(status_code=503, detail="HausKlar web app is not built")
    return FileResponse(
        file_path,
        media_type=media_type,
        headers={"Cache-Control": cache_control},
    )


@app.get("/", include_in_schema=False)
async def web_app():
    return _web_file("index.html", "text/html; charset=utf-8", "no-cache")


@app.post("/api/share-target", include_in_schema=False)
async def web_share_target(
    title: str = Form(default="", max_length=500),
    text: str = Form(default="", max_length=10_000),
    url: str = Form(default="", max_length=2_000),
    current_user: dict = Depends(get_current_user),
):
    """Receive a Web Share Target POST and redirect with only an opaque draft id."""
    from app.database import database_lease
    from app.services.coordination import create_share_draft

    async with database_lease() as db:
        identifier = await create_share_draft(
            db, current_user, text=text, title=title or None, url=url or None
        )
    return RedirectResponse(url=f"/?view=today&share={identifier}", status_code=303)


@app.get("/manifest.webmanifest", include_in_schema=False)
async def web_manifest():
    return _web_file(
        "manifest.webmanifest",
        "application/manifest+json",
        "no-cache",
    )


@app.get("/sw.js", include_in_schema=False)
async def web_service_worker():
    return _web_file("sw.js", "text/javascript; charset=utf-8", "no-cache")


@app.get("/hausklar-logo.png", include_in_schema=False)
async def web_logo():
    return _web_file(
        "icons/hausklar-192.png",
        "image/png",
        "public, max-age=604800",
    )


@app.get("/privacy-policy", response_class=HTMLResponse, include_in_schema=False)
async def privacy_policy():
    return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>HausKlar Privacy Policy</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f7f7fb; color: #1f2937; }
    main { max-width: 880px; margin: 0 auto; padding: 32px 20px 48px; line-height: 1.55; }
    h1, h2 { color: #111827; }
    h1 { margin-bottom: 0.25rem; }
    .muted { color: #6b7280; margin-top: 0; }
    section { background: white; border: 1px solid #e5e7eb; border-radius: 12px; padding: 18px 20px; margin: 14px 0; }
    ul { margin-top: 0.35rem; }
    code { background: #f3f4f6; padding: 0.1rem 0.35rem; border-radius: 6px; }
  </style>
</head>
<body>
  <main>
    <h1>HausKlar Privacy Policy</h1>
    <p class="muted">Effective date: 12 August 2026</p>

    <section>
      <h2>1. Controller and Scope</h2>
      <p>HausKlar is a self-hosted family organization app. For this deployment, data controller contact is <code>dombarker@example.invalid</code>. This policy applies to the iOS app and backend hosted at <code>hausklar.example.invalid</code>.</p>
    </section>

    <section>
      <h2>2. Data We Collect</h2>
      <ul>
        <li>Account and contact data: name, email address, hashed password, auth/session tokens, and any optional phone number, home address, emergency, caregiver or vet contact details the family enters</li>
        <li>Family planning data: tasks, calendar events, routines, meals, shopping items</li>
        <li>Child and household logs: medicine entries, illness/temperature, naps, homework, growth measurements, vaccination records, birthday records</li>
        <li>Optional adult cycle tracking: period start dates, entered cycle length, calculated planning dates, calendar display preferences, and consent to share selected dates with other signed-in household adults</li>
        <li>Optional private adult Fitness records: goals and training phases; planned and completed running, strength and other activities; precise route coordinates contained in deliberately imported activities; gear and imported activity summaries; food diary, recipes, meal templates and nutrition targets; body measurements, sleep, resting-heart-rate, heart-rate-variability, readiness and body-issue observations; and calculated progress. HausKlar does not request live or background device location.</li>
        <li>Optional private Fitness progress and food-label photographs. These remain owner-only assets and are not published as static URLs.</li>
        <li>Household renewals and expiries you record (e.g. passport, MOT, insurance, subscriptions), including any linked document</li>
        <li>Optional Example Town library monitoring: the family-entered card label, masked last four, encrypted library barcode and PIN, connection status, and current loan titles, authors, formats, renewal status and due dates. The full barcode and PIN are never returned to an app after connection.</li>
        <li>Profile photos and child photos or artwork you choose to upload. Profile photos are stored in HausKlar's private storage and served only to authenticated members of the same family. Photos and videos you send to the optional self-hosted photo archive (Immich) remain on your own hardware; local face grouping may be used to organise that library and is never sent to a third party.</li>
        <li>Documents you choose to scan, upload, or forward by email, including bills or other records they contain, their extracted text, sender metadata, and draft calendar/task suggestions</li>
        <li>Free-form capture and assistant text you submit. On iOS, dictated audio is processed on device. In the web app, speech recognition is provided by your browser or operating system and may be processed under that provider's privacy terms. HausKlar receives only the editable transcript and does not upload or store the audio itself.</li>
        <li>Assistant messages you submit and the bounded family-data snapshot needed to answer them. Conversation text is held by the client for the active chat and is not stored by default. If an adult separately enables Fitness Coach memory, that adult's Fitness conversations and confirmed memory notes are stored owner-privately on the self-hosted HausKlar server until they delete or clear them.</li>
        <li>Optional Finance records: enabled-adult membership, private and shared Finance spaces, account labels, balances, read-only transaction and statement-import data, connection status, bills, reserves, savings goals, forecasts, reviewed purchase or receipt evidence, dated product-price research, manually entered security names, public ticker symbols, quantities and optional cost basis, investment report imports, and labelled watch-only public blockchain or exchange addresses and their public holdings. For an optional bank connection, HausKlar retains the opaque provider resource identifier needed to synchronise an account or card, its resource type and a masked last four; it does not retain the full account or card number. The security list is entered independently of a broker. HausKlar does not collect bank passwords, PINs, one-time codes, brokerage credentials, private keys, seed phrases, or payment, trade, order, or signing instructions.</li>
        <li>Pet care logs: walks, feeding, vet/medication notes</li>
        <li>Technical data: sync/session metadata, timestamps, the install-scoped sync client identifier, and network-address/request metadata used for short-window rate limiting, transport security and reliability</li>
        <li>Optional usage-summary data, only after an adult explicitly opts in: the area, generic action, success or failure, iOS or web source, coarse effort, app version and timestamp. These facts are linked to that adult's account for their private 28-day summary. HausKlar never includes titles, names, notes, amounts, searches, assistant messages, health values, document details, request bodies or response bodies.</li>
      </ul>
    </section>

    <section>
      <h2>3. Why We Use Data</h2>
      <ul>
        <li>Provide app functionality and cross-device sync</li>
        <li>Generate reminders and daily briefing views</li>
        <li>Calculate an optional predicted next period and estimated ovulation date from the period start and cycle length entered by the cycle owner</li>
        <li>Store family documents, receive letters forwarded to your private capture address, and track actions linked to those documents</li>
        <li>After you give explicit AI permission, use OpenAI only when you deliberately request Bismarck, Fitness Coach, AI capture, AI document extraction, a family-insight refresh, or a yearbook narrative</li>
        <li>For a Bismarck message, use the bounded family records needed for your request &mdash; which, depending on the question, may include a child's medicine, illness, growth or health entries &mdash; to answer and prepare actions for your confirmation</li>
        <li>AI processing is not scheduled or run nightly. HausKlar does not send unattended family snapshots to OpenAI.</li>
        <li>Provide ordinary Fitness logging, plans, nutrition calculations and progress analysis locally without AI. When you explicitly send a Fitness Coach message, send only the bounded, relevant owner-private summaries needed for that request. If you separately enable Coach memory, provide resumable owner-private conversations and confirmed memory notes which you can inspect, edit, forget or clear. Coach drafts remain inert until reviewed and confirmed.</li>
        <li>When an adult separately connects Strava or Withings, import only that adult's selected activities, routes or measurements into their private Fitness space. These connections are optional and can be disconnected at any time.</li>
        <li>When a family member separately connects a Example Town library card, use the saved encrypted login only to check current physical loans and due dates. HausKlar never renews, returns or otherwise changes a library account automatically.</li>
        <li>When you separately connect Intervals.icu and send an accepted workout, deliver only that workout's scheduled date, title, structured steps, durations, targets, and any instructions or cues contained in those steps. Intervals.icu may pass the workout to the Garmin account you connected there.</li>
        <li>Provide user-directed household record-keeping, arithmetic totals, dated forecasts, savings examples, and purchase records. These informational calculations run within HausKlar and do not require AI permission; they are not financial or investment advice.</li>
        <li>When you explicitly ask the Finance coach after accepting its separate notice, send only the permitted financial fields needed for that question to the configured provider. HausKlar does not store Finance chat transcripts or run Finance questions in the background.</li>
        <li>After an adult separately enables the optional usage summary, evaluate which HausKlar features help by retaining content-free action facts for up to 28 days. This first-party analytics data is never used for advertising, marketing, cross-app tracking or a data broker.</li>
        <li>Secure accounts, prevent abuse, and maintain service reliability</li>
        <li>Operate backup/restore and disaster recovery processes</li>
      </ul>
    </section>

    <section>
      <h2>4. Legal Bases (UK/EU Users)</h2>
      <ul>
        <li>Contract/performance: operating your account and requested app features</li>
        <li>Legitimate interests: security, abuse prevention, reliability, and backup operations</li>
        <li>Consent: optional integrations and notification channels you enable, including Strava and Withings imports, Intervals.icu workout delivery, Example Town library monitoring and Apple push notifications; the optional 28-day usage summary; adult-cycle sharing with other signed-in household adults; optional owner-private Fitness Coach memory; and separate, versioned permissions shown before general family or private adult Fitness data, or Finance data, is sent to OpenAI. Finance permission is recorded per adult and Finance space; shared household Finance data is sent only when every adult in the family has accepted the current notice. These permissions can be withdrawn immediately.</li>
      </ul>
    </section>

    <section>
      <h2>5. Data Sharing and Processors</h2>
      <p>We do not sell personal data. Data may be processed by configured infrastructure/providers to run the service:</p>
      <ul>
        <li>Cloudflare (reverse proxy/tunnel and transport security)</li>
        <li>Google Drive via rclone (encrypted backup destination, if configured)</li>
        <li>OpenWeatherMap (weather lookups for briefing, if configured)</li>
        <li>CallMeBot / WhatsApp or email providers (message delivery, if configured)</li>
        <li>Resend (receipt and temporary retrieval of emails and attachments you forward to the document inbox, if configured)</li>
        <li>OpenAI, currently configured as the inference provider behind HausKlar's private Hermes bridge. Only after the signed-in adult gives the current, explicit AI permission, OpenAI receives the text or bounded context needed for an AI feature that person deliberately requests. This can include capture or document text, relevant family context (including a child's medicine, illness, growth or health entries) for a Bismarck question, or that adult's relevant Fitness goals, plans, activity summaries, strength, nutrition, body, sleep, recovery, confirmed Coach memories and bounded recent conversation for a Fitness Coach request. Profile, child, progress and food-label photos, artwork, the self-hosted photo archive, raw document or FIT files, full activity streams, cycle records and credentials are never sent to OpenAI. HausKlar does not run scheduled or nightly OpenAI processing. Fitness conversation history is stored only on the self-hosted server after that adult separately enables Coach memory.</li>
        <li>Intervals.icu, only after an adult separately connects their account and sends an accepted workout. HausKlar presents the Intervals.icu access token or personal API key issued for that connection, then sends that adult's workout date, title, structured steps, durations, targets, and any instructions or cues in those steps. Intervals.icu may pass the workout to the Garmin account connected by that adult. It does not receive HausKlar passwords, credentials for other services, food records, body measurements, health history, photographs, Coach conversations, or other household records.</li>
        <li>Strava, only after an adult connects their account, supplies activities and route coordinates that adult asks HausKlar to import. Withings, only after an adult connects their account, supplies selected body measurements and related source metadata. Each provider receives the OAuth information needed for its own connection, not credentials for another service or unrelated household data.</li>
        <li>TrueLayer, if the optional Finance bank connection is enabled, hosts the consent and bank-authentication flow and provides read-only account, balance, card, and transaction information. HausKlar retains the opaque provider resource identifier needed for future synchronisation, whether it is an account or card, and a masked last four; it does not retain the full account or card number. An attended refresh may send the public client network address to TrueLayer for security and regulatory context. The adult authenticates with the bank and TrueLayer, not HausKlar. HausKlar never receives bank passwords, PINs or one-time codes and contains no payment, transfer, trade, beneficiary, lending, or signing feature. TrueLayer Limited is authorised and regulated by the UK Financial Conduct Authority under firm reference number 901096.</li>
        <li>Alpha Vantage, if public security pricing is configured, receives only the public ticker symbol needed for a quote. It does not receive the account owner, quantity, cost basis, brokerage information or household context.</li>
        <li>Public Solana or Hyperliquid data services, only when an adult explicitly saves a labelled watch-only public address and asks HausKlar to refresh it. Only that public address is sent; no private key, seed phrase, bank data, household context, or purchase evidence is included.</li>
        <li>Royal Borough of Example Town's Civica Spydus catalogue, only after a family member connects a card. The catalogue receives that card's barcode and the PIN encrypted with the catalogue's current public key so HausKlar can read current loans and due dates. The official website receives an ordinary browser visit only when a family member taps Renew online; HausKlar does not submit a renewal.</li>
        <li>Apple Push Notification service, if iOS notifications are enabled, processes an opaque device token and privacy-safe reminder text needed to deliver the notification.</li>
      </ul>
      <p>The Finance coach has a separate notice from Bismarck. For an explicit Finance question, its current OpenAI mode may receive permitted account labels and freshness, transaction dates, descriptions, merchants, amounts and currencies, and calculated ledger totals. Credentials and full bank identifiers are excluded. Requests use <code>store: false</code>, no provider-hosted tools, and no background processing. Withdrawing Finance permission stops new model calls without deleting the financial records used by the ordinary Finance screens.</p>
      <p>Cycle-tracking records are not included in Bismarck or other AI context.</p>
      <p>Each provider processes data under its own terms and privacy policy.</p>
    </section>

    <section>
      <h2>6. Retention</h2>
      <ul>
        <li>Primary app records are retained until deleted by the account owner or through account deletion.</li>
        <li>Assistant and Fitness Coach proposals, recommendations, feedback and their completion state are retained as an audit record. Assistant chat and Fitness Coach chat are not retained by default. After an adult enables Coach memory, owner-private Fitness conversations and confirmed memory notes remain until that adult deletes or clears them; turning memory off stops new retention but does not silently erase existing records.</li>
        <li>The optional usage summary is off by default. After opt-in, content-free facts are retained for no more than 28 days. Turning it off immediately stops collection and soft-deletes the active summary; the adult can also export or clear it at any time.</li>
        <li>Account deletion is available in-app at <code>Settings -> Security &amp; data -> Danger Zone -> Delete Account</code>. The account, sessions, private preferences, usage-summary facts, private Fitness records and assets, private Finance space and records, Finance AI permission, person-specific links, and authorship/device identifiers are permanently removed from the live service. Shared household records can remain without a link to the deleted identity. When the last family account is deleted, all live family records and uploaded files are permanently removed.</li>
        <li>Disconnecting a bank removes the stored provider session and stops future reads. Previously imported accounts, balances and transactions remain until the Finance records or account are deleted, so past reports do not silently change.</li>
        <li>Disconnecting Intervals.icu removes the stored credential and stops future workout updates. Workouts already sent may remain in Intervals.icu or Garmin until you remove them there; HausKlar retains only its owner-private delivery record until the Fitness records or account are deleted.</li>
        <li>Disconnecting Strava or Withings removes the stored provider credential and stops future imports. Activities, routes or measurements already imported into the adult's private Fitness space remain until that adult deletes the record, Fitness data or account.</li>
        <li>Disconnecting a library card removes its encrypted barcode and PIN and its active loan list from the live family account. The provider may retain its own account and loan history under its terms.</li>
        <li>Encrypted disaster-recovery backups are access-controlled and never used for ordinary access. Archives older than 30 days are removed once at least seven newer recovery copies exist. During a backup outage, up to seven older archives may remain isolated until successful backups resume.</li>
      </ul>
    </section>

    <section>
      <h2>7. Security</h2>
      <ul>
        <li>HTTPS in transit</li>
        <li>JWT-based authentication and token rotation</li>
        <li>On-device credentials stored in iOS Keychain</li>
        <li>Optional Intervals.icu credentials encrypted on the HausKlar server and never returned to an app after connection</li>
        <li>Optional Strava and Withings credentials encrypted on the HausKlar server and removed when the connection is disconnected</li>
        <li>Optional TrueLayer access and refresh tokens encrypted on the HausKlar server and removed when the bank connection is disconnected</li>
        <li>Optional library barcodes and PINs encrypted on the HausKlar server, never returned after connection, and removed from the live account when the card is disconnected</li>
        <li>Server-side access controls and change-history auditing</li>
      </ul>
    </section>

    <section>
      <h2>8. International Transfers</h2>
      <p>Because optional third-party services may operate globally, limited data may be processed outside your home country. Where applicable, provider safeguards and contractual terms govern these transfers.</p>
    </section>

    <section>
      <h2>9. Children's Data</h2>
      <p>HausKlar is intended for parent/guardian-managed household use. Children do not create independent accounts in this deployment; child records are managed by authenticated adult users.</p>
    </section>

    <section>
      <h2>10. Your Rights</h2>
      <p>Depending on your jurisdiction, you may have rights to access, correct, export, restrict, or delete your data, and to object to certain processing. To request this, contact <code>dombarker@example.invalid</code>.</p>
    </section>

    <section>
      <h2>11. Medical Disclaimer</h2>
      <p>HausKlar provides reminders and record-keeping only, not medical advice. Always consult a qualified healthcare professional for clinical decisions.</p>
    </section>

    <section>
      <h2>12. Policy Changes</h2>
      <p>We may update this policy from time to time. Material changes will be reflected by an updated effective date on this page.</p>
    </section>
  </main>
</body>
</html>
"""


@app.get("/terms", response_class=HTMLResponse, include_in_schema=False)
async def terms_of_service():
    return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>HausKlar Terms of Service</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f7f7fb; color: #1f2937; }
    main { max-width: 880px; margin: 0 auto; padding: 32px 20px 48px; line-height: 1.55; }
    h1, h2 { color: #111827; }
    h1 { margin-bottom: 0.25rem; }
    .muted { color: #6b7280; margin-top: 0; }
    section { background: white; border: 1px solid #e5e7eb; border-radius: 12px; padding: 18px 20px; margin: 14px 0; }
    ul { margin-top: 0.35rem; }
    code { background: #f3f4f6; padding: 0.1rem 0.35rem; border-radius: 6px; }
  </style>
</head>
<body>
  <main>
    <h1>HausKlar Terms of Service</h1>
    <p class="muted">Effective date: 10 August 2026</p>

    <section>
      <h2>1. Acceptance of Terms</h2>
      <p>By accessing or using HausKlar ("the App"), you agree to be bound by these Terms of Service. If you do not agree, you must not use the App.</p>
    </section>

    <section>
      <h2>2. Description of Service</h2>
      <p>HausKlar is a self-hosted family organisation app designed to help households coordinate daily tasks, calendars, routines, meals, child health records, optional private adult Fitness logging, and optional household money records and savings estimates. The App consists of an iOS client and a backend service hosted at <code>hausklar.example.invalid</code>.</p>
    </section>

    <section>
      <h2>3. Acceptable Use</h2>
      <p>You agree to use the App only for its intended purpose of family organisation. You must not:</p>
      <ul>
        <li>Attempt to gain unauthorised access to the service or other users' data</li>
        <li>Use the App for any unlawful purpose</li>
        <li>Interfere with or disrupt the operation of the service</li>
        <li>Reverse-engineer, decompile, or disassemble any part of the App</li>
      </ul>
    </section>

    <section>
      <h2>4. User Accounts</h2>
      <p>You are responsible for maintaining the confidentiality of your account credentials. You must notify the administrator immediately if you suspect unauthorised use of your account. Child records are managed by authenticated adult users; children do not create independent accounts.</p>
    </section>

    <section>
      <h2>5. Intellectual Property</h2>
      <p>All rights, title, and interest in the App, including its design, code, and content, remain with the developer. You are granted a limited, non-exclusive, non-transferable licence to use the App for personal, household purposes.</p>
    </section>

    <section>
      <h2>6. Medical Disclaimer</h2>
      <p>HausKlar provides reminders, record-keeping, Fitness analysis and reviewable coaching suggestions only. The App, including Fitness Coach and readiness or nutrition summaries, does not provide medical advice, diagnosis, treatment, or a guarantee that a workout is safe or suitable. Medicine tracking and health logs are informational aids. Stop exercising when appropriate and consult a qualified healthcare professional for clinical decisions regarding medication, dosage, injury, symptoms, nutrition, or any health concern.</p>
    </section>

    <section>
      <h2>7. Limitation of Liability</h2>
      <p>Finance features provide personal household records and arithmetic estimates only. A manually entered security list and watch-only public addresses are records, not brokerage, exchange or wallet connections. HausKlar cannot make payments, transfer money, place orders or trades, lend, hold funds, or provide financial, investment, tax, or legal advice. Bank and public price information may be delayed or incomplete. Check current information with the relevant provider and obtain qualified advice where appropriate before acting.</p>
      <p>The App is provided "as is" and "as available" without warranties of any kind, whether express or implied. To the fullest extent permitted by law, the developer shall not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, arising from your use of or inability to use the App.</p>
    </section>

    <section>
      <h2>8. Termination</h2>
      <p>The administrator may suspend or terminate your access to the App at any time, with or without cause. You may delete your account at any time via <code>Settings &gt; Security &amp; data &gt; Danger Zone &gt; Delete Account</code>. Upon termination, your right to use the App ceases immediately.</p>
    </section>

    <section>
      <h2>9. Governing Law</h2>
      <p>These Terms shall be governed by and construed in accordance with the laws of England and Wales. Any disputes arising under these Terms shall be subject to the exclusive jurisdiction of the courts of England and Wales.</p>
    </section>

    <section>
      <h2>10. Changes to These Terms</h2>
      <p>We may update these Terms from time to time. Material changes will be reflected by an updated effective date on this page. Continued use of the App after changes constitutes acceptance of the revised Terms.</p>
    </section>

    <section>
      <h2>11. Contact</h2>
      <p>For questions about these Terms, contact <code>dombarker@example.invalid</code>.</p>
    </section>
  </main>
</body>
</html>
"""


@app.get("/support", response_class=HTMLResponse, include_in_schema=False)
async def support_page():
    return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>HausKlar Support</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f7f7fb; color: #1f2937; }
    main { max-width: 720px; margin: 0 auto; padding: 32px 20px 48px; line-height: 1.55; }
    section { background: white; border: 1px solid #e5e7eb; border-radius: 12px; padding: 18px 20px; margin: 14px 0; }
    a { color: #155eef; }
  </style>
</head>
<body>
  <main>
    <h1>HausKlar Support</h1>
    <section>
      <h2>Get help</h2>
      <p>Email <a href="mailto:dombarker@example.invalid">dombarker@example.invalid</a> with a description of the issue and the app version shown in Settings. Do not include passwords, medicine details, or private family documents.</p>
    </section>
    <section>
      <h2>Account and privacy</h2>
      <p>You can change your password, sign out, or delete your account from Settings. See the <a href="/privacy-policy">Privacy Policy</a> and <a href="/terms">Terms of Service</a>.</p>
    </section>
  </main>
</body>
</html>
"""
