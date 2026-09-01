import CryptoKit
import Darwin
import Foundation
import GRDB
import os

enum FitnessDatabaseError: LocalizedError {
    case notActive
    case leaseRequired
    case staleLease
    case unverifiedLegacyStore(store: URL)
    case invalidRecoveryBackup(URL)
    case migrationFailed(store: URL, backup: URL?, underlying: Error)
    case recoveryFailed(
        store: URL,
        backup: URL?,
        recoveryPaths: [URL],
        underlying: Error
    )

    var errorDescription: String? {
        switch self {
        case .notActive:
            return "Fitness data is locked. Sign in again to open it."
        case .leaseRequired:
            return "Fitness data access was refused because it was not bound to the active profile."
        case .staleLease:
            return "The active Fitness profile changed before this operation finished."
        case .unverifiedLegacyStore:
            return "HausKlar found an older Fitness store whose owner could not be proven. It was left untouched for recovery."
        case .invalidRecoveryBackup:
            return "That Fitness recovery backup could not be verified for this profile."
        case .migrationFailed:
            return "Fitness could not safely upgrade its local database. The original data and pending changes were preserved for recovery."
        case .recoveryFailed(_, let backup, let recoveryPaths, _):
            let backupDescription = backup.map {
                " The verified source backup remains at \($0.path)."
            } ?? ""
            let recoveryDescription = recoveryPaths.isEmpty
                ? " No additional recovery path was removed."
                : " Recoverable files were preserved at \(recoveryPaths.map(\.path).joined(separator: ", "))."
            return "Fitness recovery did not complete safely.\(backupDescription)\(recoveryDescription)"
        }
    }
}

/// An immutable capability for one opened owner-scoped Fitness store.
///
/// Services capture this when they activate and carry it across every suspension.
/// A lease from a closed store can never resolve to a subsequently opened store,
/// including when the same account signs in again during the same process.
struct FitnessStoreLease: Equatable, Sendable {
    let identity: String
    fileprivate let generation: UInt64
}

struct FitnessServiceSession: Equatable, Sendable {
    let identity: String
    let storeLease: FitnessStoreLease
}

private enum FitnessStoreLeaseContext {
    @TaskLocal static var current: FitnessStoreLease?
}

enum FitnessMigrations {
    static let identifiers = [
        "001_fitness_foundation",
        "002_nutrition_body",
        "003_strength",
        "004_workout_templates_programmes",
        "005_activity_import_storage",
        "006_activity_analysis_calendar",
        "007_run_plans_garmin",
        "008_healthkit_recovery",
        "009_progress_photos",
        "010_saved_analysis_charts",
        "011_nutrition_contract",
        "012_strength_contract",
        "013_nutrition_shared_contract",
        "014_daily_strength_progress_contract",
        "015_reviewable_sync_notices",
        "016_generic_body_measurements",
        "017_heart_rate_zone_settings",
        "018_goal_relationships",
        "019_cycle_tracking",
        "020_body_measurement_canonical_override",
        "021_healthkit_workout_sources",
        "022_fitness_consumer_experience",
        "023_read_path_indexes",
        "024_sync_rejection_journal",
        "025_body_weight_component_indexes",
        "026_healthkit_workout_outbox",
    ]

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(identifiers[0]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );

                CREATE TABLE fitness_outbox (
                    mutation_id TEXT PRIMARY KEY NOT NULL,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    operation TEXT NOT NULL CHECK(operation IN ('upsert', 'delete')),
                    payload_schema_version INTEGER NOT NULL,
                    base_revision INTEGER,
                    payload_json TEXT NOT NULL,
                    created_at_client TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT,
                    last_error TEXT
                );
                CREATE INDEX fitness_outbox_created_idx ON fitness_outbox(created_at_client, mutation_id);
                CREATE INDEX fitness_outbox_entity_idx ON fitness_outbox(entity_type, entity_id);

                CREATE TABLE fitness_sync_notices (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    message TEXT NOT NULL,
                    entity_type TEXT,
                    entity_id TEXT,
                    created_at TEXT NOT NULL,
                    dismissed_at TEXT
                );

                CREATE TABLE fitness_redirects (
                    entity_type TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(entity_type, source_id)
                );

                CREATE TABLE fitness_remote_entities (
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    operation TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    changed_at TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );

                CREATE TABLE fitness_pending_files (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    relative_path TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    sha256 TEXT,
                    state TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    last_error TEXT
                );

