"""Irreversible live-data deletion for a user or their final family account."""

import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone


FINANCE_TABLES = (
    "finance_accounts",
    "finance_analysis_views",
    "finance_ai_consents",
    "finance_assignments",
    "finance_balance_snapshots",
    "finance_categories",
    "finance_calendar_items",
    "finance_calendar_source_links",
    "finance_capture_drafts",
    "finance_coaching_reports",
    "finance_commitments",
    "finance_commitment_occurrences",
    "finance_connection_derived_refreshes",
    "finance_connections",
    "finance_declared_contributions",
    "finance_facts",
    "finance_forecast_days",
    "finance_forecast_events",
    "finance_forecast_snapshots",
    "finance_findings",
    "finance_goals",
    "finance_habit_observations",
    "finance_habits",
    "finance_email_aliases",
    "finance_email_enrollments",
    "finance_email_messages",
    "finance_line_refunds",
    "finance_merchant_aliases",
    "finance_merchants",
    "finance_material_questions",
    "finance_opportunity_actions",
    "finance_payday_actions",
    "finance_plan_categories",
    "finance_plans",
    "finance_preferences",
    "finance_product_comparisons",
    "finance_product_price_observations",
    "finance_projection_preferences",
    "finance_positions",
    "finance_purchase_evaluations",
    "finance_purchase_exceptions",
    "finance_purchase_classification_feedback",
    "finance_purchase_line_assessments",
    "finance_purchase_lines",
    "finance_purchase_payments",
    "finance_purchase_proposals",
    "finance_purchase_records",
    "finance_purchase_source_health",
    "finance_purchase_source_files",
    "finance_purchase_sources",
    "finance_purchase_tenders",
    "finance_normalized_purchase_items",
    "finance_recurring_series",
    "finance_report_preferences",
    "finance_retailer_research_requests",
    "finance_retailer_research_results",
    "finance_reserves",
    "finance_settings",
    "finance_share_actions",
    "finance_share_copy_links",
    "finance_source_transactions",
    "finance_spaces",
    "finance_transaction_relations",
    "finance_transaction_sources",
    "finance_transaction_splits",
    "finance_transactions",
    "finance_asset_import_previews",
    "finance_market_price_observations",
    "finance_manual_asset_values",
    "finance_manual_assets",
    "finance_asset_report_activities",
    "finance_asset_snapshots",
    "finance_asset_sources",
    "finance_valuations",
)


# Child/link rows first. SQLite foreign-key enforcement is intentionally disabled,
# but this order also remains safe if it is enabled for maintenance tooling later.
HEALTH_OWNER_PRIVATE_TABLES = (
    "fitness_vi_booking_receipts",
    "health_strava_oauth_states",
    "health_strava_connections",
    "health_intervals_publications",
    "health_intervals_oauth_states",
    "health_intervals_connections",
    "health_provider_notifications",
    "health_provider_oauth_states",
    "health_provider_connections",
    "health_sync_mutation_receipts",
    "health_change_log",
    "health_sync_notices",
    "health_cycle_period_starts",
    "health_cycle_settings",
    "health_fitness_reminders",
    "health_file_reconciliation_runs",
    "health_import_review_candidates",
    "health_sleep_stages",
    "health_progress_photos",
    "health_recovery_observations",
    "health_sleep_sessions",
    "health_source_priorities",
    "health_saved_analysis_charts",
    "health_coach_messages",
    "health_coach_conversations",
    "health_coach_memories",
    "health_coach_recommendations",
    "health_coach_proposals",
    "health_activity_quality_findings",
    "health_activity_analysis_results",
    "health_activity_features",
    "health_activity_markers",
    "health_activity_intervals",
    "health_activity_summary_metrics",
    "health_activity_metric_index",
    "health_activity_stream_assets",
    "health_activity_source_records",
    "health_activity_gear_links",
    "health_activity_goal_links",
    "health_plan_activity_links",
    "health_planned_session_gear_links",
    "health_run_workout_cues",
    "health_run_workout_steps",
    "health_garmin_exports",
    "health_jobs",
    "health_imports",
    "health_body_issue_observations",
    "health_body_locations",
    "health_session_checkins",
    "health_strength_sets",
    "health_strength_set_groups",
    "health_strength_session_exercises",
    "health_strength_planned_sets",
    "health_strength_workout_exercise_substitutions",
    "health_strength_workout_exercises",
    "health_activities",
    "health_planned_session_sets",
    "health_planned_session_exercise_substitutions",
    "health_planned_session_exercises",
    "health_planned_session_goal_links",
    "health_planned_sessions",
    "health_training_programme_goal_links",
    "health_training_programmes",
    "health_workout_versions",
    "health_workout_definitions",
    "health_exercise_setups",
    "health_exercise_muscle_roles",
    "health_exercises",
    "health_food_log_entries",
    "health_nutrition_meal_completions",
    "health_meal_template_items",
    "health_meal_templates",
    "health_recipe_components",
    "health_recipe_versions",
    "health_recipes",
    "health_food_servings",
    "health_food_versions",
    "health_foods",
    "health_body_measurements",
    "health_nutrition_targets",
    "health_training_phase_goal_links",
    "health_training_phases",
    "health_goal_relationships",
    "health_goals",
    "health_onboarding_profiles",
    "health_fitness_workspace_preferences",
    "health_user_settings",
    "health_gear_items",
    "health_source_records",
    "health_file_assets",
)


# These rows are deliberately retained after the family transaction commits so
# filesystem cleanup can retry without resurrecting deleted private metadata.
FAMILY_PURGE_EXEMPT_TABLES = ("health_deferred_file_deletions",)


