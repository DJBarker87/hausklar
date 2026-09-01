import ipaddress
from email.utils import parseaddr
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from cryptography.fernet import Fernet
from pydantic import Field
from pydantic_settings import BaseSettings

INSECURE_DEFAULT_JWT_SECRET = "change-me-to-a-random-secret"


class Settings(BaseSettings):
    # Database
    database_path: str = "hausklar.db"
    database_pool_size: int = Field(default=4, ge=1, le=32)
    database_busy_timeout_ms: int = Field(default=5000, ge=0, le=60_000)
    database_cache_kib: int = Field(default=8192, ge=1024, le=262_144)
    database_pool_acquire_timeout_seconds: float = Field(default=3.0, ge=0.1, le=30.0)

    # Request bodies are rejected at the ASGI edge before JSON parsing.
    api_max_request_bytes: int = Field(default=1_048_576, ge=65_536, le=10_485_760)

    # Document capture
    document_storage_path: str = "data/documents"
    document_max_upload_bytes: int = Field(default=25 * 1024 * 1024, ge=1_048_576, le=104_857_600)
    document_family_quota_bytes: int = Field(
        default=2 * 1024 * 1024 * 1024,
        ge=25 * 1024 * 1024,
        le=100 * 1024 * 1024 * 1024,
    )
    document_upload_rate_limit_requests: int = Field(default=30, ge=1, le=1_000)

    # Family media accepts camera originals larger than the generic 1 MB API
    # limit, then normalises them to bounded JPEGs before durable storage.
    media_max_request_bytes: int = Field(
        default=80 * 1024 * 1024, ge=2 * 1024 * 1024, le=300 * 1024 * 1024
    )
    media_max_file_bytes: int = Field(
        default=25 * 1024 * 1024, ge=2 * 1024 * 1024, le=100 * 1024 * 1024
    )
    media_family_quota_bytes: int = Field(
        default=10 * 1024 * 1024 * 1024,
        ge=100 * 1024 * 1024,
        le=500 * 1024 * 1024 * 1024,
    )
    media_upload_rate_limit_requests: int = Field(default=300, ge=10, le=10_000)
    media_cache_path: str = "data/media-cache"
    avatar_storage_path: str = "data/avatars"
    avatar_max_file_bytes: int = Field(default=786_432, ge=65_536, le=1_048_576)

    # Private Fitness files. Source FIT files are retained below fitness_storage_path;
    # streams and generated Garmin files live in the regenerable cache root.
    fitness_storage_path: str = "data/health"
    fitness_cache_path: str = "data/cache/health"
    # A separate brokered volume shared with the untrusted Fitness parser. It
    # contains only the inputs and temporary outputs for the currently claimed
    # job; the worker never mounts either Fitness storage root.
    fitness_worker_exchange_path: str = "data/fitness-worker-exchange"
    fitness_fit_max_upload_bytes: int = Field(
        default=64 * 1024 * 1024, ge=1_048_576, le=256 * 1024 * 1024
    )
    fitness_photo_max_upload_bytes: int = Field(
        default=25 * 1024 * 1024, ge=1_048_576, le=50 * 1024 * 1024
    )
    fitness_label_max_upload_bytes: int = Field(
        default=15 * 1024 * 1024, ge=1_048_576, le=25 * 1024 * 1024
    )
    fitness_owner_storage_quota_bytes: int = Field(
        default=10 * 1024 * 1024 * 1024,
        ge=256 * 1024 * 1024,
        le=500 * 1024 * 1024 * 1024,
    )
    fitness_family_storage_quota_bytes: int = Field(
        default=20 * 1024 * 1024 * 1024,
        ge=512 * 1024 * 1024,
        le=1_000 * 1024 * 1024 * 1024,
    )
    fitness_upload_rate_limit_requests: int = Field(default=120, ge=10, le=10_000)
    fitness_family_upload_rate_limit_requests: int = Field(default=200, ge=10, le=20_000)
    fitness_upload_rate_limit_window_seconds: int = Field(
        default=3_600, ge=60, le=86_400
    )
    fitness_owner_concurrent_uploads: int = Field(default=2, ge=1, le=16)
    fitness_family_concurrent_uploads: int = Field(default=4, ge=1, le=32)
    fitness_staged_asset_ttl_hours: int = Field(default=24, ge=1, le=168)
    fitness_failed_import_retention_days: int = Field(default=7, ge=1, le=90)
    fitness_worker_token: str = Field(default="", repr=False)
    fitness_worker_api_url: str = (  # gitleaks:allow
        "http://hausklar-api:8001/api/internal/fitness"  # gitleaks:allow
    )
    fitness_worker_lease_seconds: int = Field(default=300, ge=30, le=3_600)
    # Optional regional basemap. The archive and supporting assets are fixed
    # deployment paths; requests can never select a path or upstream URL.
    fitness_map_mbtiles_path: str = "/app/data/health/maps/basemap.mbtiles"
    fitness_map_sprite_path: str = "/app/data/health/maps/sprites"
    fitness_map_glyph_path: str = "/app/data/health/maps/glyphs"
    fitness_map_glyph_fontstacks: str = ""
    fitness_map_max_tile_bytes: int = Field(
        default=5 * 1024 * 1024,
        ge=16 * 1024,
        le=32 * 1024 * 1024,
    )
    fitness_map_max_uncompressed_tile_bytes: int = Field(
        default=20 * 1024 * 1024,
        ge=64 * 1024,
        le=64 * 1024 * 1024,
    )
    fitness_map_max_asset_bytes: int = Field(
        default=4 * 1024 * 1024,
        ge=16 * 1024,
        le=16 * 1024 * 1024,
    )
    fitness_map_max_concurrent_reads: int = Field(default=4, ge=1, le=16)

    # Optional private Hermes bridge. The iOS app never receives these values.
    hermes_bridge_url: str = ""
    hermes_bridge_token: str = ""
    immich_url: str = ""
    immich_api_key: str = ""
    hermes_timeout_seconds: float = Field(default=90.0, ge=5.0, le=300.0)
    hermes_queue_wait_seconds: float = Field(default=30.0, ge=0.0, le=120.0)
    fitness_coach_rate_limit_requests: int = Field(default=60, ge=5, le=500)
    fitness_coach_rate_limit_window_seconds: int = Field(default=3_600, ge=60, le=86_400)
    fitness_coach_proposal_ttl_minutes: int = Field(default=30, ge=5, le=1_440)
    assistant_rate_limit_requests: int = Field(default=120, ge=10, le=1_000)
    assistant_rate_limit_window_seconds: int = Field(default=3_600, ge=60, le=86_400)
    assistant_family_rate_limit_requests: int = Field(default=90, ge=10, le=1_000)
    assistant_global_rate_limit_requests: int = Field(default=120, ge=10, le=5_000)
    assistant_ip_rate_limit_requests: int = Field(default=60, ge=10, le=1_000)
    assistant_review_rate_limit_requests: int = Field(default=10, ge=1, le=100)

    # Finance reasoning is disabled by default. Provider/model selection is
    # deployment-only and is never accepted from a browser request.
    finance_ai_provider: Literal["off", "openai", "hermes"] = "off"
    finance_openai_api_key: str = Field(default="", repr=False)
    finance_openai_model: str = "gpt-5.6-sol"
    finance_hermes_model: str = "hermes-finance"
    finance_ai_timeout_seconds: float = Field(default=45.0, ge=5.0, le=180.0)
    finance_rate_limit_window_seconds: int = Field(default=3_600, ge=60, le=86_400)
    finance_family_rate_limit_requests: int = Field(default=120, ge=10, le=5_000)
    finance_ai_rate_limit_requests: int = Field(default=60, ge=5, le=1_000)
    finance_capture_rate_limit_requests: int = Field(default=60, ge=5, le=1_000)
    finance_provider_rate_limit_requests: int = Field(default=12, ge=2, le=500)
    finance_upload_rate_limit_requests: int = Field(default=30, ge=2, le=1_000)
    finance_export_rate_limit_requests: int = Field(default=3, ge=1, le=100)
    finance_family_concurrent_requests: int = Field(default=4, ge=1, le=32)
    finance_adult_concurrent_requests_per_kind: int = Field(default=1, ge=1, le=8)
    finance_market_price_provider: Literal["manual", "alphavantage"] = "manual"
    finance_alphavantage_api_key: str = Field(default="", repr=False)
    finance_market_price_timeout_seconds: float = Field(default=15.0, ge=3.0, le=60.0)

    # Enable Banking account-information access. The callback is deployment
    # fixed and the private RSA key is read server-side from an absolute path.
    enable_banking_application_id: str = Field(default="", repr=False)
    enable_banking_private_key_path: str = Field(default="", repr=False)
    enable_banking_callback_url: str = ""
    truelayer_client_id: str = Field(default="", repr=False, max_length=500)
    truelayer_client_secret: str = Field(default="", repr=False, max_length=2_000)
    truelayer_callback_url: str = Field(default="", max_length=2_048)
    finance_provider_encryption_key: str = Field(default="", repr=False, max_length=256)
    finance_provider_encryption_previous_keys: str = Field(default="", repr=False, max_length=4_096)
    finance_bank_sync_interval_minutes: int = Field(default=360, ge=60, le=1_440)
    finance_bank_retry_poll_interval_minutes: int = Field(default=5, ge=5, le=60)

    # Auth
    jwt_secret_key: str = INSECURE_DEFAULT_JWT_SECRET
    jwt_algorithm: Literal["HS256"] = "HS256"
    access_token_expire_minutes: int = Field(default=30, ge=5, le=1440)
    refresh_token_expire_days: int = Field(default=90, ge=1, le=365)
    allow_public_registration: bool = False
    strava_webhook_verify_token: str = ""
    health_webhook_secret: str = ""
    legacy_health_integrations_enabled: bool = False

    # CallMeBot
    notification_primary_adult_phone: str = ""
    notification_primary_adult_apikey: str = ""
    notification_secondary_adult_phone: str = ""
    notification_secondary_adult_apikey: str = ""

    # Household property identifier; private deployment configuration only.
    bin_collection_uprn: str = Field(default="", pattern=r"^$|^\d{6,20}$", repr=False)

    # Comma-separated child UUIDs for the household's swimming lesson import.
    # Kept out of source because this is deployment-specific family data.
    swimming_child_ids: str = ""

    # OpenWeatherMap
    openweathermap_api_key: str = ""
    openweathermap_lat: float = 0.0
    openweathermap_lon: float = 0.0
    weather_cache_ttl_seconds: int = Field(default=900, ge=60, le=86_400)

    # Resend
    resend_api_key: str = ""
    resend_from_email: str = "HausKlar <no-reply@example.invalid>"
    resend_webhook_secret: str = ""
    resend_inbound_domain: str = ""
    resend_inbound_address: str = ""
    resend_inbound_use_hermes: bool = False

    # Strava
    strava_integration_enabled: bool = False
    strava_client_id: str = ""
    strava_client_secret: str = Field(default="", repr=False)
    strava_redirect_uri: str = ""

    # Withings
    withings_integration_enabled: bool = False
    withings_client_id: str = Field(default="", repr=False)
    withings_client_secret: str = Field(default="", repr=False)
    withings_redirect_uri: str = ""
    withings_webhook_secret: str = Field(default="", repr=False)
    withings_sync_interval_minutes: int = Field(default=360, ge=60, le=1_440)
    withings_webhook_global_rate_limit_requests: int = Field(
        default=300, ge=10, le=10_000
    )
    withings_webhook_connection_rate_limit_requests: int = Field(
        default=60, ge=5, le=1_000
    )
    withings_webhook_rate_limit_window_seconds: int = Field(
        default=300, ge=60, le=3_600
    )

    # Intervals.icu calendar delivery and opt-in completed-activity import. OAuth
    # is preferred when its three app settings are present; a personal API key
    # remains an explicit fallback that does not require a developer app.
    intervals_icu_integration_enabled: bool = False
    intervals_icu_client_id: str = ""
    intervals_icu_client_secret: str = Field(default="", repr=False)
    intervals_icu_redirect_uri: str = ""
    intervals_icu_delivery_retry_minutes: int = Field(default=2, ge=1, le=60)
    intervals_icu_activity_sync_minutes: int = Field(default=15, ge=5, le=1_440)

    # Home Assistant
    ha_token_encryption_key: str = ""
    ha_allowed_origins: str = ""
    ha_safe_entity_ids: str = ""
    # Fixed server-side Audiobookshelf integration. Neither the upstream URL nor
    # token is returned to a client. The handoff base is the LAN-restricted
    # server-owned stream proxy used by Home Assistant/Sonos, never by iOS.
    audiobookshelf_url: str = ""
    audiobookshelf_token: str = Field(default="", repr=False)
    audiobookshelf_handoff_base_url: str = ""
    audiobookshelf_family_id: str = ""

    # App
    app_env: str = "development"
    app_base_url: str = "http://localhost:8001"
    web_app_url: str = "http://localhost:8001"
    production_family_id: str = ""
    app_review_password: str = Field(default="", max_length=128, repr=False)
    healthcheck_show_scheduler_details: bool = False
    # External and recurring jobs are opt-in. Local/demo startup performs no
    # scheduled provider work unless the operator enables this explicitly.
    scheduler_enabled: bool = False

    # Browser push. The private key is a server-side file path, never returned.
    web_push_vapid_private_key: str = ""
    web_push_vapid_public_key: str = ""
    web_push_vapid_subject: str = "mailto:admin@example.invalid"

    # Apple Push Notification service. The signing key stays in a root-owned
    # deployment file; only encrypted, owner-scoped device tokens reach SQLite.
    apns_team_id: str = ""
    apns_key_id: str = ""
    apns_private_key_path: str = Field(default="", repr=False)
    apns_bundle_id: str = "com.example.hausklar"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()