                CREATE TABLE fitness_healthkit_query_state (
                    sample_type TEXT NOT NULL,
                    predicate_version INTEGER NOT NULL,
                    anchor_data BLOB,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(sample_type, predicate_version)
                );
                """)
        }

        migrator.registerMigration(identifiers[1]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_nutrition_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    day_boundary_hour INTEGER NOT NULL DEFAULT 4,
                    energy_target_kcal REAL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );

                CREATE TABLE fitness_goals (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    metric TEXT NOT NULL,
                    target_value REAL,
                    unit TEXT,
                    target_date TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_goals_active_idx ON fitness_goals(deleted_at, target_date);

                CREATE TABLE fitness_training_phases (
                    id TEXT PRIMARY KEY NOT NULL,
                    phase_type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    starts_on TEXT,
                    ends_on TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );

                CREATE TABLE fitness_training_phase_goal_links (
                    id TEXT PRIMARY KEY NOT NULL,
                    phase_id TEXT NOT NULL,
                    goal_id TEXT NOT NULL,
                    role TEXT NOT NULL CHECK(role IN ('primary', 'secondary', 'constraint')),
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE UNIQUE INDEX fitness_phase_goal_link_idx
                    ON fitness_training_phase_goal_links(phase_id, goal_id) WHERE deleted_at IS NULL;
                CREATE UNIQUE INDEX fitness_one_primary_goal_idx
                    ON fitness_training_phase_goal_links(phase_id) WHERE role = 'primary' AND deleted_at IS NULL;

                CREATE TABLE fitness_foods (
                    id TEXT PRIMARY KEY NOT NULL,
                    current_version_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    brand TEXT,
                    is_favourite INTEGER NOT NULL DEFAULT 0,
                    is_archived INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_foods_search_idx ON fitness_foods(name, brand, is_archived);

                CREATE TABLE fitness_food_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    food_id TEXT NOT NULL,
                    kcal_per_100g REAL,
                    default_serving_grams REAL,
                    created_at TEXT NOT NULL,
                    superseded_at TEXT
                );
                CREATE INDEX fitness_food_versions_food_idx ON fitness_food_versions(food_id, created_at);

                CREATE TABLE fitness_food_log_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    food_id TEXT,
                    food_version_id TEXT,
                    food_name TEXT NOT NULL,
                    logged_at TEXT NOT NULL,
                    nutrition_date TEXT NOT NULL,
                    meal TEXT NOT NULL,
                    amount_grams REAL,
                    kcal REAL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_food_log_date_idx ON fitness_food_log_entries(nutrition_date, logged_at);

                CREATE TABLE fitness_body_measurements (
                    id TEXT PRIMARY KEY NOT NULL,
                    measured_at TEXT NOT NULL,
                    weight_kg REAL NOT NULL,
                    source TEXT NOT NULL,
                    source_identifier TEXT,
                    is_canonical INTEGER NOT NULL DEFAULT 1,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_body_measurement_time_idx ON fitness_body_measurements(measured_at, deleted_at);
                """)
        }

        migrator.registerMigration(identifiers[2]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_exercises (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    primary_muscle TEXT,
                    is_favourite INTEGER NOT NULL DEFAULT 0,
                    is_custom INTEGER NOT NULL DEFAULT 1,
                    is_archived INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_exercises_search_idx ON fitness_exercises(name, category, is_archived);

                CREATE TABLE fitness_exercise_setups (
                    id TEXT PRIMARY KEY NOT NULL,
                    exercise_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    load_mode TEXT NOT NULL,
                    increment_kg REAL,
                    bar_weight_kg REAL,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_setup_exercise_idx ON fitness_exercise_setups(exercise_id, is_default, deleted_at);

                CREATE TABLE fitness_planned_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    planned_for TEXT,
                    is_completed INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_planned_session_date_idx ON fitness_planned_sessions(planned_for, deleted_at);

                CREATE TABLE fitness_planned_session_exercises (
                    id TEXT PRIMARY KEY NOT NULL,
                    planned_session_id TEXT NOT NULL,
                    exercise_id TEXT NOT NULL,
                    exercise_setup_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    superset_group_key TEXT,
                    notes TEXT,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_planned_exercise_session_idx ON fitness_planned_session_exercises(planned_session_id, position, deleted_at);

                CREATE TABLE fitness_planned_sets (
                    id TEXT PRIMARY KEY NOT NULL,
                    planned_exercise_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    training_role TEXT NOT NULL,
                    structure_type TEXT NOT NULL,
                    component_count INTEGER NOT NULL DEFAULT 1,
                    reps_min INTEGER,
                    reps_max INTEGER,
                    load_min REAL,
                    load_max REAL,
                    load_unit TEXT,
                    rpe_min REAL,
                    rpe_max REAL,
                    rir_min REAL,
                    rir_max REAL,
                    rest_seconds INTEGER,
                    is_amrap INTEGER NOT NULL DEFAULT 0,
                    notes TEXT,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_planned_sets_exercise_idx ON fitness_planned_sets(planned_exercise_id, position, deleted_at);

                CREATE TABLE fitness_strength_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    planned_session_id TEXT,
                    readiness INTEGER,
                    session_rpe REAL,
                    performance INTEGER,
                    note TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE UNIQUE INDEX fitness_one_active_session_idx ON fitness_strength_sessions(status) WHERE status = 'active' AND deleted_at IS NULL;
                CREATE INDEX fitness_strength_session_time_idx ON fitness_strength_sessions(started_at, status);

                CREATE TABLE fitness_strength_session_exercises (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    exercise_id TEXT NOT NULL,
                    exercise_name TEXT NOT NULL,
                    setup_id TEXT NOT NULL,
                    setup_name TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_session_exercise_idx ON fitness_strength_session_exercises(session_id, position, deleted_at);

                CREATE TABLE fitness_strength_set_groups (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_exercise_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    structure_type TEXT NOT NULL DEFAULT 'straight',
                    is_amrap INTEGER NOT NULL DEFAULT 0,
                    failure_state TEXT NOT NULL DEFAULT 'unknown',
                    status TEXT NOT NULL DEFAULT 'completed',
                    position INTEGER NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_set_group_exercise_idx ON fitness_strength_set_groups(session_exercise_id, position, deleted_at);

                CREATE TABLE fitness_strength_set_components (
                    id TEXT PRIMARY KEY NOT NULL,
                    group_id TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'completed',
                    load_kg REAL,
                    reps INTEGER,
                    duration_seconds INTEGER,
                    distance_metres REAL,
                    rir REAL,
                    rpe REAL,
                    completed_at TEXT,
                    position INTEGER NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_set_component_group_idx ON fitness_strength_set_components(group_id, position, deleted_at);

                CREATE TABLE fitness_session_checkins (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    value INTEGER,
                    note TEXT,
                    recorded_at TEXT NOT NULL,
                    retrospective INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );

                CREATE TABLE fitness_body_issues (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT,
                    issue_type_key TEXT NOT NULL,
                    body_location_key TEXT NOT NULL,
                    side TEXT NOT NULL DEFAULT 'none',
                    severity INTEGER NOT NULL,
                    timing TEXT NOT NULL,
                    changed_session INTEGER NOT NULL DEFAULT 0,
                    session_change_key TEXT NOT NULL,
                    note TEXT,
                    observed_at TEXT NOT NULL,
                    resolved_at TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_body_issue_open_idx ON fitness_body_issues(resolved_at, observed_at, deleted_at);
                """)

            // Canonical exercises are owner-scoped server data and arrive through sync.
            // Fixed cross-owner local IDs would be unsyncable; custom offline exercises
            // are instead created with UUIDs and enqueued by FitnessRepository.
        }

        migrator.registerMigration(identifiers[3]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_planned_sessions ADD COLUMN training_programme_id TEXT;
                ALTER TABLE fitness_planned_sessions ADD COLUMN workout_version_id TEXT;

                CREATE TABLE fitness_workout_definitions (
                    id TEXT PRIMARY KEY NOT NULL,
                    sport_key TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    active INTEGER NOT NULL DEFAULT 1,
                    current_version_id TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_workout_definitions_name_idx
                    ON fitness_workout_definitions(active, sport_key, name, deleted_at);

                CREATE TABLE fitness_workout_definition_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_definition_id TEXT NOT NULL,
                    version_number INTEGER NOT NULL DEFAULT 1,
                    title TEXT NOT NULL,
                    purpose TEXT,
                    estimated_duration_seconds INTEGER,
                    estimated_distance_metres REAL,
                    structured_summary_json TEXT NOT NULL DEFAULT '{}',
                    version_source TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX fitness_workout_versions_definition_idx
                    ON fitness_workout_definition_versions(workout_definition_id, version_number DESC);

                CREATE TABLE fitness_workout_version_exercises (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_version_id TEXT NOT NULL,
                    exercise_id TEXT NOT NULL,
                    exercise_setup_id TEXT,
                    position INTEGER NOT NULL,
                    superset_group_key TEXT,
                    substitution_exercise_ids_json TEXT NOT NULL DEFAULT '[]',
                    notes TEXT
                );
                CREATE INDEX fitness_workout_version_exercises_idx
                    ON fitness_workout_version_exercises(workout_version_id, position);

                CREATE TABLE fitness_workout_version_sets (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_version_exercise_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    training_role TEXT NOT NULL,
                    structure_type TEXT NOT NULL,
                    component_count INTEGER NOT NULL DEFAULT 1,
                    reps_min INTEGER,
                    reps_max INTEGER,
                    load_min REAL,
                    load_max REAL,
                    load_unit TEXT,
                    rpe_min REAL,
                    rpe_max REAL,
                    rir_min REAL,
                    rir_max REAL,
                    rest_seconds INTEGER,
                    is_amrap INTEGER NOT NULL DEFAULT 0,
                    notes TEXT
                );
                CREATE INDEX fitness_workout_version_sets_idx
                    ON fitness_workout_version_sets(workout_version_exercise_id, position);

                CREATE TABLE fitness_training_programmes (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    purpose TEXT,
                    starts_on TEXT NOT NULL,
                    ends_on TEXT,
                    status TEXT NOT NULL,
                    phase_id TEXT,
                    programme_source TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_training_programmes_date_idx
                    ON fitness_training_programmes(starts_on DESC, status, deleted_at);

                CREATE TABLE fitness_training_programme_goal_links (
                    id TEXT PRIMARY KEY NOT NULL,
                    training_programme_id TEXT NOT NULL,
                    goal_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE UNIQUE INDEX fitness_training_programme_goal_link_idx
                    ON fitness_training_programme_goal_links(training_programme_id, goal_id)
                    WHERE deleted_at IS NULL;
                CREATE UNIQUE INDEX fitness_training_programme_primary_goal_idx
                    ON fitness_training_programme_goal_links(training_programme_id)
                    WHERE role = 'primary' AND deleted_at IS NULL;
                """)
        }

        migrator.registerMigration(identifiers[4]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_fit_imports (
                    id TEXT PRIMARY KEY NOT NULL,
                    original_filename TEXT NOT NULL,
                    local_filename TEXT,
                    media_type TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    server_import_id TEXT,
                    activity_id TEXT,
                    source_record_id TEXT,
                    source_retained INTEGER NOT NULL DEFAULT 0,
                    retryable INTEGER NOT NULL DEFAULT 1,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE UNIQUE INDEX fitness_fit_server_import_idx
                    ON fitness_fit_imports(server_import_id) WHERE server_import_id IS NOT NULL;
                CREATE INDEX fitness_fit_pending_idx
                    ON fitness_fit_imports(source_retained, status, updated_at);

                CREATE TABLE fitness_activities (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    sport_key TEXT NOT NULL,
                    started_at_utc TEXT NOT NULL,
                    status TEXT,
                    workout_classification TEXT,
                    phase_id TEXT,
                    gear_ids_json TEXT NOT NULL DEFAULT '[]',
                    distance_m REAL,
                    duration_s REAL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_activities_history_idx
                    ON fitness_activities(started_at_utc DESC, sport_key, deleted_at);
                CREATE INDEX fitness_activities_filter_idx
                    ON fitness_activities(phase_id, workout_classification, status, deleted_at);

                CREATE TABLE fitness_activity_details (
                    activity_id TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );

                CREATE TABLE fitness_activity_stream_ranges (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    activity_id TEXT NOT NULL,
                    clock TEXT NOT NULL,
                    metrics_key TEXT NOT NULL,
                    from_offset_ms INTEGER,
                    to_offset_ms INTEGER,
                    max_points INTEGER NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE INDEX fitness_activity_stream_activity_idx
                    ON fitness_activity_stream_ranges(activity_id, cached_at DESC);

                CREATE TABLE fitness_gear_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    gear_type_key TEXT NOT NULL,
                    name TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1,
                    default_for_sport_key TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_gear_active_idx
                    ON fitness_gear_items(gear_type_key, active, deleted_at);

                CREATE TABLE fitness_activity_context_outbox (
                    mutation_id TEXT PRIMARY KEY NOT NULL,
                    activity_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT,
                    last_error TEXT
                );
                CREATE INDEX fitness_activity_context_pending_idx
                    ON fitness_activity_context_outbox(created_at, mutation_id);
                """)
        }

        migrator.registerMigration(identifiers[5]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_activity_analysis_cache (
                    activity_id TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE TABLE fitness_activity_comparisons_cache (
                    activity_id TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE TABLE fitness_activity_adherence_cache (
                    owner_type TEXT NOT NULL,
                    owner_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL,
                    PRIMARY KEY(owner_type, owner_id)
                );

                CREATE TABLE fitness_calendar_layer_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    layer_kind TEXT NOT NULL,
                    scheduled_start_utc TEXT,
                    scheduled_date TEXT,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE INDEX fitness_calendar_layer_date_idx
                    ON fitness_calendar_layer_items(scheduled_date, scheduled_start_utc, layer_kind);

                CREATE TABLE fitness_analysis_registry_cache (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE TABLE fitness_analysis_query_cache (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration(identifiers[6]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_workout_definition_versions ADD COLUMN accepted_at TEXT;
                ALTER TABLE fitness_workout_definitions ADD COLUMN payload_json TEXT;
                ALTER TABLE fitness_training_programmes ADD COLUMN payload_json TEXT;

                CREATE TABLE fitness_run_workout_steps (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_version_id TEXT NOT NULL,
                    parent_step_id TEXT,
                    sequence INTEGER NOT NULL,
                    step_kind TEXT NOT NULL,
                    repeat_count INTEGER,
                    duration_type TEXT NOT NULL,
                    duration_value REAL,
                    target_type TEXT NOT NULL,
                    target_low REAL,
                    target_high REAL,
                    target_unit TEXT,
                    intensity_label TEXT,
                    kilometre_index INTEGER,
                    display_name TEXT NOT NULL,
                    instruction_text TEXT,
                    mental_cue_text TEXT,
                    spoken_cue_text TEXT,
                    allow_manual_advance INTEGER NOT NULL DEFAULT 0,
                    notes TEXT
                );
                CREATE INDEX fitness_run_steps_version_idx
                    ON fitness_run_workout_steps(workout_version_id, parent_step_id, sequence);

                CREATE TABLE fitness_run_workout_cues (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_version_id TEXT NOT NULL,
                    step_id TEXT,
                    sequence INTEGER NOT NULL,
                    trigger_type TEXT NOT NULL,
                    trigger_value REAL,
                    short_text TEXT NOT NULL,
                    spoken_text TEXT,
                    priority INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX fitness_run_cues_version_idx
                    ON fitness_run_workout_cues(workout_version_id, sequence);

                CREATE TABLE fitness_run_plan_drafts (
                    id TEXT PRIMARY KEY NOT NULL,
                    definition_id TEXT,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE fitness_garmin_exports (
                    id TEXT PRIMARY KEY NOT NULL,
                    workout_version_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    file_name TEXT,
                    local_filename TEXT,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE INDEX fitness_garmin_export_version_idx
                    ON fitness_garmin_exports(workout_version_id, cached_at DESC);
                """)
        }
        migrator.registerMigration(identifiers[7]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_healthkit_query_state ADD COLUMN last_completed_at TEXT;

                ALTER TABLE fitness_body_measurements ADD COLUMN source_record_id TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN canonical_state TEXT NOT NULL DEFAULT 'canonical';
                ALTER TABLE fitness_body_measurements ADD COLUMN duplicate_of_measurement_id TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN origin_provider_key TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN transport_key TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN source_namespace TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN external_object_id TEXT;
                ALTER TABLE fitness_body_measurements ADD COLUMN measurement_quality TEXT NOT NULL DEFAULT 'measured';

                CREATE TABLE fitness_external_source_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    record_kind TEXT NOT NULL,
                    sample_type TEXT NOT NULL,
                    transport_key TEXT NOT NULL,
                    origin_provider_key TEXT NOT NULL,
                    source_namespace TEXT NOT NULL,
                    source_object_id TEXT NOT NULL,
                    external_object_id TEXT,
                    source_device_identifier TEXT,
                    source_name TEXT,
                    product_type TEXT,
                    device_json TEXT,
                    metadata_json TEXT,
                    domain_entity_type TEXT NOT NULL,
                    domain_entity_id TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'active',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(record_kind,transport_key,source_namespace,source_object_id)
                );
                CREATE INDEX fitness_source_object_idx
                    ON fitness_external_source_records(sample_type,transport_key,source_object_id,state);
                CREATE INDEX fitness_source_external_idx
                    ON fitness_external_source_records(origin_provider_key,external_object_id,state);

                CREATE TABLE fitness_source_priorities (
                    id TEXT PRIMARY KEY NOT NULL,
                    metric_key TEXT NOT NULL,
                    origin_provider_key TEXT NOT NULL,
                    transport_key TEXT NOT NULL DEFAULT '',
                    source_namespace TEXT NOT NULL DEFAULT '',
                    priority INTEGER NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    UNIQUE(metric_key,origin_provider_key,transport_key,source_namespace)
                );

                CREATE TABLE fitness_sleep_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    sleep_start_utc TEXT NOT NULL,
                    sleep_end_utc TEXT NOT NULL,
                    duration_s REAL NOT NULL,
                    awake_duration_s REAL,
                    source_quality TEXT,
                    source_stages_json TEXT NOT NULL DEFAULT '[]',
                    source_record_id TEXT,
                    notes TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_sleep_start_idx
                    ON fitness_sleep_sessions(sleep_start_utc DESC,deleted_at);

                CREATE TABLE fitness_sleep_segments (
                    source_record_id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL,
                    origin_provider_key TEXT NOT NULL,
                    source_namespace TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    start_at_utc TEXT NOT NULL,
                    end_at_utc TEXT NOT NULL,
                    duration_s REAL NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_sleep_segment_session_idx
                    ON fitness_sleep_segments(session_id,deleted_at,start_at_utc);
                CREATE INDEX fitness_sleep_segment_source_idx
                    ON fitness_sleep_segments(origin_provider_key,source_namespace,deleted_at,start_at_utc,end_at_utc);

                CREATE TABLE fitness_recovery_observations (
                    id TEXT PRIMARY KEY NOT NULL,
                    metric_key TEXT NOT NULL,
                    observed_at_utc TEXT NOT NULL,
                    value_number REAL,
                    value_text TEXT,
                    unit_key TEXT,
                    source_quality TEXT,
                    source_record_id TEXT,
                    notes TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_recovery_metric_time_idx
                    ON fitness_recovery_observations(metric_key,observed_at_utc DESC,deleted_at);
                """)
        }
        migrator.registerMigration(identifiers[8]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_progress_photos (
                    id TEXT PRIMARY KEY NOT NULL,
                    captured_at TEXT NOT NULL,
                    pose TEXT NOT NULL,
                    body_weight_kg REAL,
                    measurement_snapshot_json TEXT,
                    phase_id TEXT,
                    phase_name TEXT,
                    original_asset_id TEXT NOT NULL,
                    thumbnail_asset_id TEXT,
                    original_state TEXT NOT NULL DEFAULT 'pending',
                    thumbnail_state TEXT,
                    notes TEXT,
                    metadata_acknowledged INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0,
                    client_updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_progress_photo_date_idx
                    ON fitness_progress_photos(captured_at DESC,pose,deleted_at);

                CREATE TABLE fitness_private_file_uploads (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    domain_entity_id TEXT NOT NULL,
                    asset_kind TEXT NOT NULL,
                    storage_class TEXT NOT NULL CHECK(storage_class='private_required'),
                    relative_path TEXT NOT NULL,
                    original_filename TEXT NOT NULL,
                    media_type TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    state TEXT NOT NULL,
                    upload_acknowledged INTEGER NOT NULL DEFAULT 0,
                    metadata_acknowledged INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    last_attempt_at TEXT,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                );
                CREATE INDEX fitness_private_upload_state_idx
                    ON fitness_private_file_uploads(state,created_at);

                CREATE TABLE fitness_progress_photo_cache (
                    photo_id TEXT NOT NULL,
                    representation TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    cached_at TEXT NOT NULL,
                    PRIMARY KEY(photo_id,representation)
                );
                """)
        }
        migrator.registerMigration(identifiers[9]) { db in
            try db.execute(sql: """
                DELETE FROM fitness_analysis_registry_cache;
                DELETE FROM fitness_analysis_query_cache;

                CREATE TABLE fitness_saved_analysis_charts_cache (
                    id TEXT PRIMARY KEY NOT NULL,
                    payload_json TEXT NOT NULL,
                    cached_at TEXT NOT NULL
                );
                CREATE INDEX fitness_saved_analysis_charts_cached_idx
                    ON fitness_saved_analysis_charts_cache(cached_at, id);
                """)
        }
        migrator.registerMigration(identifiers[10]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_nutrition_settings ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';
                ALTER TABLE fitness_nutrition_settings ADD COLUMN nutrition_day_start_minutes INTEGER NOT NULL DEFAULT 240;
                ALTER TABLE fitness_nutrition_settings ADD COLUMN payload_json TEXT;
                UPDATE fitness_nutrition_settings
                   SET nutrition_day_start_minutes = MIN(MAX(day_boundary_hour * 60, 0), 480);

                ALTER TABLE fitness_foods ADD COLUMN category_key TEXT;
                ALTER TABLE fitness_foods ADD COLUMN barcode TEXT;
                ALTER TABLE fitness_foods ADD COLUMN notes TEXT;
                ALTER TABLE fitness_foods ADD COLUMN household_shared INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE fitness_foods ADD COLUMN active INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE fitness_foods ADD COLUMN merged_into_food_id TEXT;
                ALTER TABLE fitness_foods ADD COLUMN editable INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE fitness_foods ADD COLUMN payload_json TEXT;
                UPDATE fitness_foods SET active = CASE WHEN is_archived = 1 THEN 0 ELSE 1 END;

                ALTER TABLE fitness_food_versions ADD COLUMN version_number INTEGER;
                ALTER TABLE fitness_food_versions ADD COLUMN effective_from TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN reference_amount REAL NOT NULL DEFAULT 100;
                ALTER TABLE fitness_food_versions ADD COLUMN reference_unit TEXT NOT NULL DEFAULT 'g';
                ALTER TABLE fitness_food_versions ADD COLUMN calories_kcal REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN source_energy_value REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN source_energy_unit TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN protein_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN carbohydrate_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN sugars_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN fat_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN saturated_fat_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN fibre_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN salt_g REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN sodium_mg REAL;
                ALTER TABLE fitness_food_versions ADD COLUMN micronutrients_json TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE fitness_food_versions ADD COLUMN source_type TEXT NOT NULL DEFAULT 'manual';
                ALTER TABLE fitness_food_versions ADD COLUMN source_note TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN confidence TEXT NOT NULL DEFAULT 'unknown';
                ALTER TABLE fitness_food_versions ADD COLUMN label_asset_id TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE fitness_food_versions ADD COLUMN server_updated_at TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN client_updated_at TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN origin_device_id TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN deleted_at TEXT;
                ALTER TABLE fitness_food_versions ADD COLUMN payload_json TEXT;
                UPDATE fitness_food_versions
                   SET calories_kcal = kcal_per_100g,
                       client_updated_at = created_at,
                       version_number = COALESCE(version_number, 1);

                CREATE TABLE fitness_food_servings (
                    id TEXT PRIMARY KEY NOT NULL,
                    food_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    amount REAL NOT NULL,
                    unit TEXT NOT NULL,
                    canonical_amount REAL NOT NULL,
                    canonical_unit TEXT NOT NULL,
                    measurement_quality TEXT NOT NULL,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    active INTEGER NOT NULL DEFAULT 1,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_food_servings_food_idx
                    ON fitness_food_servings(food_id,is_default,active,deleted_at);

                ALTER TABLE fitness_food_log_entries ADD COLUMN recipe_version_id TEXT;
                ALTER TABLE fitness_food_log_entries ADD COLUMN local_timezone TEXT NOT NULL DEFAULT 'UTC';
                ALTER TABLE fitness_food_log_entries ADD COLUMN meal_key TEXT NOT NULL DEFAULT 'snack';
                ALTER TABLE fitness_food_log_entries ADD COLUMN entered_amount REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN entered_unit TEXT;
                ALTER TABLE fitness_food_log_entries ADD COLUMN canonical_amount REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN canonical_unit TEXT;
                ALTER TABLE fitness_food_log_entries ADD COLUMN calories_kcal REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN protein_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN carbohydrate_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN sugars_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN fat_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN saturated_fat_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN fibre_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN salt_g REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN sodium_mg REAL;
                ALTER TABLE fitness_food_log_entries ADD COLUMN micronutrients_json TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE fitness_food_log_entries ADD COLUMN measurement_quality TEXT NOT NULL DEFAULT 'estimated';
                ALTER TABLE fitness_food_log_entries ADD COLUMN notes TEXT;
                ALTER TABLE fitness_food_log_entries ADD COLUMN context_tags_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE fitness_food_log_entries ADD COLUMN payload_json TEXT;
                UPDATE fitness_food_log_entries
                   SET meal_key = meal,
                       entered_amount = amount_grams,
                       entered_unit = CASE WHEN amount_grams IS NULL THEN 'serving' ELSE 'g' END,
                       canonical_amount = amount_grams,
                       canonical_unit = CASE WHEN amount_grams IS NULL THEN 'serving' ELSE 'g' END,
                       calories_kcal = kcal;
                CREATE INDEX fitness_food_log_meal_idx
                    ON fitness_food_log_entries(nutrition_date,meal_key,logged_at,deleted_at);

                CREATE TABLE fitness_recipes (
                    id TEXT PRIMARY KEY NOT NULL,
                    current_version_id TEXT,
                    name TEXT NOT NULL,
                    notes TEXT,
                    household_shared INTEGER NOT NULL DEFAULT 0,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    active INTEGER NOT NULL DEFAULT 1,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_recipes_active_idx
                    ON fitness_recipes(active,favourite,name,deleted_at);

                CREATE TABLE fitness_recipe_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    recipe_id TEXT NOT NULL,
                    version_number INTEGER,
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
                    components_json TEXT NOT NULL DEFAULT '[]',
                    per_100_g_json TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_recipe_versions_recipe_idx
                    ON fitness_recipe_versions(recipe_id,version_number DESC,deleted_at);

                CREATE TABLE fitness_meal_templates (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    meal_key TEXT NOT NULL,
                    time_relevance TEXT,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    active INTEGER NOT NULL DEFAULT 1,
                    items_json TEXT NOT NULL DEFAULT '[]',
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_meal_templates_meal_idx
                    ON fitness_meal_templates(meal_key,active,favourite,deleted_at);

                CREATE TABLE fitness_nutrition_targets (
                    id TEXT PRIMARY KEY NOT NULL,
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
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT,
                    payload_json TEXT
                );
                CREATE INDEX fitness_nutrition_targets_effective_idx
                    ON fitness_nutrition_targets(metric_key,effective_from,effective_until,active,deleted_at);

                ALTER TABLE fitness_private_file_uploads ADD COLUMN dependent_entity_type TEXT;
                ALTER TABLE fitness_private_file_uploads ADD COLUMN dependent_mutation_id TEXT;
                CREATE INDEX fitness_private_upload_mutation_idx
                    ON fitness_private_file_uploads(dependent_mutation_id,upload_acknowledged,metadata_acknowledged);
                """)
        }
        migrator.registerMigration(identifiers[11]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_exercises ADD COLUMN seed_key TEXT;
                ALTER TABLE fitness_exercises ADD COLUMN aliases_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE fitness_exercises ADD COLUMN movement_pattern_key TEXT NOT NULL DEFAULT 'other';
                ALTER TABLE fitness_exercises ADD COLUMN measurement_mode TEXT NOT NULL DEFAULT 'reps_load';
                ALTER TABLE fitness_exercises ADD COLUMN rep_count_mode TEXT NOT NULL DEFAULT 'total';
                ALTER TABLE fitness_exercises ADD COLUMN load_entry_mode TEXT NOT NULL DEFAULT 'total_external';
                ALTER TABLE fitness_exercises ADD COLUMN default_unit TEXT NOT NULL DEFAULT 'kg';
                ALTER TABLE fitness_exercises ADD COLUMN unilateral_mode TEXT NOT NULL DEFAULT 'bilateral';
                ALTER TABLE fitness_exercises ADD COLUMN equipment_type TEXT;
                ALTER TABLE fitness_exercises ADD COLUMN bodyweight_involved INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE fitness_exercises ADD COLUMN progression_direction TEXT NOT NULL DEFAULT 'higher';
                ALTER TABLE fitness_exercises ADD COLUMN notes TEXT;
                ALTER TABLE fitness_exercises ADD COLUMN active INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE fitness_exercises ADD COLUMN merged_into_exercise_id TEXT;
                ALTER TABLE fitness_exercises ADD COLUMN muscle_roles_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE fitness_exercises ADD COLUMN payload_json TEXT;
                UPDATE fitness_exercises
                   SET movement_pattern_key=LOWER(REPLACE(category,' ','_')),
                       active=CASE WHEN is_archived=1 THEN 0 ELSE 1 END;
                CREATE UNIQUE INDEX fitness_exercise_seed_active_idx
                    ON fitness_exercises(seed_key) WHERE seed_key IS NOT NULL AND active=1 AND deleted_at IS NULL;

                ALTER TABLE fitness_exercise_setups ADD COLUMN location TEXT;
                ALTER TABLE fitness_exercise_setups ADD COLUMN equipment_identifier TEXT;
                ALTER TABLE fitness_exercise_setups ADD COLUMN rep_count_mode TEXT NOT NULL DEFAULT 'total';
                ALTER TABLE fitness_exercise_setups ADD COLUMN unilateral_mode TEXT NOT NULL DEFAULT 'bilateral';
                ALTER TABLE fitness_exercise_setups ADD COLUMN machine_base_load_kg REAL;
                ALTER TABLE fitness_exercise_setups ADD COLUMN side_multiplier REAL;
                ALTER TABLE fitness_exercise_setups ADD COLUMN notes TEXT;
                ALTER TABLE fitness_exercise_setups ADD COLUMN active INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE fitness_exercise_setups ADD COLUMN merged_into_setup_id TEXT;
                ALTER TABLE fitness_exercise_setups ADD COLUMN payload_json TEXT;

                ALTER TABLE fitness_planned_session_exercises ADD COLUMN requested_setup_id TEXT;
                ALTER TABLE fitness_planned_session_exercises ADD COLUMN substitution_exercise_ids_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE fitness_planned_session_exercises ADD COLUMN payload_json TEXT;
                ALTER TABLE fitness_planned_sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'proposed';
                ALTER TABLE fitness_planned_sessions ADD COLUMN available_window_minutes INTEGER;
                ALTER TABLE fitness_planned_sessions ADD COLUMN intended_gear TEXT;
                ALTER TABLE fitness_planned_sessions ADD COLUMN payload_json TEXT;
                UPDATE fitness_planned_sessions
                   SET status=CASE WHEN is_completed=1 THEN 'completed'
                                   WHEN planned_for IS NOT NULL THEN 'scheduled' ELSE 'proposed' END;

                ALTER TABLE fitness_strength_sessions ADD COLUMN local_timezone TEXT NOT NULL DEFAULT 'UTC';
                ALTER TABLE fitness_strength_sessions ADD COLUMN rest_timer_deadline_utc TEXT;
                ALTER TABLE fitness_strength_sessions ADD COLUMN bodyweight_kg_snapshot REAL;
                ALTER TABLE fitness_strength_sessions ADD COLUMN bodyweight_source TEXT;
                ALTER TABLE fitness_strength_sessions ADD COLUMN matched_plan_key TEXT;
                ALTER TABLE fitness_strength_sessions ADD COLUMN payload_json TEXT;

                ALTER TABLE fitness_strength_session_exercises ADD COLUMN planned_exercise_id TEXT;
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN setup_load_entry_mode_snapshot TEXT NOT NULL DEFAULT 'total_external';
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN rep_count_mode_snapshot TEXT NOT NULL DEFAULT 'total';
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN superset_group_key TEXT;
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN variation_note TEXT;
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN notes TEXT;
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN payload_json TEXT;

                ALTER TABLE fitness_strength_set_groups ADD COLUMN planned_set_id TEXT;
                ALTER TABLE fitness_strength_set_groups ADD COLUMN started_at_utc TEXT;
                ALTER TABLE fitness_strength_set_groups ADD COLUMN completed_at_utc TEXT;
                ALTER TABLE fitness_strength_set_groups ADD COLUMN notes TEXT;
                ALTER TABLE fitness_strength_set_groups ADD COLUMN payload_json TEXT;
                CREATE INDEX fitness_strength_group_plan_idx
                    ON fitness_strength_set_groups(planned_set_id,session_exercise_id,deleted_at);

                ALTER TABLE fitness_strength_set_components ADD COLUMN reps_left INTEGER;
                ALTER TABLE fitness_strength_set_components ADD COLUMN reps_right INTEGER;
                ALTER TABLE fitness_strength_set_components ADD COLUMN load_value REAL;
                ALTER TABLE fitness_strength_set_components ADD COLUMN load_unit TEXT;
                ALTER TABLE fitness_strength_set_components ADD COLUMN load_entry_mode_snapshot TEXT;
                ALTER TABLE fitness_strength_set_components ADD COLUMN normalized_external_load_kg REAL;
                ALTER TABLE fitness_strength_set_components ADD COLUMN added_load_kg REAL;
                ALTER TABLE fitness_strength_set_components ADD COLUMN assistance_kg REAL;
                ALTER TABLE fitness_strength_set_components ADD COLUMN bodyweight_kg_snapshot REAL;
                ALTER TABLE fitness_strength_set_components ADD COLUMN rest_before_s INTEGER;
                ALTER TABLE fitness_strength_set_components ADD COLUMN tempo_text TEXT;
                ALTER TABLE fitness_strength_set_components ADD COLUMN notes TEXT;
                ALTER TABLE fitness_strength_set_components ADD COLUMN extra_metrics_json TEXT NOT NULL DEFAULT '{}';
                ALTER TABLE fitness_strength_set_components ADD COLUMN payload_json TEXT;
                UPDATE fitness_strength_set_components
                   SET load_value=load_kg, load_unit=CASE WHEN load_kg IS NULL THEN NULL ELSE 'kg' END,
                       normalized_external_load_kg=load_kg;
                CREATE UNIQUE INDEX fitness_strength_component_position_idx
                    ON fitness_strength_set_components(group_id,position) WHERE deleted_at IS NULL;

                ALTER TABLE fitness_session_checkins ADD COLUMN planned_session_id TEXT;
                ALTER TABLE fitness_session_checkins ADD COLUMN timing TEXT NOT NULL DEFAULT 'pre';
                ALTER TABLE fitness_session_checkins ADD COLUMN captured_before_activity_start INTEGER;
                ALTER TABLE fitness_session_checkins ADD COLUMN energy_1_5 INTEGER;
                ALTER TABLE fitness_session_checkins ADD COLUMN soreness_1_5 INTEGER;
                ALTER TABLE fitness_session_checkins ADD COLUMN motivation_1_5 INTEGER;
                ALTER TABLE fitness_session_checkins ADD COLUMN session_rpe_1_10 REAL;
                ALTER TABLE fitness_session_checkins ADD COLUMN perceived_performance_1_5 INTEGER;
                ALTER TABLE fitness_session_checkins ADD COLUMN matched_plan_key TEXT;
                ALTER TABLE fitness_session_checkins ADD COLUMN payload_json TEXT;

                ALTER TABLE fitness_body_issues ADD COLUMN planned_session_id TEXT;
                ALTER TABLE fitness_body_issues ADD COLUMN session_exercise_id TEXT;
                ALTER TABLE fitness_body_issues ADD COLUMN set_group_id TEXT;
                ALTER TABLE fitness_body_issues ADD COLUMN checkin_id TEXT;
                ALTER TABLE fitness_body_issues ADD COLUMN trend_key TEXT NOT NULL DEFAULT 'unknown';
                ALTER TABLE fitness_body_issues ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
                ALTER TABLE fitness_body_issues ADD COLUMN payload_json TEXT;
                """)
        }
        migrator.registerMigration(identifiers[12]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_recipes ADD COLUMN editable INTEGER NOT NULL DEFAULT 1;
                """)
        }
        migrator.registerMigration(identifiers[13]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_planned_sessions ADD COLUMN sport_key TEXT NOT NULL DEFAULT 'strength';
                ALTER TABLE fitness_planned_sessions ADD COLUMN time_window_start_utc TEXT;
                ALTER TABLE fitness_planned_sessions ADD COLUMN time_window_end_utc TEXT;
                ALTER TABLE fitness_planned_sessions ADD COLUMN expected_duration_s REAL;
                ALTER TABLE fitness_planned_sessions ADD COLUMN intended_gear_ids_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE fitness_strength_session_exercises ADD COLUMN unilateral_mode_snapshot TEXT NOT NULL DEFAULT 'bilateral';
                """)
        }
        migrator.registerMigration(identifiers[14]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_sync_notices ADD COLUMN previous_values_json TEXT;
                ALTER TABLE fitness_sync_notices ADD COLUMN target_entity_id TEXT;
                ALTER TABLE fitness_sync_notices ADD COLUMN server_backed INTEGER NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration(identifiers[15]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_body_measurements
                    ADD COLUMN metric_key TEXT NOT NULL DEFAULT 'body.weight_kg';
                ALTER TABLE fitness_body_measurements ADD COLUMN value_number REAL;
                ALTER TABLE fitness_body_measurements ADD COLUMN unit_key TEXT NOT NULL DEFAULT 'kg';
                ALTER TABLE fitness_body_measurements ADD COLUMN notes TEXT;
                UPDATE fitness_body_measurements SET value_number=weight_kg
                    WHERE value_number IS NULL;
                CREATE INDEX fitness_body_measurement_metric_time_idx
                    ON fitness_body_measurements(metric_key,measured_at DESC,deleted_at);
                """)
        }
        migrator.registerMigration(identifiers[16]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_nutrition_settings
                  ADD COLUMN heart_rate_zone_boundaries_json TEXT;
                """)
        }
        migrator.registerMigration(identifiers[17]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_goal_relationships (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_goal_id TEXT NOT NULL,
                    target_goal_id TEXT NOT NULL,
                    relationship TEXT NOT NULL,
                    notes TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_goal_relationships_source_idx
                    ON fitness_goal_relationships(source_goal_id,deleted_at);
                CREATE INDEX fitness_goal_relationships_target_idx
                    ON fitness_goal_relationships(target_goal_id,deleted_at);
                """)
        }
        migrator.registerMigration(identifiers[18]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_cycle_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    owner_user_id TEXT NOT NULL,
                    owner_name TEXT NOT NULL,
                    is_owner INTEGER NOT NULL DEFAULT 0,
                    cycle_length_days INTEGER NOT NULL DEFAULT 28,
                    show_period_starts INTEGER NOT NULL DEFAULT 1,
                    show_predicted_period INTEGER NOT NULL DEFAULT 1,
                    show_estimated_ovulation INTEGER NOT NULL DEFAULT 1,
                    share_period_starts_with_adults INTEGER NOT NULL DEFAULT 0,
                    share_predicted_period_with_adults INTEGER NOT NULL DEFAULT 0,
                    share_estimated_ovulation_with_adults INTEGER NOT NULL DEFAULT 0,
                    latest_period_start TEXT,
                    predicted_next_period TEXT,
                    estimated_ovulation TEXT,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_cycle_settings_owner_idx
                    ON fitness_cycle_settings(owner_user_id,deleted_at);

                CREATE TABLE fitness_cycle_period_starts (
                    id TEXT PRIMARY KEY NOT NULL,
                    owner_user_id TEXT NOT NULL,
                    settings_id TEXT,
                    started_on TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0,
                    server_updated_at TEXT,
                    client_updated_at TEXT NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    deleted_at TEXT
                );
                CREATE INDEX fitness_cycle_period_owner_date_idx
                    ON fitness_cycle_period_starts(owner_user_id,started_on DESC,deleted_at);
                """)
        }
        migrator.registerMigration(identifiers[19]) { db in
            try db.execute(sql: """
                ALTER TABLE fitness_body_measurements
                    ADD COLUMN manual_canonical_override INTEGER NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration(identifiers[20]) { db in
            try db.execute(sql:"""
                CREATE TABLE fitness_healthkit_workout_sources (
                    workout_uuid TEXT NOT NULL,
                    source_bundle_identifier TEXT NOT NULL,
                    origin_provider_key TEXT NOT NULL,
                    external_uuid TEXT,
                    source_name TEXT,
                    source_device_identifier TEXT,
                    product_type TEXT,
                    source_record_id TEXT NOT NULL,
                    activity_id TEXT,
                    state TEXT NOT NULL DEFAULT 'active',
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(workout_uuid,source_bundle_identifier)
                );
                CREATE INDEX fitness_healthkit_workout_uuid_idx
                    ON fitness_healthkit_workout_sources(workout_uuid,state);
                """)
        }
        migrator.registerMigration(identifiers[21]) { db in
            try db.execute(sql:"""
                CREATE TABLE fitness_experience_cache (
                    owner_identity TEXT NOT NULL,
                    cache_key TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(owner_identity,cache_key)
                );

                CREATE TABLE fitness_planned_meal_outbox (
                    id TEXT PRIMARY KEY NOT NULL,
                    owner_identity TEXT NOT NULL,
                    meal_plan_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT,
                    last_error TEXT
                );
                CREATE INDEX fitness_planned_meal_outbox_owner_created_idx
                    ON fitness_planned_meal_outbox(owner_identity,created_at,id);

                CREATE TABLE fitness_log_undo (
                    owner_identity TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration(identifiers[22]) { db in
            try db.execute(sql:"""
                CREATE INDEX fitness_food_log_food_version_time_idx
                    ON fitness_food_log_entries(food_version_id,deleted_at,logged_at DESC);
                CREATE INDEX fitness_food_versions_read_idx
                    ON fitness_food_versions(food_id,deleted_at,version_number DESC,created_at DESC);
                CREATE INDEX fitness_strength_session_history_idx
                    ON fitness_strength_sessions(status,deleted_at,started_at DESC);
                CREATE INDEX fitness_strength_group_history_idx
                    ON fitness_strength_set_groups(status,deleted_at,session_exercise_id,position);
                CREATE INDEX fitness_sleep_segment_overlap_idx
                    ON fitness_sleep_segments(origin_provider_key,deleted_at,start_at_utc,end_at_utc);
                """)
        }
        migrator.registerMigration(identifiers[23]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_sync_rejections (
                    mutation_id TEXT PRIMARY KEY NOT NULL,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    payload_schema_version INTEGER NOT NULL,
                    base_revision INTEGER,
                    payload_json TEXT NOT NULL,
                    created_at_client TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    last_attempt_at TEXT NOT NULL,
                    code TEXT NOT NULL,
                    message TEXT NOT NULL,
                    disposition TEXT NOT NULL CHECK(disposition IN ('retryable', 'permanent')),
                    target_entity_id TEXT,
                    target_summary_json TEXT,
                    server_notice_id TEXT,
                    rejected_at TEXT NOT NULL,
                    resolved_at TEXT
                );
                CREATE INDEX fitness_sync_rejections_state_idx
                    ON fitness_sync_rejections(resolved_at, disposition, rejected_at DESC);
                CREATE INDEX fitness_sync_rejections_entity_idx
                    ON fitness_sync_rejections(entity_type, entity_id, resolved_at);
                """)
        }
        migrator.registerMigration(identifiers[24]) { db in
            try db.execute(sql: """
                CREATE INDEX fitness_body_weight_component_idx
                    ON fitness_body_measurements(
                        metric_key, origin_provider_key, deleted_at, measured_at, weight_kg
                    );
                CREATE INDEX fitness_body_weight_external_idx
                    ON fitness_body_measurements(
                        metric_key, origin_provider_key, external_object_id, deleted_at
                    );
                """)
        }
        migrator.registerMigration(identifiers[25]) { db in
            try db.execute(sql: """
                CREATE TABLE fitness_healthkit_workout_outbox (
                    mutation_id TEXT PRIMARY KEY NOT NULL,
                    mutation_kind TEXT NOT NULL
                        CHECK(mutation_kind IN ('import', 'resolve_delete')),
                    workout_uuid TEXT NOT NULL,
                    source_bundle_identifier TEXT,
                    payload_json TEXT NOT NULL,
                    payload_byte_count INTEGER NOT NULL
                        CHECK(payload_byte_count >= 0),
                    state TEXT NOT NULL DEFAULT 'pending'
                        CHECK(state IN ('pending', 'retryable', 'permanent')),
                    attempt_count INTEGER NOT NULL DEFAULT 0
                        CHECK(attempt_count >= 0),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_attempt_at TEXT,
                    last_error TEXT
                );
                CREATE INDEX fitness_healthkit_workout_outbox_state_idx
                    ON fitness_healthkit_workout_outbox(state, created_at, mutation_id);
                CREATE INDEX fitness_healthkit_workout_outbox_workout_idx
                    ON fitness_healthkit_workout_outbox(workout_uuid, mutation_kind);
                """)
        }
        return migrator
    }
}

struct FitnessRecoveryBackup: Equatable, Sendable {
    let url: URL
    let sourceSchema: String
    let targetSchema: String
    let createdAt: Date
}

enum FitnessDatabaseRecoveryOperation: String, Sendable {
    case installRestoredStore
    case moveOriginalToRecovery
    case quarantineFailedRestore
    case restoreOriginal
    case removeStaging
    case protectRestoredStore
    case writeRestoredManifest
}

struct FitnessRecoveryReconciliationReport: Equatable, Sendable {
    let removedCount: Int
    let preservedRecoveryPaths: [URL]
    let candidateLimitReached: Bool
    let effectLimitReached: Bool
}

private struct FitnessRecoveryFailureSummary: LocalizedError {
    let primaryDescription: String
    let recoveryFailureDescriptions: [String]

    var errorDescription: String? {
        guard !recoveryFailureDescriptions.isEmpty else { return primaryDescription }
        return ([primaryDescription] + recoveryFailureDescriptions).joined(separator: " | ")
    }
}

/// Thread-safe owner of the process-wide Fitness database capability.
///
/// `@unchecked Sendable` is justified by two disjoint synchronization domains:
/// `contextLock` guards the active pool, identity and generation used by hot
/// repository operations; `lifecycleLock` serializes every open, close, delete,
/// migration and recovery filesystem transaction, including access to the
/// injected FileManager and lifecycle hooks. Lifecycle code may acquire
/// `contextLock`, but repository code never acquires `lifecycleLock`, preserving
/// one-way lock ordering. GRDB's DatabasePool owns read/write serialization once
/// a pool snapshot has escaped `contextLock`; revocation clears the capability
/// before closing that old pool, so work can fail stale but cannot cross owners.
final class FitnessDatabase: @unchecked Sendable {
    static let shared = FitnessDatabase()
    private static let logger = Logger(subsystem: "org.example.hausklar", category: "FitnessDatabase")
    private static let storeFilename = "fitness.sqlite"
    private static let storeManifestFilename = "store-manifest.json"
    private static let backupsDirectoryName = "MigrationBackups"
    private static let backupDatabaseFilename = "fitness.sqlite"
    private static let backupManifestFilename = "manifest.json"
    private static let maximumBackups = 3
    static let maximumBackupVerificationCandidates = 64
    static let maximumRecoveryReconciliationCandidates = 128
    static let maximumRecoveryReconciliationEffects = 32
    static let maximumReportedRecoveryPaths = 32
    /// Store and backup manifests contain only a few scalar fields. Keep their
    /// read boundary explicit so a replaced local file can never force an
    /// unbounded allocation before owner or checksum validation runs.
    static let maximumManifestByteCount = 16 * 1_024

    private struct StoreManifest: Codable {
        let version: Int
        let ownerIdentityHash: String
        let schemaIdentifier: String
        let updatedAt: Date
    }

    private struct BackupManifest: Codable {
        let version: Int
        let ownerIdentityHash: String
        let sourceSchema: String
        let targetSchema: String
        let createdAt: Date
        let byteCount: Int
        let sha256: String
    }

    struct Context {
        let identity: String
        let generation: UInt64
        let requiresLease: Bool
        let storeURL: URL
        let pool: DatabasePool
        let preMigrationBackupURL: URL?
    }

    private let contextLock = NSLock()
    private let lifecycleLock = NSLock()
    private let fileManager: FileManager
    private let rootDirectoryOverride: URL?
    private let migrationIdentifiers: [String]
    private let migratorFactory: () -> DatabaseMigrator
    private let recoveryOperationHook: (@Sendable (
        FitnessDatabaseRecoveryOperation,
        URL,
        URL?
    ) throws -> Void)?
    private var context: Context?
    private var nextGeneration: UInt64 = 0

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        migrationIdentifiers: [String] = FitnessMigrations.identifiers,
        migratorFactory: @escaping () -> DatabaseMigrator = { FitnessMigrations.makeMigrator() },
        recoveryOperationHook: (@Sendable (
            FitnessDatabaseRecoveryOperation,
            URL,
            URL?
        ) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryOverride = rootDirectory
        self.migrationIdentifiers = migrationIdentifiers
        self.migratorFactory = migratorFactory
        self.recoveryOperationHook = recoveryOperationHook
    }

    static func dateString(_ date: Date) -> String { ISODateParser.string(from: date) }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISODateParser.parse(string)
    }

    static func identityDirectoryName(_ identity: String) -> String {
        "owner-\(identityHash(identity))"
    }

    static func legacyIdentityDirectoryName(_ identity: String) -> String {
        safeIdentity(identity)
    }

    var activeIdentity: String? { contextLock.withLock { context?.identity } }
    var activeStoreURL: URL? { contextLock.withLock { context?.storeURL } }

    func lease(for identity: String) throws -> FitnessStoreLease {
        try contextLock.withLock {
            guard let context else { throw FitnessDatabaseError.notActive }
            guard context.identity == identity else { throw FitnessDatabaseError.staleLease }
            return FitnessStoreLease(identity: context.identity, generation: context.generation)
        }
    }

    func validate(_ lease: FitnessStoreLease) throws {
        try contextLock.withLock {
            guard let context else { throw FitnessDatabaseError.notActive }
            guard context.identity == lease.identity,
                  context.generation == lease.generation else {
                throw FitnessDatabaseError.staleLease
            }
        }
    }

    func withLease<T>(
        _ lease: FitnessStoreLease,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async throws -> T {
        try validate(lease)
        // Preserve the caller's actor while installing the task-local lease.
        // Without forwarding isolation, Swift must conservatively treat the
        // operation as a transfer into a nonisolated context.
        let result = try await FitnessStoreLeaseContext.$current.withValue(
            lease,
            operation: { try await operation() },
            isolation: isolation
        )
        // The pool is re-resolved on every repository call, but an operation
        // whose final await returns an in-memory value also needs a closing
        // generation check before that value can escape to a replacement owner.
        try validate(lease)
        return result
    }

    /// AppState is the sole production caller. `legacyOwnerProof` is the exact
    /// identity that owned the old local store before authenticated activation;
    /// without it, the retired collision-prone directory is left untouched.
    func activate(identity: String, legacyOwnerProof: String?) throws {
        try lifecycleLock.withLock {
            try activateLocked(identity: identity, legacyOwnerProof: legacyOwnerProof)
        }
    }

    private func activateLocked(identity: String, legacyOwnerProof: String?) throws {
        if contextLock.withLock({ context?.identity == identity }) { return }
        suspendLocked()
        let root = try resolvedRootDirectory()
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(
            Self.identityDirectoryName(identity), isDirectory: true
        )
        let legacy = root.appendingPathComponent(
            Self.legacyIdentityDirectoryName(identity), isDirectory: true
        )
        if !fileManager.fileExists(atPath: directory.path),
           fileManager.fileExists(atPath: legacy.path) {
            guard legacyOwnerProof == identity else {
                throw FitnessDatabaseError.unverifiedLegacyStore(store: legacy)
            }
            let existing: StoreManifest?
            do {
                existing = try storeManifestIfPresent(in: legacy)
            } catch {
                Self.logger.error(
                    "A legacy Fitness owner manifest could not be verified and was retained unchanged: \(error.localizedDescription, privacy: .private)"
                )
                throw FitnessDatabaseError.unverifiedLegacyStore(store: legacy)
            }
            if let existing,
               existing.ownerIdentityHash != Self.identityHash(identity) {
                throw FitnessDatabaseError.unverifiedLegacyStore(store: legacy)
            }
            try writeStoreManifest(
                in: legacy, identity: identity, schema: "legacy-preflight", protectFiles: true
            )
            try fileManager.moveItem(at: legacy, to: directory)
        }

        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let storeURL = directory.appendingPathComponent(Self.storeFilename)
        if fileManager.fileExists(atPath: storeURL.path) {
            let manifest: StoreManifest
            do {
                manifest = try readStoreManifest(in: directory)
            } catch {
                Self.logger.error(
                    "A canonical Fitness owner manifest could not be verified during activation: \(error.localizedDescription, privacy: .private)"
                )
                throw FitnessDatabaseError.unverifiedLegacyStore(store: directory)
            }
            guard manifest.ownerIdentityHash == Self.identityHash(identity) else {
                throw FitnessDatabaseError.unverifiedLegacyStore(store: directory)
            }
        } else {
            try writeStoreManifest(in: directory, identity: identity, schema: "new", protectFiles: true)
        }
        try open(identity: identity, storeURL: storeURL, protectFiles: true, requiresLease: true)
    }

    func activateForTesting(
        identity: String = "test:test",
        storeURL: URL,
        requiresLease: Bool = false
    ) throws {
        try lifecycleLock.withLock {
            try activateForTestingLocked(
                identity: identity,
                storeURL: storeURL,
                requiresLease: requiresLease
            )
        }
    }

    private func activateForTestingLocked(
        identity: String,
        storeURL: URL,
        requiresLease: Bool
    ) throws {
        suspendLocked()
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open(
            identity: identity, storeURL: storeURL,
            protectFiles: false, requiresLease: requiresLease
        )
    }

    private func open(
        identity: String,
        storeURL: URL,
        protectFiles: Bool,
        requiresLease: Bool
    ) throws {
        let storeURL = try validatedStoreURL(storeURL)
        let storeExisted = fileManager.fileExists(atPath: storeURL.path)
        do {
            let reconciliation = try reconcileRecoveryArtifactsLocked(
                identity: identity,
                storeURL: storeURL,
                now: Date(),
                minimumAge: 24 * 60 * 60,
                maximumCandidates: Self.maximumRecoveryReconciliationCandidates,
                maximumEffects: Self.maximumRecoveryReconciliationEffects
            )
            guard storeExisted || reconciliation.preservedRecoveryPaths.isEmpty else {
                throw FitnessDatabaseError.recoveryFailed(
                    store: storeURL,
                    backup: nil,
                    recoveryPaths: reconciliation.preservedRecoveryPaths,
                    underlying: FitnessRecoveryFailureSummary(
                        primaryDescription: "A recoverable Fitness database exists, so a replacement empty store was not created.",
                        recoveryFailureDescriptions: []
                    )
                )
            }
        } catch {
            throw FitnessDatabaseError.migrationFailed(
                store: storeURL,
                backup: nil,
                underlying: error
            )
        }
        var configuration = Configuration()
        configuration.label = "HausKlar.Fitness.\(Self.identityHash(identity).prefix(12))"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: storeURL.path, configuration: configuration)
        } catch {
            throw FitnessDatabaseError.migrationFailed(store: storeURL, backup: nil, underlying: error)
        }

        let migrator = migratorFactory()
        var backupURL: URL?
        do {
            let applied = try pool.read { db in try migrator.appliedMigrations(db) }
            let hasPendingMigration = applied != migrationIdentifiers
            if hasPendingMigration, storeExisted {
                try assertIntegrity(pool)
                backupURL = try createVerifiedBackup(
                    from: pool,
                    storeURL: storeURL,
                    identity: identity,
                    appliedMigrations: applied,
                    protectFiles: protectFiles
                )
            }
            try migrator.migrate(pool)
            try assertIntegrity(pool)
            try pool.write { db in
                guard try db.tableExists("fitness_metadata") else { return }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO fitness_metadata(key, value) VALUES ('local_schema', ?)",
                    arguments: [migrationIdentifiers.last ?? "unversioned"]
                )
                try db.execute(
                    sql: "INSERT OR IGNORE INTO fitness_metadata(key, value) VALUES ('sync_cursor', '0')"
                )
                try db.execute(
                    sql: "INSERT OR REPLACE INTO fitness_metadata(key, value) VALUES ('store_owner_hash', ?)",
                    arguments: [Self.identityHash(identity)]
                )
                if let backupURL {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO fitness_metadata(key, value) VALUES ('pre_migration_backup', ?)",
                        arguments: [backupURL.path]
                    )
                }
            }
            if protectFiles {
                try LocalFileProtection.protectSQLiteStore(at: storeURL, fileManager: fileManager)
                try writeStoreManifest(
                    in: storeURL.deletingLastPathComponent(),
                    identity: identity,
                    schema: migrationIdentifiers.last ?? "unversioned",
                    protectFiles: true
                )
            }
        } catch {
            let primaryError = error
            if backupURL == nil,
               case FitnessDatabaseError.recoveryFailed(_, let preservedBackup, _, _) = error {
                backupURL = preservedBackup
            }
            var closeFailures: [String] = []
            do {
                try pool.close()
            } catch {
                closeFailures.append("Closing the failed migration database: \(error.localizedDescription)")
            }
            let reportedError: Error = closeFailures.isEmpty
                ? primaryError
                : FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: closeFailures
                )
            Self.logger.error(
                "Fitness migration failed without reset: \(reportedError.localizedDescription)"
            )
            throw FitnessDatabaseError.migrationFailed(
                store: storeURL,
                backup: backupURL,
                underlying: reportedError
            )
        }
        contextLock.withLock {
            nextGeneration &+= 1
            context = Context(
                identity: identity,
                generation: nextGeneration,
                requiresLease: requiresLease,
                storeURL: storeURL,
                pool: pool,
                preMigrationBackupURL: backupURL
            )
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        let pool = try activePool(for: FitnessStoreLeaseContext.current)
        return try pool.read(body)
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        let pool = try activePool(for: FitnessStoreLeaseContext.current)
        return try pool.write(body)
    }

    /// Synchronous UI metadata access can bind directly to the expected owner.
    /// The pool is resolved atomically before the body begins, so a concurrent
    /// switch can close this pool but can never redirect the body into another.
    func readCurrent<T>(identity: String, _ body: (Database) throws -> T) throws -> T {
        let pool = try pool(forIdentity: identity)
        return try pool.read(body)
    }

    func writeCurrent<T>(identity: String, _ body: (Database) throws -> T) throws -> T {
        let pool = try pool(forIdentity: identity)
        return try pool.write(body)
    }

    private func pool(forIdentity identity: String) throws -> DatabasePool {
        try contextLock.withLock {
            guard let context else { throw FitnessDatabaseError.notActive }
            guard context.identity == identity else { throw FitnessDatabaseError.staleLease }
            return context.pool
        }
    }

    private func activePool(for lease: FitnessStoreLease?) throws -> DatabasePool {
        try contextLock.withLock {
            guard let context else { throw FitnessDatabaseError.notActive }
            if context.requiresLease,lease == nil { throw FitnessDatabaseError.leaseRequired }
            if let lease {
                guard context.identity == lease.identity,
                      context.generation == lease.generation else {
                    throw FitnessDatabaseError.staleLease
                }
            }
            return context.pool
        }
    }

    /// Work that would be permanently removed when the active Fitness profile is deleted.
    /// Keep this deliberately small and synchronous so Settings can protect logout
    /// without needing to understand every Fitness repository.
    func pendingLocalWorkCount() throws -> Int {
        let pool = try contextLock.withLock { () throws -> DatabasePool in
            guard let context else { throw FitnessDatabaseError.notActive }
            return context.pool
        }
        return try pool.read { db in
            let mutationCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM fitness_outbox) +
                        (SELECT COUNT(*) FROM fitness_sync_rejections WHERE resolved_at IS NULL) +
                        (SELECT COUNT(*) FROM fitness_activity_context_outbox) +
                        (SELECT COUNT(*) FROM fitness_planned_meal_outbox) +
                        (SELECT COUNT(*) FROM fitness_healthkit_workout_outbox)
                    """
            ) ?? 0
            let importCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM fitness_fit_imports WHERE status <> 'complete'"
            ) ?? 0
            return mutationCount + importCount
        }
    }

    func suspend() {
        lifecycleLock.withLock {
            suspendLocked()
        }
    }

    private func suspendLocked() {
        let pool = contextLock.withLock { () -> DatabasePool? in
            let pool = context?.pool
            context = nil
            return pool
        }
        guard let pool else { return }
        do {
            try pool.close()
        } catch {
            // The capability has already been revoked, so no operation can
            // cross into a replacement owner. Keep the close failure visible
            // for recovery diagnostics instead of silently discarding it.
            Self.logger.error(
                "Fitness database close failed after its owner lease was revoked: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func deleteActiveStore() throws {
        try lifecycleLock.withLock {
            try deleteActiveStoreLocked()
        }
    }

    private func deleteActiveStoreLocked() throws {
        guard let directory = contextLock.withLock({ context?.storeURL.deletingLastPathComponent() }) else { return }
        suspendLocked()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Removes one explicitly resolved identity store. This is used by the
    /// existing fail-closed account switch/logout boundary even when the store
    /// was never opened during the current process.
    func deleteStore(identity: String, legacyOwnerProof: String? = nil) throws {
        try lifecycleLock.withLock {
            try deleteStoreLocked(identity: identity, legacyOwnerProof: legacyOwnerProof)
        }
    }

    private func deleteStoreLocked(identity: String, legacyOwnerProof: String?) throws {
        if activeIdentity == identity { suspendLocked() }
        let root = try resolvedRootDirectory()
        let directory = root.appendingPathComponent(
            Self.identityDirectoryName(identity), isDirectory: true
        )
        let canonicalExists = fileManager.fileExists(atPath: directory.path)
        if canonicalExists {
            let manifest: StoreManifest
            do {
                manifest = try readStoreManifest(in: directory)
            } catch {
                Self.logger.error(
                    "A canonical Fitness store was retained because its owner manifest could not be verified before deletion: \(error.localizedDescription, privacy: .private)"
                )
                throw FitnessDatabaseError.unverifiedLegacyStore(store: directory)
            }
            guard manifest.ownerIdentityHash == Self.identityHash(identity) else {
                throw FitnessDatabaseError.unverifiedLegacyStore(store: directory)
            }
        }

        let legacy = root.appendingPathComponent(
            Self.legacyIdentityDirectoryName(identity), isDirectory: true
        )
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        if legacyExists {
            let manifest: StoreManifest?
            do {
                manifest = try storeManifestIfPresent(in: legacy)
            } catch {
                Self.logger.error(
                    "A legacy Fitness store was retained because its owner manifest could not be verified before deletion: \(error.localizedDescription, privacy: .private)"
                )
                throw FitnessDatabaseError.unverifiedLegacyStore(store: legacy)
            }
            let manifestMatches = manifest?.ownerIdentityHash == Self.identityHash(identity)
            let provenManifestlessLegacy = manifest == nil && legacyOwnerProof == identity
            guard manifestMatches || provenManifestlessLegacy else {
                throw FitnessDatabaseError.unverifiedLegacyStore(store: legacy)
            }
        }

        // Preflight every collision-prone target before deleting either. A
        // corrupt legacy sibling must not cause a valid canonical store to be
        // removed as the first half of a failed logout cleanup.
        if canonicalExists {
            try fileManager.removeItem(at: directory)
        }
        if legacyExists {
            try fileManager.removeItem(at: legacy)
        }
    }

    func markFirstPostMigrationSyncComplete() throws {
        try write { db in
            guard try db.tableExists("fitness_metadata") else { return }
            try db.execute(sql: "DELETE FROM fitness_metadata WHERE key = 'pre_migration_backup'")
        }
        // Verified records remain in a bounded three-record rotation.
    }

    /// Reclaims only stale, exact HausKlar staging directories. Completed or
    /// failed recovery directories containing any file are retained and
    /// reported so a later support flow can recover them explicitly.
    @discardableResult
    func reconcileRecoveryArtifacts(
        identity: String,
        storeURL: URL? = nil,
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = FitnessDatabase.maximumRecoveryReconciliationCandidates,
        maximumEffects: Int = FitnessDatabase.maximumRecoveryReconciliationEffects
    ) throws -> FitnessRecoveryReconciliationReport {
        try lifecycleLock.withLock {
            try reconcileRecoveryArtifactsLocked(
                identity: identity,
                storeURL: storeURL,
                now: now,
                minimumAge: minimumAge,
                maximumCandidates: maximumCandidates,
                maximumEffects: maximumEffects
            )
        }
    }

    private func reconcileRecoveryArtifactsLocked(
        identity: String,
        storeURL: URL?,
        now: Date,
        minimumAge: TimeInterval,
        maximumCandidates: Int,
        maximumEffects: Int
    ) throws -> FitnessRecoveryReconciliationReport {
        let destination = try validatedStoreURL(
            storeURL ?? productionStoreURL(identity: identity)
        )
        let ownerDirectory = destination.deletingLastPathComponent().standardizedFileURL
        let backupsDirectory = backupDirectory(for: destination)
        let cutoff = now.addingTimeInterval(-max(0,minimumAge))
        let boundedCandidates = max(0,maximumCandidates)
        let boundedEffects = max(0,maximumEffects)
        let dateKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        var cleanupCandidates: [(date: Date, url: URL)] = []
        var eligibleCleanupCount = 0
        var preserved: [(timestamp: Int64, url: URL)] = []

        func considerCleanup(_ url: URL, date: Date) {
            guard date <= cutoff else { return }
            eligibleCleanupCount += 1
            guard boundedCandidates > 0 else { return }
            cleanupCandidates.append((date,url))
            cleanupCandidates.sort {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            if cleanupCandidates.count > boundedCandidates {
                cleanupCandidates.removeLast()
            }
        }

        func preserve(_ url: URL, timestamp: Int64) {
            preserved.append((timestamp,url))
            preserved.sort {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            if preserved.count > Self.maximumReportedRecoveryPaths {
                preserved.removeLast()
            }
        }

        if fileManager.fileExists(atPath: backupsDirectory.path) {
            try forEachImmediateEntry(in: backupsDirectory) { entry in
                guard Self.isBackupStageFilename(entry.lastPathComponent) else { return }
                let values = try entry.resourceValues(forKeys: dateKeys)
                guard
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let date = values.contentModificationDate ?? values.creationDate else {
                    return
                }
                considerCleanup(entry,date: date)
            }
        }
        try forEachImmediateEntry(in: ownerDirectory) { entry in
            let isRestoreStage = Self.isRestoreStageFilename(entry.lastPathComponent)
            let recoveryTimestamp = Self.recoveryDirectoryTimestamp(entry.lastPathComponent)
            guard isRestoreStage || recoveryTimestamp != nil else { return }
            let values = try entry.resourceValues(forKeys: dateKeys)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else { return }
            if isRestoreStage,
               let date = values.contentModificationDate ?? values.creationDate {
                considerCleanup(entry,date: date)
                return
            }
            guard let timestamp = recoveryTimestamp else {
                return
            }
            if try directoryHasAnyImmediateEntry(entry) {
                preserve(entry,timestamp: timestamp)
            } else if let date = values.contentModificationDate ?? values.creationDate {
                considerCleanup(entry,date: date)
            }
        }

        var removedCount = 0
        for candidate in cleanupCandidates.prefix(boundedEffects) {
            do {
                try fileManager.removeItem(at: candidate.url)
                removedCount += 1
            } catch {
                let paths = boundedExistingRecoveryPaths(
                    [candidate.url,destination,backupsDirectory]
                        + preserved.map(\.url)
                )
                throw FitnessDatabaseError.recoveryFailed(
                    store: destination,
                    backup: nil,
                    recoveryPaths: paths,
                    underlying: error
                )
            }
        }
        let candidateLimitReached = eligibleCleanupCount > boundedCandidates
        let effectLimitReached = eligibleCleanupCount > boundedEffects
        if candidateLimitReached || effectLimitReached {
            Self.logger.warning(
                "Fitness recovery reconciliation stopped at its bounded maintenance limit (candidates: \(eligibleCleanupCount, privacy: .public), removed: \(removedCount, privacy: .public))."
            )
        }
        if !preserved.isEmpty {
            Self.logger.warning(
                "Preserved \(preserved.count, privacy: .public) Fitness recovery director\(preserved.count == 1 ? "y" : "ies") for explicit recovery."
            )
        }
        return FitnessRecoveryReconciliationReport(
            removedCount: removedCount,
            preservedRecoveryPaths: preserved.map(\.url),
            candidateLimitReached: candidateLimitReached,
            effectLimitReached: effectLimitReached
        )
    }

    func verifiedRecoveryBackups(
        identity: String,
        storeURL: URL? = nil
    ) throws -> [FitnessRecoveryBackup] {
        try lifecycleLock.withLock {
            try verifiedRecoveryBackupsLocked(identity: identity, storeURL: storeURL)
        }
    }

    private func verifiedRecoveryBackupsLocked(
        identity: String,
        storeURL: URL?
    ) throws -> [FitnessRecoveryBackup] {
        let resolvedStore = try validatedStoreURL(
            storeURL ?? productionStoreURL(identity: identity)
        )
        let backupsDirectory = backupDirectory(for: resolvedStore)
        var records: [FitnessRecoveryBackup] = []
        for directory in try backupRecordDirectories(for: resolvedStore) {
            do {
                records.append(try verifiedBackup(
                    in: directory,
                    identity: identity,
                    expectedBackupsDirectory: backupsDirectory
                ))
            } catch {
                Self.logger.warning(
                    "Ignored invalid Fitness recovery record at \(directory.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    /// Explicit recovery only. No backup is selected automatically, and an
    /// active owner can never be displaced while restoring somebody else.
    func restoreVerifiedBackup(
        _ backupURL: URL,
        identity: String,
        storeURL: URL? = nil
    ) throws {
        try lifecycleLock.withLock {
            try restoreVerifiedBackupLocked(
                backupURL,
                identity: identity,
                storeURL: storeURL
            )
        }
    }

    private func restoreVerifiedBackupLocked(
        _ backupURL: URL,
        identity: String,
        storeURL: URL?
    ) throws {
        let destination = try validatedStoreURL(
            storeURL ?? productionStoreURL(identity: identity)
        )
        let ownerDirectory = destination.deletingLastPathComponent()
        let backupsDirectory = backupDirectory(for: destination)
        let record = try verifiedBackup(
            in: backupURL.deletingLastPathComponent(),
            identity: identity,
            expectedBackupsDirectory: backupsDirectory
        )
        guard record.url.standardizedFileURL == backupURL.standardizedFileURL else {
            throw FitnessDatabaseError.invalidRecoveryBackup(backupURL)
        }
        try closeActiveStoreForRecovery(
            identity: identity,
            storeURL: destination,
            backupURL: record.url
        )

        do {
            _ = try reconcileRecoveryArtifactsLocked(
                identity: identity,
                storeURL: destination,
                now: Date(),
                minimumAge: 24 * 60 * 60,
                maximumCandidates: Self.maximumRecoveryReconciliationCandidates,
                maximumEffects: Self.maximumRecoveryReconciliationEffects
            )
        } catch {
            var inheritedPaths: [URL] = []
            if case FitnessDatabaseError.recoveryFailed(_, _, let recoveryPaths, _) = error {
                inheritedPaths = recoveryPaths
            }
            throw FitnessDatabaseError.recoveryFailed(
                store: destination,
                backup: record.url,
                recoveryPaths: boundedExistingRecoveryPaths(inheritedPaths),
                underlying: error
            )
        }

        let stagingDirectory = ownerDirectory.appendingPathComponent(
            ".restore-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        let recoveryDirectory = ownerDirectory.appendingPathComponent(
            "Recovery-original-\(Self.fileTimestamp())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let stagingStore = stagingDirectory.appendingPathComponent(Self.storeFilename)
        let originalComponents = try storeRecoveryComponents(for: destination).filter { url in
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw FitnessDatabaseError.invalidRecoveryBackup(url)
            }
            return true
        }
        let originalStoreExisted = originalComponents.contains(destination)
        var movedOriginals: [(source: URL, recovery: URL)] = []
        var installedRestoredStore = false
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            try LocalFileProtection.prepareDirectory(
                stagingDirectory,
                fileManager: fileManager
            )
            let sourceDigestBeforeCopy = try Self.sha256(of: record.url)
            try fileManager.copyItem(at: record.url, to: stagingStore)
            let stagedValues = try stagingStore.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            let stagedDigest = try Self.sha256(of: stagingStore)
            let sourceDigestAfterCopy = try Self.sha256(of: record.url)
            guard stagedValues.isRegularFile == true,
                  stagedValues.isSymbolicLink != true,
                  (stagedValues.fileSize ?? 0) > 0,
                  stagedDigest == sourceDigestBeforeCopy,
                  stagedDigest == sourceDigestAfterCopy,
                  try schemaIdentifier(at: stagingStore) == record.sourceSchema else {
                throw FitnessDatabaseError.invalidRecoveryBackup(stagingStore)
            }
            _ = try verifiedBackup(
                in: record.url.deletingLastPathComponent(),
                identity: identity,
                expectedBackupsDirectory: backupsDirectory
            )
            try assertIntegrity(at: stagingStore)

            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false)
            try LocalFileProtection.prepareDirectory(
                recoveryDirectory,
                fileManager: fileManager
            )
            for sourceURL in originalComponents {
                let recoveryURL = recoveryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                try recoveryOperationHook?(
                    .moveOriginalToRecovery,
                    sourceURL,
                    recoveryURL
                )
                try fileManager.moveItem(at: sourceURL, to: recoveryURL)
                movedOriginals.append((sourceURL, recoveryURL))
            }
            if !movedOriginals.isEmpty {
                try LocalFileProtection.protectDirectoryRecursively(
                    recoveryDirectory,
                    fileManager: fileManager
                )
            }
            try recoveryOperationHook?(
                .installRestoredStore,
                stagingStore,
                destination
            )
            try fileManager.moveItem(at: stagingStore, to: destination)
            installedRestoredStore = true
            try assertIntegrity(at: destination)
            guard try schemaIdentifier(at: destination) == record.sourceSchema else {
                throw FitnessDatabaseError.invalidRecoveryBackup(destination)
            }
            try recoveryOperationHook?(.protectRestoredStore, destination, nil)
            try LocalFileProtection.protectSQLiteStore(at: destination, fileManager: fileManager)
            try recoveryOperationHook?(.writeRestoredManifest, ownerDirectory, nil)
            try writeStoreManifest(
                in: ownerDirectory,
                identity: identity,
                schema: record.sourceSchema,
                protectFiles: true
            )
            let installedManifest = try readStoreManifest(in: ownerDirectory)
            guard installedManifest.ownerIdentityHash == Self.identityHash(identity),
                  installedManifest.schemaIdentifier == record.sourceSchema else {
                throw FitnessDatabaseError.invalidRecoveryBackup(
                    ownerDirectory.appendingPathComponent(Self.storeManifestFilename)
                )
            }
            _ = try verifiedBackup(
                in: record.url.deletingLastPathComponent(),
                identity: identity,
                expectedBackupsDirectory: backupsDirectory
            )
            try recoveryOperationHook?(.removeStaging, stagingDirectory, nil)
            try fileManager.removeItem(at: stagingDirectory)
        } catch {
            let primaryError = error
            var recoveryFailures: [String] = []

            func recordRecoveryFailure(
                _ operation: String,
                at url: URL,
                error: Error
            ) {
                recoveryFailures.append(
                    "\(operation) at \(url.path): \(error.localizedDescription)"
                )
            }

            if installedRestoredStore {
                for component in storeRecoveryComponents(for: destination)
                    where fileManager.fileExists(atPath: component.path) {
                    let failedRestore = recoveryDirectory.appendingPathComponent(
                        failedRestoreFilename(for: component, storeURL: destination)
                    )
                    do {
                        guard !fileManager.fileExists(atPath: failedRestore.path) else {
                            throw FitnessDatabaseError.invalidRecoveryBackup(failedRestore)
                        }
                        try recoveryOperationHook?(
                            .quarantineFailedRestore,
                            component,
                            failedRestore
                        )
                        try fileManager.moveItem(at: component, to: failedRestore)
                    } catch {
                        recordRecoveryFailure(
                            "Quarantining the failed restored component",
                            at: component,
                            error: error
                        )
                    }
                }
            }

            for pair in movedOriginals.reversed() {
                do {
                    guard fileManager.fileExists(atPath: pair.recovery.path),
                          !fileManager.fileExists(atPath: pair.source.path) else {
                        throw FitnessDatabaseError.invalidRecoveryBackup(pair.recovery)
                    }
                    try recoveryOperationHook?(
                        .restoreOriginal,
                        pair.recovery,
                        pair.source
                    )
                    try fileManager.moveItem(at: pair.recovery, to: pair.source)
                } catch {
                    recordRecoveryFailure(
                        "Restoring the original component",
                        at: pair.recovery,
                        error: error
                    )
                }
            }

            if fileManager.fileExists(atPath: stagingDirectory.path) {
                do {
                    try recoveryOperationHook?(.removeStaging, stagingDirectory, nil)
                    try fileManager.removeItem(at: stagingDirectory)
                } catch {
                    recordRecoveryFailure(
                        "Removing the restore staging directory",
                        at: stagingDirectory,
                        error: error
                    )
                }
            }

            for component in originalComponents {
                do {
                    let values = try component.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true else {
                        throw FitnessDatabaseError.invalidRecoveryBackup(component)
                    }
                } catch {
                    recordRecoveryFailure(
                        "Verifying the rolled-back original component",
                        at: component,
                        error: error
                    )
                }
            }
            if originalStoreExisted,
               fileManager.fileExists(atPath: destination.path) {
                do {
                    try assertIntegrity(at: destination)
                } catch {
                    recordRecoveryFailure(
                        "Verifying the rolled-back original database",
                        at: destination,
                        error: error
                    )
                }
            } else if !originalStoreExisted,
                      fileManager.fileExists(atPath: destination.path) {
                recordRecoveryFailure(
                    "Verifying that no restored database remained",
                    at: destination,
                    error: FitnessDatabaseError.invalidRecoveryBackup(destination)
                )
            }

            let recoveryPaths = boundedExistingRecoveryPaths(
                [recoveryDirectory, stagingDirectory, destination]
                    + movedOriginals.flatMap { [$0.recovery, $0.source] }
            )
            throw FitnessDatabaseError.recoveryFailed(
                store: destination,
                backup: record.url,
                recoveryPaths: recoveryPaths,
                underlying: FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: recoveryFailures
                )
            )
        }
    }

    // MARK: Store identity and recovery internals

    private func closeActiveStoreForRecovery(
        identity: String,
        storeURL: URL,
        backupURL: URL
    ) throws {
        let pool = try contextLock.withLock { () throws -> DatabasePool? in
            guard let context else { return nil }
            guard context.identity == identity,
                  context.storeURL.standardizedFileURL == storeURL.standardizedFileURL else {
                throw FitnessDatabaseError.staleLease
            }
            self.context = nil
            return context.pool
        }
        guard let pool else { return }
        do {
            try pool.close()
        } catch {
            throw FitnessDatabaseError.recoveryFailed(
                store: storeURL,
                backup: backupURL,
                recoveryPaths: boundedExistingRecoveryPaths([storeURL]),
                underlying: error
            )
        }
    }

    private func resolvedRootDirectory() throws -> URL {
        if let rootDirectoryOverride { return rootDirectoryOverride.standardizedFileURL }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Fitness", isDirectory: true)
    }

    private func productionStoreURL(identity: String) throws -> URL {
        try resolvedRootDirectory()
            .appendingPathComponent(Self.identityDirectoryName(identity), isDirectory: true)
            .appendingPathComponent(Self.storeFilename)
    }

    private func validatedStoreURL(_ storeURL: URL) throws -> URL {
        let storeURL = storeURL.standardizedFileURL
        guard storeURL.lastPathComponent == Self.storeFilename else {
            throw FitnessDatabaseError.invalidRecoveryBackup(storeURL)
        }
        let ownerDirectory = storeURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: ownerDirectory.path) {
            let values = try ownerDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw FitnessDatabaseError.invalidRecoveryBackup(ownerDirectory)
            }
        }
        return storeURL
    }

    private func backupDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(
            Self.backupsDirectoryName,
            isDirectory: true
        ).standardizedFileURL
    }

    private static func identityHash(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }
            try handle.close()
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            let primaryError = error
            do {
                try handle.close()
            } catch {
                throw FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: [
                        "Closing the checksum source at \(url.path): \(error.localizedDescription)",
                    ]
                )
            }
            throw primaryError
        }
    }

    private func readBoundedManifest(at url: URL) throws -> Data {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let initial = try url.resourceValues(forKeys: keys)
        guard initial.isRegularFile == true,
              initial.isSymbolicLink != true,
              let expectedByteCount = initial.fileSize,
              expectedByteCount > 0,
              expectedByteCount <= Self.maximumManifestByteCount else {
            throw FitnessDatabaseError.invalidRecoveryBackup(url)
        }

        let handle = try FileHandle(forReadingFrom: url)
        do {
            var data = Data()
            data.reserveCapacity(expectedByteCount)
            while data.count <= Self.maximumManifestByteCount {
                let remaining = Self.maximumManifestByteCount + 1 - data.count
                let chunk = try handle.read(upToCount: min(4_096, remaining)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }

            // Recheck after the bounded read. This rejects replacement/truncation
            // races without ever reading more than the configured cap plus one.
            let final = try url.resourceValues(forKeys: keys)
            guard data.count == expectedByteCount,
                  data.count <= Self.maximumManifestByteCount,
                  final.isRegularFile == true,
                  final.isSymbolicLink != true,
                  final.fileSize == expectedByteCount else {
                throw FitnessDatabaseError.invalidRecoveryBackup(url)
            }
            try handle.close()
            return data
        } catch {
            let primaryError = error
            do {
                try handle.close()
            } catch {
                throw FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: [
                        "Closing the manifest at \(url.path): \(error.localizedDescription)",
                    ]
                )
            }
            throw primaryError
        }
    }

    private func writeStoreManifest(
        in directory: URL,
        identity: String,
        schema: String,
        protectFiles: Bool
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = StoreManifest(
            version: 1,
            ownerIdentityHash: Self.identityHash(identity),
            schemaIdentifier: schema,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = directory.appendingPathComponent(Self.storeManifestFilename)
        try encoder.encode(manifest).write(
            to: url,
            options: protectFiles ? [.atomic, .completeFileProtection] : [.atomic]
        )
        if protectFiles { try LocalFileProtection.protectItem(at: url, fileManager: fileManager) }
    }

    private func readStoreManifest(in directory: URL) throws -> StoreManifest {
        let url = directory.appendingPathComponent(Self.storeManifestFilename)
        return try JSONDecoder().decode(
            StoreManifest.self,
            from: readBoundedManifest(at: url)
        )
    }

    /// Legacy stores legitimately predate owner manifests. Absence is the only
    /// condition that permits creating one from the authenticated owner proof;
    /// corruption, protection failures, and broken symlinks all fail closed.
    private func storeManifestIfPresent(in directory: URL) throws -> StoreManifest? {
        let url = directory.appendingPathComponent(Self.storeManifestFilename)
        var information = stat()
        if lstat(url.path, &information) == 0 {
            return try readStoreManifest(in: directory)
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return nil
    }

    private func createVerifiedBackup(
        from pool: DatabasePool,
        storeURL: URL,
        identity: String,
        appliedMigrations: [String],
        protectFiles: Bool
    ) throws -> URL {
        let backups = backupDirectory(for: storeURL)
        try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        if protectFiles { try LocalFileProtection.prepareDirectory(backups, fileManager: fileManager) }
        let stage = backups.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let databaseURL = stage.appendingPathComponent(Self.backupDatabaseFilename)
        var publishedDirectory: URL?
        var verifiedDatabaseURL: URL?
        do {
            let backup = try DatabaseQueue(path: databaseURL.path)
            // SQLite's online backup API captures one coherent snapshot even
            // when the source pool has committed pages in its WAL.
            do {
                try pool.backup(to: backup)
                // A DatabasePool snapshot inherits WAL mode from its source.
                // Normalize the standalone backup before closing it so later
                // read-only verification and restore never depend on writable
                // WAL/SHM sidecars beside the published recovery record.
                try backup.writeWithoutTransaction { db in
                    let journalMode = try String.fetchOne(
                        db,
                        sql: "PRAGMA journal_mode = DELETE"
                    )
                    guard journalMode?.lowercased() == "delete" else {
                        throw FitnessDatabaseError.invalidRecoveryBackup(databaseURL)
                    }
                }
                try backup.close()
            } catch {
                let backupError = error
                var closeFailures: [String] = []
                do {
                    try backup.close()
                } catch {
                    closeFailures.append(
                        "Closing the incomplete migration snapshot: \(error.localizedDescription)"
                    )
                }
                guard closeFailures.isEmpty else {
                    throw FitnessRecoveryFailureSummary(
                        primaryDescription: backupError.localizedDescription,
                        recoveryFailureDescriptions: closeFailures
                    )
                }
                throw backupError
            }
            // GRDB can retain the WAL shared-memory file after SQLite has
            // successfully changed this snapshot to DELETE journal mode and
            // closed its only connection. At that point WAL/SHM cannot contain
            // recovery data; remove only those exact obsolete sidecars before
            // enforcing the two-file published-record invariant below.
            for sidecar in sqliteComponents(for: databaseURL).dropFirst() {
                if fileManager.fileExists(atPath: sidecar.path) {
                    try fileManager.removeItem(at: sidecar)
                }
            }
            try assertIntegrity(at: databaseURL)
            let values = try databaseURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0 else {
                throw FitnessDatabaseError.invalidRecoveryBackup(databaseURL)
            }
            let manifest = BackupManifest(
                version: 1,
                ownerIdentityHash: Self.identityHash(identity),
                sourceSchema: appliedMigrations.last ?? "unversioned",
                targetSchema: migrationIdentifiers.last ?? "unversioned",
                createdAt: Date(),
                byteCount: byteCount,
                sha256: try Self.sha256(of: databaseURL)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(
                to: stage.appendingPathComponent(Self.backupManifestFilename),
                options: protectFiles ? [.atomic, .completeFileProtection] : [.atomic]
            )
            if protectFiles {
                try LocalFileProtection.protectDirectoryRecursively(stage, fileManager: fileManager)
            }
            let destination = backups.appendingPathComponent(
                "\(Self.fileTimestamp())-\(UUID().uuidString.lowercased()).backup",
                isDirectory: true
            )
            try fileManager.moveItem(at: stage, to: destination)
            publishedDirectory = destination
            let verified = try verifiedBackup(
                in: destination,
                identity: identity,
                expectedBackupsDirectory: backups
            )
            verifiedDatabaseURL = verified.url
            try rotateBackups(for: storeURL, identity: identity)
            return verified.url
        } catch {
            let primaryError = error
            var cleanupFailures: [String] = []
            var cleanupTargets: [URL] = []
            if fileManager.fileExists(atPath: stage.path) {
                cleanupTargets.append(stage)
            }
            if verifiedDatabaseURL == nil,
               let publishedDirectory,
               fileManager.fileExists(atPath: publishedDirectory.path) {
                cleanupTargets.append(publishedDirectory)
            }
            for cleanupTarget in cleanupTargets {
                do {
                    try fileManager.removeItem(at: cleanupTarget)
                } catch {
                    cleanupFailures.append(
                        "Removing the incomplete migration backup at \(cleanupTarget.path): \(error.localizedDescription)"
                    )
                }
            }
            if cleanupFailures.isEmpty,
               case FitnessDatabaseError.recoveryFailed = primaryError {
                throw primaryError
            }
            guard !cleanupFailures.isEmpty || verifiedDatabaseURL != nil else {
                throw primaryError
            }
            throw FitnessDatabaseError.recoveryFailed(
                store: storeURL,
                backup: verifiedDatabaseURL,
                recoveryPaths: boundedExistingRecoveryPaths(
                    [stage] + [publishedDirectory].compactMap { $0 }
                ),
                underlying: FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: cleanupFailures
                )
            )
        }
    }

    private func verifiedBackup(
        in directory: URL,
        identity: String,
        expectedBackupsDirectory: URL
    ) throws -> FitnessRecoveryBackup {
        let directory = directory.standardizedFileURL
        let expectedBackupsDirectory = expectedBackupsDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == expectedBackupsDirectory,
              Self.backupFilenameTimestamp(directory.lastPathComponent) != nil else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        let backupsDirectoryValues = try expectedBackupsDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard backupsDirectoryValues.isDirectory == true,
              backupsDirectoryValues.isSymbolicLink != true else {
            throw FitnessDatabaseError.invalidRecoveryBackup(expectedBackupsDirectory)
        }
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        guard try hasExactBackupContents(in: directory) else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        let databaseURL = directory.appendingPathComponent(Self.backupDatabaseFilename)
        let manifestURL = directory.appendingPathComponent(Self.backupManifestFilename)
        let manifest = try JSONDecoder().decode(
            BackupManifest.self,
            from: readBoundedManifest(at: manifestURL)
        )
        let values = try databaseURL.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard manifest.version == 1,
              manifest.ownerIdentityHash == Self.identityHash(identity),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == manifest.byteCount,
              try schemaIdentifier(at: databaseURL) == manifest.sourceSchema,
              try Self.sha256(of: databaseURL) == manifest.sha256 else {
            throw FitnessDatabaseError.invalidRecoveryBackup(databaseURL)
        }
        try assertIntegrity(at: databaseURL)
        return FitnessRecoveryBackup(
            url: databaseURL,
            sourceSchema: manifest.sourceSchema,
            targetSchema: manifest.targetSchema,
            createdAt: manifest.createdAt
        )
    }

    private func backupRecordDirectories(for storeURL: URL) throws -> [URL] {
        let backups = backupDirectory(for: try validatedStoreURL(storeURL))
        guard fileManager.fileExists(atPath: backups.path) else { return [] }
        let rootValues = try backups.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw FitnessDatabaseError.invalidRecoveryBackup(backups)
        }
        var enumerationError: Error?
        guard let entries = fileManager.enumerator(
            at: backups,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FitnessDatabaseError.invalidRecoveryBackup(backups)
        }
        var candidates: [(timestamp: Int64, url: URL)] = []
        var eligibleCount = 0
        while let next = entries.nextObject() {
            guard let entry = next as? URL else { continue }
            let url = entry.standardizedFileURL
            guard url.deletingLastPathComponent() == backups,
                  let timestamp = Self.backupFilenameTimestamp(url.lastPathComponent) else {
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                Self.logger.warning(
                    "Preserved unreadable Fitness backup candidate at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            eligibleCount += 1
            candidates.append((timestamp,url))
            candidates.sort(by: Self.backupCandidatePrecedes)
            if candidates.count > Self.maximumBackupVerificationCandidates {
                candidates.removeLast()
            }
        }
        if let enumerationError { throw enumerationError }
        if eligibleCount > Self.maximumBackupVerificationCandidates {
            Self.logger.warning(
                "Fitness backup verification bounded \(eligibleCount, privacy: .public) exact candidates to the newest \(Self.maximumBackupVerificationCandidates, privacy: .public)."
            )
        }
        return candidates.map(\.url)
    }

    private func hasExactBackupContents(in directory: URL) throws -> Bool {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationError: Error?
        guard let children = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return false }
        var names = Set<String>()
        while let next = children.nextObject() {
            guard let child = next as? URL else { return false }
            let standardizedChild = child.standardizedFileURL
            guard standardizedChild.deletingLastPathComponent() == directory,
                  names.count < 2,
                  standardizedChild.lastPathComponent == Self.backupDatabaseFilename
                    || standardizedChild.lastPathComponent == Self.backupManifestFilename,
                  names.insert(standardizedChild.lastPathComponent).inserted,
                  let values = try? standardizedChild.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return false }
        }
        if let enumerationError { throw enumerationError }
        return names == Set([
            Self.backupDatabaseFilename,
            Self.backupManifestFilename,
        ])
    }

    private static func backupFilenameTimestamp(_ filename: String) -> Int64? {
        let suffix = ".backup"
        guard filename.hasSuffix(suffix) else { return nil }
        let stem = String(filename.dropLast(suffix.count))
        guard stem.count > 37 else { return nil }
        let uuidStart = stem.index(stem.endIndex, offsetBy: -36)
        let delimiter = stem.index(before: uuidStart)
        guard stem[delimiter] == "-" else { return nil }
        let timestampText = String(stem[..<delimiter])
        let uuidText = String(stem[uuidStart...])
        guard !timestampText.isEmpty,
              timestampText.allSatisfy(\.isNumber),
              let timestamp = Int64(timestampText),
              timestamp >= 0,
              String(timestamp) == timestampText,
              isCanonicalLowercaseUUID(uuidText) else { return nil }
        return timestamp
    }

    private static func backupCandidatePrecedes(
        _ lhs: (timestamp: Int64, url: URL),
        _ rhs: (timestamp: Int64, url: URL)
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }

    private func forEachImmediateEntry(
        in directory: URL,
        _ body: (URL) throws -> Void
    ) throws {
        let directory = directory.standardizedFileURL
        let rootValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        var enumerationError: Error?
        guard let entries = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        while let next = entries.nextObject() {
            guard let entry = next as? URL else { continue }
            let standardizedEntry = entry.standardizedFileURL
            guard standardizedEntry.deletingLastPathComponent() == directory else { continue }
            try body(standardizedEntry)
        }
        if let enumerationError { throw enumerationError }
    }

    private func directoryHasAnyImmediateEntry(_ directory: URL) throws -> Bool {
        var enumerationError: Error?
        guard let entries = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FitnessDatabaseError.invalidRecoveryBackup(directory)
        }
        if entries.nextObject() != nil { return true }
        if let enumerationError { throw enumerationError }
        return false
    }

    private static func isBackupStageFilename(_ filename: String) -> Bool {
        exactLowercaseUUID(in: filename,prefix: ".stage-",suffix: "")
    }

    private static func isRestoreStageFilename(_ filename: String) -> Bool {
        exactLowercaseUUID(in: filename,prefix: ".restore-",suffix: "")
    }

    private static func recoveryDirectoryTimestamp(_ filename: String) -> Int64? {
        let prefix = "Recovery-original-"
        guard filename.hasPrefix(prefix) else { return nil }
        let remainder = String(filename.dropFirst(prefix.count))
        guard remainder.count > 37 else { return nil }
        let uuidStart = remainder.index(remainder.endIndex,offsetBy: -36)
        let delimiter = remainder.index(before: uuidStart)
        guard remainder[delimiter] == "-" else { return nil }
        let timestampText = String(remainder[..<delimiter])
        let uuidText = String(remainder[uuidStart...])
        guard let timestamp = Int64(timestampText),
              timestamp >= 0,
              String(timestamp) == timestampText,
              isCanonicalLowercaseUUID(uuidText) else { return nil }
        return timestamp
    }

    private static func exactLowercaseUUID(
        in filename: String,
        prefix: String,
        suffix: String
    ) -> Bool {
        guard filename.hasPrefix(prefix),filename.hasSuffix(suffix) else { return false }
        let uuidStart = filename.index(filename.startIndex,offsetBy: prefix.count)
        let uuidEnd = filename.index(filename.endIndex,offsetBy: -suffix.count)
        guard uuidStart <= uuidEnd else { return false }
        return isCanonicalLowercaseUUID(String(filename[uuidStart..<uuidEnd]))
    }

    private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        guard value.count == 36,
              value == value.lowercased(),
              let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private func boundedExistingRecoveryPaths(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let url = url.standardizedFileURL
            guard result.count < Self.maximumReportedRecoveryPaths,
                  seen.insert(url.path).inserted,
                  fileManager.fileExists(atPath: url.path) else { continue }
            result.append(url)
        }
        return result
    }

    private func rotateBackups(for storeURL: URL, identity: String) throws {
        let backupsDirectory = backupDirectory(for: storeURL)
        var valid: [FitnessRecoveryBackup] = []
        for directory in try backupRecordDirectories(for: storeURL) {
            do {
                valid.append(try verifiedBackup(
                    in: directory,
                    identity: identity,
                    expectedBackupsDirectory: backupsDirectory
                ))
            } catch {
                Self.logger.warning(
                    "Preserved invalid Fitness backup candidate at \(directory.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        valid.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        let expired = Array(valid.dropFirst(Self.maximumBackups))
        for record in expired.prefix(Self.maximumRecoveryReconciliationEffects) {
            do {
                try fileManager.removeItem(at: record.url.deletingLastPathComponent())
            } catch {
                throw FitnessDatabaseError.recoveryFailed(
                    store: storeURL,
                    backup: valid.first?.url,
                    recoveryPaths: boundedExistingRecoveryPaths(
                        expired.map { $0.url.deletingLastPathComponent() }
                    ),
                    underlying: error
                )
            }
        }
        if expired.count > Self.maximumRecoveryReconciliationEffects {
            throw FitnessDatabaseError.recoveryFailed(
                store: storeURL,
                backup: valid.first?.url,
                recoveryPaths: boundedExistingRecoveryPaths(
                    expired.dropFirst(Self.maximumRecoveryReconciliationEffects)
                        .map { $0.url.deletingLastPathComponent() }
                ),
                underlying: FitnessRecoveryFailureSummary(
                    primaryDescription: "Fitness backup rotation reached its bounded deletion limit before restoring the three-backup invariant.",
                    recoveryFailureDescriptions: []
                )
            )
        }
    }

    private func assertIntegrity(_ pool: DatabasePool) throws {
        try pool.read { db in try Self.assertIntegrity(db) }
    }

    private func assertIntegrity(at url: URL) throws {
        try withReadOnlyDatabase(at: url) { db in
            try Self.assertIntegrity(db)
        }
    }

    private func schemaIdentifier(at url: URL) throws -> String {
        try withReadOnlyDatabase(at: url) { db in
            guard try db.tableExists("grdb_migrations") else { return "unversioned" }
            return try String.fetchOne(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"
            ) ?? "unversioned"
        }
    }

    private func withReadOnlyDatabase<T>(
        at url: URL,
        _ body: (Database) throws -> T
    ) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            let result = try queue.read(body)
            try queue.close()
            return result
        } catch {
            let primaryError = error
            do {
                try queue.close()
            } catch {
                throw FitnessRecoveryFailureSummary(
                    primaryDescription: primaryError.localizedDescription,
                    recoveryFailureDescriptions: [
                        "Closing the verified database at \(url.path): \(error.localizedDescription)",
                    ]
                )
            }
            throw primaryError
        }
    }

    private static func assertIntegrity(_ db: Database) throws {
        let result = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard result.count == 1, result[0].lowercased() == "ok" else {
            throw DatabaseError(message: "SQLite integrity check failed: \(result.joined(separator: "; "))")
        }
    }

    private func sqliteComponents(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
    }

    private func storeRecoveryComponents(for storeURL: URL) -> [URL] {
        sqliteComponents(for: storeURL) + [
            storeURL.deletingLastPathComponent()
                .appendingPathComponent(Self.storeManifestFilename),
        ]
    }

    private func failedRestoreFilename(for component: URL, storeURL: URL) -> String {
        if component == storeURL { return "failed-restored.sqlite" }
        if component.path == storeURL.path + "-wal" { return "failed-restored.sqlite-wal" }
        if component.path == storeURL.path + "-shm" { return "failed-restored.sqlite-shm" }
        return "failed-restored-store-manifest.json"
    }

    private static func fileTimestamp(_ date: Date = Date()) -> String {
        String(Int(date.timeIntervalSince1970 * 1_000))
    }

    private static func safeIdentity(_ identity: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return identity.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}