FAMILY_PURGE_TABLES = (
    "adoption_events",
    "apns_device_registrations",
    "artworks",
    "assistant_actions",
    "birthday_preparation_links",
    "birthday_preparations",
    "birthdays",
    "calendar_event_documents",
    "calendar_event_exceptions",
    "calendar_events",
    "calendar_feed_tokens",
    "calendar_sources",
    "capture_suggestions",
    "caregiver_bookings",
    "caregiver_contacts",
    "caregiver_child_profiles",
    "caregiver_handovers",
    "child_milestones",
    "child_care_assignments",
    "child_photos",
    "child_vaccinations",
    "children",
    "consumption_events",
    "coordination_actions",
    "cycle_period_starts",
    "cycle_settings",
    "document_inbox_addresses",
    "document_people",
    "documents",
    "dog_activities",
    "dog_document_links",
    "dog_weights",
    "dog_profiles",
    "dog_vaccinations",
    "event_prep_occurrences",
    "event_prep_templates",
    "family_commitment_results",
    "family_commitment_sources",
    "family_commitments",
    "family_settings",
    "family_insights",
    "facility_calendar_preferences",
    "facility_schedule_days",
    "facility_schedule_versions",
    *FINANCE_TABLES,
    "grocery_items",
    "growth_records",
    "health_data",
    "health_household_meal_recipe_links",
    *HEALTH_OWNER_PRIVATE_TABLES,
    "holiday_dates",
    "homework_reading",
    "homework_spelling_sessions",
    "homework_spellings",
    "illnesses",
    "inbound_email_messages",
    "idempotency_records",
    "library_loans",
    "library_accounts",
    "meal_plans",
    "meal_ratings",
    "meals",
    "medicine_doses",
    "medicine_types",
    "naps",
    "present_idea_scores",
    "present_status_history",
    "present_ideas",
    "purchase_batches",
    "purchases",
    "reminder_deliveries",
    "reminder_preferences",
    "renewal_checklist_items",
    "renewal_outcomes",
    "renewals",
    "routine_items",
    "routine_term_overrides",
    "share_capture_drafts",
    "shopping_items",
    "school_club_exceptions",
    "school_clubs",
    "star_chart_balance_transactions",
    "star_chart_balances",
    "star_chart_stars",
    "star_charts",
    "sync_queue",
    "task_assignments",
    "tasks",
    "temperature_readings",
    "term_dates",
    "term_time_handoff_overrides",
    "term_time_handoffs",
    "tesco_history_lines",
    "tesco_history_orders",
    "tesco_history_imports",
    "toast_club_import_days",
    "toast_club_imports",
    "web_push_subscriptions",
    "yearbook_narratives",
)

USER_PRIVATE_TABLES = (
    "adoption_events",
    "apns_device_registrations",
    "coordination_actions",
    "present_idea_scores",
    "reminder_deliveries",
    "reminder_preferences",
    "share_capture_drafts",
    "web_push_subscriptions",
)


@dataclass(frozen=True)
class AccountDeletionResult:
    final_family: bool
    storage_keys: tuple[str, ...] = ()
    fitness_storage_keys: tuple[tuple[str, str], ...] = ()
    fitness_deletion_queue: tuple[tuple[str, str, str], ...] = ()


async def _queue_fitness_file_deletions(
    db,
    *,
    family_id: str,
    owner_user_id: str | None,
    storage_keys: tuple[tuple[str, str], ...],
) -> tuple[tuple[str, str, str], ...]:
    now = datetime.now(timezone.utc).isoformat()
    queued: list[tuple[str, str, str]] = []
    for storage_key, storage_class in storage_keys:
        identifier = str(uuid.uuid4())
        await db.execute(
            "INSERT INTO health_deferred_file_deletions "
            "(id, storage_key, storage_class, status, attempt_count, revision, "
            "family_id, owner_user_id, created_at, updated_at, created_by) "
            "VALUES (?, ?, ?, 'pending', 0, 1, ?, ?, ?, ?, ?)",
            (
                identifier,
                storage_key,
                storage_class,
                family_id,
                owner_user_id,
                now,
                now,
                owner_user_id,
            ),
        )
        queued.append((identifier, storage_key, storage_class))
    return tuple(queued)


async def process_deferred_fitness_file_deletions(db, *, limit: int = 200) -> int:
    """Retry committed account-deletion file removals without private logging."""
    from app.services.fitness.activity_import import remove_fitness_storage_key

    rows = await (
        await db.execute(
            "SELECT id, storage_key, storage_class FROM health_deferred_file_deletions "
            "WHERE status IN ('pending','retrying') AND deleted_at IS NULL "
            "ORDER BY created_at LIMIT ?",
            (limit,),
        )
    ).fetchall()
    completed = 0
    for candidate in rows:
        await db.execute("BEGIN IMMEDIATE")
        try:
            row = await (
                await db.execute(
                    "SELECT id, storage_key, storage_class "
                    "FROM health_deferred_file_deletions WHERE id = ? "
                    "AND status IN ('pending','retrying') AND deleted_at IS NULL",
                    (candidate["id"],),
                )
            ).fetchone()
            if row is None:
                await db.rollback()
                continue
            restored = await (
                await db.execute(
                    "SELECT 1 FROM health_file_assets WHERE storage_key = ? "
                    "AND storage_class = ? AND state IN ('staged','ready') "
                    "AND deleted_at IS NULL LIMIT 1",
                    (row["storage_key"], row["storage_class"]),
                )
            ).fetchone()
            if restored is not None:
                await db.execute(
                    "DELETE FROM health_deferred_file_deletions WHERE id = ?",
                    (row["id"],),
                )
                await db.commit()
                continue
            try:
                await remove_fitness_storage_key(row["storage_key"], row["storage_class"])
            except (OSError, ValueError):
                now = datetime.now(timezone.utc).isoformat()
                await db.execute(
                    "UPDATE health_deferred_file_deletions SET status = 'retrying', "
                    "attempt_count = attempt_count + 1, last_attempt_at = ?, updated_at = ?, "
                    "revision = revision + 1 WHERE id = ?",
                    (now, now, row["id"]),
                )
                await db.commit()
                continue
            # Once the private file is gone, retaining its path would itself
            # defeat deletion, so the operational row is intentionally purged.
            await db.execute(
                "DELETE FROM health_deferred_file_deletions WHERE id = ?",
                (row["id"],),
            )
            await db.commit()
            completed += 1
        except BaseException:
            if db.in_transaction:
                await db.rollback()
            raise
    return completed


