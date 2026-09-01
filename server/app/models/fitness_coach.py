"""Strict contracts for explicit, reviewable Fitness coaching."""

from datetime import date, datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictBool, model_validator

from app.models.fitness import (
    MealTemplatePayload,
    NutritionTargetPayload,
    PlannedSetPayload,
    RunWorkoutCuePayload,
    RunWorkoutStepPayload,
)


CoachIntent = Literal[
    "discussion",
    "morning",
    "post_workout",
    "evening",
    "weekly",
    "run_plan",
    "strength_plan",
]
CoachProposalKind = Literal[
    "run_workout",
    "strength_workout",
    "training_week",
    "nutrition_change",
    "goal_adjustment",
    "calendar_change",
    "family_calendar_event",
    "planned_meal_log",
    "shopping_list",
    "family_task",
    "fitness_reminder",
    "chart",
]
CoachFeedback = Literal[
    "accepted",
    "rejected",
    "tried_worked",
    "tried_too_hard",
    "tried_too_hungry",
    "unavailable",
    "disliked",
    "analysis_inaccurate",
    "other",
]


def _require_aware(value: datetime, field_name: str) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{field_name} must include a timezone")


class CoachModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)


class CoachHistoryTurn(CoachModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=2_000)


class CoachMessageRequest(CoachModel):
    message: str = Field(min_length=1, max_length=2_000)
    intent: CoachIntent = "discussion"
    conversation_id: UUID | None = None
    ephemeral: bool = False
    history: list[CoachHistoryTurn] = Field(default_factory=list, max_length=8)
    timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    client_now: str | None = Field(default=None, max_length=100)
    context_ids: list[str] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def unique_context_ids(self):
        if self.ephemeral and self.conversation_id is not None:
            raise ValueError("ephemeral requests cannot resume a stored conversation")
        if self.ephemeral and self.intent != "discussion":
            raise ValueError("ephemeral requests support discussion only")
        if len(set(self.context_ids)) != len(self.context_ids):
            raise ValueError("context_ids must be unique")
        if any(not value or len(value) > 100 for value in self.context_ids):
            raise ValueError("context_ids contain an invalid identifier")
        return self


class CoachEvidence(CoachModel):
    id: str = Field(min_length=1, max_length=120)
    kind: str = Field(min_length=1, max_length=80)
    label: str = Field(min_length=1, max_length=160)
    summary: str = Field(min_length=1, max_length=1_000)
    period: dict[str, str] | None = None
    sample_size: int | None = Field(default=None, ge=0)
    completeness: float | None = Field(default=None, ge=0, le=1)
    source_ids: list[str] = Field(default_factory=list, max_length=50)


class CoachValidationIssue(CoachModel):
    code: str | None = Field(default=None, max_length=80)
    path: str | None = Field(default=None, max_length=240)
    message: str = Field(min_length=1, max_length=500)


class CoachWarning(CoachModel):
    code: str | None = Field(default=None, max_length=80)
    message: str = Field(min_length=1, max_length=500)


class CoachProposalValidation(CoachModel):
    valid: bool
    issues: list[CoachValidationIssue] = Field(default_factory=list, max_length=50)


class CoachProposalPreview(CoachModel):
    change: list[str] = Field(min_length=1, max_length=40)
    visibility: Literal["Private to you", "Visible to your family"]


class CoachProposal(CoachModel):
    id: UUID
    kind: CoachProposalKind
    payload: dict[str, Any]
    preview: CoachProposalPreview | None = None
    validation: CoachProposalValidation
    warnings: list[CoachWarning | str] = Field(default_factory=list, max_length=20)
    confirmable: bool
    review_only_reason: str | None = Field(default=None, max_length=500)
    expires_at: datetime