def validate_security_configuration() -> None:
    """Fail fast when production auth/webhook secrets are insecure."""
    app_env = settings.app_env.strip().lower()
    is_production = app_env == "production"

    if not is_production:
        return

    jwt_secret = settings.jwt_secret_key.strip()
    if not jwt_secret or jwt_secret == INSECURE_DEFAULT_JWT_SECRET or len(jwt_secret) < 32:
        raise RuntimeError(
            "JWT_SECRET_KEY is insecure for production. Set a random secret with at least 32 characters."
        )

    if settings.finance_ai_provider == "openai" and not settings.finance_openai_api_key.strip():
        raise RuntimeError("FINANCE_OPENAI_API_KEY must be set when FINANCE_AI_PROVIDER=openai")
    if settings.finance_ai_provider == "hermes" and not (
        settings.hermes_bridge_url.strip() and settings.hermes_bridge_token.strip()
    ):
        raise RuntimeError(
            "HERMES_BRIDGE_URL and HERMES_BRIDGE_TOKEN must be set when FINANCE_AI_PROVIDER=hermes"
        )

    enable_banking_values = (
        settings.enable_banking_application_id.strip(),
        settings.enable_banking_private_key_path.strip(),
        settings.enable_banking_callback_url.strip(),
    )
    if any(enable_banking_values) and not all(enable_banking_values):
        raise RuntimeError(
            "ENABLE_BANKING_APPLICATION_ID, ENABLE_BANKING_PRIVATE_KEY_PATH and "
            "ENABLE_BANKING_CALLBACK_URL must be configured together"
        )
    if all(enable_banking_values):
        private_key_path = Path(settings.enable_banking_private_key_path)
        callback_url = urlparse(settings.enable_banking_callback_url)
        if not private_key_path.is_absolute():
            raise RuntimeError("ENABLE_BANKING_PRIVATE_KEY_PATH must be absolute")
        if (
            callback_url.scheme != "https"
            or not callback_url.hostname
            or callback_url.username
            or callback_url.password
            or callback_url.params
            or callback_url.query
            or callback_url.fragment
            or callback_url.path != "/api/finance/connections/enable-banking/callback"
        ):
            raise RuntimeError(
                "ENABLE_BANKING_CALLBACK_URL must be the fixed HTTPS Finance callback URL"
            )
        if not settings.finance_provider_encryption_key.strip():
            raise RuntimeError(
                "FINANCE_PROVIDER_ENCRYPTION_KEY is required for Enable Banking encrypted storage"
            )

    truelayer_values = (
        settings.truelayer_client_id.strip(),
        settings.truelayer_client_secret.strip(),
        settings.truelayer_callback_url.strip(),
    )
    if any(truelayer_values) and not all(truelayer_values):
        raise RuntimeError(
            "TRUELAYER_CLIENT_ID, TRUELAYER_CLIENT_SECRET and "
            "TRUELAYER_CALLBACK_URL must be configured together"
        )
    if all(truelayer_values):
        callback_url = urlparse(settings.truelayer_callback_url)
        try:
            truelayer_explicit_port = callback_url.port is not None
        except ValueError:
            truelayer_explicit_port = True
        if (
            callback_url.scheme != "https"
            or not callback_url.hostname
            or truelayer_explicit_port
            or callback_url.username
            or callback_url.password
            or callback_url.query
            or callback_url.fragment
            or callback_url.path != "/api/finance/connections/truelayer/callback"
        ):
            raise RuntimeError(
                "TRUELAYER_CALLBACK_URL must be the fixed HTTPS Finance callback URL"
            )
        if not settings.finance_provider_encryption_key.strip():
            raise RuntimeError(
                "FINANCE_PROVIDER_ENCRYPTION_KEY is required for TrueLayer encrypted storage"
            )

    if settings.legacy_health_integrations_enabled:
        raise RuntimeError(
            "Legacy health integrations are not safe for multi-family production use. "
            "Keep LEGACY_HEALTH_INTEGRATIONS_ENABLED=false."
        )

    strava_values = (
        settings.strava_client_id.strip(),
        settings.strava_client_secret.strip(),
        settings.strava_redirect_uri.strip(),
    )
    if settings.strava_integration_enabled:
        if not all(strava_values) or not settings.ha_token_encryption_key.strip():
            raise RuntimeError(
                "STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET, STRAVA_REDIRECT_URI and "
                "HA_TOKEN_ENCRYPTION_KEY are required together"
            )
        redirect = urlparse(settings.strava_redirect_uri.strip())
        if (
            redirect.scheme != "https"
            or not redirect.hostname
            or redirect.username
            or redirect.password
            or redirect.query
            or redirect.fragment
            or redirect.path != "/api/fitness/integrations/strava/callback"
        ):
            raise RuntimeError(
                "STRAVA_REDIRECT_URI must be the fixed HTTPS Fitness Strava callback URL"
            )

    if settings.withings_integration_enabled:
        if not all(
            value.strip()
            for value in (
                settings.withings_client_id,
                settings.withings_client_secret,
                settings.withings_redirect_uri,
                settings.withings_webhook_secret,
                settings.ha_token_encryption_key,
            )
        ):
            raise RuntimeError(
                "WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET, WITHINGS_REDIRECT_URI, "
                "WITHINGS_WEBHOOK_SECRET and HA_TOKEN_ENCRYPTION_KEY are required when "
                "WITHINGS_INTEGRATION_ENABLED=true"
            )
        redirect = urlparse(settings.withings_redirect_uri.strip())
        if (
            redirect.scheme != "https"
            or not redirect.hostname
            or redirect.username
            or redirect.password
            or redirect.query
            or redirect.fragment
            or redirect.path != "/api/fitness/integrations/withings/callback"
        ):
            raise RuntimeError(
                "WITHINGS_REDIRECT_URI must be the fixed HTTPS Fitness Withings callback URL"
            )
        app_base = urlparse(settings.app_base_url.strip())
        if app_base.scheme != "https" or not app_base.hostname:
            raise RuntimeError(
                "APP_BASE_URL must be HTTPS when the Withings integration is enabled"
            )
        if len(settings.withings_webhook_secret.strip()) < 32:
            raise RuntimeError("WITHINGS_WEBHOOK_SECRET must contain at least 32 characters")

    if settings.intervals_icu_integration_enabled:
        if not settings.ha_token_encryption_key.strip():
            raise RuntimeError(
                "HA_TOKEN_ENCRYPTION_KEY is required when INTERVALS_ICU_INTEGRATION_ENABLED=true"
            )
        oauth_values = (
            settings.intervals_icu_client_id.strip(),
            settings.intervals_icu_client_secret.strip(),
            settings.intervals_icu_redirect_uri.strip(),
        )
        if any(oauth_values) and not all(oauth_values):
            raise RuntimeError(
                "INTERVALS_ICU_CLIENT_ID, INTERVALS_ICU_CLIENT_SECRET and "
                "INTERVALS_ICU_REDIRECT_URI must be configured together"
            )
        if all(oauth_values):
            redirect = urlparse(settings.intervals_icu_redirect_uri.strip())
            if (
                redirect.scheme != "https"
                or not redirect.hostname
                or redirect.username
                or redirect.password
                or redirect.query
                or redirect.fragment
                or redirect.path != "/api/fitness/integrations/intervals/oauth/callback"
            ):
                raise RuntimeError(
                    "INTERVALS_ICU_REDIRECT_URI must be the fixed HTTPS Fitness "
                    "Intervals.icu callback URL"
                )

    worker_token = settings.fitness_worker_token.strip()
    if worker_token and len(worker_token) < 32:
        raise RuntimeError("FITNESS_WORKER_TOKEN must contain at least 32 characters")

    if settings.resend_inbound_domain.strip() and len(settings.resend_webhook_secret.strip()) < 32:
        raise RuntimeError(
            "RESEND_WEBHOOK_SECRET must be set when RESEND_INBOUND_DOMAIN is configured"
        )
    if settings.resend_api_key.strip():
        sender_address = parseaddr(settings.resend_from_email.strip())[1].lower()
        sender_local, separator, sender_domain = sender_address.rpartition("@")
        if (
            not separator
            or not sender_local
            or "." not in sender_domain
            or sender_domain.endswith(".local")
            or sender_domain.endswith((".invalid", ".test"))
            or sender_domain in {"example.com", "example.net", "example.org"}
        ):
            raise RuntimeError("RESEND_FROM_EMAIL must use a valid non-local sender address")
    inbound_address = settings.resend_inbound_address.strip().lower()
    inbound_domain = settings.resend_inbound_domain.strip().lower().lstrip("@")
    if inbound_address:
        local_part, separator, address_domain = inbound_address.partition("@")
        if (
            not inbound_domain
            or not separator
            or address_domain != inbound_domain
            or not local_part
            or len(local_part) > 64
            or any(
                character not in "abcdefghijklmnopqrstuvwxyz0123456789._+-"
                for character in local_part
            )
        ):
            raise RuntimeError(
                "RESEND_INBOUND_ADDRESS must be a valid address on RESEND_INBOUND_DOMAIN"
            )

    app_url = urlparse(settings.app_base_url.strip())
    if app_url.scheme != "https" or not app_url.hostname:
        raise RuntimeError("APP_BASE_URL must be an absolute HTTPS URL in production")

    web_app_url = urlparse(settings.web_app_url.strip())
    if web_app_url.scheme != "https" or not web_app_url.hostname:
        raise RuntimeError("WEB_APP_URL must be an absolute HTTPS URL in production")

    bridge_url = settings.hermes_bridge_url.strip()
    bridge_token = settings.hermes_bridge_token.strip()
    if bool(bridge_url) != bool(bridge_token):
        raise RuntimeError("HERMES_BRIDGE_URL and HERMES_BRIDGE_TOKEN must be configured together")
    if bridge_url:
        parsed_bridge = urlparse(bridge_url)
        try:
            bridge_address = ipaddress.ip_address(parsed_bridge.hostname or "")
        except ValueError as exc:
            raise RuntimeError("HERMES_BRIDGE_URL must use a private IP address") from exc
        if (
            parsed_bridge.scheme not in {"http", "https"}
            or parsed_bridge.username
            or parsed_bridge.password
            or not bridge_address.is_private
            or len(bridge_token) < 32
        ):
            raise RuntimeError(
                "Hermes bridge must use a private URL and a token of at least 32 characters"
            )

    immich_url = settings.immich_url.strip()
    immich_key = settings.immich_api_key.strip()
    if bool(immich_url) != bool(immich_key):
        raise RuntimeError("IMMICH_URL and IMMICH_API_KEY must be configured together")
    if immich_url:
        parsed_immich = urlparse(immich_url)
        try:
            immich_address = ipaddress.ip_address(parsed_immich.hostname or "")
        except ValueError as exc:
            raise RuntimeError("IMMICH_URL must use a private IP address") from exc
        if (
            parsed_immich.scheme not in {"http", "https"}
            or parsed_immich.username
            or parsed_immich.password
            or not immich_address.is_private
        ):
            raise RuntimeError("IMMICH_URL must be a private-network URL")

    encryption_key = settings.ha_token_encryption_key.strip()
    if encryption_key:
        try:
            Fernet(encryption_key.encode())
        except (TypeError, ValueError) as exc:
            raise RuntimeError("HA_TOKEN_ENCRYPTION_KEY is not a valid Fernet key") from exc

    finance_encryption_keys = [
        settings.finance_provider_encryption_key.strip(),
        *(value.strip() for value in settings.finance_provider_encryption_previous_keys.split(",")),
    ]
    for finance_encryption_key in filter(None, finance_encryption_keys):
        try:
            Fernet(finance_encryption_key.encode())
        except (TypeError, ValueError) as exc:
            raise RuntimeError(
                "Finance provider encryption keys must be valid Fernet keys"
            ) from exc
    finance_primary_key = settings.finance_provider_encryption_key.strip()
    if finance_primary_key and encryption_key and finance_primary_key == encryption_key:
        raise RuntimeError(
            "FINANCE_PROVIDER_ENCRYPTION_KEY must be distinct from HA_TOKEN_ENCRYPTION_KEY"
        )

    vapid_private = settings.web_push_vapid_private_key.strip()
    vapid_public = settings.web_push_vapid_public_key.strip()
    if bool(vapid_private) != bool(vapid_public):
        raise RuntimeError(
            "WEB_PUSH_VAPID_PRIVATE_KEY and WEB_PUSH_VAPID_PUBLIC_KEY must be configured together"
        )
    if vapid_private and (not Path(vapid_private).is_absolute() or len(vapid_public) < 40):
        raise RuntimeError("Web push VAPID configuration is invalid")

    apns_values = (
        settings.apns_team_id.strip(),
        settings.apns_key_id.strip(),
        settings.apns_private_key_path.strip(),
    )
    if any(apns_values) and not all(apns_values):
        raise RuntimeError(
            "APNS_TEAM_ID, APNS_KEY_ID and APNS_PRIVATE_KEY_PATH must be configured together"
        )
    if all(apns_values):
        team_id, key_id, key_path = apns_values
        if (
            len(team_id) != 10
            or not team_id.isalnum()
            or len(key_id) != 10
            or not key_id.isalnum()
            or not Path(key_path).is_absolute()
            or not settings.apns_bundle_id.strip()
        ):
            raise RuntimeError("APNs configuration is invalid")