async def _storage_keys(db, family_id: str) -> tuple[str, ...]:
    keys: list[str] = []
    for table in ("documents", "artworks", "child_photos"):
        cursor = await db.execute(
            f"SELECT storage_key FROM {table} WHERE family_id = ? AND storage_key IS NOT NULL",
            (family_id,),
        )
        keys.extend(row[0] for row in await cursor.fetchall() if row[0])
    for table in ("artworks", "child_photos"):
        cursor = await db.execute(
            f"SELECT original_storage_key FROM {table} "
            "WHERE family_id = ? AND original_storage_key IS NOT NULL",
            (family_id,),
        )
        keys.extend(row[0] for row in await cursor.fetchall() if row[0])
    cursor = await db.execute(
        "SELECT storage_key FROM finance_purchase_source_files "
        "WHERE family_id = ? AND storage_key IS NOT NULL",
        (family_id,),
    )
    keys.extend(row[0] for row in await cursor.fetchall() if row[0])
    return tuple(dict.fromkeys(keys))


async def _fitness_storage_keys(
    db,
    family_id: str,
    *,
    owner_user_id: str | None = None,
) -> tuple[tuple[str, str], ...]:
    """Collect a member's Fitness files before their asset rows are removed."""
    parameters: list[str] = [family_id]
    owner_clause = ""
    if owner_user_id is not None:
        owner_clause = " AND owner_user_id = ?"
        parameters.append(owner_user_id)
    rows = await (
        await db.execute(
            "SELECT storage_key, storage_class FROM health_file_assets "
            "WHERE family_id = ?" + owner_clause + " AND storage_key IS NOT NULL",
            parameters,
        )
    ).fetchall()
    return tuple(dict.fromkeys((row[0], row[1]) for row in rows if row[0] and row[1]))


async def _delete_private_finance(
    db,
    *,
    user_id: str,
    family_id: str,
) -> tuple[str, ...]:
    """Remove a departing adult's private Finance space and cloud-AI consent."""
    # A bank connection belongs to the adult who authorised it even when its
    # imported history belongs to the household. Invalidate every one of that
    # adult's provider operations before authorship is anonymised below. Shared
    # accounts and transactions remain readable, but nobody can reuse the
    # departing adult's credential or an already-running callback/sync lease.
    await db.execute(
        """
        UPDATE finance_connections
        SET status = 'DISCONNECTED', encrypted_provider_secret_ref = NULL,
            callback_state_hash = NULL, sync_lease_token = NULL,
            sync_lease_expires_at = NULL, next_retry_at = NULL,
            consecutive_sync_failures = 0, last_error_code = NULL,
            operation_generation = operation_generation + 1,
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE family_id = ? AND created_by = ? AND deleted_at IS NULL
        """,
        (family_id, user_id),
    )
    personal_spaces = await (
        await db.execute(
            """
            SELECT id FROM finance_spaces
            WHERE family_id = ? AND kind = 'personal' AND owner_user_id = ?
            """,
            (family_id, user_id),
        )
    ).fetchall()
    personal_space_ids = [row[0] for row in personal_spaces]
    storage_keys: list[str] = []
    for space_id in personal_space_ids:
        rows = await (
            await db.execute(
                "SELECT storage_key FROM finance_purchase_source_files "
                "WHERE family_id = ? AND space_id = ? AND storage_key IS NOT NULL",
                (family_id, space_id),
            )
        ).fetchall()
        storage_keys.extend(row[0] for row in rows if row[0])

    # Household consent belongs to the adult, so it is removed even though the
    # shared household records remain for the other family member.
    await db.execute(
        "DELETE FROM finance_ai_consents WHERE family_id = ? AND user_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_analysis_views WHERE family_id = ? AND owner_user_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_capture_drafts WHERE family_id = ? AND creator_user_id = ?",
        (family_id, user_id),
    )
    # Report preferences and generated guidance belong to the member even when
    # their selected space is the shared household space.
    await db.execute(
        "DELETE FROM finance_report_preferences WHERE family_id = ? AND member_user_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_coaching_reports WHERE family_id = ? AND member_user_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_projection_preferences WHERE family_id = ? AND user_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_calendar_source_links WHERE family_id = ? AND owner_user_id = ?",
        (family_id, user_id),
    )
    # Source-to-household provenance is private to the sharing adult.  Their
    # already-published household copies remain, but no source identifier or
    # active future rule survives account deletion.
    await db.execute(
        "DELETE FROM finance_share_copy_links "
        "WHERE family_id = ? AND share_action_id IN ("
        "SELECT id FROM finance_share_actions "
        "WHERE family_id = ? AND owner_user_id = ?)",
        (family_id, family_id, user_id),
    )
    await db.execute(
        "DELETE FROM finance_share_actions WHERE family_id = ? AND owner_user_id = ?",
        (family_id, user_id),
    )

    for space_id in personal_space_ids:
        # Occurrences inherit privacy from their commitment but deliberately do
        # not duplicate space_id, so remove them before the parent commitments.
        await db.execute(
            "DELETE FROM finance_commitment_occurrences "
            "WHERE family_id = ? AND commitment_id IN ("
            "SELECT id FROM finance_commitments "
            "WHERE family_id = ? AND space_id = ?)",
            (family_id, family_id, space_id),
        )
        for table in FINANCE_TABLES:
            if table in {"finance_settings", "finance_spaces"}:
                continue
            columns = {
                row[1] for row in await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
            }
            if "space_id" in columns:
                await db.execute(
                    f"DELETE FROM {table} WHERE family_id = ? AND space_id = ?",
                    (family_id, space_id),
                )
        await db.execute(
            "DELETE FROM finance_spaces WHERE family_id = ? AND id = ?",
            (family_id, space_id),
        )

    # History snapshots can otherwise retain private balances, descriptions or
    # encrypted connection material after the authoritative rows are gone.
    clauses = ["changed_by = ?", "instr(previous_values, ?) > 0"]
    parameters: list[str] = [user_id, user_id]
    for space_id in personal_space_ids:
        clauses.append("instr(previous_values, ?) > 0")
        parameters.append(space_id)
    await db.execute(
        f"""
        DELETE FROM record_history
        WHERE family_id = ? AND table_name LIKE 'finance_%'
          AND ({" OR ".join(clauses)})
        """,
        (family_id, *parameters),
    )
    return tuple(dict.fromkeys(storage_keys))