class CoachRecommendation(CoachModel):
    id: str
    revision: int
    created_at: str
    updated_at: str
    recommendation_type: str
    recommendation_text: str
    evidence: list[CoachEvidence] = Field(default_factory=list)
    finding_references: list[str] = Field(default_factory=list)
    expected_effect: str | dict[str, Any] | None = None
    status: str
    user_feedback: CoachFeedback | None = None
    followed_state: str | None = None
    outcome_review: str | None = None
    model_provider: str | None = None
    model_id: str | None = None


class CoachMemoryCandidate(CoachModel):
    content: str = Field(min_length=1, max_length=1_000)
    category: str | None = Field(default=None, min_length=1, max_length=80)


class CoachMessageResponse(CoachModel):
    status: Literal["complete", "unavailable"]
    answer: str = Field(max_length=10_000)
    conversation_id: str | None = None
    memory_candidates: list[CoachMemoryCandidate] = Field(default_factory=list, max_length=3)
    evidence: list[CoachEvidence] = Field(default_factory=list, max_length=20)
    recommendation: CoachRecommendation | None = None
    proposal: CoachProposal | None = None


class CoachMemorySettingUpdate(CoachModel):
    enabled: bool


class CoachMemorySettingResponse(CoachModel):
    enabled: bool
    enabled_at: str | None = None


class CoachContextPreferencesUpdate(CoachModel):
    family_calendar: StrictBool | None = None
    household_meals: StrictBool | None = None
    weather: StrictBool | None = None

    @model_validator(mode="after")
    def includes_a_change(self):
        if not self.model_fields_set or all(
            getattr(self, field) is None for field in self.model_fields_set
        ):
            raise ValueError("At least one context preference is required")
        return self


class CoachContextPreferencesResponse(CoachModel):
    family_calendar: bool = False
    household_meals: bool = False
    weather: bool = False


class CoachConversationCreate(CoachModel):
    id: UUID | None = None
    title: str | None = Field(default=None, min_length=1, max_length=160)


class CoachConversationResponse(CoachModel):
    id: str
    title: str
    last_message_at: str | None = None
    revision: int
    created_at: str
    updated_at: str


class CoachStoredMessage(CoachModel):
    id: str
    conversation_id: str
    sequence: int
    role: Literal["user", "assistant"]
    content: str
    intent: CoachIntent | None = None
    created_at: str


class CoachConversationDetail(CoachConversationResponse):
    messages: list[CoachStoredMessage] = Field(default_factory=list, max_length=200)


class CoachMemoryCreate(CoachModel):
    id: UUID | None = None
    content: str = Field(min_length=1, max_length=1_000)
    category: str | None = Field(default=None, min_length=1, max_length=80)


class CoachMemoryPatch(CoachModel):
    content: str | None = Field(default=None, min_length=1, max_length=1_000)
    category: str | None = Field(default=None, min_length=1, max_length=80)

    @model_validator(mode="after")
    def has_change(self):
        if not self.model_fields_set:
            raise ValueError("A memory edit requires at least one field")
        return self


class CoachMemoryResponse(CoachModel):
    id: str
    content: str
    category: str | None = None
    confirmed_at: str
    revision: int
    created_at: str
    updated_at: str


class CoachMemoryClearResponse(CoachModel):
    conversations: int
    messages: int
    memories: int


class CoachProposalDestination(CoachModel):
    kind: Literal[
        "planned_session",
        "nutrition_target",
        "meal_template",
        "goal",
        "analysis_chart",
        "calendar_event",
        "food_log",
        "shopping",
        "task",
        "fitness_reminder",
    ]
    target: str = Field(min_length=1, max_length=500)
    label: str = Field(min_length=1, max_length=200)


class CoachProposalDecision(CoachModel):
    status: Literal["confirmed", "declined", "expired", "invalid"]
    message: str
    result_ids: list[str] | None = None
    next_destinations: list[CoachProposalDestination] = Field(default_factory=list, max_length=20)


