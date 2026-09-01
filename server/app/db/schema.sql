-- HausKlar Database Schema
-- All tables include universal columns: id, created_at, updated_at, created_by, client_id, client_timestamp, deleted_at

CREATE TABLE IF NOT EXISTS families (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    invite_code TEXT UNIQUE,
    invite_expires_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_families_invite ON families(invite_code) WHERE invite_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    priority INTEGER NOT NULL DEFAULT 5,
    avatar_url TEXT,
    family_id TEXT,
    must_change_password INTEGER NOT NULL DEFAULT 0,
    auth_version INTEGER NOT NULL DEFAULT 0,
    ai_consent_version TEXT,
    ai_consent_at TEXT,
    ai_consent_revoked_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_users_family ON users(family_id);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    token TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    rotation_family_id TEXT NOT NULL,
    parent_token_id TEXT,
    replaced_by_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token ON refresh_tokens(token);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);

CREATE TABLE IF NOT EXISTS children (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    date_of_birth TEXT NOT NULL,
    notes TEXT,
    avatar_url TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_children_family ON children(family_id);

-- Effective-dated education and care placements. These facts are deliberately
-- separate from term dates: a childminder may have no school calendar, while a
-- school or preschool placement can select the correct term-date source.
CREATE TABLE IF NOT EXISTS child_care_assignments (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    provider_key TEXT NOT NULL,
    provider_name TEXT NOT NULL,
    assignment_kind TEXT NOT NULL
        CHECK (assignment_kind IN ('school', 'preschool', 'childminder')),
    effective_from TEXT,
    effective_until TEXT,
    follows_term_dates INTEGER NOT NULL DEFAULT 1
        CHECK (follows_term_dates IN (0, 1)),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_child_care_assignment_identity_active
    ON child_care_assignments(family_id, child_id, provider_key, effective_from)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_child_care_assignment_effective
    ON child_care_assignments(family_id, child_id, effective_from, effective_until)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS present_ideas (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    occasion TEXT NOT NULL,
    occasion_key TEXT,
    event_year INTEGER NOT NULL DEFAULT (strftime('%Y', 'now')),
    title TEXT NOT NULL,
    birthday_id TEXT,
    status TEXT NOT NULL DEFAULT 'idea'
        CHECK (status IN ('idea', 'shortlist', 'assigned', 'bought', 'arrived', 'wrapped', 'stashed', 'given')),
    status_updated_at TEXT,
    owner_id TEXT,
    notes TEXT,
    assigned_to TEXT,
    url TEXT,
    retailer TEXT,
    budget_minor INTEGER CHECK (budget_minor IS NULL OR budget_minor >= 0),
    price_minor INTEGER CHECK (price_minor IS NULL OR price_minor >= 0),
    currency TEXT NOT NULL DEFAULT 'GBP',
    deadline TEXT,
    hiding_location TEXT,
    recipient_can_see INTEGER NOT NULL DEFAULT 0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_present_ideas_child ON present_ideas(child_id);
CREATE INDEX IF NOT EXISTS idx_present_ideas_occasion ON present_ideas(occasion);
-- Indexes on newer present fields are created by the upgrade migration after
-- those columns have been added to an installed database.
CREATE INDEX IF NOT EXISTS idx_present_ideas_deleted ON present_ideas(deleted_at);
CREATE INDEX IF NOT EXISTS idx_present_ideas_family ON present_ideas(family_id);

CREATE TABLE IF NOT EXISTS present_status_history (
    id TEXT PRIMARY KEY,
    idea_id TEXT NOT NULL,
    from_status TEXT
        CHECK (from_status IS NULL OR from_status IN ('idea', 'shortlist', 'assigned', 'bought', 'arrived', 'wrapped', 'stashed', 'given')),
    to_status TEXT NOT NULL
        CHECK (to_status IN ('idea', 'shortlist', 'assigned', 'bought', 'arrived', 'wrapped', 'stashed', 'given')),
    changed_at TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_present_status_history_idea
    ON present_status_history(idea_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_present_status_history_family
    ON present_status_history(family_id);

CREATE TABLE IF NOT EXISTS present_idea_scores (
    id TEXT PRIMARY KEY,
    idea_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_present_idea_scores_idea_user_active
    ON present_idea_scores(idea_id, user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_present_idea_scores_idea ON present_idea_scores(idea_id);
CREATE INDEX IF NOT EXISTS idx_present_idea_scores_user ON present_idea_scores(user_id);
CREATE INDEX IF NOT EXISTS idx_present_idea_scores_deleted ON present_idea_scores(deleted_at);
CREATE INDEX IF NOT EXISTS idx_present_idea_scores_family ON present_idea_scores(family_id);

CREATE TABLE IF NOT EXISTS calendar_events (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    start_time TEXT NOT NULL,
    end_time TEXT,
    all_day INTEGER NOT NULL DEFAULT 0,
    recurrence_rule TEXT,
    location TEXT,
    family_member_ids TEXT, -- JSON array of UUIDs
    affected_member_ids TEXT, -- JSON array of adult UUIDs whose availability is affected
    assigned_to TEXT,
    event_type TEXT DEFAULT 'other',
    exertion INTEGER NOT NULL DEFAULT 0,
    color TEXT,
    rugby_source_venue TEXT CHECK (rugby_source_venue IN ('home', 'away')),
    rugby_venue_override TEXT CHECK (rugby_venue_override IN ('home', 'away')),
    source_document_id TEXT,
    calendar_source_id TEXT,
    external_uid TEXT,
    external_instance_key TEXT,
    source_term_date_id TEXT, -- Generated boundary event's source term_dates row
    term_boundary TEXT, -- first | last | first_last
    read_only INTEGER NOT NULL DEFAULT 0,
    overridden_event_id TEXT, -- Read-only source event superseded by this editable row
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_time);
CREATE INDEX IF NOT EXISTS idx_calendar_events_end ON calendar_events(end_time);
CREATE INDEX IF NOT EXISTS idx_calendar_events_assigned ON calendar_events(assigned_to);
CREATE INDEX IF NOT EXISTS idx_calendar_events_deleted ON calendar_events(deleted_at);
CREATE INDEX IF NOT EXISTS idx_calendar_events_family ON calendar_events(family_id);

-- A recurring series remains one calendar_events row. Exceptions suppress one
-- generated occurrence; an edited exception points at its ordinary, editable
-- replacement calendar_events row. No source/import row is ever mutated here.
CREATE TABLE IF NOT EXISTS calendar_event_exceptions (
    id TEXT PRIMARY KEY,
    series_id TEXT NOT NULL,
    occurrence_start TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('cancelled', 'replacement')),
    replacement_event_id TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_event_exceptions_active
    ON calendar_event_exceptions(family_id, series_id, occurrence_start)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_series
    ON calendar_event_exceptions(family_id, series_id);
CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_replacement
    ON calendar_event_exceptions(replacement_event_id);
CREATE INDEX IF NOT EXISTS idx_calendar_event_exceptions_deleted
    ON calendar_event_exceptions(deleted_at);

-- An event can carry several documents. source_document_id on calendar_events
-- remains the first attachment so older installed clients continue to work.
CREATE TABLE IF NOT EXISTS calendar_event_documents (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'other'
        CHECK (role IN ('ticket', 'booking', 'school_letter', 'insurance', 'other')),
    position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_event_documents_active
    ON calendar_event_documents(family_id, event_id, document_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_event
    ON calendar_event_documents(family_id, event_id, position);
CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_document
    ON calendar_event_documents(family_id, document_id);
CREATE INDEX IF NOT EXISTS idx_calendar_event_documents_deleted
    ON calendar_event_documents(deleted_at);

-- Adult-owned cycle tracking. These records are never treated as ordinary
-- family calendar rows: the calendar API projects only the entries the
-- authenticated account may see.
CREATE TABLE IF NOT EXISTS cycle_settings (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    cycle_length_days INTEGER NOT NULL DEFAULT 28 CHECK (cycle_length_days BETWEEN 10 AND 365),
    share_with_adults INTEGER NOT NULL DEFAULT 0,
    show_period_starts INTEGER NOT NULL DEFAULT 1,
    show_predicted_period INTEGER NOT NULL DEFAULT 1,
    show_estimated_ovulation INTEGER NOT NULL DEFAULT 1,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cycle_settings_owner_active
    ON cycle_settings(owner_user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cycle_settings_family
    ON cycle_settings(family_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS cycle_period_starts (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    started_on TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cycle_period_starts_owner_date_active
    ON cycle_period_starts(owner_user_id, started_on) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cycle_period_starts_family_owner_date
    ON cycle_period_starts(family_id, owner_user_id, started_on DESC)
    WHERE deleted_at IS NULL;

-- Fitness is the canonical owner of private menstrual-cycle tracking. The
-- legacy cycle_* tables above remain only as a migration source for installed
-- clients with already-queued /sync/push operations.
CREATE TABLE IF NOT EXISTS health_cycle_settings (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    cycle_length_days INTEGER NOT NULL DEFAULT 28 CHECK (cycle_length_days BETWEEN 10 AND 365),
    show_period_starts INTEGER NOT NULL DEFAULT 1,
    show_predicted_period INTEGER NOT NULL DEFAULT 1,
    show_estimated_ovulation INTEGER NOT NULL DEFAULT 1,
    share_period_starts_with_adults INTEGER NOT NULL DEFAULT 0,
    share_predicted_period_with_adults INTEGER NOT NULL DEFAULT 0,
    share_estimated_ovulation_with_adults INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_cycle_settings_owner_active
    ON health_cycle_settings(owner_user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_cycle_settings_family
    ON health_cycle_settings(family_id, owner_user_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_cycle_period_starts (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    started_on TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_cycle_period_owner_date_active
    ON health_cycle_period_starts(owner_user_id, started_on) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_cycle_period_family_owner_date
    ON health_cycle_period_starts(family_id, owner_user_id, started_on DESC)
    WHERE deleted_at IS NULL;

-- Finance data is authorised by space before any aggregation or analysis.
-- A personal space belongs to exactly one family adult; the household space
-- contains only records deliberately made available to the household.
CREATE TABLE IF NOT EXISTS finance_spaces (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('personal', 'household')),
    owner_user_id TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (kind = 'personal' AND owner_user_id IS NOT NULL)
        OR (kind = 'household' AND owner_user_id IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_spaces_personal_owner_active
    ON finance_spaces(owner_user_id)
    WHERE kind = 'personal' AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_spaces_household_family_active
    ON finance_spaces(family_id)
    WHERE kind = 'household' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_spaces_family_kind_active
    ON finance_spaces(family_id, kind)
    WHERE deleted_at IS NULL;

-- Household financial dates and the default display currency must be shared
-- by the adults using the same household plan.
CREATE TABLE IF NOT EXISTS finance_settings (
    id TEXT PRIMARY KEY,
    household_timezone TEXT NOT NULL DEFAULT 'Europe/London',
    default_currency TEXT NOT NULL DEFAULT 'GBP'
        CHECK (length(default_currency) = 3 AND default_currency = upper(default_currency)),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_settings_family_active
    ON finance_settings(family_id) WHERE deleted_at IS NULL;

-- Each family adult controls whether reviewed Finance dates are
-- included in their authenticated Calendar response. Nothing is written to
-- the ordinary family calendar.
CREATE TABLE IF NOT EXISTS finance_projection_preferences (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    show_money INTEGER NOT NULL DEFAULT 1 CHECK (show_money IN (0, 1)),
    show_deliveries INTEGER NOT NULL DEFAULT 1 CHECK (show_deliveries IN (0, 1)),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_projection_preferences_user_active
    ON finance_projection_preferences(user_id) WHERE deleted_at IS NULL;

-- Explicit Finance-AI consent is separate from general assistant consent and
-- binds one adult, one Finance space, and the exact deployed disclosure.
CREATE TABLE IF NOT EXISTS finance_ai_consents (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    disclosure_version TEXT NOT NULL,
    consent_version TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('openai', 'hermes')),
    model TEXT NOT NULL,
    store_response INTEGER NOT NULL DEFAULT 0 CHECK (store_response = 0),
    background_processing INTEGER NOT NULL DEFAULT 0 CHECK (background_processing = 0),
    accepted_at TEXT NOT NULL,
    revoked_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_ai_consent_current
    ON finance_ai_consents(user_id, space_id, consent_version, accepted_at DESC)
    WHERE revoked_at IS NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_ai_consent_space_current
    ON finance_ai_consents(space_id, consent_version, user_id)
    WHERE revoked_at IS NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_connections (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    institution_id TEXT,
    status TEXT NOT NULL CHECK (status IN (
        'CONNECTED', 'REAUTH_REQUIRED', 'EXPIRED', 'PROVIDER_DOWN',
        'PARTIAL', 'DISCONNECTED'
    )),
    granted_capabilities TEXT NOT NULL DEFAULT '[]',
    consent_created_at TEXT,
    consent_expires_at TEXT,
    last_success_at TEXT,
    last_error_code TEXT,
    encrypted_provider_secret_ref TEXT,
    callback_state_hash TEXT,
    data_through_at TEXT,
    sync_lease_token TEXT,
    sync_lease_expires_at TEXT,
    next_retry_at TEXT,
    consecutive_sync_failures INTEGER NOT NULL DEFAULT 0 CHECK (
        consecutive_sync_failures >= 0
    ),
    operation_generation INTEGER NOT NULL DEFAULT 0 CHECK (
        operation_generation >= 0
    ),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_connections_space_status
    ON finance_connections(space_id, status) WHERE deleted_at IS NULL;

-- Bank imports remain successful even if a deterministic follow-up refresh fails.
-- Each hook records only a bounded operational code; no financial content or
-- exception text is persisted here.
CREATE TABLE IF NOT EXISTS finance_connection_derived_refreshes (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    connection_id TEXT NOT NULL,
    hook_kind TEXT NOT NULL CHECK (hook_kind IN (
        'PURCHASE_REMATCH', 'FORECAST', 'PAYDAY_MATCH', 'COACH_REPORT'
    )),
    status TEXT NOT NULL CHECK (status IN ('SUCCEEDED', 'FAILED')),
    last_attempt_at TEXT NOT NULL,
    last_success_at TEXT,
    last_error_code TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_connection_derived_hook_active
    ON finance_connection_derived_refreshes(connection_id, hook_kind)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_connection_derived_space
    ON finance_connection_derived_refreshes(space_id, status, updated_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_accounts (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    connection_id TEXT,
    provider_account_id TEXT,
    provider_resource_type TEXT NOT NULL DEFAULT 'ACCOUNT' CHECK (
        provider_resource_type IN ('ACCOUNT', 'CARD')
    ),
    label TEXT NOT NULL,
    institution TEXT,
    account_type TEXT NOT NULL CHECK (account_type IN (
        'CURRENT', 'SAVINGS', 'CREDIT_CARD', 'CASH', 'INVESTMENT', 'CRYPTO'
    )),
    purpose TEXT NOT NULL DEFAULT 'OPERATING_CURRENT' CHECK (purpose IN (
        'OPERATING_CURRENT', 'SAVINGS', 'CREDIT_CARD', 'GOAL', 'IGNORED',
        'INVESTMENT_LIKE'
    )),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    last_four TEXT,
    include_in_cashflow INTEGER NOT NULL DEFAULT 1,
    include_in_net_worth INTEGER NOT NULL DEFAULT 1,
    primary_spending_account INTEGER NOT NULL DEFAULT 0,
    minimum_balance_minor INTEGER NOT NULL DEFAULT 0,
    card_paid_in_full INTEGER NOT NULL DEFAULT 0,
    card_settlement_account_id TEXT,
    card_statement_close_day INTEGER CHECK (
        card_statement_close_day IS NULL OR card_statement_close_day BETWEEN 1 AND 31
    ),
    card_repayment_day INTEGER CHECK (
        card_repayment_day IS NULL OR card_repayment_day BETWEEN 1 AND 31
    ),
    history_synced_from_date TEXT,
    fresh_through_date TEXT,
    data_through_at TEXT,
    provider_presence_status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (
        provider_presence_status IN ('ACTIVE', 'OMITTED')
    ),
    provider_omitted_at TEXT,
    provider_previous_settings_json TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_accounts_provider_active
    ON finance_accounts(connection_id, provider_account_id)
    WHERE connection_id IS NOT NULL AND provider_account_id IS NOT NULL
      AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_accounts_space_active
    ON finance_accounts(space_id, label) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_accounts_direct_spend_default
    ON finance_accounts(space_id, currency)
    WHERE primary_spending_account = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_balance_snapshots (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    booked_minor INTEGER NOT NULL,
    available_minor INTEGER,
    credit_limit_minor INTEGER,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    provider_at TEXT,
    observed_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_balances_account_observed
    ON finance_balance_snapshots(account_id, observed_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_balances_space_observed
    ON finance_balance_snapshots(space_id, observed_at DESC)
    WHERE deleted_at IS NULL;

-- Immutable after insertion. Provider payloads are reduced to the fields used
-- by the ledger before this boundary; arbitrary raw provider JSON is not kept.
CREATE TABLE IF NOT EXISTS finance_source_transactions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('PROVIDER', 'CSV', 'OFX', 'MANUAL')),
    source_batch_id TEXT NOT NULL,
    source_transaction_id TEXT,
    source_statement_id TEXT,
    replaces_source_transaction_id TEXT,
    source_group_id TEXT,
    source_fingerprint TEXT NOT NULL,
    booking_date TEXT NOT NULL,
    value_date TEXT,
    pending_status TEXT NOT NULL CHECK (pending_status IN ('PENDING', 'POSTED')),
    transaction_kind TEXT NOT NULL DEFAULT 'CASEY'
        CHECK (transaction_kind IN ('CASEY', 'FEE', 'CASH_WITHDRAWAL')),
    amount_minor INTEGER NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    source_description TEXT NOT NULL,
    cleaned_description TEXT NOT NULL,
    merchant_text TEXT,
    merchant_category_code TEXT,
    bank_code TEXT,
    bank_sub_code TEXT,
    observed_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_source_provider_identity
    ON finance_source_transactions(account_id, source_transaction_id, pending_status)
    WHERE source_transaction_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_source_statement_identity
    ON finance_source_transactions(account_id, source_statement_id, pending_status)
    WHERE source_statement_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_source_fingerprint
    ON finance_source_transactions(account_id, source_fingerprint)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_source_account_date
    ON finance_source_transactions(account_id, booking_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_source_space_observed
    ON finance_source_transactions(space_id, observed_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_merchants (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    name TEXT NOT NULL,
    merchant_kind TEXT NOT NULL DEFAULT 'BROAD_OR_UNKNOWN'
        CHECK (merchant_kind IN ('NARROW_SERVICE', 'BROAD_RETAILER', 'MARKETPLACE', 'BROAD_OR_UNKNOWN')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_merchants_space_name
    ON finance_merchants(space_id, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_merchant_aliases (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    merchant_id TEXT NOT NULL,
    normalised_alias TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_merchant_alias_space_active
    ON finance_merchant_aliases(space_id, normalised_alias)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_categories (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    parent_id TEXT,
    name TEXT NOT NULL,
    system_key TEXT,
    spending_type TEXT NOT NULL DEFAULT 'FLEXIBLE'
        CHECK (spending_type IN ('FIXED', 'FLEXIBLE', 'DISCRETIONARY')),
    counts_as_spending INTEGER NOT NULL DEFAULT 1
        CHECK (counts_as_spending IN (0, 1)),
    protected INTEGER NOT NULL DEFAULT 0,
    floor_minor INTEGER,
    flexibility_weight TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_categories_space_name_active
    ON finance_categories(space_id, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_transactions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    canonical_date TEXT NOT NULL,
    amount_minor INTEGER NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    state TEXT NOT NULL CHECK (state IN ('PENDING', 'POSTED', 'SUPERSEDED', 'VOID')),
    transaction_kind TEXT NOT NULL DEFAULT 'CASEY'
        CHECK (transaction_kind IN ('CASEY', 'FEE', 'CASH_WITHDRAWAL')),
    source_kind TEXT NOT NULL,
    source_group_id TEXT,
    description TEXT NOT NULL,
    cleaned_description TEXT NOT NULL,
    merchant_text TEXT,
    merchant_id TEXT,
    primary_category_id TEXT,
    user_note TEXT,
    superseded_by_id TEXT,
    data_through_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_transactions_space_date
    ON finance_transactions(space_id, canonical_date DESC, id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_transactions_account_date
    ON finance_transactions(account_id, canonical_date DESC, id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_transactions_space_state_date
    ON finance_transactions(space_id, state, canonical_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_transactions_transfer_match
    ON finance_transactions(space_id, currency, amount_minor, canonical_date DESC, id)
    WHERE state = 'POSTED' AND transaction_kind <> 'FEE' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_transaction_sources (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    transaction_id TEXT NOT NULL,
    source_transaction_id TEXT NOT NULL,
    is_primary INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_transaction_source_active
    ON finance_transaction_sources(source_transaction_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_transaction_sources_transaction
    ON finance_transaction_sources(transaction_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_transaction_relations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    from_transaction_id TEXT NOT NULL,
    to_transaction_id TEXT NOT NULL,
    relation_type TEXT NOT NULL CHECK (relation_type IN (
        'INTERNAL_TRANSFER', 'CREDIT_CARD_REPAYMENT', 'REFUND', 'REVERSAL',
        'REIMBURSEMENT', 'CHARGEBACK', 'FEE', 'FX_LEG', 'CASH_WITHDRAWAL'
    )),
    status TEXT NOT NULL DEFAULT 'SUGGESTED'
        CHECK (status IN ('SUGGESTED', 'CONFIRMED', 'REJECTED')),
    method TEXT NOT NULL,
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    note TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (from_transaction_id <> to_transaction_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_relation_pair_type_active
    ON finance_transaction_relations(from_transaction_id, to_transaction_id, relation_type)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_relations_space_status
    ON finance_transaction_relations(space_id, status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_relations_to
    ON finance_transaction_relations(to_transaction_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_relations_from_confirmed
    ON finance_transaction_relations(
        from_transaction_id, space_id, family_id, relation_type
    ) WHERE status = 'CONFIRMED' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_relations_to_confirmed
    ON finance_transaction_relations(
        to_transaction_id, space_id, family_id, relation_type
    ) WHERE status = 'CONFIRMED' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_transaction_splits (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    transaction_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL,
    category_id TEXT,
    label TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_splits_transaction_active
    ON finance_transaction_splits(transaction_id, created_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_splits_space_active
    ON finance_transaction_splits(space_id) WHERE deleted_at IS NULL;

-- Append-only classification history. User-confirmed rows can outrank rule or
-- model suggestions without overwriting how an earlier result was produced.
CREATE TABLE IF NOT EXISTS finance_assignments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    target_type TEXT NOT NULL CHECK (target_type IN ('TRANSACTION', 'PURCHASE', 'PURCHASE_LINE')),
    target_id TEXT NOT NULL,
    assignment_type TEXT NOT NULL CHECK (assignment_type IN ('MERCHANT', 'CATEGORY')),
    assigned_value_id TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('USER', 'RULE', 'AI')),
    status TEXT NOT NULL CHECK (status IN ('PROPOSED', 'CONFIRMED', 'REJECTED')),
    confidence_bps INTEGER CHECK (confidence_bps BETWEEN 0 AND 10000),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_assignments_target_created
    ON finance_assignments(space_id, target_type, target_id, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_assignments_scope_target
    ON finance_assignments(
        space_id, family_id, target_type, target_id, assignment_type, status,
        created_at DESC, id DESC
    ) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_recurring_series (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    detection_key TEXT,
    name TEXT NOT NULL,
    series_type TEXT NOT NULL CHECK (series_type IN (
        'SALARY', 'BILL', 'SUBSCRIPTION', 'RECURRING_COST'
    )),
    interval_kind TEXT NOT NULL CHECK (interval_kind IN (
        'MONTHLY', 'FOUR_WEEKLY', 'ANNUAL', 'IRREGULAR'
    )),
    expected_minor INTEGER NOT NULL,
    low_minor INTEGER,
    high_minor INTEGER,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    next_expected_date TEXT,
    working_day_adjustment TEXT CHECK (
        working_day_adjustment IS NULL
        OR working_day_adjustment IN ('PREVIOUS', 'NEXT')
    ),
    evidence_json TEXT NOT NULL DEFAULT '[]',
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    status TEXT NOT NULL DEFAULT 'CANDIDATE' CHECK (status IN (
        'CANDIDATE', 'CONFIRMED', 'REJECTED', 'EXPIRED'
    )),
    confirmed_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_recurring_space_status_date
    ON finance_recurring_series(space_id, status, next_expected_date)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_recurring_detection_key_active
    ON finance_recurring_series(space_id, detection_key)
    WHERE detection_key IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_findings (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    finding_key TEXT NOT NULL,
    finding_type TEXT NOT NULL CHECK (finding_type IN (
        'TREND_CHANGE', 'SEASONAL', 'REPEATED_ONE_OFF', 'PRICE_DRIFT',
        'DUPLICATE_REPLACEMENT', 'REPEATED_RETURN',
        'ANNUALISED_SMALL_COST'
    )),
    title TEXT NOT NULL,
    observation TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    baseline_json TEXT NOT NULL DEFAULT '{}',
    saving_low_minor INTEGER NOT NULL DEFAULT 0 CHECK (saving_low_minor >= 0),
    saving_high_minor INTEGER NOT NULL DEFAULT 0 CHECK (
        saving_high_minor >= saving_low_minor
    ),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    effort INTEGER NOT NULL DEFAULT 1 CHECK (effort > 0),
    overlap_group TEXT,
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN (
        'OPEN', 'ACCEPTED', 'DISMISSED', 'SNOOZED', 'EXPIRED'
    )),
    data_through_date TEXT NOT NULL,
    detected_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_findings_key_active
    ON finance_findings(space_id, finding_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_findings_space_status_score
    ON finance_findings(space_id, status, saving_high_minor DESC, confidence_bps DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_material_questions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    question_key TEXT NOT NULL,
    question_kind TEXT NOT NULL CHECK (question_kind IN (
        'SALARY', 'NURSERY', 'MISSING_CARD', 'LARGE_UNITEMISED_PURCHASE'
    )),
    prompt TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    action_kind TEXT NOT NULL CHECK (action_kind IN (
        'CONFIRM_RECURRING', 'IDENTIFY_SALARY', 'SAVE_NURSERY_PLAN',
        'ADD_CREDIT_CARD', 'ITEMISE_PURCHASE'
    )),
    action_target_id TEXT,
    priority_minor INTEGER NOT NULL DEFAULT 0 CHECK (priority_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN (
        'OPEN', 'CONFIRMED', 'CORRECTED', 'DISMISSED', 'EXPIRED'
    )),
    answer_text TEXT,
    resolved_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_material_question_key_active
    ON finance_material_questions(space_id, question_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_material_questions_open
    ON finance_material_questions(space_id, priority_minor DESC, created_at)
    WHERE status = 'OPEN' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_facts (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    fact_key TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version > 0),
    statement TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'PROPOSED' CHECK (status IN (
        'PROPOSED', 'CONFIRMED', 'REJECTED', 'EXPIRED'
    )),
    supersedes_id TEXT,
    confirmed_at TEXT,
    expired_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_facts_key_version
    ON finance_facts(space_id, fact_key, version) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_facts_space_status_updated
    ON finance_facts(space_id, status, updated_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_preferences (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    preference_key TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version > 0),
    statement TEXT NOT NULL,
    value_kind TEXT NOT NULL DEFAULT 'NEUTRAL' CHECK (value_kind IN (
        'PROTECTED', 'VALUED', 'REGRETTED', 'NEGOTIABLE', 'NEUTRAL'
    )),
    evidence_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'PROPOSED' CHECK (status IN (
        'PROPOSED', 'CONFIRMED', 'REJECTED', 'EXPIRED'
    )),
    supersedes_id TEXT,
    confirmed_at TEXT,
    expired_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_preferences_key_version
    ON finance_preferences(space_id, preference_key, version) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_preferences_space_status_updated
    ON finance_preferences(space_id, status, updated_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_commitments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    name TEXT NOT NULL,
    amount_mode TEXT NOT NULL CHECK (amount_mode IN ('EXACT', 'RANGE', 'FORECAST')),
    exact_minor INTEGER,
    expected_minor INTEGER,
    low_minor INTEGER,
    high_minor INTEGER,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    recurrence TEXT NOT NULL CHECK (recurrence IN (
        'ONE_OFF', 'MONTHLY', 'ANNUAL', 'TERMLY', 'CUSTOM'
    )),
    reviewed_dates_json TEXT NOT NULL,
    priority TEXT NOT NULL CHECK (priority IN ('PROTECTED', 'IMPORTANT', 'OPTIONAL')),
    funding_account_id TEXT,
    already_reserved_minor INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN (
        'ACTIVE', 'PAUSED', 'COMPLETED', 'CANCELLED'
    )),
    payment_handling TEXT NOT NULL DEFAULT 'UNSPECIFIED' CHECK (
        payment_handling IN ('UNSPECIFIED', 'AUTOMATIC', 'MANUAL', 'RENEWAL')
    ),
    show_in_calendar INTEGER NOT NULL DEFAULT 0 CHECK (show_in_calendar IN (0, 1)),
    show_in_tasks INTEGER NOT NULL DEFAULT 0 CHECK (show_in_tasks IN (0, 1)),
    responsible_user_id TEXT,
    notes TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_commitments_space_status
    ON finance_commitments(space_id, status, updated_at DESC) WHERE deleted_at IS NULL;

-- A reviewed commitment date is a stable occurrence. Calendar and Task IDs
-- belong to the projection, so refreshing or moving a date updates the same
-- logical item instead of creating another family record.
CREATE TABLE IF NOT EXISTS finance_commitment_occurrences (
    id TEXT PRIMARY KEY,
    commitment_id TEXT NOT NULL,
    due_date TEXT NOT NULL,
    calendar_projection_id TEXT NOT NULL,
    task_projection_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN (
        'ACTIVE', 'PAUSED', 'CANCELLED'
    )),
    task_completed_at TEXT,
    task_completed_by TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_occurrence_commitment_due_active
    ON finance_commitment_occurrences(commitment_id, due_date) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_occurrence_calendar_projection
    ON finance_commitment_occurrences(calendar_projection_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_occurrence_task_projection
    ON finance_commitment_occurrences(task_projection_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_occurrence_family_due
    ON finance_commitment_occurrences(family_id, due_date) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_reserves (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    name TEXT NOT NULL,
    allocated_minor INTEGER NOT NULL DEFAULT 0 CHECK (allocated_minor >= 0),
    target_minor INTEGER CHECK (target_minor IS NULL OR target_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    linked_account_id TEXT,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN (
        'ACTIVE', 'PAUSED', 'COMPLETED', 'CANCELLED'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_reserves_space_status
    ON finance_reserves(space_id, status, updated_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_goals (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    name TEXT NOT NULL,
    target_minor INTEGER NOT NULL CHECK (target_minor > 0),
    deadline TEXT NOT NULL,
    currently_allocated_minor INTEGER NOT NULL DEFAULT 0 CHECK (currently_allocated_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    priority TEXT NOT NULL CHECK (priority IN ('PROTECTED', 'IMPORTANT', 'OPTIONAL')),
    allowed_funding_sources_json TEXT NOT NULL DEFAULT '[]',
    emergency_buffer_minor INTEGER NOT NULL DEFAULT 0 CHECK (emergency_buffer_minor >= 0),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN (
        'ACTIVE', 'PAUSED', 'ACHIEVED', 'CANCELLED'
    )),
    notes TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_goals_space_status_deadline
    ON finance_goals(space_id, status, deadline) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_forecast_snapshots (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    input_snapshot_digest TEXT NOT NULL,
    engine_version TEXT NOT NULL,
    household_timezone TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    household_buffer_minor INTEGER NOT NULL DEFAULT 0,
    canonical_input_json TEXT NOT NULL,
    passed INTEGER NOT NULL,
    limiting_event_json TEXT,
    minimum_household_free_minor INTEGER NOT NULL,
    minimum_household_free_date TEXT NOT NULL,
    data_through_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_forecast_digest_version_active
    ON finance_forecast_snapshots(space_id, input_snapshot_digest, engine_version)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_forecast_space_created
    ON finance_forecast_snapshots(space_id, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_forecast_events (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    event_key TEXT NOT NULL,
    event_date TEXT NOT NULL,
    account_id TEXT NOT NULL,
    destination_account_id TEXT,
    amount_minor INTEGER NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    event_kind TEXT NOT NULL CHECK (event_kind IN (
        'income', 'expense', 'commitment', 'reserve', 'goal', 'planned',
        'transfer', 'card_purchase', 'refund'
    )),
    sequence INTEGER NOT NULL DEFAULT 0,
    provenance TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_forecast_event_key_active
    ON finance_forecast_events(snapshot_id, event_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_forecast_events_space_date
    ON finance_forecast_events(space_id, event_date, sequence) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_forecast_days (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    forecast_date TEXT NOT NULL,
    account_balances_json TEXT NOT NULL,
    household_liquid_minor INTEGER NOT NULL,
    household_free_minor INTEGER NOT NULL,
    constraints_passed_through_day INTEGER NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_forecast_day_active
    ON finance_forecast_days(snapshot_id, forecast_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_forecast_days_space_date
    ON finance_forecast_days(space_id, forecast_date) WHERE deleted_at IS NULL;

-- Finance purchase evidence is separate from ordinary Documents. Raw structured
-- facts are append-only; corrections create a new source and derived purchase.
CREATE TABLE IF NOT EXISTS finance_email_aliases (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    alias_kind TEXT NOT NULL CHECK (alias_kind IN ('PERSONAL', 'HOUSEHOLD')),
    owner_user_id TEXT,
    address TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    rotated_from_id TEXT,
    last_received_at TEXT,
    last_parsed_at TEXT,
    last_test_sent_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (alias_kind = 'PERSONAL' AND owner_user_id IS NOT NULL)
        OR (alias_kind = 'HOUSEHOLD' AND owner_user_id IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_email_alias_address
    ON finance_email_aliases(LOWER(address));
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_email_alias_space_active
    ON finance_email_aliases(space_id)
    WHERE enabled = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_email_enrollments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    alias_id TEXT NOT NULL,
    expected_forwarder_address TEXT NOT NULL,
    retailer_domain TEXT NOT NULL,
    transport_marker TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'ACTIVE', 'DISABLED')),
    verified_at TEXT,
    last_received_at TEXT,
    last_success_at TEXT,
    last_authentication_json TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_email_enrollment_active
    ON finance_email_enrollments(alias_id, LOWER(expected_forwarder_address), retailer_domain)
    WHERE status IN ('PENDING', 'ACTIVE') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_email_enrollment_space
    ON finance_email_enrollments(space_id, status) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_email_messages (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    alias_id TEXT NOT NULL,
    enrollment_id TEXT,
    provider_message_id TEXT NOT NULL,
    internet_message_id TEXT,
    visible_sender TEXT NOT NULL,
    subject TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'PROCESSING', 'PARSED', 'QUARANTINED', 'UNSUPPORTED', 'FAILED'
    )),
    source_id TEXT,
    failure_reason TEXT,
    received_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_email_provider_message
    ON finance_email_messages(provider_message_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_email_message_space
    ON finance_email_messages(space_id, received_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_sources (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    external_source_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN (
        'tesco_batch', 'amazon_email', 'e_receipt', 'service_invoice',
        'pdf', 'image', 'html', 'natural_language'
    )),
    corrects_source_id TEXT,
    parser_version TEXT,
    extraction_status TEXT NOT NULL CHECK (extraction_status IN (
        'PARSED', 'QUARANTINED', 'UNSUPPORTED'
    )),
    confidence_bps INTEGER CHECK (confidence_bps BETWEEN 0 AND 10000),
    raw_payload_json TEXT NOT NULL,
    issues_json TEXT NOT NULL DEFAULT '[]',
    storage_area TEXT NOT NULL DEFAULT 'finance-evidence'
        CHECK (storage_area = 'finance-evidence'),
    storage_key TEXT,
    media_type TEXT,
    byte_size INTEGER CHECK (byte_size IS NULL OR byte_size >= 0),
    email_alias_id TEXT,
    email_enrollment_id TEXT,
    provider_message_id TEXT,
    internet_message_id TEXT,
    visible_sender TEXT,
    email_subject TEXT,
    authentication_json TEXT,
    received_at TEXT NOT NULL,
    parsed_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_source_identity_active
    ON finance_purchase_sources(space_id, source_kind, external_source_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_sources_space_status
    ON finance_purchase_sources(space_id, extraction_status, received_at DESC)
    WHERE deleted_at IS NULL;

-- Delivery dates are projected only after an adult reviews typed date/time
-- fields. Unstructured receipt or email prose is never guessed into Calendar.
CREATE TABLE IF NOT EXISTS finance_calendar_items (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    item_kind TEXT NOT NULL CHECK (item_kind IN (
        'GROCERY_DELIVERY', 'PARCEL_DELIVERY'
    )),
    source_id TEXT NOT NULL,
    starts_at TEXT NOT NULL,
    ends_at TEXT,
    all_day INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0, 1)),
    reviewed INTEGER NOT NULL CHECK (reviewed = 1),
    calendar_projection_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CANCELLED')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_calendar_item_source_active
    ON finance_calendar_items(space_id, source_id, item_kind) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_calendar_item_projection_active
    ON finance_calendar_items(calendar_projection_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_calendar_item_family_start
    ON finance_calendar_items(family_id, starts_at) WHERE deleted_at IS NULL;

-- Private-to-household delivery calendar choices copy only the source kind.
-- The private evidence identifier remains in this internal map and is never
-- exposed through the household Finance source.
CREATE TABLE IF NOT EXISTS finance_calendar_source_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    source_space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    calendar_space_id TEXT NOT NULL,
    calendar_source_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_calendar_source_link_active
    ON finance_calendar_source_links(owner_user_id, source_space_id, source_id, calendar_space_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_calendar_source_link_calendar
    ON finance_calendar_source_links(calendar_space_id, calendar_source_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_source_files (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    file_role TEXT NOT NULL CHECK (file_role IN ('MESSAGE', 'ATTACHMENT')),
    filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    storage_key TEXT,
    byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
    storage_status TEXT NOT NULL CHECK (storage_status IN (
        'STORED', 'REJECTED_TYPE', 'REJECTED_SIZE', 'REJECTED_UNSAFE'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_purchase_source_files_source
    ON finance_purchase_source_files(source_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_source_files_family_storage
    ON finance_purchase_source_files(family_id, storage_status)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_source_health (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    health_status TEXT NOT NULL CHECK (health_status IN (
        'HEALTHY', 'DEGRADED', 'QUARANTINED', 'UNSUPPORTED'
    )),
    last_received_at TEXT,
    last_parsed_at TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
    latest_issue_code TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_health_kind_active
    ON finance_purchase_source_health(space_id, source_kind)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_records (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    purchase_ref TEXT NOT NULL,
    merchant_name TEXT NOT NULL,
    merchant_id TEXT,
    external_order_reference TEXT,
    purchased_on TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    lines_subtotal_minor INTEGER NOT NULL CHECK (lines_subtotal_minor >= 0),
    shipping_minor INTEGER NOT NULL DEFAULT 0 CHECK (shipping_minor >= 0),
    vat_included_minor INTEGER NOT NULL DEFAULT 0 CHECK (vat_included_minor >= 0),
    order_discount_minor INTEGER NOT NULL DEFAULT 0 CHECK (order_discount_minor >= 0),
    final_total_minor INTEGER NOT NULL CHECK (final_total_minor >= 0),
    refunded_minor INTEGER NOT NULL DEFAULT 0 CHECK (refunded_minor >= 0),
    status TEXT NOT NULL CHECK (status IN (
        'pending', 'partly_fulfilled', 'fulfilled', 'partly_refunded',
        'refunded', 'cancelled'
    )),
    source_kind TEXT NOT NULL,
    extraction_confidence_bps INTEGER NOT NULL CHECK (
        extraction_confidence_bps BETWEEN 0 AND 10000
    ),
    supersedes_purchase_id TEXT,
    superseded_by_id TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_ref_version_active
    ON finance_purchase_records(space_id, source_id, purchase_ref)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchases_space_date_current
    ON finance_purchase_records(space_id, purchased_on DESC, id)
    WHERE superseded_by_id IS NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchases_space_date_created_current
    ON finance_purchase_records(
        space_id, purchased_on DESC, created_at DESC, id DESC
    ) WHERE superseded_by_id IS NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_lines (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    purchase_id TEXT NOT NULL,
    source_line_reference TEXT NOT NULL,
    line_position INTEGER NOT NULL CHECK (line_position >= 0),
    line_kind TEXT NOT NULL CHECK (line_kind IN (
        'product', 'service', 'delivery', 'fee', 'tax', 'unknown'
    )),
    raw_description TEXT NOT NULL,
    quantity_decimal TEXT NOT NULL,
    unit_description TEXT,
    unit_price_minor INTEGER CHECK (unit_price_minor IS NULL OR unit_price_minor >= 0),
    line_gross_minor INTEGER,
    line_discount_minor INTEGER,
    line_net_minor INTEGER,
    evidence_status TEXT NOT NULL CHECK (evidence_status IN (
        'observed_structured', 'observed_document', 'user_confirmed',
        'inferred', 'unitemised'
    )),
    source_refs_json TEXT NOT NULL,
    seller TEXT,
    product_reference TEXT,
    replaces_description TEXT,
    shipment_reference TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (line_gross_minor IS NULL AND line_discount_minor IS NULL AND line_net_minor IS NULL)
        OR (
            line_gross_minor >= 0 AND line_discount_minor >= 0 AND line_net_minor >= 0
            AND line_net_minor = line_gross_minor - line_discount_minor
        )
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_line_ref_active
    ON finance_purchase_lines(purchase_id, source_line_reference)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_lines_space_purchase
    ON finance_purchase_lines(space_id, purchase_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_lines_list
    ON finance_purchase_lines(space_id, purchase_id, line_position, id)
    WHERE deleted_at IS NULL;

-- Source evidence above is immutable.  Editable understanding is stored in a
-- separate layer so a correction can never rewrite what the retailer supplied.
CREATE TABLE IF NOT EXISTS finance_normalized_purchase_items (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    identity_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    item_kind TEXT NOT NULL CHECK (item_kind IN ('product', 'service', 'unknown')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_normalized_item_key_active
    ON finance_normalized_purchase_items(space_id, identity_key)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_line_assessments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    normalized_item_id TEXT,
    beneficiary TEXT,
    purpose TEXT,
    plannedness TEXT CHECK (plannedness IS NULL OR plannedness IN (
        'planned', 'routine', 'replacement', 'emergency', 'impulse', 'unknown'
    )),
    utility TEXT CHECK (utility IS NULL OR utility IN (
        'essential', 'useful', 'optional', 'unclear'
    )),
    decision_quality TEXT CHECK (decision_quality IS NULL OR decision_quality IN (
        'sensible', 'mixed', 'questionable', 'poor_value', 'unknown'
    )),
    value_for_money TEXT CHECK (value_for_money IS NULL OR value_for_money IN (
        'good', 'fair', 'poor', 'unknown'
    )),
    outcome_state TEXT CHECK (outcome_state IS NULL OR outcome_state IN (
        'valued', 'neutral', 'regretted', 'returned', 'unused', 'unknown'
    )),
    classification_source TEXT NOT NULL CHECK (classification_source IN (
        'USER', 'LEARNED', 'RULE', 'MODEL', 'IMPORT'
    )),
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    review_status TEXT NOT NULL CHECK (review_status IN (
        'UNREVIEWED', 'NEEDS_REVIEW', 'CONFIRMED'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_line_assessment_active
    ON finance_purchase_line_assessments(line_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_line_assessment_review
    ON finance_purchase_line_assessments(space_id, review_status, confidence_bps)
    WHERE deleted_at IS NULL;

-- Append-only examples used to suggest the same classification for future
-- matching source descriptions. They are feedback, never source evidence.
CREATE TABLE IF NOT EXISTS finance_purchase_classification_feedback (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    identity_key TEXT NOT NULL,
    field_name TEXT NOT NULL CHECK (field_name IN (
        'normalized_item', 'beneficiary', 'purpose', 'plannedness', 'utility',
        'decision_quality', 'value_for_money', 'outcome_state'
    )),
    previous_value TEXT,
    corrected_value TEXT,
    correction_reason TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_purchase_feedback_learning
    ON finance_purchase_classification_feedback(space_id, identity_key, field_name, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_tenders (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    purchase_id TEXT NOT NULL,
    tender_ref TEXT NOT NULL,
    tender_kind TEXT NOT NULL CHECK (tender_kind IN (
        'bank', 'card', 'cash', 'gift_card', 'credit', 'unknown'
    )),
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    provider_transaction_id TEXT,
    card_suffix TEXT,
    source_refs_json TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_tender_ref_active
    ON finance_purchase_tenders(purchase_id, tender_ref) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_line_refunds (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    purchase_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    refund_ref TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    quantity_decimal TEXT,
    source_refs_json TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_line_refund_ref_active
    ON finance_line_refunds(purchase_id, refund_ref) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_line_refunds_scope_purchase_line
    ON finance_line_refunds(space_id, family_id, purchase_id, line_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_payments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    purchase_id TEXT NOT NULL,
    transaction_id TEXT,
    line_id TEXT,
    allocation_ref TEXT NOT NULL,
    tender_kind TEXT NOT NULL CHECK (tender_kind IN (
        'bank', 'card', 'cash', 'gift_card', 'credit', 'unknown'
    )),
    allocated_minor INTEGER NOT NULL CHECK (allocated_minor <> 0),
    match_method TEXT NOT NULL CHECK (match_method IN (
        'AUTO_EXACT', 'REVIEWED', 'EVIDENCED_NON_BANK'
    )),
    status TEXT NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN (
        'PROPOSED', 'CONFIRMED', 'REJECTED'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (tender_kind IN ('bank', 'card') AND transaction_id IS NOT NULL)
        OR (tender_kind NOT IN ('bank', 'card') AND transaction_id IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_allocation_ref_active
    ON finance_purchase_payments(purchase_id, allocation_ref)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_payments_transaction
    ON finance_purchase_payments(space_id, transaction_id)
    WHERE transaction_id IS NOT NULL AND status = 'CONFIRMED' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_payments_scope_purchase
    ON finance_purchase_payments(space_id, family_id, purchase_id, status)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_payments_summary
    ON finance_purchase_payments(space_id, purchase_id, allocated_minor)
    WHERE status = 'CONFIRMED' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_exceptions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    purchase_id TEXT,
    exception_kind TEXT NOT NULL CHECK (exception_kind IN (
        'QUARANTINED_EVIDENCE', 'UNSUPPORTED_SOURCE', 'AMBIGUOUS_MATCH',
        'UNMATCHED_PURCHASE', 'PARTIAL_ITEMISATION'
    )),
    title TEXT NOT NULL,
    detail TEXT NOT NULL,
    amount_minor INTEGER CHECK (amount_minor IS NULL OR amount_minor >= 0),
    currency TEXT,
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'RESOLVED', 'DISMISSED')),
    priority INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_purchase_exception_source_open
    ON finance_purchase_exceptions(source_id)
    WHERE status = 'OPEN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_purchase_inbox_space_priority
    ON finance_purchase_exceptions(space_id, status, priority DESC, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_analysis_views (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    specification_json TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_analysis_views_owner
    ON finance_analysis_views(owner_user_id, space_id, updated_at DESC)
    WHERE deleted_at IS NULL;

-- Comparable product prices remain dated evidence; research inputs contain
-- only sanitised item/pack constraints and never household financial context.
CREATE TABLE IF NOT EXISTS finance_retailer_research_requests (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    normalized_item_id TEXT NOT NULL,
    request_json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'REQUESTED' CHECK (status IN (
        'REQUESTED', 'RESULT_READY', 'CANCELLED'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_retailer_research_space_status
    ON finance_retailer_research_requests(space_id, status, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_retailer_research_results (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    match_kind TEXT NOT NULL CHECK (match_kind IN (
        'EXACT', 'REALISTIC_SUBSTITUTE', 'BEHAVIOURAL_ALTERNATIVE'
    )),
    retailer_name TEXT NOT NULL,
    product_name TEXT NOT NULL,
    brand_variant TEXT,
    pack_quantity_decimal TEXT NOT NULL,
    pack_unit TEXT NOT NULL,
    comparable_quantity_decimal TEXT NOT NULL,
    unit_basis TEXT NOT NULL,
    price_minor INTEGER NOT NULL CHECK (price_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    observed_on TEXT NOT NULL,
    delivery_low_minor INTEGER NOT NULL DEFAULT 0 CHECK (delivery_low_minor >= 0),
    delivery_high_minor INTEGER NOT NULL DEFAULT 0 CHECK (
        delivery_high_minor >= delivery_low_minor
    ),
    travel_low_minor INTEGER NOT NULL DEFAULT 0 CHECK (travel_low_minor >= 0),
    travel_high_minor INTEGER NOT NULL DEFAULT 0 CHECK (
        travel_high_minor >= travel_low_minor
    ),
    likely_waste_low_bps INTEGER NOT NULL DEFAULT 0 CHECK (
        likely_waste_low_bps BETWEEN 0 AND 10000
    ),
    likely_waste_high_bps INTEGER NOT NULL DEFAULT 0 CHECK (
        likely_waste_high_bps BETWEEN likely_waste_low_bps AND 10000
    ),
    inconvenience_note TEXT NOT NULL,
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    source_label TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_retailer_results_request
    ON finance_retailer_research_results(request_id, observed_on DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_product_price_observations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    normalized_item_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('PURCHASE_LINE', 'RETAILER_RESEARCH')),
    source_line_id TEXT,
    research_result_id TEXT,
    retailer_name TEXT NOT NULL,
    product_name TEXT NOT NULL,
    brand_variant TEXT,
    pack_quantity_decimal TEXT NOT NULL,
    pack_unit TEXT NOT NULL,
    comparable_quantity_decimal TEXT NOT NULL,
    unit_basis TEXT NOT NULL,
    price_minor INTEGER NOT NULL CHECK (price_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    observed_on TEXT NOT NULL,
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    evidence_json TEXT NOT NULL DEFAULT '[]',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (source_kind = 'PURCHASE_LINE' AND source_line_id IS NOT NULL AND research_result_id IS NULL)
        OR (source_kind = 'RETAILER_RESEARCH' AND source_line_id IS NULL AND research_result_id IS NOT NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_product_price_line_active
    ON finance_product_price_observations(source_line_id)
    WHERE source_line_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_product_price_result_active
    ON finance_product_price_observations(research_result_id, normalized_item_id)
    WHERE research_result_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_product_price_history
    ON finance_product_price_observations(space_id, normalized_item_id, observed_on DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_product_comparisons (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    normalized_item_id TEXT NOT NULL,
    research_result_id TEXT NOT NULL,
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    actual_quantity_decimal TEXT NOT NULL,
    actual_spend_minor INTEGER NOT NULL CHECK (actual_spend_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    comparison_mode TEXT NOT NULL CHECK (comparison_mode IN ('EXACT', 'RANGE')),
    candidate_low_minor INTEGER NOT NULL CHECK (candidate_low_minor >= 0),
    candidate_high_minor INTEGER NOT NULL CHECK (candidate_high_minor >= candidate_low_minor),
    saving_low_minor INTEGER NOT NULL,
    saving_high_minor INTEGER NOT NULL CHECK (saving_high_minor >= saving_low_minor),
    unmatched_observation_count INTEGER NOT NULL DEFAULT 0 CHECK (
        unmatched_observation_count >= 0
    ),
    confidence_bps INTEGER NOT NULL CHECK (confidence_bps BETWEEN 0 AND 10000),
    overlap_group TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    data_through_date TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN (
        'OPEN', 'ACCEPTED', 'DISMISSED', 'SUPERSEDED'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_product_comparison_identity
    ON finance_product_comparisons(
        space_id, normalized_item_id, research_result_id, period_start, period_end
    ) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_product_comparison_overlap
    ON finance_product_comparisons(space_id, overlap_group, status)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_opportunity_actions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    comparison_id TEXT NOT NULL,
    overlap_group TEXT NOT NULL,
    action_kind TEXT NOT NULL CHECK (action_kind IN ('PREFERENCE', 'HABIT_EXPERIMENT')),
    action_payload_json TEXT NOT NULL,
    target_preference_id TEXT,
    status TEXT NOT NULL CHECK (status IN ('CREATED', 'READY_FOR_CONFIRMATION')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_opportunity_action_comparison
    ON finance_opportunity_actions(comparison_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_opportunity_action_overlap
    ON finance_opportunity_actions(space_id, overlap_group) WHERE deleted_at IS NULL;

-- HL is report-only. Chain sources contain a labelled public address and no
-- credentials, signing keys, secrets, RPC URL or trading capability.
CREATE TABLE IF NOT EXISTS finance_asset_import_previews (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind = 'HL_REPORT'),
    label TEXT NOT NULL,
    account_wrapper TEXT NOT NULL CHECK (account_wrapper IN (
        'ISA', 'SIPP', 'GENERAL', 'JUNIOR_ISA', 'OTHER'
    )),
    as_of_date TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    cash_value_minor INTEGER NOT NULL CHECK (cash_value_minor >= 0),
    holdings_json TEXT NOT NULL,
    activities_json TEXT NOT NULL DEFAULT '[]',
    reported_total_minor INTEGER CHECK (reported_total_minor IS NULL OR reported_total_minor >= 0),
    calculated_known_total_minor INTEGER NOT NULL CHECK (calculated_known_total_minor >= 0),
    unknown_value_count INTEGER NOT NULL CHECK (unknown_value_count >= 0),
    reconciliation_difference_minor INTEGER,
    status TEXT NOT NULL DEFAULT 'PREVIEWED' CHECK (status IN (
        'PREVIEWED', 'CONFIRMED', 'EXPIRED'
    )),
    expires_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_asset_preview_space_status
    ON finance_asset_import_previews(space_id, status, expires_at)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_asset_sources (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN (
        'HL_REPORT', 'MANUAL_PORTFOLIO', 'SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC'
    )),
    label TEXT NOT NULL,
    public_address TEXT,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PAUSED')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (source_kind IN ('HL_REPORT', 'MANUAL_PORTFOLIO') AND public_address IS NULL)
        OR (source_kind IN ('SOLANA_PUBLIC', 'HYPERLIQUID_PUBLIC') AND public_address IS NOT NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_asset_public_address
    ON finance_asset_sources(space_id, source_kind, public_address)
    WHERE public_address IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_asset_sources_space
    ON finance_asset_sources(space_id, status, label) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_manual_portfolio_space
    ON finance_asset_sources(space_id)
    WHERE source_kind = 'MANUAL_PORTFOLIO' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_asset_snapshots (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    as_of_at TEXT NOT NULL,
    snapshot_kind TEXT NOT NULL CHECK (snapshot_kind IN ('REVIEWED_REPORT', 'WATCH_ONLY')),
    data_status TEXT NOT NULL CHECK (data_status IN ('COMPLETE', 'PARTIAL')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_asset_snapshot_source_time
    ON finance_asset_snapshots(source_id, as_of_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_asset_snapshots_space_time
    ON finance_asset_snapshots(space_id, as_of_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_asset_report_activities (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    activity_type TEXT NOT NULL CHECK (activity_type IN (
        'CONTRIBUTION', 'WITHDRAWAL', 'BUY', 'SELL', 'INCOME', 'FEE'
    )),
    occurred_on TEXT NOT NULL,
    amount_minor INTEGER NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    description TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_asset_activity_snapshot_date
    ON finance_asset_report_activities(snapshot_id, occurred_on, id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_asset_activity_space_date
    ON finance_asset_report_activities(
        space_id, family_id, occurred_on, snapshot_id, id
    ) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_positions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    snapshot_id TEXT NOT NULL,
    asset_key TEXT NOT NULL,
    asset_name TEXT NOT NULL,
    asset_class TEXT NOT NULL CHECK (asset_class IN (
        'OPERATING_CASH', 'PROTECTED_RESERVE', 'GOAL_CASH', 'ACCESSIBLE_SAVINGS',
        'BROKERAGE_INVESTMENT', 'PENSION_LOCKED', 'STABLE_CRYPTO',
        'VOLATILE_CRYPTO', 'PROPERTY', 'OTHER_ASSET', 'LIABILITY'
    )),
    position_kind TEXT NOT NULL CHECK (position_kind IN (
        'HOLDING', 'DEBT', 'EQUITY', 'EXPOSURE', 'UNREALISED_PNL'
    )),
    include_in_net_worth INTEGER NOT NULL DEFAULT 1 CHECK (
        include_in_net_worth IN (0, 1)
    ),
    quantity_decimal TEXT NOT NULL,
    quantity_unit TEXT NOT NULL,
    instrument_id_kind TEXT CHECK (instrument_id_kind IS NULL OR instrument_id_kind IN (
        'ISIN', 'SEDOL', 'TICKER', 'OTHER'
    )),
    instrument_id TEXT,
    quote_symbol TEXT,
    quote_currency TEXT,
    cost_basis_minor INTEGER CHECK (cost_basis_minor IS NULL OR cost_basis_minor >= 0),
    cost_basis_currency TEXT CHECK (
        cost_basis_currency IS NULL OR (
            length(cost_basis_currency) = 3 AND cost_basis_currency = upper(cost_basis_currency)
        )
    ),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_position_snapshot_key_kind
    ON finance_positions(snapshot_id, asset_key, position_kind) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_valuations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    position_id TEXT NOT NULL,
    valuation_status TEXT NOT NULL CHECK (valuation_status IN ('KNOWN', 'UNKNOWN')),
    value_minor INTEGER,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    unit_price_minor INTEGER,
    price_source TEXT,
    observed_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (
        (valuation_status = 'KNOWN' AND value_minor IS NOT NULL)
        OR (valuation_status = 'UNKNOWN' AND value_minor IS NULL AND unit_price_minor IS NULL)
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_valuation_position_active
    ON finance_valuations(position_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_valuations_space_observed
    ON finance_valuations(space_id, observed_at DESC) WHERE deleted_at IS NULL;

-- Public end-of-day prices are cached separately from reviewed holdings. A
-- failed refresh leaves these immutable observations in place, so the latest
-- known value remains useful while markets are shut or a provider is offline.
CREATE TABLE IF NOT EXISTS finance_market_price_observations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    asset_key TEXT NOT NULL,
    quote_symbol TEXT NOT NULL,
    quote_currency TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    unit_price_minor INTEGER NOT NULL CHECK (unit_price_minor >= 0),
    observed_at TEXT NOT NULL,
    source_label TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_market_price_source_asset_time
    ON finance_market_price_observations(source_id, asset_key, observed_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_market_price_space_time
    ON finance_market_price_observations(space_id, observed_at DESC)
    WHERE deleted_at IS NULL;

-- Property, other assets, externally valued pensions and debts use reviewed
-- dated values. They never contain account credentials or trading controls.
CREATE TABLE IF NOT EXISTS finance_manual_assets (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    name TEXT NOT NULL,
    asset_class TEXT NOT NULL CHECK (asset_class IN (
        'PENSION_LOCKED', 'PROPERTY', 'OTHER_ASSET', 'LIABILITY'
    )),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ARCHIVED')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_manual_assets_space
    ON finance_manual_assets(space_id, status, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_manual_asset_values (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    as_of_at TEXT NOT NULL,
    value_minor INTEGER NOT NULL CHECK (value_minor >= 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    source_label TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_manual_asset_item_time
    ON finance_manual_asset_values(item_id, as_of_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_manual_asset_values_space_time
    ON finance_manual_asset_values(space_id, as_of_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS calendar_sources (
    id TEXT PRIMARY KEY,
    family_id TEXT NOT NULL,
    name TEXT NOT NULL,
    encrypted_url TEXT NOT NULL,
    hostname TEXT NOT NULL,
    assigned_to TEXT,
    source_kind TEXT NOT NULL DEFAULT 'ics' CHECK (source_kind IN ('ics', 'school_rugby')),
    config_json TEXT,
    color TEXT NOT NULL DEFAULT '#2563EB',
    enabled INTEGER NOT NULL DEFAULT 1,
    etag TEXT,
    last_modified TEXT,
    last_synced_at TEXT,
    last_success_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_calendar_sources_family ON calendar_sources(family_id);
CREATE INDEX IF NOT EXISTS idx_calendar_sources_enabled ON calendar_sources(enabled, deleted_at);

CREATE TABLE IF NOT EXISTS calendar_feed_tokens (
    id TEXT PRIMARY KEY,
    family_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    token_prefix TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_feed_tokens_hash_active
    ON calendar_feed_tokens(token_hash) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_calendar_feed_tokens_family ON calendar_feed_tokens(family_id);

CREATE TABLE IF NOT EXISTS reminder_preferences (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    event_reminders_enabled INTEGER NOT NULL DEFAULT 1,
    event_minutes_before INTEGER NOT NULL DEFAULT 30,
    task_reminders_enabled INTEGER NOT NULL DEFAULT 1,
    morning_summary_enabled INTEGER NOT NULL DEFAULT 1,
    morning_summary_time TEXT NOT NULL DEFAULT '07:00',
    evening_summary_enabled INTEGER NOT NULL DEFAULT 1,
    evening_summary_time TEXT NOT NULL DEFAULT '19:00',
    quiet_start TEXT NOT NULL DEFAULT '21:00',
    quiet_end TEXT NOT NULL DEFAULT '07:00',
    privacy_mode INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reminder_preferences_user_active
    ON reminder_preferences(user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reminder_preferences_family ON reminder_preferences(family_id);

CREATE TABLE IF NOT EXISTS coordination_actions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    action_kind TEXT NOT NULL CHECK (action_kind IN ('tomorrow_ack', 'load_later')),
    entity_id TEXT,
    target_date TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_coordination_actions_user
    ON coordination_actions(user_id, action_kind, target_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_coordination_actions_entity
    ON coordination_actions(family_id, entity_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS share_capture_drafts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    encrypted_text TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_share_capture_drafts_owner
    ON share_capture_drafts(user_id, expires_at) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS web_push_subscriptions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    endpoint_hash TEXT NOT NULL,
    encrypted_subscription TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_web_push_endpoint_active
    ON web_push_subscriptions(endpoint_hash) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_web_push_user ON web_push_subscriptions(user_id, deleted_at);

CREATE TABLE IF NOT EXISTS apns_device_registrations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    encrypted_device_token TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
    bundle_id TEXT NOT NULL,
    app_version TEXT,
    last_registered_at TEXT NOT NULL,
    last_error_code TEXT,
    last_error_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_apns_device_token_active
    ON apns_device_registrations(token_hash) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_apns_device_user
    ON apns_device_registrations(user_id, deleted_at);

CREATE TABLE IF NOT EXISTS reminder_deliveries (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    subscription_id TEXT NOT NULL,
    reminder_key TEXT NOT NULL,
    delivered_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reminder_delivery_dedupe
    ON reminder_deliveries(subscription_id, reminder_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reminder_deliveries_created ON reminder_deliveries(created_at);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    assigned_to TEXT,
    due_date TEXT,
    completed_at TEXT,
    category TEXT DEFAULT 'other' CHECK (category IN ('bins', 'household', 'shopping', 'admin', 'other')),
    recurrence_rule TEXT,
    priority INTEGER DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),
    actionable_from TEXT,
    source_document_id TEXT,
    source_event_id TEXT,
    prep_occurrence_id TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned ON tasks(assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_deleted ON tasks(deleted_at);
CREATE INDEX IF NOT EXISTS idx_tasks_family ON tasks(family_id);

-- Reusable, deterministic preparation checklists suggested from calendar events.
CREATE TABLE IF NOT EXISTS event_prep_templates (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    match_terms TEXT NOT NULL,
    items TEXT NOT NULL,
    lead_hours INTEGER NOT NULL DEFAULT 24 CHECK (lead_hours BETWEEN 0 AND 168),
    assigned_to TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_event_prep_templates_family
    ON event_prep_templates(family_id, enabled) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS event_prep_occurrences (
    id TEXT PRIMARY KEY,
    template_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    occurrence_start TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('added', 'dismissed')),
    task_ids TEXT NOT NULL DEFAULT '[]',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_event_prep_occurrence_active
    ON event_prep_occurrences(family_id, template_id, event_id, occurrence_start)
    WHERE deleted_at IS NULL;

-- Secure family document store and capture inbox. Files live on the mounted data
-- volume; only metadata and the storage-relative key are kept in SQLite.
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    storage_key TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'file' CHECK (source IN ('scan', 'photo', 'file', 'text', 'share')),
    category TEXT NOT NULL DEFAULT 'other' CHECK (category IN ('school', 'medical', 'childcare', 'identity', 'finance', 'activities', 'household', 'other')),
    category_confidence REAL CHECK (category_confidence IS NULL OR category_confidence BETWEEN 0 AND 1),
    status TEXT NOT NULL DEFAULT 'inbox' CHECK (status IN ('inbox', 'filed', 'archived', 'failed')),
    document_date TEXT,
    document_date_confidence REAL CHECK (document_date_confidence IS NULL OR document_date_confidence BETWEEN 0 AND 1),
    page_count INTEGER NOT NULL DEFAULT 1,
    extracted_text TEXT,
    notes TEXT,
    processor TEXT NOT NULL DEFAULT 'device' CHECK (processor IN ('device', 'hermes', 'fallback')),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_documents_family_created ON documents(family_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_documents_family_status ON documents(family_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_documents_sha256 ON documents(family_id, sha256) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS document_people (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    person_id TEXT NOT NULL,
    person_type TEXT NOT NULL CHECK (person_type IN ('user', 'child')),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_document_people_active
    ON document_people(document_id, person_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_document_people_person
    ON document_people(family_id, person_id, document_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS capture_suggestions (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('event', 'task')),
    title TEXT NOT NULL,
    details TEXT,
    start_time TEXT,
    end_time TEXT,
    due_date TEXT,
    all_day INTEGER NOT NULL DEFAULT 1,
    assigned_to TEXT,
    confidence REAL NOT NULL DEFAULT 0.5 CHECK (confidence BETWEEN 0 AND 1),
    source_text TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'dismissed')),
    result_id TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_capture_suggestions_document
    ON capture_suggestions(document_id, status, created_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_capture_suggestions_family_status
    ON capture_suggestions(family_id, status, created_at DESC) WHERE deleted_at IS NULL;

-- Incoming information becomes a reviewable family commitment before any
-- calendar event, task or preparation item is written. One commitment can
-- represent a whole school message or travel dossier rather than forcing each
-- extracted fact through an unrelated CRUD screen.
CREATE TABLE IF NOT EXISTS family_commitments (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (
        kind IN ('school', 'invitation', 'outing', 'childcare', 'appointment', 'travel')
    ),
    visibility TEXT NOT NULL DEFAULT 'family'
        CHECK (visibility IN ('family', 'owner')),
    owner_user_id TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT,
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'action_required', 'ready', 'confirmed', 'declined')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    plan_json TEXT NOT NULL,
    external_action_status TEXT NOT NULL DEFAULT 'not_required'
        CHECK (external_action_status IN ('not_required', 'pending', 'completed', 'declined')),
    external_action_outcome TEXT,
    external_action_completed_at TEXT,
    group_key TEXT,
    dedupe_key TEXT,
    interpretation_processor TEXT
        CHECK (interpretation_processor IS NULL OR interpretation_processor IN ('typed', 'fallback', 'hermes')),
    supersedes_id TEXT,
    change_summary_json TEXT,
    confirmed_at TEXT,
    declined_at TEXT,
    decline_reason TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    updated_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_family_commitments_family_status
    ON family_commitments(family_id, status, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_family_commitments_owner_status
    ON family_commitments(owner_user_id, status, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_family_commitments_group
    ON family_commitments(family_id, group_key, updated_at DESC)
    WHERE group_key IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_family_commitments_dedupe
    ON family_commitments(family_id, dedupe_key)
    WHERE dedupe_key IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS family_commitment_sources (
    id TEXT PRIMARY KEY,
    commitment_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('document', 'email', 'share', 'manual', 'provider')),
    document_id TEXT,
    label TEXT,
    provider_reference TEXT,
    source_url TEXT,
    observed_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_family_commitment_sources_active
    ON family_commitment_sources(family_id, commitment_id, id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_family_commitment_sources_document
    ON family_commitment_sources(family_id, document_id)
    WHERE document_id IS NOT NULL AND deleted_at IS NULL;

-- Stable result relations form the confirmation receipt and make retries
-- exactly-once even when a client loses the original HTTP response.
CREATE TABLE IF NOT EXISTS family_commitment_results (
    id TEXT PRIMARY KEY,
    commitment_id TEXT NOT NULL,
    source_item_id TEXT NOT NULL,
    result_type TEXT NOT NULL
        CHECK (result_type IN ('calendar_event', 'task', 'preparation_task')),
    result_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_family_commitment_results_active
    ON family_commitment_results(family_id, commitment_id, source_item_id, result_type, result_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_family_commitment_results_target
    ON family_commitment_results(family_id, result_type, result_id)
    WHERE deleted_at IS NULL;

-- Hermes can propose only these short-lived, server-validated actions. The model
-- never receives credentials and cannot execute an action directly.
CREATE TABLE IF NOT EXISTS assistant_actions (
    id TEXT PRIMARY KEY,
    action_type TEXT NOT NULL CHECK (
        action_type IN ('calendar_event', 'home_lights', 'create_task', 'complete_task', 'shopping_item')
    ),
    payload TEXT NOT NULL,
    summary TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'executing', 'executed', 'declined', 'failed', 'expired')),
    expires_at TEXT NOT NULL,
    executed_at TEXT,
    result_id TEXT,
    error TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_assistant_actions_family_status
    ON assistant_actions(family_id, status, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_assistant_actions_expiry
    ON assistant_actions(expires_at) WHERE status = 'pending' AND deleted_at IS NULL;

-- Durable abuse counters survive API restarts. Rows are short-lived and pruned
-- whenever a protected action reserves budget.
CREATE TABLE IF NOT EXISTS security_rate_limit_events (
    id TEXT PRIMARY KEY,
    rate_key TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_security_rate_limit_key_created
    ON security_rate_limit_events(rate_key, created_at);

CREATE TABLE IF NOT EXISTS document_inbox_addresses (
    id TEXT PRIMARY KEY,
    address TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_document_inbox_address_active
    ON document_inbox_addresses(LOWER(address)) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_document_inbox_family_active
    ON document_inbox_addresses(family_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS inbound_email_messages (
    id TEXT PRIMARY KEY,
    provider_message_id TEXT NOT NULL,
    internet_message_id TEXT,
    from_address TEXT NOT NULL,
    to_address TEXT NOT NULL,
    subject TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'processing'
        CHECK (status IN ('processing', 'processed', 'ignored', 'failed')),
    document_ids TEXT,
    error TEXT,
    lease_token TEXT,
    lease_expires_at TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_inbound_email_provider_message
    ON inbound_email_messages(provider_message_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_inbound_email_family_created
    ON inbound_email_messages(family_id, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS task_assignments (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    assignee_id TEXT NOT NULL,
    assignee_type TEXT NOT NULL CHECK (assignee_type IN ('user', 'child')),
    completed_at TEXT,
    completed_by TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_task_assignments_task ON task_assignments(task_id);
CREATE INDEX IF NOT EXISTS idx_task_assignments_assignee ON task_assignments(assignee_id);
CREATE INDEX IF NOT EXISTS idx_task_assignments_deleted ON task_assignments(deleted_at);
CREATE INDEX IF NOT EXISTS idx_task_assignments_family ON task_assignments(family_id);

CREATE TABLE IF NOT EXISTS medicine_types (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    min_hours_between_doses REAL NOT NULL DEFAULT 4.0,
    max_doses_24h INTEGER NOT NULL DEFAULT 4,
    notes TEXT,
    color TEXT,
    default_dose_amount TEXT,
    child_id TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_medicine_types_child ON medicine_types(child_id);
CREATE INDEX IF NOT EXISTS idx_medicine_types_family ON medicine_types(family_id);

CREATE TABLE IF NOT EXISTS medicine_doses (
    id TEXT PRIMARY KEY,
    medicine_type_id TEXT,
    child_id TEXT NOT NULL,
    given_at TEXT NOT NULL,
    given_by TEXT NOT NULL,
    dose_amount TEXT,
    medicine_name TEXT,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    safety_warnings_json TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_medicine_doses_type ON medicine_doses(medicine_type_id);
CREATE INDEX IF NOT EXISTS idx_medicine_doses_child ON medicine_doses(child_id);
CREATE INDEX IF NOT EXISTS idx_medicine_doses_given_at ON medicine_doses(given_at);
CREATE INDEX IF NOT EXISTS idx_medicine_doses_deleted ON medicine_doses(deleted_at);
CREATE INDEX IF NOT EXISTS idx_medicine_doses_family ON medicine_doses(family_id);

CREATE TABLE IF NOT EXISTS naps (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    sleep_type TEXT NOT NULL DEFAULT 'nap' CHECK (sleep_type IN ('nap', 'bedtime')),
    location TEXT,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_naps_child ON naps(child_id);
CREATE INDEX IF NOT EXISTS idx_naps_started ON naps(started_at);
CREATE INDEX IF NOT EXISTS idx_naps_deleted ON naps(deleted_at);
CREATE INDEX IF NOT EXISTS idx_naps_family ON naps(family_id);

CREATE TABLE IF NOT EXISTS dog_activities (
    id TEXT PRIMARY KEY,
    activity_type TEXT NOT NULL CHECK (activity_type IN ('walk', 'feed', 'feed_breakfast', 'feed_dinner', 'vet', 'medication')),
    started_at TEXT NOT NULL,
    ended_at TEXT,
    notes TEXT,
    is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0,1)),
    done_by TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_dog_activities_type ON dog_activities(activity_type);
CREATE INDEX IF NOT EXISTS idx_dog_activities_started ON dog_activities(started_at);
CREATE INDEX IF NOT EXISTS idx_dog_activities_deleted ON dog_activities(deleted_at);
CREATE INDEX IF NOT EXISTS idx_dog_activities_family ON dog_activities(family_id);

-- Structured vaccination history for the family dog. This deliberately lives
-- outside dog_activities: vaccine name, administration date and renewal date
-- are durable health-record fields rather than a one-off activity note.
CREATE TABLE IF NOT EXISTS dog_vaccinations (
    id TEXT PRIMARY KEY,
    vaccine_name TEXT NOT NULL,
    given_on TEXT NOT NULL,
    next_due_on TEXT,
    notes TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_dog_vaccinations_family_given
    ON dog_vaccinations(family_id, given_on DESC) WHERE deleted_at IS NULL;

-- One family dog profile keeps daily care times and the important facts that
-- should be available during a vet call without crowding the daily care view.
CREATE TABLE IF NOT EXISTS dog_profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT 'Dog',
    date_of_birth TEXT,
    breed TEXT,
    microchip_number TEXT,
    insurance_provider TEXT,
    insurance_policy_number TEXT,
    vet_name TEXT,
    vet_phone TEXT,
    allergies TEXT,
    medicine_notes TEXT,
    breakfast_window_start TEXT NOT NULL DEFAULT '07:00',
    breakfast_window_end TEXT NOT NULL DEFAULT '09:00',
    walk_window_start TEXT NOT NULL DEFAULT '10:00',
    walk_window_end TEXT NOT NULL DEFAULT '14:00',
    dinner_window_start TEXT NOT NULL DEFAULT '17:00',
    dinner_window_end TEXT NOT NULL DEFAULT '19:00',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dog_profiles_family_active
    ON dog_profiles(family_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS dog_weights (
    id TEXT PRIMARY KEY,
    measured_on TEXT NOT NULL,
    weight_kg REAL NOT NULL CHECK (weight_kg > 0 AND weight_kg <= 200),
    notes TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_dog_weights_family_measured
    ON dog_weights(family_id, measured_on DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS dog_document_links (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'other'
        CHECK (role IN ('insurance', 'vet', 'microchip', 'medicine', 'other')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dog_document_links_active
    ON dog_document_links(family_id, document_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_dog_document_links_document
    ON dog_document_links(document_id);

CREATE TABLE IF NOT EXISTS birthdays (
    id TEXT PRIMARY KEY,
    person_name TEXT NOT NULL,
    date_of_birth TEXT NOT NULL,
    birth_year INTEGER,
    birth_month INTEGER CHECK (birth_month BETWEEN 1 AND 12),
    birth_day INTEGER CHECK (birth_day BETWEEN 1 AND 31),
    relationship TEXT DEFAULT 'friend' CHECK (relationship IN ('family', 'friend', 'school')),
    reminder_days_before INTEGER DEFAULT 7,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_birthdays_family ON birthdays(family_id);

CREATE TABLE IF NOT EXISTS birthday_preparations (
    id TEXT PRIMARY KEY,
    birthday_id TEXT NOT NULL,
    occurrence_year INTEGER NOT NULL,
    card_status TEXT NOT NULL DEFAULT 'not_started'
        CHECK (card_status IN ('not_started', 'to_buy', 'bought', 'written', 'sent')),
    card_message TEXT,
    celebration_status TEXT NOT NULL DEFAULT 'not_started'
        CHECK (celebration_status IN ('not_started', 'planning', 'planned')),
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_birthday_preparations_active
    ON birthday_preparations(family_id, birthday_id, occurrence_year)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS birthday_preparation_links (
    id TEXT PRIMARY KEY,
    birthday_id TEXT NOT NULL,
    occurrence_year INTEGER NOT NULL,
    record_type TEXT NOT NULL CHECK (record_type IN ('task', 'calendar_event')),
    record_id TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_birthday_preparation_links_active
    ON birthday_preparation_links(family_id, birthday_id, occurrence_year, record_type, record_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS meals (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    recipe_url TEXT,
    tags TEXT, -- JSON array
    ingredients TEXT, -- JSON array of {name, quantity, category}
    last_made_at TEXT,
    prep_minutes INTEGER,
    servings INTEGER,
    allergy_notes TEXT,
    preference_notes TEXT,
    not_for_us INTEGER NOT NULL DEFAULT 0,
    source TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_meals_family ON meals(family_id);

CREATE TABLE IF NOT EXISTS meal_plans (
    id TEXT PRIMARY KEY,
    meal_id TEXT NOT NULL,
    date TEXT NOT NULL,
    meal_type TEXT NOT NULL CHECK (meal_type IN ('breakfast', 'lunch', 'dinner')),
    notes TEXT,
    tired_household INTEGER NOT NULL DEFAULT 0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_meal_plans_date ON meal_plans(date);
CREATE INDEX IF NOT EXISTS idx_meal_plans_family ON meal_plans(family_id);

CREATE TABLE IF NOT EXISTS meal_ratings (
    id TEXT PRIMARY KEY,
    meal_plan_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 3),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_meal_ratings_plan ON meal_ratings(meal_plan_id);
CREATE INDEX IF NOT EXISTS idx_meal_ratings_child ON meal_ratings(child_id);
CREATE INDEX IF NOT EXISTS idx_meal_ratings_deleted ON meal_ratings(deleted_at);
CREATE INDEX IF NOT EXISTS idx_meal_ratings_family ON meal_ratings(family_id);

CREATE TABLE IF NOT EXISTS shopping_items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    quantity TEXT,
    category TEXT,
    meal_plan_id TEXT,
    checked INTEGER NOT NULL DEFAULT 0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_shopping_items_family ON shopping_items(family_id);

CREATE TABLE IF NOT EXISTS grocery_items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT,
    default_unit TEXT NOT NULL DEFAULT 'each',
    aliases TEXT, -- JSON array
    is_use_by_tracked INTEGER NOT NULL DEFAULT 0,
    tesco_hint TEXT,
    default_quantity REAL DEFAULT 1.0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_grocery_items_category ON grocery_items(category);
CREATE INDEX IF NOT EXISTS idx_grocery_items_deleted ON grocery_items(deleted_at);
CREATE INDEX IF NOT EXISTS idx_grocery_items_family ON grocery_items(family_id);

CREATE TABLE IF NOT EXISTS purchase_batches (
    id TEXT PRIMARY KEY,
    purchased_at TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'tesco',
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_purchase_batches_purchased ON purchase_batches(purchased_at);
CREATE INDEX IF NOT EXISTS idx_purchase_batches_deleted ON purchase_batches(deleted_at);
CREATE INDEX IF NOT EXISTS idx_purchase_batches_family ON purchase_batches(family_id);

CREATE TABLE IF NOT EXISTS purchases (
    id TEXT PRIMARY KEY,
    purchase_batch_id TEXT NOT NULL,
    grocery_item_id TEXT NOT NULL,
    qty REAL NOT NULL DEFAULT 1.0,
    unit TEXT NOT NULL DEFAULT 'each',
    raw_name TEXT,
    price_pence INTEGER,
    use_by_date TEXT,
    storage TEXT DEFAULT 'fridge' CHECK (storage IN ('fridge', 'freezer', 'pantry')),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_purchases_batch ON purchases(purchase_batch_id);
CREATE INDEX IF NOT EXISTS idx_purchases_item ON purchases(grocery_item_id);
CREATE INDEX IF NOT EXISTS idx_purchases_use_by ON purchases(use_by_date);
CREATE INDEX IF NOT EXISTS idx_purchases_deleted ON purchases(deleted_at);
CREATE INDEX IF NOT EXISTS idx_purchases_family ON purchases(family_id);

-- Tesco history is evidence about what was bought, not a claim about what is
-- currently in the pantry. Raw portability reports are parsed in memory and
-- discarded; only the bounded transaction facts below are retained.
CREATE TABLE IF NOT EXISTS tesco_history_imports (
    id TEXT PRIMARY KEY,
    source_sha256 TEXT NOT NULL,
    filename TEXT NOT NULL,
    parsed_order_count INTEGER NOT NULL CHECK (parsed_order_count >= 0),
    imported_order_count INTEGER NOT NULL CHECK (imported_order_count >= 0),
    line_count INTEGER NOT NULL CHECK (line_count >= 0),
    first_purchased_at TEXT,
    last_purchased_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tesco_history_import_hash_active
    ON tesco_history_imports(family_id, source_sha256) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tesco_history_import_family_time
    ON tesco_history_imports(family_id, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS tesco_history_orders (
    id TEXT PRIMARY KEY,
    import_id TEXT,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('data_export', 'receipt_email')),
    external_order_id TEXT,
    purchased_at TEXT NOT NULL,
    channel TEXT,
    store_name TEXT,
    total_pence INTEGER CHECK (total_pence IS NULL OR total_pence >= 0),
    currency TEXT NOT NULL DEFAULT 'GBP'
        CHECK (length(currency) = 3 AND currency = upper(currency)),
    source_fingerprint TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tesco_history_order_fingerprint_active
    ON tesco_history_orders(family_id, source_fingerprint) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tesco_history_order_family_date
    ON tesco_history_orders(family_id, purchased_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS tesco_history_lines (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL,
    external_product_id TEXT,
    product_name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    quantity REAL NOT NULL DEFAULT 1.0 CHECK (quantity > 0),
    unit TEXT,
    unit_price_pence INTEGER CHECK (unit_price_pence IS NULL OR unit_price_pence >= 0),
    line_total_pence INTEGER CHECK (line_total_pence IS NULL OR line_total_pence >= 0),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_tesco_history_lines_order
    ON tesco_history_lines(order_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tesco_history_lines_family_name
    ON tesco_history_lines(family_id, normalized_name, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS consumption_events (
    id TEXT PRIMARY KEY,
    grocery_item_id TEXT NOT NULL,
    event_at TEXT NOT NULL,
    amount REAL NOT NULL DEFAULT 1.0,
    unit TEXT NOT NULL DEFAULT 'each',
    event_type TEXT NOT NULL DEFAULT 'consumed' CHECK (event_type IN ('consumed', 'wasted', 'spilled')),
    source TEXT DEFAULT 'app' CHECK (source IN ('app', 'home_assistant')),
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_consumption_item ON consumption_events(grocery_item_id);
CREATE INDEX IF NOT EXISTS idx_consumption_event_at ON consumption_events(event_at);
CREATE INDEX IF NOT EXISTS idx_consumption_deleted ON consumption_events(deleted_at);
CREATE INDEX IF NOT EXISTS idx_consumption_family ON consumption_events(family_id);

CREATE TABLE IF NOT EXISTS health_data (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL CHECK (source IN ('strava', 'withings', 'apple_health')),
    data_type TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    metadata TEXT, -- JSON
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_data_source ON health_data(source);
CREATE INDEX IF NOT EXISTS idx_health_data_recorded ON health_data(recorded_at);
CREATE INDEX IF NOT EXISTS idx_health_data_family ON health_data(family_id);

CREATE TABLE IF NOT EXISTS homework_reading (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    book_title TEXT NOT NULL,
    minutes INTEGER NOT NULL,
    date TEXT NOT NULL,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_homework_reading_child ON homework_reading(child_id);
CREATE INDEX IF NOT EXISTS idx_homework_reading_family ON homework_reading(family_id);

CREATE TABLE IF NOT EXISTS homework_spellings (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    word_list TEXT NOT NULL, -- JSON array
    test_date TEXT NOT NULL,
    score INTEGER,
    practice_count INTEGER NOT NULL DEFAULT 0,
    completed_at TEXT,
    notes TEXT,
    link_url TEXT,
    source_document_id TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_homework_spellings_child ON homework_spellings(child_id);
CREATE INDEX IF NOT EXISTS idx_homework_spellings_family ON homework_spellings(family_id);

CREATE TABLE IF NOT EXISTS homework_spelling_sessions (
    id TEXT PRIMARY KEY,
    spellings_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    practised_at TEXT NOT NULL,
    attempts_json TEXT NOT NULL, -- JSON array of {word, correct}
    correct_count INTEGER NOT NULL,
    total_count INTEGER NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_homework_spelling_sessions_list
    ON homework_spelling_sessions(family_id, spellings_id, practised_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_homework_spelling_sessions_child
    ON homework_spelling_sessions(family_id, child_id, practised_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS growth_records (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    date TEXT NOT NULL,
    height_cm REAL,
    weight_kg REAL,
    head_circumference_cm REAL,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_growth_records_child ON growth_records(child_id);
CREATE INDEX IF NOT EXISTS idx_growth_records_family ON growth_records(family_id);

CREATE TABLE IF NOT EXISTS record_history (
    id TEXT PRIMARY KEY,
    table_name TEXT NOT NULL,
    record_id TEXT NOT NULL,
    previous_values TEXT NOT NULL, -- JSON
    changed_by TEXT,
    family_id TEXT,
    changed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_record_history_record ON record_history(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_record_history_family ON record_history(family_id);
CREATE INDEX IF NOT EXISTS idx_record_history_family_changed
    ON record_history(family_id, changed_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS sync_queue (
    id TEXT PRIMARY KEY,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    table_name TEXT NOT NULL,
    record_id TEXT NOT NULL,
    payload TEXT, -- JSON
    client_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    retry_count INTEGER NOT NULL DEFAULT 0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status);
CREATE INDEX IF NOT EXISTS idx_sync_queue_family ON sync_queue(family_id);

-- Completed client mutation responses. Installed clients attach a stable UUID to
-- every replayable JSON write so a lost response can be retried without creating
-- a second family record or repeating an action.
CREATE TABLE IF NOT EXISTS idempotency_records (
    id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL,
    owner_user_id TEXT NOT NULL,
    family_id TEXT,
    method TEXT NOT NULL,
    request_path TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body BLOB NOT NULL,
    response_content_type TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_idempotency_owner_operation
    ON idempotency_records(owner_user_id, operation_id);
CREATE INDEX IF NOT EXISTS idx_idempotency_expiry
    ON idempotency_records(expires_at);

-- A short-lived, owner-scoped record of allowlisted semantic interactions and
-- server-confirmed actions. Stable control/workflow keys are never derived from
-- labels or user content; request and response bodies never enter this boundary.
CREATE TABLE IF NOT EXISTS adoption_events (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    module TEXT NOT NULL,
    action TEXT NOT NULL,
    outcome TEXT NOT NULL,
    entry_source TEXT NOT NULL CHECK (entry_source IN ('ios', 'web', 'unknown')),
    effort TEXT NOT NULL CHECK (effort IN ('quick', 'standard', 'involved')),
    app_version TEXT NOT NULL,
    event_kind TEXT NOT NULL DEFAULT 'server_action' CHECK (
        event_kind IN ('server_action', 'screen_view', 'control', 'workflow')
    ),
    surface TEXT NOT NULL DEFAULT 'server',
    workflow TEXT,
    workflow_run_id TEXT,
    duration_bucket TEXT NOT NULL DEFAULT 'unknown' CHECK (
        duration_bucket IN ('under_10s', 'under_1m', 'under_5m', 'over_5m', 'unknown')
    ),
    interaction_count INTEGER CHECK (
        interaction_count IS NULL OR (interaction_count >= 0 AND interaction_count <= 100)
    ),
    connectivity TEXT NOT NULL DEFAULT 'unknown' CHECK (
        connectivity IN ('online', 'offline', 'queued', 'unknown')
    ),
    failure_class TEXT CHECK (
        failure_class IS NULL OR failure_class IN (
            'validation', 'network', 'authorization', 'conflict', 'provider',
            'server', 'cancelled', 'unknown'
        )
    ),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_adoption_owner_time
    ON adoption_events(user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_adoption_family_shared_time
    ON adoption_events(family_id, module, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_adoption_retention
    ON adoption_events(created_at) WHERE deleted_at IS NULL;
-- Indexes that reference columns added after the original adoption-events
-- release are created by _run_migrations, after those columns are present.

CREATE TABLE IF NOT EXISTS routine_items (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    name TEXT NOT NULL,
    color TEXT NOT NULL,
    days_of_week TEXT NOT NULL, -- JSON array of ints 0(Mon)-6(Sun)
    sort_order INTEGER DEFAULT 0,
    time_of_day TEXT,
    location TEXT,
    preparation_note TEXT,
    prep_template_id TEXT,
    reminder_minutes INTEGER,
    calendar_projection INTEGER NOT NULL DEFAULT 1 CHECK (calendar_projection IN (0, 1)),
    term_only INTEGER NOT NULL DEFAULT 1 CHECK (term_only IN (0, 1)),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_routine_items_person ON routine_items(person_id);
CREATE INDEX IF NOT EXISTS idx_routine_items_deleted ON routine_items(deleted_at);
CREATE INDEX IF NOT EXISTS idx_routine_items_family ON routine_items(family_id);

CREATE TABLE IF NOT EXISTS term_dates (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    label TEXT,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    user_overridden INTEGER NOT NULL DEFAULT 0 CHECK (user_overridden IN (0, 1)),
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_term_dates_person ON term_dates(person_id);
CREATE INDEX IF NOT EXISTS idx_term_dates_deleted ON term_dates(deleted_at);
CREATE INDEX IF NOT EXISTS idx_term_dates_family ON term_dates(family_id);

CREATE TABLE IF NOT EXISTS routine_term_overrides (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL UNIQUE,
    is_active INTEGER NOT NULL,
    expires_on TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_routine_term_overrides_person ON routine_term_overrides(person_id);
CREATE INDEX IF NOT EXISTS idx_routine_term_overrides_family ON routine_term_overrides(family_id);

-- Quiet, term-aware coordination markers shown directly in the planner. They
-- are intentionally not tasks: nobody has to complete or acknowledge them.
CREATE TABLE IF NOT EXISTS term_time_handoffs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('pickup', 'work_departure')),
    weekday INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    time_of_day TEXT NOT NULL,
    term_person_id TEXT NOT NULL,
    -- Populated only for work departures. Pickup is a child + time/window;
    -- the family decides who collects without formal assignment here.
    owner_user_id TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    updated_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_term_time_handoff_weekday_active
    ON term_time_handoffs(family_id, kind, weekday, term_person_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_term_time_handoff_term_person
    ON term_time_handoffs(family_id, term_person_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS term_time_handoff_overrides (
    id TEXT PRIMARY KEY,
    handoff_id TEXT NOT NULL,
    occurrence_date TEXT NOT NULL,
    time_of_day TEXT NOT NULL,
    owner_user_id TEXT,
    is_cancelled INTEGER NOT NULL DEFAULT 0 CHECK (is_cancelled IN (0, 1)),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    updated_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_term_time_handoff_override_active
    ON term_time_handoff_overrides(family_id, handoff_id, occurrence_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_term_time_handoff_override_date
    ON term_time_handoff_overrides(family_id, occurrence_date)
    WHERE deleted_at IS NULL;

-- School clubs are entered once as a calm term-time rule, then projected into
-- Calendar. A cancelled date is retained as an exception so the family can
-- still see that the session was deliberately cancelled rather than missing.
CREATE TABLE IF NOT EXISTS school_clubs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    child_id TEXT NOT NULL,
    weekday INTEGER NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    active_from TEXT NOT NULL,
    active_until TEXT,
    location TEXT,
    color TEXT NOT NULL DEFAULT '#2563EB',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    updated_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_school_clubs_family_child
    ON school_clubs(family_id, child_id, weekday) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_school_clubs_active_range
    ON school_clubs(family_id, active_from, active_until) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS school_club_exceptions (
    id TEXT PRIMARY KEY,
    club_id TEXT NOT NULL,
    occurrence_date TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'cancelled' CHECK (status = 'cancelled'),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    updated_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_school_club_exception_active
    ON school_club_exceptions(family_id, club_id, occurrence_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_school_club_exception_date
    ON school_club_exceptions(family_id, occurrence_date) WHERE deleted_at IS NULL;

-- Toast booking forms are parsed deterministically. The original Word file is
-- transient because it contains contact details; only the reviewed schedule
-- and its digest cross the persistence boundary. Non-booked days are retained
-- so a later corrected form can explicitly remove an earlier booking.
CREATE TABLE IF NOT EXISTS toast_club_imports (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    source_sha256 TEXT NOT NULL,
    source_title TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    valid_to TEXT NOT NULL,
    base_start_time TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_toast_club_import_digest_active
    ON toast_club_imports(family_id, source_sha256) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_toast_club_import_child_range
    ON toast_club_imports(family_id, child_id, valid_from, valid_to)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS toast_club_import_days (
    id TEXT PRIMARY KEY,
    import_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    booking_date TEXT NOT NULL,
    session_code TEXT CHECK (session_code IS NULL OR session_code IN ('1', '2')),
    pickup_end TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_toast_club_import_day_active
    ON toast_club_import_days(family_id, import_id, booking_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_toast_club_day_child_date
    ON toast_club_import_days(family_id, child_id, booking_date)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS holiday_dates (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    date TEXT NOT NULL,
    label TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_holiday_dates_person ON holiday_dates(person_id);
CREATE INDEX IF NOT EXISTS idx_holiday_dates_date ON holiday_dates(date);
CREATE INDEX IF NOT EXISTS idx_holiday_dates_deleted ON holiday_dates(deleted_at);
CREATE INDEX IF NOT EXISTS idx_holiday_dates_family ON holiday_dates(family_id);

-- Illness tracking
CREATE TABLE IF NOT EXISTS illnesses (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_illnesses_child ON illnesses(child_id);
CREATE INDEX IF NOT EXISTS idx_illnesses_started ON illnesses(started_at);
CREATE INDEX IF NOT EXISTS idx_illnesses_ended ON illnesses(ended_at);
CREATE INDEX IF NOT EXISTS idx_illnesses_deleted ON illnesses(deleted_at);
CREATE INDEX IF NOT EXISTS idx_illnesses_family ON illnesses(family_id);

CREATE TABLE IF NOT EXISTS temperature_readings (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    illness_id TEXT,
    value_celsius REAL NOT NULL,
    recorded_at TEXT NOT NULL,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_temp_readings_child ON temperature_readings(child_id);
CREATE INDEX IF NOT EXISTS idx_temp_readings_illness ON temperature_readings(illness_id);
CREATE INDEX IF NOT EXISTS idx_temp_readings_recorded ON temperature_readings(recorded_at);
CREATE INDEX IF NOT EXISTS idx_temp_readings_deleted ON temperature_readings(deleted_at);
CREATE INDEX IF NOT EXISTS idx_temp_readings_family ON temperature_readings(family_id);

-- Star Charts
CREATE TABLE IF NOT EXISTS star_charts (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT 'Star Chart',
    grid_rows INTEGER NOT NULL DEFAULT 5,
    grid_columns INTEGER NOT NULL DEFAULT 5,
    reward_amount_pence INTEGER NOT NULL DEFAULT 500,
    completed_at TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_star_charts_child ON star_charts(child_id);
CREATE INDEX IF NOT EXISTS idx_star_charts_deleted ON star_charts(deleted_at);
CREATE INDEX IF NOT EXISTS idx_star_charts_family ON star_charts(family_id);

CREATE TABLE IF NOT EXISTS star_chart_stars (
    id TEXT PRIMARY KEY,
    chart_id TEXT NOT NULL,
    row_index INTEGER NOT NULL,
    col_index INTEGER NOT NULL,
    awarded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_star_chart_stars_chart ON star_chart_stars(chart_id);
CREATE INDEX IF NOT EXISTS idx_star_chart_stars_deleted ON star_chart_stars(deleted_at);
CREATE INDEX IF NOT EXISTS idx_star_chart_stars_family ON star_chart_stars(family_id);

CREATE TABLE IF NOT EXISTS star_chart_balances (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL UNIQUE,
    balance_pence INTEGER NOT NULL DEFAULT 0,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_star_chart_balances_family ON star_chart_balances(family_id);

CREATE TABLE IF NOT EXISTS star_chart_balance_transactions (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    amount_pence INTEGER NOT NULL,
    reason TEXT NOT NULL CHECK (reason IN ('chart_completed', 'manual_adjustment', 'payout')),
    chart_id TEXT,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_star_chart_transactions_child ON star_chart_balance_transactions(child_id);
CREATE INDEX IF NOT EXISTS idx_star_chart_transactions_deleted ON star_chart_balance_transactions(deleted_at);
CREATE INDEX IF NOT EXISTS idx_star_chart_transactions_family ON star_chart_balance_transactions(family_id);

-- Composite indexes for request hot paths. Partial indexes keep soft-deleted rows
-- out of the working set while preserving them for history and sync.
CREATE INDEX IF NOT EXISTS idx_users_family_name_active
    ON users(family_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_children_family_dob_active
    ON children(family_id, date_of_birth) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_calendar_family_start_active
    ON calendar_events(family_id, start_time) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_family_created_active
    ON tasks(family_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_family_due_active
    ON tasks(family_id, due_date) WHERE deleted_at IS NULL AND completed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_assignments_task_created_active
    ON task_assignments(task_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_assignments_family_assignee_active
    ON task_assignments(family_id, assignee_id, task_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_medicine_types_family_child_active
    ON medicine_types(family_id, child_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_medicine_doses_family_child_given_active
    ON medicine_doses(family_id, child_id, given_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_medicine_doses_family_given_active
    ON medicine_doses(family_id, given_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_naps_family_started_active
    ON naps(family_id, started_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_dog_family_type_started_active
    ON dog_activities(family_id, activity_type, started_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_meals_family_name_active
    ON meals(family_id, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_meal_plans_family_date_active
    ON meal_plans(family_id, date, meal_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_shopping_family_created_active
    ON shopping_items(family_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_family_source_type_recorded_active
    ON health_data(family_id, source, data_type, recorded_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_growth_family_child_date_active
    ON growth_records(family_id, child_id, date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_routine_family_sort_active
    ON routine_items(family_id, sort_order, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_term_dates_family_start_active
    ON term_dates(family_id, start_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_temperature_family_child_recorded_active
    ON temperature_readings(family_id, child_id, recorded_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_illnesses_family_active_started
    ON illnesses(family_id, ended_at, started_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_star_charts_family_created_active
    ON star_charts(family_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_star_chart_stars_chart_awarded_active
    ON star_chart_stars(chart_id, awarded_at) WHERE deleted_at IS NULL;

-- School Brain gap-detection findings — things nobody put in the system,
-- spotted by a user-requested cross-check of letters, calendar, tasks and weather.
CREATE TABLE IF NOT EXISTS family_insights (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('missing_event', 'prep', 'weather', 'conflict', 'other')),
    message TEXT NOT NULL,
    detail TEXT,
    target_date TEXT,
    source_document_id TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'dismissed')),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_family_insights_family_status
    ON family_insights(family_id, status, target_date);

-- Photographed kids' drawings with deliberately rough dating.
CREATE TABLE IF NOT EXISTS artworks (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    title TEXT,
    notes TEXT,
    medium TEXT,
    story TEXT,
    child_quote TEXT,
    school_year TEXT,
    approx_date TEXT NOT NULL,
    favourite INTEGER NOT NULL DEFAULT 0 CHECK (favourite IN (0, 1)),
    include_in_yearbook INTEGER NOT NULL DEFAULT 1 CHECK (include_in_yearbook IN (0, 1)),
    yearbook_position INTEGER,
    media_type TEXT NOT NULL,
    storage_key TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_media_type TEXT,
    original_storage_key TEXT,
    original_file_size INTEGER,
    rotation_degrees INTEGER NOT NULL DEFAULT 0
        CHECK (rotation_degrees IN (0, 90, 180, 270)),
    enhanced INTEGER NOT NULL DEFAULT 0 CHECK (enhanced IN (0, 1)),
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_artworks_family_child
    ON artworks(family_id, child_id, approx_date DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_artworks_family_client
    ON artworks(family_id, client_id)
    WHERE client_id IS NOT NULL AND deleted_at IS NULL;

-- Cached Bismarck-composed narrative for a child's yearbook (keyed by content
-- hash so it regenerates only when the underlying facts change).
CREATE TABLE IF NOT EXISTS yearbook_narratives (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    year INTEGER NOT NULL,
    narrative TEXT NOT NULL,
    facts_hash TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_yearbook_narratives_child_year
    ON yearbook_narratives(family_id, child_id, year) WHERE deleted_at IS NULL;

-- Household renewals and expiries (passport, MOT, insurance, subscriptions) so
-- nothing lapses unnoticed. Surfaced as insights ahead of the due date.
CREATE TABLE IF NOT EXISTS renewals (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'other'
        CHECK (category IN ('document', 'vehicle', 'insurance', 'subscription',
                            'utility', 'membership', 'medical', 'other')),
    due_date TEXT NOT NULL,
    recurrence_months INTEGER,
    cost_pence INTEGER,
    reminder_days_before INTEGER NOT NULL DEFAULT 21,
    source_document_id TEXT,
    finance_commitment_id TEXT,
    provider TEXT,
    reference TEXT,
    action_url TEXT,
    comparison_url TEXT,
    contact_url TEXT,
    responsible_user_id TEXT,
    reminders_enabled INTEGER NOT NULL DEFAULT 1,
    escalate_after_days INTEGER DEFAULT 3,
    show_in_calendar INTEGER NOT NULL DEFAULT 0,
    show_in_tasks INTEGER NOT NULL DEFAULT 0,
    task_completed_at TEXT,
    task_completed_by TEXT,
    notes TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_renewals_family_due
    ON renewals(family_id, due_date) WHERE deleted_at IS NULL;
-- idx_renewals_finance_commitment_active is created by _run_migrations after
-- finance_commitment_id has been added to databases with a legacy renewals table.

CREATE TABLE IF NOT EXISTS renewal_checklist_items (
    id TEXT PRIMARY KEY,
    renewal_id TEXT NOT NULL,
    title TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    checked_at TEXT,
    checked_by TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_renewal_checklist_active
    ON renewal_checklist_items(family_id, renewal_id, position)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS renewal_outcomes (
    id TEXT PRIMARY KEY,
    renewal_id TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('renewed', 'not_renewing')),
    due_date TEXT NOT NULL,
    decided_at TEXT NOT NULL,
    cost_pence INTEGER,
    next_due_date TEXT,
    notes TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_renewal_outcomes_history
    ON renewal_outcomes(family_id, renewal_id, decided_at DESC)
    WHERE deleted_at IS NULL;

-- Read-only Example Town library monitoring. The catalogue card and
-- PIN are encrypted before storage and are never returned by an API response.
CREATE TABLE IF NOT EXISTS library_accounts (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL DEFAULT 'local_authority_spydus'
        CHECK (provider IN ('local_authority_spydus')),
    label TEXT NOT NULL,
    card_last_four TEXT NOT NULL,
    encrypted_card_number TEXT NOT NULL,
    encrypted_pin TEXT NOT NULL,
    sync_enabled INTEGER NOT NULL DEFAULT 1,
    reminder_days_before INTEGER NOT NULL DEFAULT 7,
    last_sync_at TEXT,
    last_success_at TEXT,
    last_error_code TEXT,
    next_sync_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_library_accounts_due_sync
    ON library_accounts(sync_enabled, next_sync_at)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_library_accounts_family
    ON library_accounts(family_id, created_at)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS library_loans (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    external_item_hash TEXT NOT NULL,
    title TEXT NOT NULL,
    author TEXT,
    material_format TEXT,
    due_date TEXT NOT NULL,
    provider_status TEXT,
    renewable INTEGER,
    renewal_count INTEGER,
    task_completed_at TEXT,
    task_completed_by TEXT,
    last_seen_at TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    UNIQUE(account_id, external_item_hash)
);
CREATE INDEX IF NOT EXISTS idx_library_loans_family_due
    ON library_loans(family_id, due_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_library_loans_account
    ON library_loans(account_id, last_seen_at)
    WHERE deleted_at IS NULL;

-- Photos of the children, added explicitly in-app (no external photo service).
-- taken_on is the real capture date read from the camera roll; caption is
-- editable after upload.
CREATE TABLE IF NOT EXISTS child_photos (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    caption TEXT,
    taken_on TEXT NOT NULL,
    media_type TEXT NOT NULL,
    storage_key TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    location TEXT,
    story TEXT,
    favourite INTEGER NOT NULL DEFAULT 0,
    include_in_yearbook INTEGER NOT NULL DEFAULT 1,
    yearbook_position INTEGER,
    original_media_type TEXT,
    original_storage_key TEXT,
    original_file_size INTEGER,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_child_photos_family_child
    ON child_photos(family_id, child_id, taken_on DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_child_photos_family_client
    ON child_photos(family_id, client_id)
    WHERE client_id IS NOT NULL AND deleted_at IS NULL;

-- Incremental sync filters by family and updated_at and must include tombstones.
CREATE INDEX IF NOT EXISTS idx_sync_calendar_events ON calendar_events(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_tasks ON tasks(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_medicine_types ON medicine_types(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_medicine_doses ON medicine_doses(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_naps ON naps(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_dog_activities ON dog_activities(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_birthdays ON birthdays(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_meals ON meals(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_meal_plans ON meal_plans(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_meal_ratings ON meal_ratings(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_shopping_items ON shopping_items(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_grocery_items ON grocery_items(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_purchase_batches ON purchase_batches(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_purchases ON purchases(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_consumption_events ON consumption_events(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_health_data ON health_data(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_homework_reading ON homework_reading(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_homework_spellings ON homework_spellings(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_growth_records ON growth_records(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_children ON children(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_present_ideas ON present_ideas(family_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_present_scores ON present_idea_scores(family_id, updated_at);

-- Children's health record: developmental milestones a child has achieved.
-- The reference list of milestones lives in code (app/services/health_record.py).
CREATE TABLE IF NOT EXISTS child_milestones (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    milestone_key TEXT NOT NULL,
    achieved_on TEXT NOT NULL,
    note TEXT,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_child_milestones_child ON child_milestones(child_id);
CREATE INDEX IF NOT EXISTS idx_child_milestones_family ON child_milestones(family_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_child_milestones_active
    ON child_milestones(child_id, milestone_key) WHERE deleted_at IS NULL;

-- Children's health record: recorded childhood vaccinations. The routine
-- schedule itself lives in code (app/services/health_record.py).
CREATE TABLE IF NOT EXISTS child_vaccinations (
    id TEXT PRIMARY KEY,
    child_id TEXT NOT NULL,
    vaccine_key TEXT NOT NULL,
    vaccine_name TEXT,
    given_on TEXT NOT NULL,
    family_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_child_vaccinations_child ON child_vaccinations(child_id);
CREATE INDEX IF NOT EXISTS idx_child_vaccinations_family ON child_vaccinations(family_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_child_vaccinations_active
    ON child_vaccinations(child_id, vaccine_key) WHERE deleted_at IS NULL;

-- Deterministic Finance plans and coaching loops. These rows are adult-only,
-- space-scoped records; none of them can initiate a payment or purchase.
CREATE TABLE IF NOT EXISTS finance_plans (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    proposal_group_id TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version > 0),
    strategy TEXT NOT NULL CHECK (strategy IN (
        'MINIMAL_DISRUPTION', 'TARGET_DATE', 'AGGRESSIVE', 'RESILIENT'
    )),
    effort_level TEXT NOT NULL DEFAULT 'MEDIUM' CHECK (effort_level IN (
        'EASY', 'MEDIUM', 'HARD'
    )),
    answer_basis TEXT NOT NULL DEFAULT 'ESTIMATED' CHECK (answer_basis IN (
        'EXACT', 'ESTIMATED', 'BOUNDED'
    )),
    confidence_bps INTEGER NOT NULL DEFAULT 5000
        CHECK (confidence_bps BETWEEN 0 AND 10000),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    goal_id TEXT NOT NULL,
    source_plan_id TEXT,
    recovery_mode TEXT CHECK (recovery_mode IS NULL OR recovery_mode IN (
        'CURRENT_CYCLE', 'SPREAD_CYCLES', 'USE_UNDERSPEND',
        'DEFER_PURCHASE', 'ACCEPT_NEW_DATE'
    )),
    target_date TEXT NOT NULL,
    supported_goal_date TEXT,
    forecast_coverage_end TEXT,
    required_monthly_minor INTEGER NOT NULL DEFAULT 0
        CHECK (required_monthly_minor >= 0),
    planned_monthly_saving_minor INTEGER NOT NULL DEFAULT 0
        CHECK (planned_monthly_saving_minor >= 0),
    projected_amount_at_target_minor INTEGER NOT NULL DEFAULT 0
        CHECK (projected_amount_at_target_minor >= 0),
    goal_shortfall_at_target_minor INTEGER NOT NULL DEFAULT 0
        CHECK (goal_shortfall_at_target_minor >= 0),
    monthly_change_minor INTEGER NOT NULL,
    household_buffer_minor INTEGER NOT NULL CHECK (household_buffer_minor >= 0),
    required_reduction_minor INTEGER NOT NULL CHECK (required_reduction_minor >= 0),
    achieved_reduction_minor INTEGER NOT NULL CHECK (achieved_reduction_minor >= 0),
    shortfall_minor INTEGER NOT NULL CHECK (shortfall_minor >= 0),
    feasible INTEGER NOT NULL CHECK (feasible IN (0, 1)),
    protected_category_count INTEGER NOT NULL CHECK (protected_category_count >= 0),
    input_snapshot_json TEXT NOT NULL,
    rationale TEXT NOT NULL,
    assumptions_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'PROPOSED' CHECK (status IN (
        'PROPOSED', 'ACTIVE', 'SUPERSEDED', 'REJECTED'
    )),
    activated_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_plan_group_strategy_active
    ON finance_plans(space_id, proposal_group_id, strategy)
    WHERE deleted_at IS NULL;
-- Earlier releases allowed only one active plan for an entire Finance space.
-- Re-running the schema must replace that index as well as initialise a fresh DB.
DROP INDEX IF EXISTS idx_finance_plan_one_active;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_plan_one_active_per_goal
    ON finance_plans(space_id, goal_id)
    WHERE status = 'ACTIVE' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_plans_space_version
    ON finance_plans(space_id, version DESC, strategy) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_plan_categories (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    category_id TEXT NOT NULL,
    name TEXT NOT NULL,
    baseline_minor INTEGER NOT NULL CHECK (baseline_minor >= 0),
    floor_minor INTEGER NOT NULL CHECK (floor_minor >= 0),
    protected INTEGER NOT NULL CHECK (protected IN (0, 1)),
    weight INTEGER NOT NULL CHECK (weight > 0),
    reduction_minor INTEGER NOT NULL CHECK (reduction_minor >= 0),
    budget_minor INTEGER NOT NULL CHECK (budget_minor >= 0),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_plan_category_active
    ON finance_plan_categories(plan_id, category_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_payday_actions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    plan_id TEXT NOT NULL,
    due_date TEXT NOT NULL,
    source_account_id TEXT NOT NULL,
    destination_account_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    safe_after_transfer_minor INTEGER NOT NULL CHECK (safe_after_transfer_minor >= 0),
    answer_mode TEXT NOT NULL DEFAULT 'CURRENT_EXACT' CHECK (
        answer_mode IN ('CURRENT_EXACT', 'DATED_EXACT')
    ),
    data_through_at TEXT,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    date_tolerance_days INTEGER NOT NULL CHECK (date_tolerance_days BETWEEN 0 AND 14),
    grace_days INTEGER NOT NULL CHECK (grace_days BETWEEN 0 AND 14),
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN (
        'PENDING', 'MATCHED', 'DONE', 'SKIPPED', 'CHANGED',
        'RECALCULATED', 'EXPIRED'
    )),
    matched_relation_id TEXT,
    matched_at TEXT,
    changed_amount_minor INTEGER,
    recalculated_action_id TEXT,
    resolution_note TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (source_account_id <> destination_account_id)
);
CREATE INDEX IF NOT EXISTS idx_finance_payday_space_due
    ON finance_payday_actions(space_id, status, due_date) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_habits (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    finding_id TEXT,
    slot TEXT NOT NULL CHECK (slot IN ('PRIMARY', 'SECONDARY')),
    name TEXT NOT NULL,
    trigger_text TEXT NOT NULL,
    filters_json TEXT NOT NULL,
    baseline_start TEXT NOT NULL,
    baseline_end TEXT NOT NULL,
    baseline_minor INTEGER NOT NULL CHECK (baseline_minor >= 0),
    start_date TEXT NOT NULL,
    review_date TEXT NOT NULL,
    expected_saving_low_minor INTEGER NOT NULL CHECK (expected_saving_low_minor >= 0),
    expected_saving_high_minor INTEGER NOT NULL CHECK (
        expected_saving_high_minor >= expected_saving_low_minor
    ),
    actual_spend_minor INTEGER NOT NULL DEFAULT 0 CHECK (actual_spend_minor >= 0),
    realised_saving_minor INTEGER NOT NULL DEFAULT 0 CHECK (realised_saving_minor >= 0),
    displacement_minor INTEGER NOT NULL DEFAULT 0 CHECK (displacement_minor >= 0),
    friction_rating INTEGER CHECK (friction_rating BETWEEN 1 AND 5),
    fallback TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN (
        'PROPOSED', 'ACTIVE', 'PAUSED', 'COMPLETED', 'ABANDONED'
    )),
    review_decision TEXT CHECK (review_decision IS NULL OR review_decision IN (
        'KEEP', 'ADJUST', 'STOP'
    )),
    review_note TEXT,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_habit_active_slot
    ON finance_habits(space_id, slot)
    WHERE status = 'ACTIVE' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_habit_observations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    habit_id TEXT NOT NULL,
    observed_through TEXT NOT NULL,
    qualifying_spend_minor INTEGER NOT NULL CHECK (qualifying_spend_minor >= 0),
    baseline_expected_minor INTEGER NOT NULL CHECK (baseline_expected_minor >= 0),
    realised_saving_minor INTEGER NOT NULL CHECK (realised_saving_minor >= 0),
    displacement_minor INTEGER NOT NULL CHECK (displacement_minor >= 0),
    evidence_json TEXT NOT NULL DEFAULT '[]',
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_habit_observation_through
    ON finance_habit_observations(habit_id, observed_through) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_proposals (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN (
        'TEXT', 'URL_METADATA', 'SCREENSHOT_METADATA', 'QUOTE', 'BASKET', 'LINES'
    )),
    source_text TEXT,
    source_url TEXT,
    source_metadata_json TEXT NOT NULL DEFAULT '{}',
    name TEXT NOT NULL,
    amount_low_minor INTEGER NOT NULL CHECK (amount_low_minor >= 0),
    amount_high_minor INTEGER NOT NULL CHECK (amount_high_minor >= amount_low_minor),
    desired_date TEXT NOT NULL,
    recurrence TEXT NOT NULL CHECK (recurrence IN ('ONE_OFF', 'MONTHLY', 'ANNUAL')),
    payment_account_id TEXT NOT NULL,
    purpose TEXT,
    beneficiary TEXT,
    lines_json TEXT NOT NULL DEFAULT '[]',
    cheaper_alternative_minor INTEGER,
    later_date TEXT,
    uncertainties_json TEXT NOT NULL DEFAULT '[]',
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    status TEXT NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN (
        'CONFIRMED', 'EVALUATED', 'APPROVED', 'DISMISSED'
    )),
    approved_evaluation_id TEXT,
    approved_scenario TEXT CHECK (approved_scenario IS NULL OR approved_scenario IN (
        'BUY_NOW', 'BUY_LATER', 'CHEAPER', 'DO_NOTHING'
    )),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_proposals_space_status
    ON finance_purchase_proposals(space_id, status, desired_date) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_purchase_evaluations (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    proposal_id TEXT NOT NULL,
    forecast_id TEXT NOT NULL,
    verdict TEXT NOT NULL CHECK (verdict IN (
        'YES', 'YES_IF', 'NOT_YET', 'NO_UNDER_CURRENT_PLAN'
    )),
    rationale TEXT NOT NULL,
    scenarios_json TEXT NOT NULL,
    historical_context_json TEXT NOT NULL,
    evidence_json TEXT NOT NULL DEFAULT '[]',
    data_through_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_evaluations_proposal
    ON finance_purchase_evaluations(proposal_id, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_report_preferences (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    member_user_id TEXT NOT NULL,
    locale TEXT NOT NULL DEFAULT 'en' CHECK (locale IN ('en', 'de')),
    daily_time TEXT NOT NULL DEFAULT '07:00:00',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    notification_channel TEXT NOT NULL DEFAULT 'IN_APP' CHECK (
        notification_channel IN ('IN_APP', 'BROWSER')
    ),
    notification_mode TEXT NOT NULL DEFAULT 'ACTION_ONLY' CHECK (
        notification_mode IN ('ACTION_ONLY', 'DAILY', 'NEVER')
    ),
    show_more_by_default INTEGER NOT NULL DEFAULT 0 CHECK (
        show_more_by_default IN (0, 1)
    ),
    quiet_hours_start TEXT,
    quiet_hours_end TEXT,
    underfunded_commitment_threshold_minor INTEGER NOT NULL DEFAULT 5000 CHECK (
        underfunded_commitment_threshold_minor >= 0
    ),
    goal_movement_threshold_minor INTEGER NOT NULL DEFAULT 5000 CHECK (
        goal_movement_threshold_minor >= 0
    ),
    missed_payday_alerts INTEGER NOT NULL DEFAULT 1 CHECK (
        missed_payday_alerts IN (0, 1)
    ),
    selected_return_deadline_alerts INTEGER NOT NULL DEFAULT 1 CHECK (
        selected_return_deadline_alerts IN (0, 1)
    ),
    tone TEXT NOT NULL DEFAULT 'BALANCED' CHECK (
        tone IN ('GENTLE', 'BALANCED', 'BLUNT')
    ),
    default_spend_account_id TEXT,
    extra_cash_buffer_minor INTEGER NOT NULL DEFAULT 0 CHECK (
        extra_cash_buffer_minor >= 0
    ),
    writing_mode TEXT NOT NULL DEFAULT 'LOCAL' CHECK (
        writing_mode IN ('LOCAL', 'CLOUD_WITH_CONSENT')
    ),
    allow_dated_estimates INTEGER NOT NULL DEFAULT 1 CHECK (
        allow_dated_estimates IN (0, 1)
    ),
    ordinary_purchase_alerts INTEGER NOT NULL DEFAULT 0 CHECK (
        ordinary_purchase_alerts = 0
    ),
    group_related_alerts INTEGER NOT NULL DEFAULT 1 CHECK (
        group_related_alerts = 1
    ),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_report_preference_member_space
    ON finance_report_preferences(member_user_id, space_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_coaching_reports (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    member_user_id TEXT NOT NULL,
    report_kind TEXT NOT NULL CHECK (report_kind IN (
        'DAILY', 'DRIFT', 'WEEKLY', 'MONTHLY'
    )),
    local_date TEXT NOT NULL,
    household_timezone TEXT NOT NULL,
    locale TEXT NOT NULL CHECK (locale IN ('en', 'de')),
    input_digest TEXT NOT NULL,
    source_watermark TEXT,
    data_through_at TEXT,
    itemised_coverage_bps INTEGER CHECK (
        itemised_coverage_bps BETWEEN 0 AND 10000
    ),
    trajectory_status TEXT NOT NULL CHECK (trajectory_status IN (
        'ON_PLAN', 'WATCH', 'OFF_PLAN', 'UNKNOWN'
    )),
    expected_durable_saving_minor INTEGER NOT NULL,
    primary_action_json TEXT,
    optional_observation_json TEXT,
    summary_json TEXT NOT NULL,
    explanation TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_report_idempotent
    ON finance_coaching_reports(
        member_user_id, space_id, report_kind, local_date, input_digest
    ) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_reports_member_date
    ON finance_coaching_reports(member_user_id, space_id, report_kind, local_date DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_capture_drafts (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    creator_user_id TEXT NOT NULL,
    draft_kind TEXT NOT NULL CHECK (draft_kind IN (
        'FACT', 'PREFERENCE', 'TRANSACTION_CORRECTION', 'PURCHASE_DETAILS',
        'ITEM_OUTCOME', 'CASH_SPEND', 'COMMITMENT', 'GOAL', 'HABIT',
        'PURCHASE_PLAN'
    )),
    payload_json TEXT NOT NULL,
    target_options_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'PENDING' CHECK (
        status IN ('PENDING', 'CONFIRMED', 'EXPIRED')
    ),
    expires_at TEXT NOT NULL,
    confirmed_action_kind TEXT,
    confirmed_action_id TEXT,
    confirmation_digest TEXT,
    confirmed_result_json TEXT,
    confirmed_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_capture_drafts_creator_status
    ON finance_capture_drafts(creator_user_id, status, expires_at)
    WHERE deleted_at IS NULL;

-- Visibility changes are copied into the household space.  The source-side
-- identifiers below are internal provenance only; no household-facing route
-- returns them.  Stopping a future share leaves already-created household
-- records intact.
CREATE TABLE IF NOT EXISTS finance_share_actions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    source_space_id TEXT NOT NULL,
    household_space_id TEXT NOT NULL,
    share_kind TEXT NOT NULL CHECK (share_kind IN (
        'ACCOUNT', 'TRANSACTION', 'PURCHASE', 'PURCHASE_LINES',
        'COMMITMENT', 'GOAL', 'CONTRIBUTION', 'RULE'
    )),
    source_record_type TEXT,
    source_record_id TEXT,
    selection_json TEXT NOT NULL DEFAULT '[]',
    selection_digest TEXT NOT NULL DEFAULT '',
    rule_target TEXT CHECK (
        rule_target IS NULL OR rule_target IN ('TRANSACTION', 'PURCHASE')
    ),
    rule_match_kind TEXT CHECK (
        rule_match_kind IS NULL OR rule_match_kind = 'MERCHANT'
    ),
    rule_match_value TEXT,
    status TEXT NOT NULL CHECK (status IN ('ACTIVE', 'COMPLETED', 'STOPPED')),
    household_record_type TEXT,
    household_record_id TEXT,
    stopped_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_share_direct_idempotent
    ON finance_share_actions(
        source_space_id, share_kind, source_record_id, selection_digest
    )
    WHERE share_kind <> 'RULE' AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_share_rule_idempotent
    ON finance_share_actions(
        owner_user_id, source_space_id, rule_target, rule_match_kind, rule_match_value
    )
    WHERE share_kind = 'RULE' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_share_actions_owner
    ON finance_share_actions(owner_user_id, status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_share_actions_future
    ON finance_share_actions(source_space_id, status, share_kind)
    WHERE status = 'ACTIVE' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS finance_share_copy_links (
    id TEXT PRIMARY KEY,
    share_action_id TEXT NOT NULL,
    source_space_id TEXT NOT NULL,
    source_record_type TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    household_space_id TEXT NOT NULL,
    household_record_type TEXT NOT NULL,
    household_record_id TEXT NOT NULL,
    accounting_treatment TEXT NOT NULL DEFAULT 'CASEY' CHECK (
        accounting_treatment IN (
            'CASEY', 'NEUTRAL_TRANSFER', 'REFUND', 'REIMBURSEMENT'
        )
    ),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finance_share_copy_source
    ON finance_share_copy_links(
        share_action_id, source_record_type, source_record_id, household_record_type
    ) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_finance_share_copy_household
    ON finance_share_copy_links(household_space_id, household_record_type, household_record_id)
    WHERE deleted_at IS NULL;

-- Contributions are deliberately not canonical transactions: putting a
-- synthetic personal counterparty into the cash ledger would distort income,
-- consumption, safe-to-spend and net-worth totals.  Household planning may
-- consume this neutral record explicitly.
CREATE TABLE IF NOT EXISTS finance_declared_contributions (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
    currency TEXT NOT NULL CHECK (length(currency) = 3 AND currency = upper(currency)),
    contribution_date TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT 'Contribution from a personal space'
        CHECK (label = 'Contribution from a personal space'),
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CANCELLED')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_finance_contributions_space_date
    ON finance_declared_contributions(space_id, contribution_date DESC, id)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------------------------------
-- Adult Fitness module. Domain rows are private to owner_user_id; family_id
-- remains present for tenant isolation, audit history and account deletion.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS health_user_settings (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    nutrition_day_start_minutes INTEGER NOT NULL DEFAULT 240
        CHECK (nutrition_day_start_minutes BETWEEN 0 AND 480),
    timezone TEXT NOT NULL DEFAULT 'Europe/London',
    show_planned INTEGER NOT NULL DEFAULT 1 CHECK (show_planned IN (0,1)),
    show_completed INTEGER NOT NULL DEFAULT 0 CHECK (show_completed IN (0,1)),
    heart_rate_zone_boundaries_bpm_json TEXT NOT NULL DEFAULT '[120,140,155,170]',
    coach_personality_preset TEXT NOT NULL DEFAULT 'balanced_supportive'
        CHECK (coach_personality_preset IN (
            'scientific_hard_driving','balanced_supportive','calm_encouraging','custom'
        )),
    coach_directness INTEGER NOT NULL DEFAULT 3
        CHECK (coach_directness BETWEEN 1 AND 5),
    coach_challenge_bias TEXT NOT NULL DEFAULT 'balanced'
        CHECK (coach_challenge_bias IN ('conservative','balanced','ambitious')),
    coach_detail_level TEXT NOT NULL DEFAULT 'standard'
        CHECK (coach_detail_level IN ('brief','standard','detailed')),
    coach_custom_instruction TEXT,
    coach_memory_enabled INTEGER NOT NULL DEFAULT 0,
    coach_memory_enabled_at TEXT,
    breakfast_time TEXT NOT NULL DEFAULT '08:00',
    lunch_time TEXT NOT NULL DEFAULT '12:30',
    dinner_time TEXT NOT NULL DEFAULT '18:30',
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_settings_owner_active
    ON health_user_settings(owner_user_id) WHERE deleted_at IS NULL;

-- A meal stays available on Today while foods are still being assembled.
-- Completion is an explicit, owner-private acknowledgement, not inferred from
-- the presence of one diary item because real meals commonly contain several.
CREATE TABLE IF NOT EXISTS health_nutrition_meal_completions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    nutrition_date TEXT NOT NULL,
    meal_key TEXT NOT NULL CHECK (meal_key IN ('breakfast','lunch','dinner','snack')),
    completed_at TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_meal_completion_owner_day_meal
    ON health_nutrition_meal_completions(owner_user_id, nutrition_date, meal_key)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_meal_completion_family_day
    ON health_nutrition_meal_completions(family_id, nutrition_date)
    WHERE deleted_at IS NULL;

-- Durable acknowledgements for externally completed Vi bookings. One canonical
-- row owns each logical class booking; alias rows reserve every caller UUID used
-- to retry it, so a restarted client cannot create a duplicate or reuse an ID
-- for different booking details. These receipts outlive calendar tombstones.
CREATE TABLE IF NOT EXISTS fitness_vi_booking_receipts (
    id TEXT PRIMARY KEY,
    canonical_receipt_id TEXT NOT NULL,
    is_canonical INTEGER NOT NULL CHECK (is_canonical IN (0,1)),
    owner_user_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider = 'vi_training'),
    logical_key TEXT NOT NULL,
    event_id TEXT NOT NULL,
    booking_date TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    label TEXT NOT NULL,
    classification TEXT NOT NULL CHECK (
        classification IN ('strength','run','conditioning','mobility','other')
    ),
    location TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_fitness_vi_booking_logical_active
    ON fitness_vi_booking_receipts(owner_user_id, logical_key)
    WHERE is_canonical = 1 AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_fitness_vi_booking_canonical
    ON fitness_vi_booking_receipts(owner_user_id, canonical_receipt_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_fitness_vi_booking_family
    ON fitness_vi_booking_receipts(family_id, created_at DESC)
    WHERE deleted_at IS NULL;

-- Fitness is a private, optional adult workspace. These choices control only
-- that adult's navigation and Today contribution; they are never family-wide.
CREATE TABLE IF NOT EXISTS health_fitness_workspace_preferences (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)),
    pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
    show_nutrition_today INTEGER NOT NULL DEFAULT 0 CHECK (show_nutrition_today IN (0,1)),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_fitness_workspace_owner_active
    ON health_fitness_workspace_preferences(owner_user_id) WHERE deleted_at IS NULL;

-- Owner-private reminders created only after an explicit Fitness Coach
-- confirmation. They never appear in the family task or calendar surfaces.
CREATE TABLE IF NOT EXISTS health_fitness_reminders (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    title TEXT NOT NULL,
    remind_at_utc TEXT NOT NULL,
    notes TEXT,
    planned_session_id TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','completed')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_fitness_reminders_owner_time
    ON health_fitness_reminders(owner_user_id, remind_at_utc)
    WHERE deleted_at IS NULL AND status = 'active';

-- One private, resumable first-run setup per adult. The public API exposes only
-- the human preference fields and the accepted week; the stored preview also
-- carries the deterministic IDs needed to make confirmation exactly-once.
CREATE TABLE IF NOT EXISTS health_onboarding_profiles (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft','skipped','complete')),
    main_outcome TEXT,
    availability_json TEXT NOT NULL DEFAULT '[]',
    activities_json TEXT NOT NULL DEFAULT '[]',
    equipment_json TEXT NOT NULL DEFAULT '[]',
    food_preferences_json TEXT NOT NULL DEFAULT '[]',
    source_connections_json TEXT NOT NULL DEFAULT '[]',
    coach_style TEXT,
    use_family_calendar INTEGER NOT NULL DEFAULT 0
        CHECK (use_family_calendar IN (0,1)),
    use_household_meals INTEGER NOT NULL DEFAULT 0
        CHECK (use_household_meals IN (0,1)),
    use_weather INTEGER NOT NULL DEFAULT 0 CHECK (use_weather IN (0,1)),
    memory_enabled INTEGER NOT NULL DEFAULT 0 CHECK (memory_enabled IN (0,1)),
    preview_id TEXT,
    preview_json TEXT,
    preview_hash TEXT,
    previewed_at TEXT,
    confirmed_at TEXT,
    goal_id TEXT,
    session_ids_json TEXT NOT NULL DEFAULT '[]',
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_onboarding_owner_active
    ON health_onboarding_profiles(owner_user_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_goals (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    goal_type TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    name TEXT NOT NULL,
    baseline_value REAL,
    current_value REAL,
    target_value REAL,
    unit_key TEXT,
    starts_on TEXT NOT NULL,
    target_date TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('draft','active','paused','completed','abandoned')),
    acceptable_rate_min REAL,
    acceptable_rate_max REAL,
    notes TEXT,
    completed_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_goals_owner_status
    ON health_goals(owner_user_id, status, priority DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_goal_relationships (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    source_goal_id TEXT NOT NULL,
    target_goal_id TEXT NOT NULL,
    relationship TEXT NOT NULL
        CHECK (relationship IN ('supports','conflicts','depends_on','subgoal_of')),
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_goal_relationship_active
    ON health_goal_relationships(owner_user_id, source_goal_id, target_goal_id, relationship)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_training_phases (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    phase_type TEXT NOT NULL,
    name TEXT NOT NULL,
    starts_on TEXT NOT NULL,
    ends_on TEXT,
    calorie_policy_json TEXT,
    protein_policy_json TEXT,
    running_priorities_json TEXT,
    strength_priorities_json TEXT,
    accepted_tradeoffs_json TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_phases_owner_dates
    ON health_training_phases(owner_user_id, starts_on DESC, ends_on)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_training_phase_goal_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    training_phase_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary','constraint')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_phase_goal_link_active
    ON health_training_phase_goal_links(owner_user_id, training_phase_id, goal_id, role)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_phase_primary_goal_active
    ON health_training_phase_goal_links(owner_user_id, training_phase_id)
    WHERE role = 'primary' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_workout_definitions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    sport_key TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_workouts_owner_sport
    ON health_workout_definitions(owner_user_id, sport_key, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_workout_versions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_definition_id TEXT NOT NULL,
    version_number INTEGER NOT NULL,
    sport_key TEXT NOT NULL,
    title TEXT NOT NULL,
    purpose TEXT,
    estimated_duration_s INTEGER,
    estimated_distance_m REAL,
    structured_summary_json TEXT NOT NULL DEFAULT '{}',
    version_source TEXT NOT NULL DEFAULT 'user'
        CHECK (version_source IN ('user','coach','import')),
    accepted_at TEXT,
    accepted_by TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_workout_version_number
    ON health_workout_versions(owner_user_id, workout_definition_id, version_number)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_training_programmes (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    purpose TEXT,
    starts_on TEXT NOT NULL,
    ends_on TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    phase_id TEXT,
    programme_source TEXT NOT NULL DEFAULT 'user',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_programmes_owner_dates
    ON health_training_programmes(owner_user_id, starts_on DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_training_programme_goal_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    training_programme_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary','constraint')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_programme_goal_link_active
    ON health_training_programme_goal_links(owner_user_id, training_programme_id, goal_id, role)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_sessions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    sport_key TEXT NOT NULL,
    training_programme_id TEXT,
    workout_version_id TEXT,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed','accepted','scheduled','in_progress','completed',
                          'partially_completed','skipped','cancelled')),
    session_source TEXT NOT NULL DEFAULT 'user'
        CHECK (session_source IN ('user','coach','imported')),
    scheduled_start_utc TEXT,
    scheduled_date TEXT,
    time_window_start_utc TEXT,
    time_window_end_utc TEXT,
    local_timezone TEXT NOT NULL,
    expected_duration_s INTEGER,
    expected_distance_m REAL,
    expected_pace_s_per_km REAL,
    priority INTEGER NOT NULL DEFAULT 0,
    movable INTEGER NOT NULL DEFAULT 1,
    visibility TEXT NOT NULL DEFAULT 'private'
        CHECK (visibility IN ('private','logistics_shared')),
    shared_title TEXT,
    reason_for_placement TEXT,
    completion_activity_id TEXT,
    completion_state TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_planned_owner_start
    ON health_planned_sessions(owner_user_id, scheduled_start_utc, scheduled_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_planned_shared
    ON health_planned_sessions(family_id, scheduled_start_utc, scheduled_date)
    WHERE visibility = 'logistics_shared' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_session_goal_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary','maintenance','constraint')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_planned_goal_link_active
    ON health_planned_session_goal_links(owner_user_id, planned_session_id, goal_id, role)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_session_exercises (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT NOT NULL,
    exercise_id TEXT NOT NULL,
    exercise_setup_id TEXT,
    sequence INTEGER NOT NULL,
    superset_group_key TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_planned_session_exercise_sequence
    ON health_planned_session_exercises(owner_user_id, planned_session_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_session_exercise_substitutions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_exercise_id TEXT NOT NULL,
    substitute_exercise_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_planned_session_substitution
    ON health_planned_session_exercise_substitutions(
        owner_user_id, planned_session_exercise_id, substitute_exercise_id
    ) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_session_sets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_exercise_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    training_role TEXT NOT NULL
        CHECK (training_role IN ('warmup','working','backoff','technique','test','other')),
    structure_type TEXT NOT NULL DEFAULT 'straight'
        CHECK (structure_type IN ('straight','drop','rest_pause','cluster','other')),
    component_count INTEGER NOT NULL DEFAULT 1 CHECK (component_count >= 1),
    reps_min INTEGER,
    reps_max INTEGER,
    load_min REAL,
    load_max REAL,
    load_unit TEXT,
    rpe_min REAL,
    rpe_max REAL,
    rir_min REAL,
    rir_max REAL,
    rest_s INTEGER,
    is_amrap INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_planned_session_set_sequence
    ON health_planned_session_sets(owner_user_id, planned_session_exercise_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_foods (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    household_shared INTEGER NOT NULL DEFAULT 0,
    name TEXT NOT NULL,
    brand TEXT,
    category_key TEXT,
    barcode TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    favourite INTEGER NOT NULL DEFAULT 0,
    merged_into_food_id TEXT,
    merged_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_foods_owner_name
    ON health_foods(owner_user_id, active, name) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_foods_household_name
    ON health_foods(family_id, household_shared, name)
    WHERE household_shared = 1 AND active = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_food_versions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    food_id TEXT NOT NULL,
    version_number INTEGER NOT NULL,
    effective_from TEXT,
    reference_amount REAL NOT NULL CHECK (reference_amount > 0),
    reference_unit TEXT NOT NULL
        CHECK (reference_unit IN ('g','ml','item','serving','custom')),
    calories_kcal REAL,
    source_energy_value REAL,
    source_energy_unit TEXT CHECK (source_energy_unit IS NULL OR source_energy_unit IN ('kcal','kj')),
    protein_g REAL,
    carbohydrate_g REAL,
    sugars_g REAL,
    fat_g REAL,
    saturated_fat_g REAL,
    fibre_g REAL,
    salt_g REAL,
    sodium_mg REAL,
    micronutrients_json TEXT NOT NULL DEFAULT '{}',
    source_type TEXT NOT NULL DEFAULT 'manual',
    source_note TEXT,
    confidence TEXT NOT NULL DEFAULT 'measured',
    label_asset_id TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_food_version_number
    ON health_food_versions(owner_user_id, food_id, version_number) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_food_servings (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    food_id TEXT NOT NULL,
    name TEXT NOT NULL,
    amount REAL NOT NULL CHECK (amount > 0),
    unit TEXT NOT NULL,
    canonical_amount REAL NOT NULL CHECK (canonical_amount > 0),
    canonical_unit TEXT NOT NULL,
    measurement_quality TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_food_serving_name
    ON health_food_servings(owner_user_id, food_id, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_recipes (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    household_shared INTEGER NOT NULL DEFAULT 0,
    name TEXT NOT NULL,
    notes TEXT,
    favourite INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_recipes_owner_name
    ON health_recipes(owner_user_id, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_recipe_versions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    recipe_id TEXT NOT NULL,
    version_number INTEGER NOT NULL,
    finished_weight_g REAL,
    servings REAL,
    calories_kcal REAL,
    protein_g REAL,
    carbohydrate_g REAL,
    sugars_g REAL,
    fat_g REAL,
    saturated_fat_g REAL,
    fibre_g REAL,
    salt_g REAL,
    lower_calories_kcal REAL,
    upper_calories_kcal REAL,
    confidence TEXT NOT NULL DEFAULT 'calculated',
    source_note TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_recipe_version_number
    ON health_recipe_versions(owner_user_id, recipe_id, version_number) WHERE deleted_at IS NULL;

-- Family meal planning can reference one explicit shared Fitness recipe
-- version. The association is family-visible; food diary entries remain private.
CREATE TABLE IF NOT EXISTS health_household_meal_recipe_links (
    id TEXT PRIMARY KEY,
    meal_id TEXT NOT NULL,
    recipe_version_id TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_household_meal_link_active
    ON health_household_meal_recipe_links(family_id, meal_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_household_meal_link_recipe
    ON health_household_meal_recipe_links(family_id, recipe_version_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_recipe_components (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    recipe_version_id TEXT NOT NULL,
    food_version_id TEXT NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 0,
    amount REAL NOT NULL CHECK (amount > 0),
    unit TEXT NOT NULL,
    canonical_amount REAL NOT NULL CHECK (canonical_amount > 0),
    canonical_unit TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_recipe_components_version
    ON health_recipe_components(owner_user_id, recipe_version_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_meal_templates (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    meal_key TEXT NOT NULL,
    time_relevance TEXT,
    favourite INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_meal_templates_owner
    ON health_meal_templates(owner_user_id, favourite DESC, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_meal_template_items (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    meal_template_id TEXT NOT NULL,
    food_version_id TEXT,
    recipe_version_id TEXT,
    sequence INTEGER NOT NULL DEFAULT 0,
    amount REAL NOT NULL CHECK (amount > 0),
    unit TEXT NOT NULL,
    canonical_amount REAL NOT NULL CHECK (canonical_amount > 0),
    canonical_unit TEXT NOT NULL,
    measurement_quality TEXT NOT NULL DEFAULT 'standard_serving',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_meal_template_items
    ON health_meal_template_items(owner_user_id, meal_template_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_food_log_entries (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    food_version_id TEXT,
    recipe_version_id TEXT,
    source_meal_plan_id TEXT,
    household_meal_link_id TEXT,
    logged_at_utc TEXT NOT NULL,
    local_timezone TEXT NOT NULL,
    nutrition_date TEXT NOT NULL,
    meal_key TEXT NOT NULL,
    entered_amount REAL NOT NULL CHECK (entered_amount > 0),
    entered_unit TEXT NOT NULL,
    canonical_amount REAL NOT NULL CHECK (canonical_amount > 0),
    canonical_unit TEXT NOT NULL,
    measurement_quality TEXT NOT NULL,
    calories_kcal REAL,
    protein_g REAL,
    carbohydrate_g REAL,
    sugars_g REAL,
    fat_g REAL,
    saturated_fat_g REAL,
    fibre_g REAL,
    salt_g REAL,
    micronutrients_json TEXT NOT NULL DEFAULT '{}',
    notes TEXT,
    context_tags_json TEXT NOT NULL DEFAULT '[]',
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK ((food_version_id IS NULL) <> (recipe_version_id IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_health_food_log_owner_day
    ON health_food_log_entries(owner_user_id, nutrition_date, logged_at_utc)
    WHERE deleted_at IS NULL;
-- idx_health_food_log_owner_meal_plan is created by _run_migrations after its
-- provenance columns have been added to databases with a legacy diary table.

CREATE TABLE IF NOT EXISTS health_nutrition_targets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_value REAL,
    target_min REAL,
    target_max REAL,
    training_day_value REAL,
    rest_day_value REAL,
    phase_id TEXT,
    effective_from TEXT NOT NULL,
    effective_until TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_nutrition_targets_owner_metric
    ON health_nutrition_targets(owner_user_id, metric_key, effective_from DESC)
    WHERE active = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_body_measurements (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    measured_at_utc TEXT NOT NULL,
    local_timezone TEXT NOT NULL,
    value REAL NOT NULL,
    unit_key TEXT NOT NULL,
    source_record_id TEXT,
    measurement_quality TEXT NOT NULL DEFAULT 'measured',
    canonical_state TEXT NOT NULL DEFAULT 'canonical'
        CHECK (canonical_state IN ('canonical','duplicate','excluded')),
    duplicate_of_measurement_id TEXT,
    manual_canonical_override INTEGER NOT NULL DEFAULT 0
        CHECK (manual_canonical_override IN (0,1)),
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_body_measurements_owner_metric_time
    ON health_body_measurements(owner_user_id, metric_key, measured_at_utc DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activities (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    sport_key TEXT NOT NULL,
    sub_sport_key TEXT,
    parent_activity_id TEXT,
    leg_index INTEGER,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'in_progress',
    planned_session_id TEXT,
    workout_version_id TEXT,
    primary_source_record_id TEXT,
    primary_stream_asset_id TEXT,
    started_at_utc TEXT NOT NULL,
    ended_at_utc TEXT,
    local_timezone TEXT NOT NULL,
    local_calendar_date TEXT,
    elapsed_duration_s REAL,
    timer_duration_s REAL,
    moving_duration_s REAL,
    distance_m REAL,
    energy_kcal REAL,
    energy_estimation_method TEXT,
    energy_estimation_weight_kg REAL,
    energy_estimation_weight_measured_at_utc TEXT,
    energy_estimation_met REAL,
    measurement_quality TEXT NOT NULL DEFAULT 'measured',
    import_state TEXT NOT NULL DEFAULT 'not_imported',
    parser_version TEXT,
    workout_classification TEXT,
    classification_source TEXT,
    phase_id TEXT,
    route_preview_json TEXT,
    rest_timer_deadline_utc TEXT,
    session_rpe REAL,
    perceived_performance INTEGER,
    matched_plan_key TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_activities_owner_started
    ON health_activities(owner_user_id, started_at_utc DESC) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_active_strength_session
    ON health_activities(owner_user_id)
    WHERE sport_key = 'strength' AND status = 'in_progress' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_exercises (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    seed_key TEXT,
    name TEXT NOT NULL,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    movement_pattern_key TEXT NOT NULL DEFAULT 'other',
    measurement_mode TEXT NOT NULL DEFAULT 'reps_load',
    rep_count_mode TEXT NOT NULL DEFAULT 'total',
    load_entry_mode TEXT NOT NULL DEFAULT 'total_external',
    default_unit TEXT NOT NULL DEFAULT 'kg',
    unilateral_mode TEXT NOT NULL DEFAULT 'bilateral',
    equipment_type TEXT,
    bodyweight_involved INTEGER NOT NULL DEFAULT 0,
    progression_direction TEXT NOT NULL DEFAULT 'higher',
    notes TEXT,
    favourite INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    merged_into_exercise_id TEXT,
    merged_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_exercises_owner_name
    ON health_exercises(owner_user_id, active, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_exercises_owner_seed
    ON health_exercises(owner_user_id, seed_key)
    WHERE seed_key IS NOT NULL AND active = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_exercise_muscle_roles (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    exercise_id TEXT NOT NULL,
    muscle_group_key TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary')),
    contribution_weight REAL NOT NULL DEFAULT 1.0,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_exercise_muscle_role
    ON health_exercise_muscle_roles(owner_user_id, exercise_id, muscle_group_key)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_exercise_setups (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    exercise_id TEXT NOT NULL,
    name TEXT NOT NULL,
    location TEXT,
    equipment_identifier TEXT,
    load_entry_mode TEXT,
    rep_count_mode TEXT,
    unilateral_mode TEXT,
    bar_weight_kg REAL,
    machine_base_load_kg REAL,
    side_multiplier REAL,
    notes TEXT,
    is_default INTEGER NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    merged_into_setup_id TEXT,
    merged_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_setups_owner_exercise
    ON health_exercise_setups(owner_user_id, exercise_id, is_default DESC)
    WHERE active = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_workout_exercises (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_version_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    exercise_id TEXT NOT NULL,
    exercise_setup_id TEXT,
    superset_group_key TEXT,
    substitutions_json TEXT NOT NULL DEFAULT '[]',
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_workout_sequence
    ON health_strength_workout_exercises(owner_user_id, workout_version_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_workout_exercise_substitutions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_exercise_id TEXT NOT NULL,
    substitute_exercise_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_workout_substitution
    ON health_strength_workout_exercise_substitutions(
        owner_user_id, workout_exercise_id, substitute_exercise_id
    ) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_planned_sets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_exercise_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    training_role TEXT NOT NULL DEFAULT 'working',
    structure_type TEXT NOT NULL DEFAULT 'straight',
    component_count INTEGER NOT NULL DEFAULT 1 CHECK (component_count >= 1),
    reps_min INTEGER,
    reps_max INTEGER,
    load_min REAL,
    load_max REAL,
    load_unit TEXT,
    rpe_min REAL,
    rpe_max REAL,
    rir_min REAL,
    rir_max REAL,
    rest_s INTEGER,
    is_amrap INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_planned_set_sequence
    ON health_strength_planned_sets(owner_user_id, workout_exercise_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_session_exercises (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    exercise_id TEXT NOT NULL,
    exercise_setup_id TEXT NOT NULL,
    exercise_setup_name_snapshot TEXT NOT NULL DEFAULT 'Historical setup',
    load_entry_mode_snapshot TEXT NOT NULL DEFAULT 'total_external',
    rep_count_mode_snapshot TEXT NOT NULL DEFAULT 'total',
    unilateral_mode_snapshot TEXT NOT NULL DEFAULT 'bilateral',
    planned_exercise_id TEXT,
    sequence INTEGER NOT NULL,
    superset_group_key TEXT,
    variation_note TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_session_exercise_sequence
    ON health_strength_session_exercises(owner_user_id, activity_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_set_groups (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    session_exercise_id TEXT NOT NULL,
    planned_set_id TEXT,
    sequence INTEGER NOT NULL,
    training_role TEXT NOT NULL
        CHECK (training_role IN ('warmup','working','backoff','technique','test','other')),
    structure_type TEXT NOT NULL
        CHECK (structure_type IN ('straight','drop','rest_pause','cluster','other')),
    status TEXT NOT NULL
        CHECK (status IN ('planned','in_progress','completed','partial','skipped','aborted')),
    is_amrap INTEGER NOT NULL DEFAULT 0,
    failure_state TEXT NOT NULL DEFAULT 'none'
        CHECK (failure_state IN (
            'none','technical','muscular','stopped_for_body_issue','unknown'
        )),
    started_at_utc TEXT,
    completed_at_utc TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_group_sequence
    ON health_strength_set_groups(owner_user_id, session_exercise_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strength_sets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    set_group_id TEXT NOT NULL,
    component_index INTEGER NOT NULL CHECK (component_index >= 0),
    component_status TEXT NOT NULL CHECK (component_status IN ('completed','partial','skipped')),
    reps INTEGER,
    reps_left INTEGER,
    reps_right INTEGER,
    load_value REAL,
    load_unit TEXT,
    load_entry_mode_snapshot TEXT,
    normalized_external_load_kg REAL,
    added_load_kg REAL,
    assistance_kg REAL,
    bodyweight_kg_snapshot REAL,
    duration_s REAL,
    distance_m REAL,
    rpe REAL CHECK (rpe IS NULL OR (rpe >= 0 AND rpe <= 10)),
    rir REAL CHECK (rir IS NULL OR (rir >= 0 AND rir <= 10)),
    rest_before_s INTEGER,
    tempo_text TEXT,
    completed_at_utc TEXT,
    notes TEXT,
    extra_metrics_json TEXT NOT NULL DEFAULT '{}',
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strength_set_component
    ON health_strength_sets(owner_user_id, set_group_id, component_index)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_session_checkins (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT,
    activity_id TEXT,
    timing TEXT NOT NULL CHECK (timing IN ('pre','post')),
    captured_at_utc TEXT NOT NULL,
    capture_quality TEXT NOT NULL CHECK (capture_quality IN ('contemporaneous','retrospective')),
    captured_before_activity_start INTEGER,
    readiness_1_5 INTEGER CHECK (readiness_1_5 IS NULL OR readiness_1_5 BETWEEN 1 AND 5),
    energy_1_5 INTEGER CHECK (energy_1_5 IS NULL OR energy_1_5 BETWEEN 1 AND 5),
    soreness_1_5 INTEGER CHECK (soreness_1_5 IS NULL OR soreness_1_5 BETWEEN 1 AND 5),
    motivation_1_5 INTEGER CHECK (motivation_1_5 IS NULL OR motivation_1_5 BETWEEN 1 AND 5),
    session_rpe_1_10 REAL CHECK (session_rpe_1_10 IS NULL OR session_rpe_1_10 BETWEEN 1 AND 10),
    perceived_performance_1_5 INTEGER
        CHECK (perceived_performance_1_5 IS NULL OR perceived_performance_1_5 BETWEEN 1 AND 5),
    matched_plan_key TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_checkins_owner_time
    ON health_session_checkins(owner_user_id, captured_at_utc DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_body_locations (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL DEFAULT 'system',
    location_key TEXT NOT NULL,
    parent_key TEXT,
    display_name TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL DEFAULT 'system',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_body_location_key
    ON health_body_locations(location_key) WHERE deleted_at IS NULL;

INSERT OR IGNORE INTO health_body_locations
    (id, owner_user_id, location_key, parent_key, display_name, active, revision,
     family_id, created_by, client_id, client_timestamp, deleted_at)
VALUES
    ('health-body-location-shoulder', 'system', 'shoulder', NULL, 'Shoulder', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-elbow', 'system', 'elbow', NULL, 'Elbow', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-wrist-hand', 'system', 'wrist_hand', NULL, 'Wrist / hand', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-upper-back', 'system', 'upper_back', NULL, 'Upper back', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-lower-back', 'system', 'lower_back', NULL, 'Lower back', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-hip-groin', 'system', 'hip_groin', NULL, 'Hip / groin', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-thigh', 'system', 'thigh', NULL, 'Thigh', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-knee', 'system', 'knee', NULL, 'Knee', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-calf-shin', 'system', 'calf_shin', NULL, 'Calf / shin', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-ankle', 'system', 'ankle', NULL, 'Ankle', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-foot', 'system', 'foot', NULL, 'Foot', 1, 1, 'system', 'system', NULL, NULL, NULL),
    ('health-body-location-other', 'system', 'other', NULL, 'Other', 1, 1, 'system', 'system', NULL, NULL, NULL);

CREATE TABLE IF NOT EXISTS health_body_issue_observations (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT,
    activity_id TEXT,
    session_exercise_id TEXT,
    set_group_id TEXT,
    checkin_id TEXT,
    observed_at_utc TEXT NOT NULL,
    timing TEXT NOT NULL CHECK (timing IN ('pre','during','post','next_day','standalone')),
    issue_type_key TEXT NOT NULL
        CHECK (issue_type_key IN ('pain','tightness','discomfort','weakness','injury','other')),
    body_location_key TEXT NOT NULL,
    side TEXT NOT NULL
        CHECK (side IN ('left','right','bilateral','midline','not_applicable','unknown')),
    severity_0_10 INTEGER NOT NULL CHECK (severity_0_10 BETWEEN 0 AND 10),
    changed_session INTEGER NOT NULL,
    session_change_key TEXT NOT NULL,
    trend_key TEXT NOT NULL DEFAULT 'unknown',
    status TEXT NOT NULL DEFAULT 'active',
    resolved_at_utc TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK ((changed_session = 0 AND session_change_key = 'none') OR
           (changed_session = 1 AND session_change_key <> 'none'))
);
CREATE INDEX IF NOT EXISTS idx_health_body_issues_owner_time
    ON health_body_issue_observations(owner_user_id, observed_at_utc DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_sync_mutation_receipts (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    mutation_id TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    result_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_sync_receipt_owner_mutation
    ON health_sync_mutation_receipts(owner_user_id, mutation_id);

CREATE TABLE IF NOT EXISTS health_change_log (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    owner_user_id TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    entity_revision INTEGER NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('upsert','delete','redirect')),
    data_json TEXT,
    changed_at TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_change_log_owner_sequence
    ON health_change_log(owner_user_id, sequence);

CREATE TABLE IF NOT EXISTS health_sync_notices (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    previous_revision INTEGER,
    accepted_revision INTEGER NOT NULL,
    previous_values_json TEXT,
    message TEXT NOT NULL,
    dismissed_at TEXT,
    expires_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_sync_notices_owner_active
    ON health_sync_notices(owner_user_id, dismissed_at, created_at DESC)
    WHERE deleted_at IS NULL;

-- -------------------------------------------------------------------------
-- Fitness activity ingestion, files, streams, analysis and run planning.
-- Original source files are durable; stream and Garmin assets are regenerable.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS health_file_assets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    asset_kind TEXT NOT NULL,
    storage_class TEXT NOT NULL
        CHECK (storage_class IN ('source_required','private_required','regenerable')),
    storage_key TEXT NOT NULL,
    original_filename TEXT,
    media_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
    file_fingerprint TEXT,
    state TEXT NOT NULL DEFAULT 'staged'
        CHECK (state IN ('staged','ready','missing','deleted')),
    source_asset_id TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_file_asset_storage_key
    ON health_file_assets(storage_key) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_file_asset_owner_class
    ON health_file_assets(owner_user_id, storage_class, state) WHERE deleted_at IS NULL;

-- Survives account-row deletion only until the corresponding private file is
-- successfully unlinked. This closes the commit/filesystem retry gap without
-- retaining Fitness domain data or exposing a public job surface.
CREATE TABLE IF NOT EXISTS health_deferred_file_deletions (
    id TEXT PRIMARY KEY,
    storage_key TEXT NOT NULL,
    storage_class TEXT NOT NULL CHECK (storage_class IN ('source_required','private_required','regenerable')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','retrying')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT,
    owner_user_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_deferred_file_deletions_pending
    ON health_deferred_file_deletions(status, created_at) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_source_records (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    record_kind TEXT NOT NULL,
    sample_type TEXT,
    transport_key TEXT NOT NULL,
    origin_provider_key TEXT NOT NULL,
    source_namespace TEXT NOT NULL DEFAULT '',
    source_object_id TEXT NOT NULL,
    external_object_id TEXT,
    source_device_identifier TEXT,
    source_name TEXT,
    product_type TEXT,
    device_json TEXT,
    metadata_json TEXT,
    domain_entity_type TEXT,
    domain_entity_id TEXT,
    source_created_at_utc TEXT,
    raw_asset_id TEXT,
    file_fingerprint TEXT,
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active','deleted','superseded')),
    raw_metadata_json TEXT,
    parser_name TEXT,
    parser_version TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_source_exact_identity
    ON health_source_records(
        owner_user_id, record_kind, transport_key, source_namespace, source_object_id
    ) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_source_external_identity
    ON health_source_records(owner_user_id, origin_provider_key, external_object_id)
    WHERE external_object_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_source_fit_fingerprint
    ON health_source_records(owner_user_id, file_fingerprint)
    WHERE file_fingerprint IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_imports (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    client_import_id TEXT,
    file_asset_id TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    activity_id TEXT,
    job_id TEXT,
    status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','processing','complete','error')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    error_code TEXT,
    error_message TEXT,
    retryable INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_import_client_id
    ON health_imports(owner_user_id, client_import_id)
    WHERE client_import_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_import_owner_status
    ON health_imports(owner_user_id, status, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_source_records (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','corroborating','metadata_only')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_source_link
    ON health_activity_source_records(owner_user_id, activity_id, source_record_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_stream_assets (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    file_asset_id TEXT NOT NULL,
    stream_kind TEXT NOT NULL DEFAULT 'primary',
    format TEXT NOT NULL DEFAULT 'parquet',
    schema_version INTEGER NOT NULL DEFAULT 1,
    parser_version TEXT NOT NULL,
    row_count INTEGER NOT NULL,
    start_offset_ms INTEGER,
    end_offset_ms INTEGER,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_stream_activity
    ON health_activity_stream_assets(owner_user_id, activity_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_metric_index (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    stream_asset_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    sample_count INTEGER NOT NULL,
    non_null_count INTEGER NOT NULL,
    minimum REAL,
    maximum REAL,
    average REAL,
    unit_key TEXT,
    quality TEXT NOT NULL DEFAULT 'measured',
    source_field TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_metric_index_key
    ON health_activity_metric_index(owner_user_id, stream_asset_id, metric_key)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_summary_metrics (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    value_number REAL,
    value_text TEXT,
    value_bool INTEGER,
    unit_key TEXT,
    origin TEXT NOT NULL CHECK (origin IN ('source','derived','user')),
    quality TEXT NOT NULL DEFAULT 'measured',
    calculation_version TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK ((value_number IS NOT NULL) + (value_text IS NOT NULL) + (value_bool IS NOT NULL) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_summary_metric
    ON health_activity_summary_metrics(owner_user_id, activity_id, metric_key, origin)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_intervals (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    parent_interval_id TEXT,
    sequence INTEGER NOT NULL,
    interval_kind TEXT NOT NULL,
    origin TEXT NOT NULL,
    start_offset_ms INTEGER NOT NULL,
    end_offset_ms INTEGER NOT NULL,
    start_distance_m REAL,
    end_distance_m REAL,
    label TEXT,
    metrics_json TEXT NOT NULL DEFAULT '{}',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (end_offset_ms >= start_offset_ms)
);
CREATE INDEX IF NOT EXISTS idx_health_activity_intervals
    ON health_activity_intervals(owner_user_id, activity_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_markers (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    offset_ms INTEGER NOT NULL,
    distance_m REAL,
    marker_key TEXT NOT NULL,
    label TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_activity_markers
    ON health_activity_markers(owner_user_id, activity_id, offset_ms)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_features (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    feature_key TEXT NOT NULL,
    feature_version TEXT NOT NULL,
    value_json TEXT NOT NULL,
    quality TEXT NOT NULL DEFAULT 'derived',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_feature
    ON health_activity_features(owner_user_id, activity_id, feature_key, feature_version)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_analysis_results (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    analysis_key TEXT NOT NULL,
    calculation_version TEXT NOT NULL,
    status TEXT NOT NULL,
    result_json TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_analysis
    ON health_activity_analysis_results(owner_user_id, activity_id, analysis_key, calculation_version)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_quality_findings (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    finding_key TEXT NOT NULL,
    severity TEXT NOT NULL,
    message TEXT NOT NULL,
    start_offset_ms INTEGER,
    end_offset_ms INTEGER,
    limits_analysis_keys_json TEXT NOT NULL DEFAULT '[]',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_activity_quality
    ON health_activity_quality_findings(owner_user_id, activity_id, severity)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_import_review_candidates (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    import_id TEXT NOT NULL,
    candidate_activity_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    confidence REAL,
    state TEXT NOT NULL DEFAULT 'pending',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS health_gear_items (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    gear_type_key TEXT NOT NULL,
    name TEXT NOT NULL,
    brand TEXT,
    model TEXT,
    variant TEXT,
    started_at TEXT,
    retired_at TEXT,
    initial_usage_distance_m REAL,
    default_for_sport_key TEXT,
    notes TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_gear_owner_active
    ON health_gear_items(owner_user_id, active, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_gear_owner_default
    ON health_gear_items(owner_user_id, default_for_sport_key)
    WHERE active = 1 AND default_for_sport_key IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_gear_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    gear_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary','sensor','other')),
    start_offset_ms INTEGER,
    end_offset_ms INTEGER,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_gear_link
    ON health_activity_gear_links(owner_user_id, activity_id, gear_id, role)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_planned_session_gear_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT NOT NULL,
    gear_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('primary','secondary','sensor','other')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_planned_gear_link
    ON health_planned_session_gear_links(owner_user_id, planned_session_id, gear_id, role)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_activity_goal_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('planned','user_assigned','inferred_reviewed')),
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_activity_goal_link
    ON health_activity_goal_links(owner_user_id, activity_id, goal_id, role)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_plan_activity_links (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    planned_session_id TEXT NOT NULL,
    activity_id TEXT NOT NULL,
    match_method TEXT NOT NULL,
    confidence REAL,
    active INTEGER NOT NULL DEFAULT 1,
    user_confirmed INTEGER NOT NULL DEFAULT 0,
    unlinked_at TEXT,
    explanation TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_plan_activity_active
    ON health_plan_activity_links(owner_user_id, planned_session_id)
    WHERE active = 1 AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_jobs (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    job_type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','running','complete','failed')),
    payload_json TEXT NOT NULL DEFAULT '{}',
    result_json TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    available_at TEXT NOT NULL,
    lease_token TEXT,
    lease_expires_at TEXT,
    last_error TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_jobs_claim
    ON health_jobs(status, available_at, created_at) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_run_workout_steps (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_version_id TEXT NOT NULL,
    parent_step_id TEXT,
    sequence INTEGER NOT NULL,
    kilometre_index INTEGER,
    step_kind TEXT NOT NULL CHECK (step_kind IN ('step','repeat_block')),
    repeat_count INTEGER,
    duration_type TEXT NOT NULL
        CHECK (duration_type IN ('distance_m','time_s','lap_button','open','calories')),
    duration_value REAL,
    target_type TEXT NOT NULL
        CHECK (target_type IN ('pace_s_per_km','heart_rate_bpm','heart_rate_zone','power_w',
                               'power_zone','cadence_spm','rpe','none')),
    target_low REAL,
    target_high REAL,
    target_unit TEXT,
    intensity_label TEXT,
    display_name TEXT NOT NULL,
    instruction_text TEXT,
    mental_cue_text TEXT,
    spoken_cue_text TEXT,
    allow_manual_advance INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_run_steps_version
    ON health_run_workout_steps(owner_user_id, workout_version_id, parent_step_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_run_workout_cues (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_version_id TEXT NOT NULL,
    step_id TEXT,
    sequence INTEGER NOT NULL,
    trigger_type TEXT NOT NULL,
    trigger_value REAL,
    short_text TEXT NOT NULL,
    spoken_text TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_run_cues_version
    ON health_run_workout_cues(owner_user_id, workout_version_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_garmin_exports (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    workout_version_id TEXT NOT NULL,
    destination TEXT NOT NULL DEFAULT 'garmin_fit_file',
    status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued','generating','ready','error','revoked')),
    file_asset_id TEXT,
    file_name TEXT,
    external_export_id TEXT,
    scheduled_date TEXT,
    mapping_report_json TEXT NOT NULL DEFAULT '[]',
    last_attempt_at TEXT,
    last_error TEXT,
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_garmin_export_version_destination
    ON health_garmin_exports(owner_user_id, workout_version_id, destination)
    WHERE status <> 'revoked' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_file_reconciliation_runs (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    status TEXT NOT NULL,
    required_missing_count INTEGER NOT NULL DEFAULT 0,
    regenerable_missing_count INTEGER NOT NULL DEFAULT 0,
    orphan_count INTEGER NOT NULL DEFAULT 0,
    result_json TEXT NOT NULL DEFAULT '{}',
    revision INTEGER NOT NULL DEFAULT 1,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);

-- -------------------------------------------------------------------------
-- Fitness sleep/recovery provenance and private progress photographs.
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS health_source_priorities (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    origin_provider_key TEXT NOT NULL,
    transport_key TEXT NOT NULL DEFAULT '',
    source_namespace TEXT NOT NULL DEFAULT '',
    priority INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_source_priority_scope
    ON health_source_priorities(
        owner_user_id, metric_key, origin_provider_key, transport_key, source_namespace
    ) WHERE deleted_at IS NULL;

-- Owner-bound health-provider authorisation. OAuth material is encrypted as a
-- single rotating payload and is never included in Fitness sync or exports.
CREATE TABLE IF NOT EXISTS health_provider_connections (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('withings')),
    provider_user_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'connected','reauth_required','provider_down','disconnected'
    )),
    scopes_json TEXT NOT NULL DEFAULT '[]',
    encrypted_token_json TEXT,
    access_token_expires_at TEXT,
    refresh_token_expires_at TEXT,
    last_sync_at TEXT,
    data_through_at TEXT,
    last_error_code TEXT,
    subscribed_categories_json TEXT NOT NULL DEFAULT '[]',
    webhook_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (webhook_status IN ('pending','active','error','disabled')),
    sync_lease_token TEXT,
    sync_lease_expires_at TEXT,
    next_retry_at TEXT,
    consecutive_sync_failures INTEGER NOT NULL DEFAULT 0
        CHECK (consecutive_sync_failures >= 0),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_provider_connection_owner
    ON health_provider_connections(owner_user_id, provider)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_provider_connection_remote_user
    ON health_provider_connections(provider, provider_user_id)
    WHERE status <> 'disconnected' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_provider_connection_due
    ON health_provider_connections(provider, status, next_retry_at, last_sync_at)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_provider_oauth_states (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('withings')),
    state_digest TEXT NOT NULL,
    return_surface TEXT NOT NULL CHECK (return_surface IN ('app','web')),
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_provider_oauth_state_digest
    ON health_provider_oauth_states(provider, state_digest)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_provider_oauth_state_expiry
    ON health_provider_oauth_states(expires_at)
    WHERE consumed_at IS NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_provider_notifications (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    connection_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('withings')),
    provider_user_id TEXT NOT NULL,
    event_key TEXT NOT NULL,
    category INTEGER NOT NULL,
    start_at_unix INTEGER NOT NULL,
    end_at_unix INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','processing','complete','error')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_retry_at TEXT,
    last_error_code TEXT,
    processed_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (end_at_unix >= start_at_unix)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_provider_notification_identity
    ON health_provider_notifications(connection_id, event_key)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_provider_notification_pending
    ON health_provider_notifications(status, next_retry_at, created_at)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_sleep_sessions (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    sleep_start_utc TEXT NOT NULL,
    sleep_end_utc TEXT NOT NULL,
    duration_s REAL NOT NULL CHECK (duration_s >= 0),
    awake_duration_s REAL CHECK (awake_duration_s IS NULL OR awake_duration_s >= 0),
    source_quality TEXT,
    source_record_id TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (sleep_end_utc > sleep_start_utc)
);
CREATE INDEX IF NOT EXISTS idx_health_sleep_owner_start
    ON health_sleep_sessions(owner_user_id, sleep_start_utc DESC)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_sleep_source
    ON health_sleep_sessions(owner_user_id, source_record_id)
    WHERE source_record_id IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_sleep_stages (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    sleep_session_id TEXT NOT NULL,
    source_record_id TEXT,
    sequence INTEGER NOT NULL,
    stage TEXT NOT NULL,
    start_at_utc TEXT NOT NULL,
    end_at_utc TEXT NOT NULL,
    duration_s REAL NOT NULL CHECK (duration_s >= 0),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK (end_at_utc > start_at_utc)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_sleep_stage_sequence
    ON health_sleep_stages(owner_user_id, sleep_session_id, sequence)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_sleep_stage_time
    ON health_sleep_stages(owner_user_id, sleep_session_id, start_at_utc)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_sleep_stage_source
    ON health_sleep_stages(owner_user_id, source_record_id)
    WHERE source_record_id IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_recovery_observations (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    metric_key TEXT NOT NULL,
    observed_at_utc TEXT NOT NULL,
    value_number REAL,
    value_text TEXT,
    unit_key TEXT,
    source_quality TEXT,
    source_record_id TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT,
    CHECK ((value_number IS NOT NULL) + (value_text IS NOT NULL) = 1)
);
CREATE INDEX IF NOT EXISTS idx_health_recovery_owner_metric_time
    ON health_recovery_observations(owner_user_id, metric_key, observed_at_utc DESC)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_recovery_source
    ON health_recovery_observations(owner_user_id, source_record_id)
    WHERE source_record_id IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_progress_photos (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    pose TEXT NOT NULL CHECK (pose IN ('front','side_left','side_right','back','custom')),
    body_weight_kg REAL CHECK (body_weight_kg IS NULL OR body_weight_kg > 0),
    measurement_snapshot_json TEXT,
    phase_id TEXT,
    original_asset_id TEXT NOT NULL,
    thumbnail_asset_id TEXT,
    notes TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_progress_photo_original
    ON health_progress_photos(owner_user_id, original_asset_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_progress_photo_owner_date_pose
    ON health_progress_photos(owner_user_id, captured_at DESC, pose)
    WHERE deleted_at IS NULL;

-- Registered-key unified analysis definitions. Query results for heavy work are
-- stored on the existing fenced health_jobs row; definitions never contain SQL.
CREATE TABLE IF NOT EXISTS health_saved_analysis_charts (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    measure_key TEXT NOT NULL,
    dimension_key TEXT NOT NULL,
    chart_type_key TEXT NOT NULL,
    filter_keys_json TEXT NOT NULL DEFAULT '[]',
    comparison_key TEXT,
    date_window_days INTEGER NOT NULL CHECK (date_window_days BETWEEN 1 AND 366),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_saved_analysis_charts_owner
    ON health_saved_analysis_charts(owner_user_id, updated_at DESC)
    WHERE deleted_at IS NULL;

-- Fitness Coach retains reviewable proposals and recommendation outcomes, never
-- conversation transcripts. Model output remains inert JSON until ordinary
-- owner-scoped services revalidate a confirmed proposal.
CREATE TABLE IF NOT EXISTS health_coach_proposals (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    proposal_kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    validation_json TEXT NOT NULL,
    warnings_json TEXT NOT NULL DEFAULT '[]',
    evidence_json TEXT NOT NULL DEFAULT '[]',
    model_provider TEXT NOT NULL,
    model_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','confirmed','declined','expired','invalid')),
    expires_at TEXT NOT NULL,
    confirmed_at TEXT,
    declined_at TEXT,
    result_ids_json TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_coach_proposals_owner_status
    ON health_coach_proposals(owner_user_id, status, expires_at)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_coach_recommendations (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    recommendation_type TEXT NOT NULL,
    goal_ids_json TEXT NOT NULL DEFAULT '[]',
    finding_references_json TEXT NOT NULL DEFAULT '[]',
    evidence_json TEXT NOT NULL DEFAULT '[]',
    recommendation_text TEXT NOT NULL,
    proposal_id TEXT,
    expected_effect_json TEXT,
    model_provider TEXT NOT NULL,
    model_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    user_feedback TEXT,
    followed_state TEXT,
    outcome_review TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_coach_recommendations_owner
    ON health_coach_recommendations(owner_user_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_coach_conversations (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    title TEXT NOT NULL,
    last_message_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_coach_conversations_owner_recent
    ON health_coach_conversations(owner_user_id, last_message_at DESC, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_coach_messages (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    role TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content TEXT NOT NULL,
    intent TEXT,
    model_provider TEXT,
    model_id TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_coach_message_sequence_active
    ON health_coach_messages(owner_user_id, conversation_id, sequence)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_coach_messages_owner_conversation
    ON health_coach_messages(owner_user_id, conversation_id, sequence)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_coach_memories (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    content TEXT NOT NULL,
    category TEXT,
    confirmed_at TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_coach_memories_owner_recent
    ON health_coach_memories(owner_user_id, updated_at DESC)
    WHERE deleted_at IS NULL;

-- Owner-bound Intervals.icu calendar delivery and explicit completed-activity
-- import. Provider credentials are held in one encrypted payload and are never
-- exposed through Fitness sync or exports.
CREATE TABLE IF NOT EXISTS health_intervals_connections (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    provider_user_id TEXT,
    provider_display_name TEXT,
    status TEXT NOT NULL CHECK (status IN (
        'connected','reauth_required','provider_down','disconnected'
    )),
    auth_method TEXT NOT NULL CHECK (auth_method IN ('oauth','personal_api_key')),
    scopes_json TEXT NOT NULL DEFAULT '["CALENDAR:WRITE","SETTINGS:READ","ACTIVITY:READ"]',
    encrypted_token_json TEXT,
    access_token_expires_at TEXT,
    garmin_training_connected INTEGER
        CHECK (garmin_training_connected IS NULL OR garmin_training_connected IN (0,1)),
    last_tested_at TEXT,
    last_error_code TEXT,
    activity_import_enabled INTEGER NOT NULL DEFAULT 0
        CHECK (activity_import_enabled IN (0,1)),
    activity_import_since TEXT,
    last_activity_import_at TEXT,
    last_activity_import_error_code TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_intervals_connection_owner
    ON health_intervals_connections(owner_user_id)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_intervals_connection_athlete
    ON health_intervals_connections(provider_user_id)
    WHERE provider_user_id IS NOT NULL AND status <> 'disconnected' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_intervals_oauth_states (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    state_digest TEXT NOT NULL,
    return_surface TEXT NOT NULL CHECK (return_surface IN ('app','web')),
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_intervals_oauth_state_digest
    ON health_intervals_oauth_states(state_digest)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_intervals_oauth_state_expiry
    ON health_intervals_oauth_states(expires_at)
    WHERE consumed_at IS NULL AND deleted_at IS NULL;

-- Strava is deliberately separate from generic provider connections: its
-- rotating token, athlete identity and import cursor are owner-private.
CREATE TABLE IF NOT EXISTS health_strava_connections (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    athlete_id TEXT,
    athlete_name TEXT,
    status TEXT NOT NULL CHECK (status IN (
        'connected','reauth_required','provider_down','disconnected'
    )),
    scopes_json TEXT NOT NULL DEFAULT '["activity:read_all"]',
    encrypted_token_json TEXT,
    access_token_expires_at TEXT,
    last_sync_at TEXT,
    data_through_at TEXT,
    last_error_code TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strava_connection_owner
    ON health_strava_connections(owner_user_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strava_connection_athlete
    ON health_strava_connections(athlete_id)
    WHERE athlete_id IS NOT NULL AND status <> 'disconnected' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_strava_oauth_states (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    state_digest TEXT NOT NULL,
    return_surface TEXT NOT NULL CHECK (return_surface IN ('app','web')),
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_strava_oauth_state_digest
    ON health_strava_oauth_states(state_digest) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_strava_oauth_state_expiry
    ON health_strava_oauth_states(expires_at)
    WHERE consumed_at IS NULL AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS health_intervals_publications (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    connection_id TEXT NOT NULL,
    planned_session_id TEXT NOT NULL,
    external_id TEXT NOT NULL,
    provider_event_id TEXT,
    state TEXT NOT NULL CHECK (state IN ('pending','sent','cancelled','error')),
    desired_action TEXT NOT NULL CHECK (desired_action IN ('publish','cancel')),
    source_revision INTEGER NOT NULL CHECK (source_revision >= 1),
    payload_json TEXT,
    mapping_warnings_json TEXT NOT NULL DEFAULT '[]',
    push_errors_json TEXT NOT NULL DEFAULT '[]',
    sent_at TEXT,
    last_attempt_at TEXT,
    next_retry_at TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    last_error_code TEXT,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_intervals_publication_session
    ON health_intervals_publications(owner_user_id, planned_session_id)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_health_intervals_publication_external
    ON health_intervals_publications(owner_user_id, external_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_health_intervals_publication_retry
    ON health_intervals_publications(state, next_retry_at)
    WHERE state IN ('pending','error') AND deleted_at IS NULL;

-- Deterministic facility availability imported from Example School's periodically issued
-- staff timetable. Versions are immutable so a future timetable can be uploaded
-- before the current one ends; readers select the newest version covering each
-- requested date. These rows are projected into Calendar on demand and never
-- become ordinary reminder-generating calendar events.
CREATE TABLE IF NOT EXISTS facility_schedule_versions (
    id TEXT PRIMARY KEY,
    provider_key TEXT NOT NULL DEFAULT 'school_college'
        CHECK (provider_key IN ('school_college')),
    title TEXT NOT NULL,
    source_document_id TEXT,
    personal_owner_user_id TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    valid_to TEXT NOT NULL,
    source_sha256 TEXT NOT NULL,
    day_count INTEGER NOT NULL CHECK (day_count > 0),
    status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed')),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_facility_versions_family_hash_active
    ON facility_schedule_versions(family_id, provider_key, source_sha256)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_facility_versions_family_range
    ON facility_schedule_versions(family_id, provider_key, valid_from, valid_to, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS facility_schedule_days (
    id TEXT PRIMARY KEY,
    version_id TEXT NOT NULL,
    local_date TEXT NOT NULL,
    family_swimming_json TEXT NOT NULL DEFAULT '[]',
    lane_swimming_json TEXT NOT NULL DEFAULT '[]',
    weights_room_json TEXT NOT NULL DEFAULT '[]',
    pool_closed INTEGER NOT NULL DEFAULT 0 CHECK (pool_closed IN (0,1)),
    weights_room_closed INTEGER NOT NULL DEFAULT 0 CHECK (weights_room_closed IN (0,1)),
    raw_athens TEXT,
    raw_weights_room TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_facility_days_version_date_active
    ON facility_schedule_days(version_id, local_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_facility_days_family_date
    ON facility_schedule_days(family_id, local_date, version_id)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS facility_calendar_preferences (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    show_family_swimming INTEGER NOT NULL DEFAULT 0
        CHECK (show_family_swimming IN (0,1)),
    show_personal_facilities INTEGER NOT NULL DEFAULT 0
        CHECK (show_personal_facilities IN (0,1)),
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_facility_preferences_user_active
    ON facility_calendar_preferences(user_id)
    WHERE deleted_at IS NULL;

-- Parent-authored caregiver handover. Booking secrets are stored only as
-- one-way hashes; the bootstrap value is returned once in a URL fragment.
CREATE TABLE IF NOT EXISTS caregiver_handovers (
    id TEXT PRIMARY KEY,
    address TEXT,
    wifi_name TEXT,
    wifi_password TEXT,
    emergency_instructions TEXT,
    house_instructions TEXT,
    dog_instructions TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_handover_family_active
    ON caregiver_handovers(family_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS caregiver_child_profiles (
    id TEXT PRIMARY KEY,
    handover_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    care_notes TEXT,
    allergies TEXT,
    food TEXT,
    comfort TEXT,
    toileting TEXT,
    bedtime TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_child_family_active
    ON caregiver_child_profiles(family_id, child_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS caregiver_contacts (
    id TEXT PRIMARY KEY,
    handover_id TEXT NOT NULL,
    name TEXT NOT NULL,
    phone TEXT NOT NULL,
    relationship TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_caregiver_contacts_handover
    ON caregiver_contacts(family_id, handover_id, priority) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS caregiver_bookings (
    id TEXT PRIMARY KEY,
    handover_id TEXT NOT NULL,
    label TEXT NOT NULL,
    starts_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    child_ids TEXT NOT NULL,
    bootstrap_hash TEXT NOT NULL,
    bootstrap_used_at TEXT,
    session_hash TEXT,
    last_accessed_at TEXT,
    revoked_at TEXT,
    family_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_by TEXT,
    client_id TEXT,
    client_timestamp TEXT,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_booking_bootstrap
    ON caregiver_bookings(bootstrap_hash);
CREATE UNIQUE INDEX IF NOT EXISTS idx_caregiver_booking_session
    ON caregiver_bookings(session_hash) WHERE session_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_caregiver_booking_family_window
    ON caregiver_bookings(family_id, starts_at, expires_at) WHERE deleted_at IS NULL;