async def _transfer_linked_household_nutrition(
    db,
    *,
    departing_user_id: str,
    family_id: str,
) -> None:
    """Keep the recipe graph behind retained family meal links usable.

    Fitness nutrition is owner-private by default, but explicitly linked household
    recipes are family data. When their original owner leaves, the highest-priority
    remaining adult becomes the custodian of only the linked recipe versions and
    the ingredient rows those versions need. Unlinked nutrition remains private and
    is deleted by the normal owner-table pass below.
    """
    remaining_owner = await (
        await db.execute(
            "SELECT id FROM users WHERE family_id = ? AND id != ? "
            "AND deleted_at IS NULL ORDER BY priority DESC, id LIMIT 1",
            (family_id, departing_user_id),
        )
    ).fetchone()
    if remaining_owner is None:
        return
    new_owner_id = remaining_owner[0]

    linked_versions = await (
        await db.execute(
            "SELECT DISTINCT v.id, v.recipe_id FROM health_household_meal_recipe_links l "
            "JOIN health_recipe_versions v ON v.id = l.recipe_version_id "
            "AND v.family_id = l.family_id "
            "WHERE l.family_id = ? AND v.owner_user_id = ?",
            (family_id, departing_user_id),
        )
    ).fetchall()
    version_ids = [row[0] for row in linked_versions]
    recipe_ids = list(dict.fromkeys(row[1] for row in linked_versions))
    if not version_ids:
        return

    version_placeholders = ",".join("?" for _ in version_ids)
    components = await (
        await db.execute(
            f"SELECT id, food_version_id FROM health_recipe_components "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND recipe_version_id IN ({version_placeholders})",
            (family_id, departing_user_id, *version_ids),
        )
    ).fetchall()
    component_ids = [row[0] for row in components]
    food_version_ids = list(dict.fromkeys(row[1] for row in components))

    await db.execute(
        f"UPDATE health_recipe_versions SET owner_user_id = ? "
        f"WHERE family_id = ? AND owner_user_id = ? "
        f"AND id IN ({version_placeholders})",
        (new_owner_id, family_id, departing_user_id, *version_ids),
    )
    if recipe_ids:
        recipe_placeholders = ",".join("?" for _ in recipe_ids)
        await db.execute(
            f"UPDATE health_recipes SET owner_user_id = ? "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND id IN ({recipe_placeholders})",
            (new_owner_id, family_id, departing_user_id, *recipe_ids),
        )
    if component_ids:
        component_placeholders = ",".join("?" for _ in component_ids)
        await db.execute(
            f"UPDATE health_recipe_components SET owner_user_id = ? "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND id IN ({component_placeholders})",
            (new_owner_id, family_id, departing_user_id, *component_ids),
        )

    if not food_version_ids:
        return
    food_version_placeholders = ",".join("?" for _ in food_version_ids)
    food_versions = await (
        await db.execute(
            f"SELECT id, food_id FROM health_food_versions "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND id IN ({food_version_placeholders})",
            (family_id, departing_user_id, *food_version_ids),
        )
    ).fetchall()
    transferred_version_ids = [row[0] for row in food_versions]
    food_ids = list(dict.fromkeys(row[1] for row in food_versions))
    if not transferred_version_ids:
        return
    transferred_placeholders = ",".join("?" for _ in transferred_version_ids)
    await db.execute(
        f"UPDATE health_food_versions SET owner_user_id = ?, label_asset_id = NULL "
        f"WHERE family_id = ? AND owner_user_id = ? "
        f"AND id IN ({transferred_placeholders})",
        (new_owner_id, family_id, departing_user_id, *transferred_version_ids),
    )
    if food_ids:
        food_placeholders = ",".join("?" for _ in food_ids)
        await db.execute(
            f"UPDATE health_foods SET owner_user_id = ? "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND id IN ({food_placeholders})",
            (new_owner_id, family_id, departing_user_id, *food_ids),
        )
        await db.execute(
            f"UPDATE health_food_servings SET owner_user_id = ? "
            f"WHERE family_id = ? AND owner_user_id = ? "
            f"AND food_id IN ({food_placeholders})",
            (new_owner_id, family_id, departing_user_id, *food_ids),
        )