class CoachProposalUndoDecision(CoachModel):
    status: Literal["undone", "already_undone", "conflict", "invalid"]
    message: str
    affected_ids: list[str] = Field(default_factory=list, max_length=100)


class CoachRecommendationFeedback(CoachModel):
    feedback: CoachFeedback
    followed_state: str | None = Field(default=None, max_length=80)
    outcome_review: str | None = Field(default=None, max_length=2_000)


class CoachRunWorkoutPayload(CoachModel):
    title: str = Field(min_length=1, max_length=200)
    purpose: str = Field(min_length=1, max_length=1_000)
    scheduled_start_utc: datetime | None = None
    scheduled_date: date | None = None
    local_timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    estimated_duration_s: int | None = Field(default=None, ge=0, le=86_400)
    estimated_distance_m: float | None = Field(default=None, ge=0, le=200_000)
    expected_difficulty: str | None = Field(default=None, max_length=160)
    route_assumption: str | None = Field(default=None, max_length=500)
    terrain_assumption: str | None = Field(default=None, max_length=500)
    goal_reason: str | None = Field(default=None, max_length=1_000)
    goal_ids: list[UUID] = Field(default_factory=list, max_length=20)
    intended_gear_ids: list[UUID] = Field(default_factory=list, max_length=20)
    steps: list[RunWorkoutStepPayload] = Field(min_length=1, max_length=200)
    cues: list[RunWorkoutCuePayload] = Field(default_factory=list, max_length=200)
    garmin_limitations: list[str] = Field(default_factory=list, max_length=20)

    @model_validator(mode="after")
    def complete_plan(self):
        if self.scheduled_start_utc is None and self.scheduled_date is None:
            raise ValueError("A run proposal needs a scheduled date or start time")
        if self.estimated_duration_s is None and self.estimated_distance_m is None:
            raise ValueError("A run proposal needs an estimated duration or distance")
        if len(set(self.goal_ids)) != len(self.goal_ids):
            raise ValueError("A run proposal cannot repeat a goal")
        if len(set(self.intended_gear_ids)) != len(self.intended_gear_ids):
            raise ValueError("A run proposal cannot repeat intended gear")
        return self


class CoachStrengthExercise(CoachModel):
    exercise_id: UUID
    exercise_name: str = Field(min_length=1, max_length=200)
    exercise_setup_id: UUID
    setup_name: str = Field(min_length=1, max_length=200)
    sequence: int = Field(ge=0, le=99)
    superset_group_key: str | None = Field(default=None, max_length=80)
    substitution_exercise_ids: list[UUID] = Field(default_factory=list, max_length=20)
    notes: str | None = Field(default=None, max_length=1_000)
    sets: list[PlannedSetPayload] = Field(min_length=1, max_length=30)

    @model_validator(mode="after")
    def valid_ranges(self):
        for index, planned_set in enumerate(self.sets):
            for low_key, high_key in (
                ("reps_min", "reps_max"),
                ("load_min", "load_max"),
                ("rpe_min", "rpe_max"),
                ("rir_min", "rir_max"),
            ):
                low = getattr(planned_set, low_key)
                high = getattr(planned_set, high_key)
                if low is not None and high is not None and low > high:
                    raise ValueError(f"sets.{index}.{low_key} cannot exceed {high_key}")
        return self


class CoachStrengthWorkoutPayload(CoachModel):
    title: str = Field(min_length=1, max_length=200)
    purpose: str = Field(min_length=1, max_length=1_000)
    scheduled_start_utc: datetime | None = None
    scheduled_date: date | None = None
    local_timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    estimated_duration_s: int = Field(ge=300, le=21_600)
    location: str | None = Field(default=None, max_length=200)
    goal_reason: str | None = Field(default=None, max_length=1_000)
    goal_ids: list[UUID] = Field(default_factory=list, max_length=20)
    exercises: list[CoachStrengthExercise] = Field(min_length=1, max_length=24)

    @model_validator(mode="after")
    def complete_plan(self):
        if self.scheduled_start_utc is None and self.scheduled_date is None:
            raise ValueError("A strength proposal needs a scheduled date or start time")
        exercise_ids = [item.exercise_id for item in self.exercises]
        sequences = [item.sequence for item in self.exercises]
        if len(set(exercise_ids)) != len(exercise_ids):
            raise ValueError("A strength proposal cannot repeat an exercise")
        if len(set(sequences)) != len(sequences):
            raise ValueError("Strength exercise sequence values must be unique")
        if len(set(self.goal_ids)) != len(self.goal_ids):
            raise ValueError("A strength proposal cannot repeat a goal")
        return self


class CoachTrainingWeekSession(CoachModel):
    title: str = Field(min_length=1, max_length=200)
    sport_key: Literal["running", "strength"]
    scheduled_date: date
    expected_duration_s: int | None = Field(default=None, ge=0, le=86_400)
    expected_distance_m: float | None = Field(default=None, ge=0, le=200_000)
    purpose: str | None = Field(default=None, max_length=1_000)
    expected_difficulty: str | None = Field(default=None, max_length=160)
    route_assumption: str | None = Field(default=None, max_length=500)
    terrain_assumption: str | None = Field(default=None, max_length=500)
    goal_reason: str | None = Field(default=None, max_length=1_000)
    goal_ids: list[UUID] = Field(default_factory=list, max_length=20)
    intended_gear_ids: list[UUID] = Field(default_factory=list, max_length=20)
    steps: list[RunWorkoutStepPayload] = Field(default_factory=list, max_length=200)
    cues: list[RunWorkoutCuePayload] = Field(default_factory=list, max_length=200)
    garmin_limitations: list[str] = Field(default_factory=list, max_length=20)
    location: str | None = Field(default=None, max_length=200)
    exercises: list[CoachStrengthExercise] = Field(default_factory=list, max_length=24)

    @model_validator(mode="after")
    def executable_definition(self):
        if len(set(self.goal_ids)) != len(self.goal_ids):
            raise ValueError("A week session cannot repeat a goal")
        if len(set(self.intended_gear_ids)) != len(self.intended_gear_ids):
            raise ValueError("A week session cannot repeat intended gear")
        if self.sport_key == "running":
            if not self.steps:
                raise ValueError("A running week session requires executable steps")
            if self.expected_duration_s is None and self.expected_distance_m is None:
                raise ValueError("A running week session needs duration or distance")
            if self.exercises:
                raise ValueError("A running week session cannot contain strength exercises")
        else:
            if not self.exercises:
                raise ValueError("A strength week session requires executable exercises")
            if self.expected_duration_s is None or self.expected_duration_s < 300:
                raise ValueError("A strength week session needs at least five minutes")
            if self.steps or self.cues:
                raise ValueError("A strength week session cannot contain run steps or cues")
            if self.intended_gear_ids:
                raise ValueError("A strength week session cannot contain run gear")
        return self


class CoachTrainingWeekPayload(CoachModel):
    name: str = Field(min_length=1, max_length=200)
    purpose: str = Field(min_length=1, max_length=1_000)
    starts_on: date
    local_timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    sessions: list[CoachTrainingWeekSession] = Field(min_length=1, max_length=14)

    @model_validator(mode="after")
    def sessions_within_week(self):
        week_end = self.starts_on.toordinal() + 6
        if any(
            not self.starts_on.toordinal() <= item.scheduled_date.toordinal() <= week_end
            for item in self.sessions
        ):
            raise ValueError("Training-week sessions must fall within its seven-day window")
        return self