def _scrub_identity_text(
    value: str,
    *,
    user_id: str,
    user_email: str,
    user_name: str,
) -> str:
    """Replace identifiers and a standalone display name in retained shared text."""
    cleaned = re.sub(re.escape(user_id), "", value, flags=re.IGNORECASE)
    cleaned = re.sub(
        re.escape(user_email),
        "Deleted family member",
        cleaned,
        flags=re.IGNORECASE,
    )
    if user_name.strip():
        cleaned = re.sub(
            rf"(?<!\w){re.escape(user_name.strip())}(?!\w)",
            "Deleted family member",
            cleaned,
            flags=re.IGNORECASE,
        )
    return cleaned


def _contains_identity(
    value: str,
    *,
    user_id: str,
    user_email: str,
    user_name: str,
) -> bool:
    if user_id.casefold() in value.casefold() or user_email.casefold() in value.casefold():
        return True
    return bool(
        user_name.strip()
        and re.search(
            rf"(?<!\w){re.escape(user_name.strip())}(?!\w)",
            value,
            flags=re.IGNORECASE,
        )
    )


def _scrub_commitment_plan_identity(
    value,
    *,
    user_id: str,
    user_email: str,
    user_name: str,
):
    """Remove a departing adult's identifiers without discarding shared planning."""
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if key in {"person_ids", "affected_adult_ids"} and isinstance(item, list):
                cleaned[key] = [person for person in item if person != user_id]
            elif key == "assigned_to" and item == user_id:
                cleaned[key] = None
            else:
                cleaned[key] = _scrub_commitment_plan_identity(
                    item,
                    user_id=user_id,
                    user_email=user_email,
                    user_name=user_name,
                )
        external = cleaned.get("external_action")
        original_external = value.get("external_action")
        if isinstance(external, dict) and isinstance(original_external, dict):
            target = original_external.get("target")
            if isinstance(target, str) and _contains_identity(
                target,
                user_id=user_id,
                user_email=user_email,
                user_name=user_name,
            ):
                external["target_type"] = "manual"
                external["target"] = "Follow the instructions in the retained family source"
        return cleaned
    if isinstance(value, list):
        return [
            _scrub_commitment_plan_identity(
                item,
                user_id=user_id,
                user_email=user_email,
                user_name=user_name,
            )
            for item in value
        ]
    if isinstance(value, str):
        return _scrub_identity_text(
            value,
            user_id=user_id,
            user_email=user_email,
            user_name=user_name,
        )
    return value


async def _remove_private_and_transfer_shared_commitments(
    db,
    *,
    user_id: str,
    user_email: str,
    user_name: str,
    family_id: str,
) -> None:
    """Erase private drafts; anonymise and retain explicitly shared family plans."""
    replacement = await (
        await db.execute(
            "SELECT id FROM users WHERE family_id = ? AND id != ? AND deleted_at IS NULL "
            "ORDER BY priority DESC, id LIMIT 1",
            (family_id, user_id),
        )
    ).fetchone()
    if replacement is None:
        return
    replacement_user_id = replacement[0]

    private_rows = await (
        await db.execute(
            "SELECT id FROM family_commitments WHERE family_id = ? "
            "AND owner_user_id = ? AND visibility = 'owner'",
            (family_id, user_id),
        )
    ).fetchall()
    private_ids = [row[0] for row in private_rows]
    if private_ids:
        placeholders = ",".join("?" for _ in private_ids)
        results = await (
            await db.execute(
                f"SELECT result_type, result_id FROM family_commitment_results "
                f"WHERE family_id = ? AND commitment_id IN ({placeholders})",
                (family_id, *private_ids),
            )
        ).fetchall()
        event_ids = [row[1] for row in results if row[0] == "calendar_event"]
        task_ids = [row[1] for row in results if row[0] in {"task", "preparation_task"}]
        if event_ids:
            event_placeholders = ",".join("?" for _ in event_ids)
            await db.execute(
                f"DELETE FROM calendar_event_documents WHERE family_id = ? "
                f"AND event_id IN ({event_placeholders})",
                (family_id, *event_ids),
            )
            await db.execute(
                f"DELETE FROM calendar_event_exceptions WHERE family_id = ? "
                f"AND (series_id IN ({event_placeholders}) "
                f"OR replacement_event_id IN ({event_placeholders}))",
                (family_id, *event_ids, *event_ids),
            )
            await db.execute(
                f"DELETE FROM calendar_events WHERE family_id = ? AND id IN ({event_placeholders})",
                (family_id, *event_ids),
            )
        if task_ids:
            task_placeholders = ",".join("?" for _ in task_ids)
            await db.execute(
                f"DELETE FROM task_assignments WHERE family_id = ? "
                f"AND task_id IN ({task_placeholders})",
                (family_id, *task_ids),
            )
            await db.execute(
                f"DELETE FROM tasks WHERE family_id = ? AND id IN ({task_placeholders})",
                (family_id, *task_ids),
            )
        for table_name, record_ids in (
            ("calendar_events", event_ids),
            ("tasks", task_ids),
            ("family_commitments", private_ids),
        ):
            if record_ids:
                record_placeholders = ",".join("?" for _ in record_ids)
                await db.execute(
                    f"DELETE FROM record_history WHERE family_id = ? AND table_name = ? "
                    f"AND record_id IN ({record_placeholders})",
                    (family_id, table_name, *record_ids),
                )
        for table in ("family_commitment_results", "family_commitment_sources"):
            await db.execute(
                f"DELETE FROM {table} WHERE family_id = ? AND commitment_id IN ({placeholders})",
                (family_id, *private_ids),
            )
        await db.execute(
            f"DELETE FROM family_commitments WHERE family_id = ? AND id IN ({placeholders})",
            (family_id, *private_ids),
        )

    shared_rows = await (
        await db.execute(
            "SELECT id, plan_json, title, summary, owner_user_id, created_by, updated_by "
            "FROM family_commitments WHERE family_id = ? AND visibility = 'family' "
            "AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchall()
    now = datetime.now(timezone.utc).isoformat()
    for row in shared_rows:
        try:
            plan = json.loads(row[1])
        except (TypeError, json.JSONDecodeError):
            plan = {}
        scrubbed_plan = _scrub_commitment_plan_identity(
            plan,
            user_id=user_id,
            user_email=user_email,
            user_name=user_name,
        )
        title = row[2]
        if isinstance(title, str):
            title = _scrub_identity_text(
                title,
                user_id=user_id,
                user_email=user_email,
                user_name=user_name,
            )
        summary = row[3]
        if isinstance(summary, str):
            summary = _scrub_identity_text(
                summary,
                user_id=user_id,
                user_email=user_email,
                user_name=user_name,
            )
        await db.execute(
            """UPDATE family_commitments
               SET owner_user_id = CASE WHEN owner_user_id = ? THEN ? ELSE owner_user_id END,
                   plan_json = ?, title = ?, summary = ?, dedupe_key = CASE WHEN created_by = ?
                       THEN NULL ELSE dedupe_key END,
                   updated_by = CASE WHEN updated_by = ? THEN NULL ELSE updated_by END,
                   revision = revision + 1, updated_at = ?
               WHERE id = ? AND family_id = ?""",
            (
                user_id,
                replacement_user_id,
                json.dumps(scrubbed_plan, ensure_ascii=False, separators=(",", ":")),
                title,
                summary,
                user_id,
                user_id,
                now,
                row[0],
                family_id,
            ),
        )
    source_rows = await (
        await db.execute(
            "SELECT id, label, provider_reference, source_url "
            "FROM family_commitment_sources WHERE family_id = ? AND deleted_at IS NULL",
            (family_id,),
        )
    ).fetchall()
    for source in source_rows:
        label = source[1]
        provider_reference = source[2]
        source_url = source[3]
        for field_name, value in (
            ("label", label),
            ("provider_reference", provider_reference),
        ):
            if isinstance(value, str):
                cleaned = _scrub_identity_text(
                    value,
                    user_id=user_id,
                    user_email=user_email,
                    user_name=user_name,
                )
                if field_name == "label":
                    label = cleaned
                else:
                    provider_reference = cleaned
        if isinstance(source_url, str) and _contains_identity(
            source_url,
            user_id=user_id,
            user_email=user_email,
            user_name=user_name,
        ):
            source_url = None
        await db.execute(
            "UPDATE family_commitment_sources SET label = ?, provider_reference = ?, "
            "source_url = ?, updated_at = ? WHERE id = ? AND family_id = ?",
            (label, provider_reference, source_url, now, source[0], family_id),
        )


async def _scrub_shared_user(
    db,
    *,
    user_id: str,
    user_name: str,
    user_email: str,
    family_id: str,
) -> tuple[str, ...]:
    """Remove a departing adult's identity while preserving anonymous family records."""
    finance_storage_keys = await _delete_private_finance(
        db,
        user_id=user_id,
        family_id=family_id,
    )
    await _transfer_linked_household_nutrition(
        db,
        departing_user_id=user_id,
        family_id=family_id,
    )
    await _remove_private_and_transfer_shared_commitments(
        db,
        user_id=user_id,
        user_email=user_email,
        user_name=user_name,
        family_id=family_id,
    )
    # A household forwarding enrollment is member-bound by mailbox address,
    # not by created_by. Disable and scrub it before the user row disappears so
    # forwarding cannot remain live and household health cannot reveal it.
    await db.execute(
        """
        UPDATE finance_email_enrollments
        SET status = 'DISABLED',
            expected_forwarder_address = 'demo-person-5@example.invalid',
            transport_marker = 'Deleted family member',
            last_authentication_json = NULL,
            deleted_at = COALESCE(deleted_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE family_id = ? AND LOWER(expected_forwarder_address) = LOWER(?)
        """,
        (family_id, user_email),
    )
    # Retain genuinely shared purchase history, but remove the departed adult's
    # mailbox from email/evidence metadata (including reviewed raw evidence).
    await db.execute(
        """
        UPDATE finance_email_messages
        SET visible_sender = CASE WHEN LOWER(visible_sender) = LOWER(?)
                                  THEN 'Deleted family member'
                                  ELSE REPLACE(visible_sender, ?, 'Deleted family member') END,
            internet_message_id = CASE WHEN internet_message_id IS NULL THEN NULL
                                  ELSE REPLACE(internet_message_id, ?, '') END,
            subject = REPLACE(subject, ?, 'Deleted family member')
        WHERE family_id = ? AND (
            LOWER(visible_sender) = LOWER(?) OR internet_message_id LIKE ? OR subject LIKE ?
        )
        """,
        (
            user_email,
            user_email,
            user_email,
            user_email,
            family_id,
            user_email,
            f"%{user_email}%",
            f"%{user_email}%",
        ),
    )
    # SQLite REPLACE is case-sensitive. Provider metadata can preserve display
    # casing, so make a bounded second pass over the fixed metadata columns.
    email_pattern = re.compile(re.escape(user_email), re.IGNORECASE)
    for table, replacements in (
        (
            "finance_email_messages",
            {
                "visible_sender": "Deleted family member",
                "internet_message_id": "",
                "subject": "Deleted family member",
            },
        ),
        (
            "finance_purchase_sources",
            {
                "visible_sender": "Deleted family member",
                "internet_message_id": "",
                "email_subject": "Deleted family member",
                "raw_payload_json": "Deleted family member",
                "authentication_json": "",
            },
        ),
    ):
        fields = tuple(replacements)
        rows = await (
            await db.execute(
                f"SELECT id, {', '.join(fields)} FROM {table} WHERE family_id = ?",
                (family_id,),
            )
        ).fetchall()
        for row in rows:
            changed: dict[str, str] = {}
            for index, field in enumerate(fields, start=1):
                value = row[index]
                if isinstance(value, str) and email_pattern.search(value):
                    changed[field] = email_pattern.sub(replacements[field], value)
            if changed:
                await db.execute(
                    f"UPDATE {table} SET "
                    + ", ".join(f"{field} = ?" for field in changed)
                    + " WHERE id = ? AND family_id = ?",
                    (*changed.values(), row[0], family_id),
                )
    await db.execute(
        """
        UPDATE finance_purchase_sources
        SET visible_sender = CASE WHEN LOWER(COALESCE(visible_sender, '')) = LOWER(?)
                                  THEN NULL
                                  ELSE REPLACE(visible_sender, ?, 'Deleted family member') END,
            internet_message_id = CASE WHEN internet_message_id IS NULL THEN NULL
                                  ELSE REPLACE(internet_message_id, ?, '') END,
            email_subject = CASE WHEN email_subject IS NULL THEN NULL
                            ELSE REPLACE(email_subject, ?, 'Deleted family member') END,
            raw_payload_json = REPLACE(raw_payload_json, ?, 'Deleted family member'),
            authentication_json = CASE WHEN authentication_json IS NULL THEN NULL
                                  ELSE REPLACE(authentication_json, ?, '') END
        WHERE family_id = ? AND (
            LOWER(COALESCE(visible_sender, '')) = LOWER(?)
            OR internet_message_id LIKE ? OR email_subject LIKE ?
            OR raw_payload_json LIKE ? OR authentication_json LIKE ?
        )
        """,
        (
            user_email,
            user_email,
            user_email,
            user_email,
            user_email,
            user_email,
            family_id,
            user_email,
            f"%{user_email}%",
            f"%{user_email}%",
            f"%{user_email}%",
            f"%{user_email}%",
        ),
    )
    # Remove private and person-scoped rows rather than leaving dangling identifiers.
    for table in USER_PRIVATE_TABLES:
        await db.execute(f"DELETE FROM {table} WHERE user_id = ?", (user_id,))
    await db.execute(
        "DELETE FROM family_settings WHERE family_id = ? AND setting_key IN (?, ?)",
        (
            family_id,
            f"usage_history:{user_id}",
            f"onboarding:{user_id}",
        ),
    )
    for table in ("cycle_period_starts", "cycle_settings"):
        await db.execute(
            f"DELETE FROM {table} WHERE family_id = ? AND owner_user_id = ?",
            (family_id, user_id),
        )
    for table in HEALTH_OWNER_PRIVATE_TABLES:
        await db.execute(
            f"DELETE FROM {table} WHERE family_id = ? AND owner_user_id = ?",
            (family_id, user_id),
        )
    await db.execute(
        "DELETE FROM document_people "
        "WHERE family_id = ? AND person_type = 'user' AND person_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "DELETE FROM task_assignments "
        "WHERE family_id = ? AND assignee_type = 'user' AND assignee_id = ?",
        (family_id, user_id),
    )
    for table in ("routine_items", "term_dates", "routine_term_overrides", "holiday_dates"):
        await db.execute(
            f"DELETE FROM {table} WHERE family_id = ? AND person_id = ?",
            (family_id, user_id),
        )

    # Remove direct assignment/completion references from records the family retains.
    for table in (
        "present_ideas",
        "calendar_events",
        "calendar_sources",
        "tasks",
        "event_prep_templates",
        "capture_suggestions",
    ):
        await db.execute(
            f"UPDATE {table} SET assigned_to = NULL WHERE family_id = ? AND assigned_to = ?",
            (family_id, user_id),
        )
    await db.execute(
        "UPDATE present_ideas SET owner_id = NULL WHERE family_id = ? AND owner_id = ?",
        (family_id, user_id),
    )
    await db.execute(
        "UPDATE task_assignments SET completed_by = NULL WHERE family_id = ? AND completed_by = ?",
        (family_id, user_id),
    )
    await db.execute(
        "UPDATE medicine_doses SET given_by = 'Deleted family member' "
        "WHERE family_id = ? AND given_by IN (?, ?)",
        (family_id, user_id, user_name),
    )

    # Calendar events can contain several participant and affected-adult IDs.
    for field in ("family_member_ids", "affected_member_ids"):
        cursor = await db.execute(
            f"SELECT id, {field} FROM calendar_events WHERE family_id = ? AND {field} IS NOT NULL",
            (family_id,),
        )
        for event_id, raw_members in await cursor.fetchall():
            try:
                member_ids = json.loads(raw_members)
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(member_ids, list) or user_id not in member_ids:
                continue
            remaining = [member_id for member_id in member_ids if member_id != user_id]
            await db.execute(
                f"UPDATE calendar_events SET {field} = ? WHERE id = ? AND family_id = ?",
                (json.dumps(remaining) if remaining else None, event_id, family_id),
            )

    # Remove provider receipts and pending assistant payloads tied to the account.
    await db.execute(
        "DELETE FROM inbound_email_messages "
        "WHERE family_id = ? AND (created_by = ? OR LOWER(from_address) = LOWER(?))",
        (family_id, user_id, user_email),
    )
    await db.execute(
        "DELETE FROM assistant_actions WHERE family_id = ? AND (created_by = ? OR payload LIKE ?)",
        (family_id, user_id, f"%{user_id}%"),
    )
    await db.execute(
        "UPDATE documents SET notes = REPLACE(notes, ?, 'Deleted family member') "
        "WHERE family_id = ? AND notes IS NOT NULL",
        (user_email, family_id),
    )
    await db.execute(
        "DELETE FROM sync_queue WHERE family_id = ? AND (record_id = ? OR payload LIKE ?)",
        (family_id, user_id, f"%{user_id}%"),
    )

    # Strip authorship and install-scoped client IDs from every retained family table.
    for table in FAMILY_PURGE_TABLES:
        columns = {
            row[1] for row in await (await db.execute(f"PRAGMA table_info({table})")).fetchall()
        }
        if "created_by" in columns:
            assignments = "created_by = NULL"
            if "client_id" in columns:
                assignments += ", client_id = NULL"
            await db.execute(
                f"UPDATE {table} SET {assignments} WHERE family_id = ? AND created_by = ?",
                (family_id, user_id),
            )
    await db.execute(
        "UPDATE users SET created_by = NULL WHERE family_id = ? AND created_by = ?",
        (family_id, user_id),
    )

    # Change history can contain snapshots of account IDs or email addresses.
    await db.execute(
        "DELETE FROM record_history WHERE family_id = ? AND "
        "(changed_by = ? OR previous_values LIKE ? OR previous_values LIKE ?)",
        (family_id, user_id, f"%{user_id}%", f"%{user_email}%"),
    )
    await db.execute(
        "UPDATE record_history SET changed_by = NULL WHERE changed_by = ?",
        (user_id,),
    )
    await db.execute(
        "DELETE FROM security_rate_limit_events WHERE rate_key LIKE ?",
        (f"%{user_id}%",),
    )
    return finance_storage_keys


async def delete_account_data(db, *, user_id: str, family_id: str | None) -> AccountDeletionResult:
    """Delete the account transactionally; shared data survives while another adult remains."""
    await db.execute("BEGIN IMMEDIATE")
    try:
        if not family_id:
            await db.execute("DELETE FROM refresh_tokens WHERE user_id = ?", (user_id,))
            await db.execute(
                "DELETE FROM record_history WHERE table_name = 'users' AND record_id = ?",
                (user_id,),
            )
            await db.execute("DELETE FROM users WHERE id = ?", (user_id,))
            await db.commit()
            return AccountDeletionResult(final_family=False)

        cursor = await db.execute(
            "SELECT COUNT(*) FROM users WHERE family_id = ? AND id != ? AND deleted_at IS NULL",
            (family_id, user_id),
        )
        final_family = (await cursor.fetchone())[0] == 0

        if not final_family:
            cursor = await db.execute(
                "SELECT name, email FROM users WHERE id = ? AND family_id = ?",
                (user_id, family_id),
            )
            account = await cursor.fetchone()
            if not account:
                raise RuntimeError("Account no longer exists")
            fitness_storage_keys = await _fitness_storage_keys(
                db,
                family_id,
                owner_user_id=user_id,
            )
            fitness_deletion_queue = await _queue_fitness_file_deletions(
                db,
                family_id=family_id,
                owner_user_id=user_id,
                storage_keys=fitness_storage_keys,
            )
            await db.execute("DELETE FROM refresh_tokens WHERE user_id = ?", (user_id,))
            storage_keys = await _scrub_shared_user(
                db,
                user_id=user_id,
                user_name=account[0],
                user_email=account[1],
                family_id=family_id,
            )
            await db.execute(
                "DELETE FROM record_history WHERE table_name = 'users' AND record_id = ?",
                (user_id,),
            )
            await db.execute("DELETE FROM users WHERE id = ?", (user_id,))
            await db.commit()
            return AccountDeletionResult(
                final_family=False,
                storage_keys=storage_keys,
                fitness_storage_keys=fitness_storage_keys,
                fitness_deletion_queue=fitness_deletion_queue,
            )

        storage_keys = await _storage_keys(db, family_id)
        fitness_storage_keys = await _fitness_storage_keys(db, family_id)
        fitness_deletion_queue = await _queue_fitness_file_deletions(
            db,
            family_id=family_id,
            owner_user_id=user_id,
            storage_keys=fitness_storage_keys,
        )
        cursor = await db.execute("SELECT id FROM users WHERE family_id = ?", (family_id,))
        family_user_ids = [row[0] for row in await cursor.fetchall()]
        if family_user_ids:
            placeholders = ",".join("?" for _ in family_user_ids)
            await db.execute(
                f"DELETE FROM refresh_tokens WHERE user_id IN ({placeholders})",
                family_user_ids,
            )
        if family_user_ids:
            placeholders = ",".join("?" for _ in family_user_ids)
            await db.execute(
                f"""
                DELETE FROM record_history
                WHERE family_id = ?
                   OR (
                        family_id IS NULL
                        AND (
                            CASE WHEN json_valid(previous_values)
                                 THEN json_extract(previous_values, '$.family_id') END = ?
                            OR (
                                CASE WHEN json_valid(previous_values)
                                     THEN json_extract(previous_values, '$.family_id') END IS NULL
                                AND changed_by IN ({placeholders})
                            )
                        )
                   )
                """,
                (family_id, family_id, *family_user_ids),
            )
            await db.execute(
                f"UPDATE record_history SET changed_by = NULL WHERE changed_by IN ({placeholders})",
                family_user_ids,
            )
        else:
            await db.execute("DELETE FROM record_history WHERE family_id = ?", (family_id,))
        for table in FAMILY_PURGE_TABLES:
            await db.execute(f"DELETE FROM {table} WHERE family_id = ?", (family_id,))
        await db.execute(
            "DELETE FROM security_rate_limit_events WHERE rate_key LIKE ?",
            (f"%{family_id}%",),
        )
        await db.execute("DELETE FROM users WHERE family_id = ?", (family_id,))
        await db.execute("DELETE FROM families WHERE id = ?", (family_id,))
        await db.commit()
        return AccountDeletionResult(
            final_family=True,
            storage_keys=storage_keys,
            fitness_storage_keys=fitness_storage_keys,
            fitness_deletion_queue=fitness_deletion_queue,
        )
    except BaseException:
        if db.in_transaction:
            await db.rollback()
        raise