class CoachNutritionChangePayload(CoachModel):
    action_type: Literal["review_only", "nutrition_target", "meal_template"] = "review_only"
    food_or_meal: str = Field(min_length=1, max_length=300)
    observation_period: str = Field(min_length=1, max_length=200)
    proposed_change: str = Field(min_length=1, max_length=1_000)
    expected_effect: str = Field(min_length=1, max_length=1_000)
    uncertainty: str | None = Field(default=None, max_length=1_000)
    nutrition_target: NutritionTargetPayload | None = None
    meal_template: MealTemplatePayload | None = None

    @model_validator(mode="after")
    def valid_action(self):
        if self.action_type == "review_only":
            if self.nutrition_target is not None or self.meal_template is not None:
                raise ValueError("Review-only nutrition drafts cannot contain an action")
        elif self.action_type == "nutrition_target":
            if self.nutrition_target is None or self.meal_template is not None:
                raise ValueError("A nutrition-target action requires only nutrition_target")
        elif self.meal_template is None or self.nutrition_target is not None:
            raise ValueError("A meal-template action requires only meal_template")
        return self


class CoachGoalAdjustmentPayload(CoachModel):
    action_type: Literal["review_only", "adjust_target"] = "review_only"
    goal_id: UUID
    goal_name: str = Field(min_length=1, max_length=200)
    current_target: str | None = Field(default=None, min_length=1, max_length=200)
    proposed_target: str | None = Field(default=None, min_length=1, max_length=200)
    current_target_value: float | None = None
    proposed_target_value: float | None = None
    current_target_date: date | None = None
    proposed_target_date: date | None = None
    unit_key: str | None = Field(default=None, max_length=40)
    reason: str = Field(min_length=1, max_length=1_000)

    @model_validator(mode="after")
    def valid_action(self):
        if self.action_type == "review_only":
            if not self.current_target or not self.proposed_target:
                raise ValueError(
                    "A review-only goal draft needs current_target and proposed_target"
                )
            return self
        if self.proposed_target_value is None and self.proposed_target_date is None:
            raise ValueError("A typed goal adjustment needs a new value or target date")
        if (
            self.proposed_target_value == self.current_target_value
            and self.proposed_target_date == self.current_target_date
        ):
            raise ValueError("A goal adjustment must change the accepted target")
        return self


class CoachCalendarChangePayload(CoachModel):
    planned_session_id: UUID
    title: str = Field(min_length=1, max_length=200)
    current_start_utc: datetime | None = None
    current_scheduled_date: date | None = None
    current_window_start_utc: datetime | None = None
    current_window_end_utc: datetime | None = None
    proposed_start_utc: datetime
    reason: str = Field(min_length=1, max_length=1_000)


class CoachFamilyCalendarEventPayload(CoachModel):
    title: str = Field(min_length=1, max_length=300)
    start_time: datetime
    end_time: datetime | None = None
    all_day: bool = False
    location: str | None = Field(default=None, max_length=500)
    planned_session_id: UUID | None = None
    family_visible: StrictBool = True

    @model_validator(mode="after")
    def valid_times(self):
        if self.family_visible is not True:
            raise ValueError("Calendar logistics must be visibly marked as family-visible")
        _require_aware(self.start_time, "start_time")
        if self.end_time is not None:
            _require_aware(self.end_time, "end_time")
        if self.end_time is not None and self.end_time <= self.start_time:
            raise ValueError("Calendar end time must be after its start time")
        return self


class CoachPlannedMealLogPayload(CoachModel):
    meal_plan_id: UUID
    meal_name: str = Field(min_length=1, max_length=300)
    meal_date: date | None = None
    meal_type: Literal["breakfast", "lunch", "dinner"] | None = None
    link_id: UUID
    recipe_version_id: UUID
    portion: float = Field(gt=0, le=100_000)
    unit: Literal["serving", "g"]
    logged_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    notes: str | None = Field(default=None, max_length=4_000)
    private_to_you: StrictBool = True

    @model_validator(mode="after")
    def valid_visibility_and_time(self):
        if self.private_to_you is not True:
            raise ValueError("A planned meal diary entry must stay private to you")
        _require_aware(self.logged_at_utc, "logged_at_utc")
        return self


class CoachShoppingItem(CoachModel):
    name: str = Field(min_length=1, max_length=300)
    quantity: str | None = Field(default=None, max_length=100)
    category: str | None = Field(default=None, max_length=100)
    meal_plan_id: UUID | None = None


class CoachShoppingListPayload(CoachModel):
    items: list[CoachShoppingItem] = Field(min_length=1, max_length=30)
    family_visible: StrictBool = True

    @model_validator(mode="after")
    def valid_family_list(self):
        if self.family_visible is not True:
            raise ValueError("Shopping items must be visibly marked as family-visible")
        identities = [
            (item.name.casefold(), str(item.meal_plan_id) if item.meal_plan_id else None)
            for item in self.items
        ]
        if len(identities) != len(set(identities)):
            raise ValueError("A Shopping proposal cannot repeat the same item")
        return self


class CoachFamilyTaskPayload(CoachModel):
    title: str = Field(min_length=1, max_length=300)
    description: str | None = Field(default=None, max_length=10_000)
    assigned_to: str | None = Field(default=None, max_length=100)
    due_date: datetime | None = None
    priority: int = Field(default=2, ge=1, le=3)
    actionable_from: datetime | None = None
    family_visible: StrictBool = True

    @model_validator(mode="after")
    def valid_times(self):
        if self.family_visible is not True:
            raise ValueError("A family task must be visibly marked as family-visible")
        if self.due_date is not None:
            _require_aware(self.due_date, "due_date")
        if self.actionable_from is not None:
            _require_aware(self.actionable_from, "actionable_from")
        if (
            self.due_date is not None
            and self.actionable_from is not None
            and self.actionable_from > self.due_date
        ):
            raise ValueError("Task actionable time must not be after its due date")
        return self


class CoachFitnessReminderPayload(CoachModel):
    title: str = Field(min_length=1, max_length=300)
    remind_at_utc: datetime
    notes: str | None = Field(default=None, max_length=4_000)
    planned_session_id: UUID | None = None
    private_to_you: StrictBool = True

    @model_validator(mode="after")
    def valid_visibility_and_time(self):
        if self.private_to_you is not True:
            raise ValueError("A Fitness reminder must stay private to you")
        _require_aware(self.remind_at_utc, "remind_at_utc")
        return self


class CoachFitnessReminderResponse(CoachModel):
    id: UUID
    title: str
    remind_at_utc: datetime
    notes: str | None = None
    planned_session_id: UUID | None = None
    status: Literal["active", "completed"]


class CoachChartPayload(CoachModel):
    name: str = Field(min_length=1, max_length=160)
    measure_key: str = Field(min_length=1, max_length=120)
    dimension_key: str = Field(min_length=1, max_length=120)
    chart_type_key: Literal[
        "line",
        "rolling_average",
        "bar",
        "stacked_bar",
        "scatter",
        "histogram",
        "calendar_heatmap",
        "range_band",
        "table",
    ]
    filter_keys: list[str] = Field(default_factory=list, max_length=4)
    comparison_key: str | None = Field(default=None, max_length=100)
    date_window_days: int = Field(ge=1, le=366)


PROPOSAL_PAYLOAD_MODELS = {
    "run_workout": CoachRunWorkoutPayload,
    "strength_workout": CoachStrengthWorkoutPayload,
    "training_week": CoachTrainingWeekPayload,
    "nutrition_change": CoachNutritionChangePayload,
    "goal_adjustment": CoachGoalAdjustmentPayload,
    "calendar_change": CoachCalendarChangePayload,
    "family_calendar_event": CoachFamilyCalendarEventPayload,
    "planned_meal_log": CoachPlannedMealLogPayload,
    "shopping_list": CoachShoppingListPayload,
    "family_task": CoachFamilyTaskPayload,
    "fitness_reminder": CoachFitnessReminderPayload,
    "chart": CoachChartPayload,
}
