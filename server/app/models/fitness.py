"""Typed contracts for the private adult Fitness module."""

from datetime import date, datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, StrictBool, model_validator


class FitnessModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid", str_strip_whitespace=True, allow_inf_nan=False
    )


class ClientRecord(FitnessModel):
    id: UUID | None = None
    client_id: str | None = Field(default=None, max_length=100)
    client_timestamp: str | None = Field(default=None, max_length=100)


CoachPersonalityPreset = Literal[
    "scientific_hard_driving",
    "balanced_supportive",
    "calm_encouraging",
    "custom",
]
CoachChallengeBias = Literal["conservative", "balanced", "ambitious"]
CoachDetailLevel = Literal["brief", "standard", "detailed"]
ExerciseMeasurementMode = Literal[
    "reps_load",
    "reps_only",
    "duration",
    "duration_load",
    "distance",
    "distance_load",
    "calories_or_machine_metric",
    "custom",
]
ExerciseRepCountMode = Literal[
    "total", "per_side", "left_right_separate", "not_applicable"
]
ExerciseLoadEntryMode = Literal[
    "total_external",
    "per_hand",
    "per_side",
    "machine_stack",
    "machine_level",
    "added_bodyweight",
    "assistance",
    "bodyweight_only",
    "none",
]
ExerciseUnilateralMode = Literal[
    "bilateral",
    "unilateral_same_set",
    "unilateral_separate_sets",
    "alternating",
    "not_applicable",
]


class CoachPreferencesUpdate(FitnessModel):
    personality_preset: CoachPersonalityPreset
    directness: int = Field(ge=1, le=5)
    challenge_bias: CoachChallengeBias
    detail_level: CoachDetailLevel
    custom_instruction: str | None = Field(default=None, max_length=500)


class CalendarPreferencesResponse(FitnessModel):
    show_planned: bool = True
    show_completed: bool = False


class CalendarPreferencesUpdate(FitnessModel):
    show_planned: StrictBool | None = None
    show_completed: StrictBool | None = None

    @model_validator(mode="after")
    def includes_a_change(self):
        if self.show_planned is None and self.show_completed is None:
            raise ValueError("At least one calendar preference is required")
        return self


class NutritionSettingsUpdate(FitnessModel):
    nutrition_day_start_minutes: int = Field(ge=0, le=480)
    timezone: str = Field(default="Europe/London", min_length=1, max_length=100)
    heart_rate_zone_boundaries_bpm: list[int] | None = Field(
        default=None, min_length=4, max_length=4
    )
    coach_personality_preset: CoachPersonalityPreset | None = None
    coach_directness: int | None = Field(default=None, ge=1, le=5)
    coach_challenge_bias: CoachChallengeBias | None = None
    coach_detail_level: CoachDetailLevel | None = None
    coach_custom_instruction: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def valid_heart_rate_zones(self):
        boundaries = self.heart_rate_zone_boundaries_bpm
        if boundaries is not None:
            if any(value < 60 or value > 240 for value in boundaries):
                raise ValueError("Heart-rate zone boundaries must be between 60 and 240 bpm")
            if boundaries != sorted(set(boundaries)):
                raise ValueError("Heart-rate zone boundaries must be unique and increasing")
        return self


GoalStatus = Literal["draft", "active", "paused", "completed", "abandoned"]


class GoalPayload(ClientRecord):
    goal_type: str = Field(min_length=1, max_length=80)
    metric_key: str = Field(min_length=1, max_length=120)
    name: str = Field(min_length=1, max_length=160)
    baseline_value: float | None = None
    current_value: float | None = None
    target_value: float | None = None
    unit_key: str | None = Field(default=None, max_length=40)
    starts_on: date
    target_date: date | None = None
    priority: int = Field(default=0, ge=0, le=100)
    status: GoalStatus = "active"
    acceptable_rate_min: float | None = None
    acceptable_rate_max: float | None = None
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def valid_dates_and_rate(self):
        if self.target_date is not None and self.target_date < self.starts_on:
            raise ValueError("target_date cannot be before starts_on")
        if (
            self.acceptable_rate_min is not None
            and self.acceptable_rate_max is not None
            and self.acceptable_rate_min > self.acceptable_rate_max
        ):
            raise ValueError("acceptable_rate_min cannot exceed acceptable_rate_max")
        return self


class GoalPatch(FitnessModel):
    goal_type: str | None = Field(default=None, min_length=1, max_length=80)
    metric_key: str | None = Field(default=None, min_length=1, max_length=120)
    name: str | None = Field(default=None, min_length=1, max_length=160)
    baseline_value: float | None = None
    current_value: float | None = None
    target_value: float | None = None
    unit_key: str | None = Field(default=None, max_length=40)
    starts_on: date | None = None
    target_date: date | None = None
    priority: int | None = Field(default=None, ge=0, le=100)
    status: GoalStatus | None = None
    acceptable_rate_min: float | None = None
    acceptable_rate_max: float | None = None
    notes: str | None = Field(default=None, max_length=4_000)


class GoalRelationshipPayload(ClientRecord):
    source_goal_id: UUID
    target_goal_id: UUID
    relationship: Literal["supports", "conflicts", "depends_on", "subgoal_of"]
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def distinct_goals(self):
        if self.source_goal_id == self.target_goal_id:
            raise ValueError("A goal cannot have a relationship with itself")
        return self


class GoalLinkPayload(FitnessModel):
    goal_id: UUID
    role: Literal["primary", "secondary", "constraint"]


class PlannedSessionGoalLinkPayload(FitnessModel):
    goal_id: UUID
    role: Literal["primary", "secondary", "maintenance", "constraint"]


class PlannedSetPayload(FitnessModel):
    id: UUID | None = None
    sequence: int = Field(ge=0)
    training_role: Literal["warmup", "working", "backoff", "technique", "test", "other"]
    structure_type: Literal["straight", "drop", "rest_pause", "cluster", "other"] = "straight"
    component_count: int = Field(default=1, ge=1, le=20)
    reps_min: int | None = Field(default=None, ge=0)
    reps_max: int | None = Field(default=None, ge=0)
    load_min: float | None = Field(default=None, ge=0)
    load_max: float | None = Field(default=None, ge=0)
    load_unit: str | None = Field(default=None, max_length=40)
    rpe_min: float | None = Field(default=None, ge=0, le=10)
    rpe_max: float | None = Field(default=None, ge=0, le=10)
    rir_min: float | None = Field(default=None, ge=0, le=10)
    rir_max: float | None = Field(default=None, ge=0, le=10)
    rest_s: int | None = Field(default=None, ge=0)
    is_amrap: bool = False
    notes: str | None = Field(default=None, max_length=1_000)


class PlannedExercisePayload(FitnessModel):
    id: UUID | None = None
    exercise_id: UUID
    exercise_setup_id: UUID | None = None
    sequence: int = Field(ge=0)
    superset_group_key: str | None = Field(default=None, max_length=80)
    substitution_exercise_ids: list[UUID] = Field(default_factory=list, max_length=30)
    notes: str | None = Field(default=None, max_length=1_000)
    planned_sets: list[PlannedSetPayload] = Field(default_factory=list, max_length=100)


class RunWorkoutStepPayload(FitnessModel):
    id: UUID | None = None
    parent_step_id: UUID | None = None
    sequence: int = Field(ge=0)
    kilometre_index: int | None = Field(default=None, ge=1)
    step_kind: Literal["step", "repeat_block"] = "step"
    repeat_count: int | None = Field(default=None, ge=1, le=100)
    duration_type: Literal["distance_m", "time_s", "lap_button", "open", "calories"]
    duration_value: float | None = Field(default=None, gt=0)
    target_type: Literal[
        "pace_s_per_km",
        "heart_rate_bpm",
        "heart_rate_zone",
        "power_w",
        "power_zone",
        "cadence_spm",
        "rpe",
        "none",
    ] = "none"
    target_low: float | None = None
    target_high: float | None = None
    target_unit: str | None = Field(default=None, max_length=40)
    intensity_label: str | None = Field(default=None, max_length=80)
    display_name: str = Field(min_length=1, max_length=120)
    instruction_text: str | None = Field(default=None, max_length=1_000)
    mental_cue_text: str | None = Field(default=None, max_length=500)
    spoken_cue_text: str | None = Field(default=None, max_length=500)
    allow_manual_advance: bool = False
    notes: str | None = Field(default=None, max_length=1_000)
    children: list["RunWorkoutStepPayload"] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def valid_step(self):
        if self.step_kind == "repeat_block":
            if self.repeat_count is None or not self.children:
                raise ValueError("A repeat block needs a finite repeat_count and child steps")
        elif self.children or self.repeat_count is not None:
            raise ValueError("Only repeat blocks can contain child steps or repeat_count")
        if self.step_kind == "step":
            needs_value = self.duration_type in {"distance_m", "time_s", "calories"}
            if needs_value != (self.duration_value is not None):
                raise ValueError("The selected duration type has an invalid duration_value")
        if (
            self.target_low is not None
            and self.target_high is not None
            and self.target_low > self.target_high
        ):
            raise ValueError("target_low cannot exceed target_high")
        if self.target_type == "none" and any(
            value is not None for value in (self.target_low, self.target_high, self.target_unit)
        ):
            raise ValueError("A step without a target cannot contain target values")
        return self


class RunWorkoutCuePayload(FitnessModel):
    id: UUID | None = None
    step_id: UUID | None = None
    sequence: int = Field(ge=0)
    trigger_type: Literal[
        "workout_start",
        "step_start",
        "step_end",
        "distance_from_workout_start_m",
        "distance_from_step_start_m",
        "time_from_workout_start_s",
        "time_from_step_start_s",
        "halfway",
        "final_kilometre",
        "manual",
    ]
    trigger_value: float | None = Field(default=None, ge=0)
    short_text: str = Field(min_length=1, max_length=200)
    spoken_text: str | None = Field(default=None, max_length=500)
    priority: int = Field(default=0, ge=0, le=100)


class PlannedGearLinkPayload(FitnessModel):
    gear_id: UUID
    role: Literal["primary", "secondary", "sensor", "other"] = "primary"


class WorkoutVersionPayload(ClientRecord):
    title: str = Field(min_length=1, max_length=200)
    purpose: str | None = Field(default=None, max_length=1_000)
    estimated_duration_s: int | None = Field(default=None, ge=0)
    estimated_distance_m: float | None = Field(default=None, ge=0)
    structured_summary: dict = Field(default_factory=dict)
    version_source: Literal["user", "coach", "import"] = "user"
    accepted_at: datetime | None = None
    exercise_items: list[PlannedExercisePayload] = Field(default_factory=list, max_length=100)
    run_steps: list[RunWorkoutStepPayload] = Field(default_factory=list, max_length=200)
    run_cues: list[RunWorkoutCuePayload] = Field(default_factory=list, max_length=200)


class WorkoutDefinitionPayload(ClientRecord):
    sport_key: str = Field(min_length=1, max_length=80)
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=4_000)
    active: bool = True
    version: WorkoutVersionPayload | None = None


class TrainingProgrammePayload(ClientRecord):
    name: str = Field(min_length=1, max_length=200)
    purpose: str | None = Field(default=None, max_length=1_000)
    starts_on: date
    ends_on: date | None = None
    status: Literal["draft", "active", "paused", "completed", "abandoned"] = "active"
    phase_id: UUID | None = None
    programme_source: Literal["user", "coach", "import"] = "user"
    goal_links: list[GoalLinkPayload] = Field(default_factory=list, max_length=50)

    @model_validator(mode="after")
    def valid_programme(self):
        if self.ends_on is not None and self.ends_on < self.starts_on:
            raise ValueError("ends_on cannot be before starts_on")
        if sum(link.role == "primary" for link in self.goal_links) > 1:
            raise ValueError("A programme can have at most one primary goal")
        if len({str(link.goal_id) for link in self.goal_links}) != len(self.goal_links):
            raise ValueError("A programme cannot link the same goal twice")
        return self


class TrainingPhasePayload(ClientRecord):
    phase_type: Literal[
        "fat_loss",
        "maintenance",
        "recomposition",
        "running_base",
        "race_preparation",
        "strength_emphasis",
        "recovery",
        "return_to_training",
        "custom",
    ]
    name: str = Field(min_length=1, max_length=160)
    starts_on: date
    ends_on: date | None = None
    goal_links: list[GoalLinkPayload] = Field(default_factory=list, max_length=50)
    calorie_policy: dict | None = None
    protein_policy: dict | None = None
    running_priorities: list[str] = Field(default_factory=list, max_length=50)
    strength_priorities: list[str] = Field(default_factory=list, max_length=50)
    accepted_tradeoffs: list[str] = Field(default_factory=list, max_length=50)
    notes: str | None = Field(default=None, max_length=4_000)
    active: bool = True

    @model_validator(mode="after")
    def valid_phase(self):
        if self.ends_on is not None and self.ends_on < self.starts_on:
            raise ValueError("ends_on cannot be before starts_on")
        if sum(link.role == "primary" for link in self.goal_links) > 1:
            raise ValueError("A phase can have at most one primary goal")
        if len({str(link.goal_id) for link in self.goal_links}) != len(self.goal_links):
            raise ValueError("A phase cannot link the same goal twice")
        return self


class PlannedSessionPayload(ClientRecord):
    sport_key: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=200)
    local_timezone: str = Field(min_length=1, max_length=100)
    training_programme_id: UUID | None = None
    workout_version_id: UUID | None = None
    status: Literal[
        "proposed",
        "accepted",
        "scheduled",
        "in_progress",
        "completed",
        "partially_completed",
        "skipped",
        "cancelled",
    ] = "proposed"
    session_source: Literal["user", "coach", "imported"] = "user"
    scheduled_start_utc: datetime | None = None
    scheduled_date: date | None = None
    time_window_start_utc: datetime | None = None
    time_window_end_utc: datetime | None = None
    expected_duration_s: int | None = Field(default=None, ge=0)
    expected_distance_m: float | None = Field(default=None, ge=0)
    expected_pace_s_per_km: float | None = Field(default=None, gt=0, le=3_600)
    priority: int = Field(default=0, ge=0, le=100)
    movable: bool = True
    visibility: Literal["private", "logistics_shared"] = "private"
    shared_title: str | None = Field(default=None, max_length=200)
    reason_for_placement: str | None = Field(default=None, max_length=1_000)
    completion_activity_id: UUID | None = None
    completion_state: str | None = Field(default=None, max_length=80)
    goal_links: list[PlannedSessionGoalLinkPayload] = Field(default_factory=list, max_length=50)
    exercise_items: list[PlannedExercisePayload] = Field(default_factory=list, max_length=100)
    gear_links: list[PlannedGearLinkPayload] = Field(default_factory=list, max_length=30)
    intended_gear_ids: list[UUID] = Field(default_factory=list, max_length=30)

    @model_validator(mode="after")
    def valid_schedule(self):
        if self.time_window_start_utc and self.time_window_end_utc:
            if self.time_window_end_utc <= self.time_window_start_utc:
                raise ValueError("time_window_end_utc must be after its start")
        if self.visibility == "logistics_shared" and not self.shared_title:
            self.shared_title = {
                "running": "Running",
                "strength": "Training",
            }.get(self.sport_key, "Fitness")
        if len({str(link.goal_id) for link in self.goal_links}) != len(self.goal_links):
            raise ValueError("A planned session cannot link the same goal twice")
        if sum(link.role == "primary" for link in self.goal_links) > 1:
            raise ValueError("A planned session can have at most one primary goal")
        exercise_ids = [str(item.exercise_id) for item in self.exercise_items]
        if len(exercise_ids) != len(set(exercise_ids)):
            raise ValueError("A planned session cannot prescribe the same exercise twice")
        if len({str(identifier) for identifier in self.intended_gear_ids}) != len(
            self.intended_gear_ids
        ):
            raise ValueError("A planned session cannot link the same intended gear twice")
        return self


class FoodVersionPayload(ClientRecord):
    food_id: UUID | None = None
    effective_from: date | None = None
    reference_amount: float = Field(gt=0)
    reference_unit: Literal["g", "ml", "item", "serving", "custom"]
    calories_kcal: float | None = Field(default=None, ge=0)
    source_energy_value: float | None = Field(default=None, ge=0)
    source_energy_unit: Literal["kcal", "kj"] | None = None
    protein_g: float | None = Field(default=None, ge=0)
    carbohydrate_g: float | None = Field(default=None, ge=0)
    sugars_g: float | None = Field(default=None, ge=0)
    fat_g: float | None = Field(default=None, ge=0)
    saturated_fat_g: float | None = Field(default=None, ge=0)
    fibre_g: float | None = Field(default=None, ge=0)
    salt_g: float | None = Field(default=None, ge=0)
    sodium_mg: float | None = Field(default=None, ge=0)
    micronutrients: dict[str, float | None] = Field(default_factory=dict)
    source_type: str = Field(default="manual", max_length=80)
    source_note: str | None = Field(default=None, max_length=1_000)
    confidence: str = Field(default="measured", max_length=40)
    label_asset_id: UUID | None = None

    @model_validator(mode="after")
    def energy_source_is_complete(self):
        if (self.source_energy_value is None) != (self.source_energy_unit is None):
            raise ValueError("source_energy_value and source_energy_unit must be supplied together")
        return self


class FoodPayload(ClientRecord):
    name: str = Field(min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=160)
    category_key: str | None = Field(default=None, max_length=80)
    barcode: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)
    household_shared: bool = False
    favourite: bool = False
    active: bool = True
    version: FoodVersionPayload | None = None


class FoodPatch(FitnessModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=160)
    category_key: str | None = Field(default=None, max_length=80)
    barcode: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)
    household_shared: bool | None = None
    favourite: bool | None = None
    active: bool | None = None


class ServingPayload(ClientRecord):
    food_id: UUID | None = None
    name: str = Field(min_length=1, max_length=120)
    amount: float = Field(gt=0)
    unit: str = Field(min_length=1, max_length=40)
    canonical_amount: float = Field(gt=0)
    canonical_unit: str = Field(min_length=1, max_length=40)
    measurement_quality: Literal[
        "weighed", "measured", "standard_serving", "estimated", "restaurant_estimate"
    ]
    is_default: bool = False
    active: bool = True


class MergePayload(FitnessModel):
    source_id: UUID
    target_id: UUID


class RecipeComponentPayload(FitnessModel):
    id: UUID | None = None
    food_version_id: UUID
    amount: float = Field(gt=0)
    unit: str = Field(min_length=1, max_length=40)
    canonical_amount: float = Field(gt=0)
    canonical_unit: str = Field(min_length=1, max_length=40)
    sequence: int | None = Field(default=None, ge=0)


class RecipeVersionPayload(ClientRecord):
    recipe_id: UUID | None = None
    components: list[RecipeComponentPayload] = Field(default_factory=list, max_length=200)
    finished_weight_g: float | None = Field(default=None, gt=0)
    servings: float | None = Field(default=None, gt=0)
    calories_kcal: float | None = Field(default=None, ge=0)
    protein_g: float | None = Field(default=None, ge=0)
    carbohydrate_g: float | None = Field(default=None, ge=0)
    sugars_g: float | None = Field(default=None, ge=0)
    fat_g: float | None = Field(default=None, ge=0)
    saturated_fat_g: float | None = Field(default=None, ge=0)
    fibre_g: float | None = Field(default=None, ge=0)
    salt_g: float | None = Field(default=None, ge=0)
    lower_calories_kcal: float | None = Field(default=None, ge=0)
    upper_calories_kcal: float | None = Field(default=None, ge=0)
    confidence: str = Field(default="calculated", max_length=40)
    source_note: str | None = Field(default=None, max_length=1_000)

    @model_validator(mode="after")
    def valid_estimate_range(self):
        if (
            self.lower_calories_kcal is not None
            and self.upper_calories_kcal is not None
            and self.lower_calories_kcal > self.upper_calories_kcal
        ):
            raise ValueError("lower_calories_kcal cannot exceed upper_calories_kcal")
        return self


class RecipePayload(ClientRecord):
    name: str = Field(min_length=1, max_length=200)
    notes: str | None = Field(default=None, max_length=4_000)
    household_shared: bool = False
    favourite: bool = False
    active: bool = True
    version: RecipeVersionPayload | None = None


class MealTemplateItemPayload(FitnessModel):
    id: UUID | None = None
    food_version_id: UUID | None = None
    recipe_version_id: UUID | None = None
    label: str | None = Field(default=None, max_length=200)
    amount: float = Field(gt=0)
    unit: str = Field(min_length=1, max_length=40)
    canonical_amount: float = Field(gt=0)
    canonical_unit: str = Field(min_length=1, max_length=40)
    measurement_quality: str = Field(default="standard_serving", max_length=40)
    sequence: int | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def one_source(self):
        if (self.food_version_id is None) == (self.recipe_version_id is None):
            raise ValueError("Provide exactly one food or recipe version")
        return self


class MealTemplatePayload(ClientRecord):
    name: str = Field(min_length=1, max_length=200)
    meal_key: str = Field(min_length=1, max_length=40)
    time_relevance: str | None = Field(default=None, max_length=80)
    favourite: bool = False
    active: bool = True
    items: list[MealTemplateItemPayload] = Field(default_factory=list, max_length=100)


class NutritionTargetPayload(ClientRecord):
    metric_key: str = Field(min_length=1, max_length=120)
    target_type: Literal[
        "fixed", "range", "weekly_average", "training_rest", "phase"
    ]
    target_value: float | None = Field(default=None, ge=0)
    target_min: float | None = Field(default=None, ge=0)
    target_max: float | None = Field(default=None, ge=0)
    training_day_value: float | None = Field(default=None, ge=0)
    rest_day_value: float | None = Field(default=None, ge=0)
    phase_id: UUID | None = None
    effective_from: date
    effective_until: date | None = None
    active: bool = True

    @model_validator(mode="after")
    def valid_target_shape(self):
        if self.effective_until is not None and self.effective_until < self.effective_from:
            raise ValueError("effective_until cannot be before effective_from")
        if self.target_type in {"fixed", "weekly_average"}:
            if self.target_value is None:
                raise ValueError("This target type requires target_value")
        elif self.target_type == "range":
            if self.target_min is None or self.target_max is None:
                raise ValueError("A range target requires target_min and target_max")
            if self.target_min > self.target_max:
                raise ValueError("target_min cannot exceed target_max")
        elif self.target_type == "training_rest":
            if self.training_day_value is None or self.rest_day_value is None:
                raise ValueError(
                    "A training/rest target requires both day-specific values"
                )
        elif self.target_type == "phase":
            if self.phase_id is None or self.target_value is None:
                raise ValueError("A phase target requires phase_id and target_value")
        return self


class FoodLogPayload(ClientRecord):
    food_version_id: UUID | None = None
    recipe_version_id: UUID | None = None
    logged_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    meal_key: Literal[
        "breakfast", "lunch", "dinner", "snack", "drink", "pre_workout",
        "during_workout", "post_workout", "other",
    ]
    entered_amount: float = Field(gt=0)
    entered_unit: str = Field(min_length=1, max_length=40)
    canonical_amount: float = Field(gt=0)
    canonical_unit: str = Field(min_length=1, max_length=40)
    measurement_quality: Literal[
        "weighed", "measured", "standard_serving", "estimated", "restaurant_estimate"
    ]
    notes: str | None = Field(default=None, max_length=4_000)
    context_tags: list[str] = Field(default_factory=list, max_length=50)

    @model_validator(mode="after")
    def one_source(self):
        if (self.food_version_id is None) == (self.recipe_version_id is None):
            raise ValueError("Provide exactly one food or recipe version")
        return self


class NutritionMealCompletionPayload(ClientRecord):
    nutrition_date: date
    meal_key: Literal["breakfast", "lunch", "dinner", "snack"]


class BodyMeasurementPayload(ClientRecord):
    metric_key: str = Field(min_length=1, max_length=120)
    measured_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    value: float
    unit_key: str = Field(min_length=1, max_length=40)
    source_record_id: UUID | None = None
    measurement_quality: str = Field(default="measured", max_length=40)
    canonical_state: Literal["canonical", "duplicate", "excluded"] = "canonical"
    duplicate_of_measurement_id: UUID | None = None
    notes: str | None = Field(default=None, max_length=4_000)


class MuscleRolePayload(FitnessModel):
    muscle_group_key: str = Field(min_length=1, max_length=80)
    role: Literal["primary", "secondary"]
    contribution_weight: float | None = Field(default=None, ge=0, le=1)


class ExercisePayload(ClientRecord):
    seed_key: str | None = Field(default=None, max_length=100)
    name: str = Field(min_length=1, max_length=200)
    aliases: list[str] = Field(default_factory=list, max_length=100)
    movement_pattern_key: str = Field(default="other", max_length=80)
    measurement_mode: ExerciseMeasurementMode = "reps_load"
    rep_count_mode: ExerciseRepCountMode = "total"
    load_entry_mode: ExerciseLoadEntryMode = "total_external"
    default_unit: str = Field(default="kg", max_length=40)
    unilateral_mode: ExerciseUnilateralMode = "bilateral"
    equipment_type: str | None = Field(default=None, max_length=100)
    bodyweight_involved: bool = False
    progression_direction: Literal["higher", "lower", "mixed"] = "higher"
    notes: str | None = Field(default=None, max_length=4_000)
    favourite: bool = False
    active: bool = True
    muscle_roles: list[MuscleRolePayload] = Field(default_factory=list, max_length=50)


class ExerciseSetupPayload(ClientRecord):
    exercise_id: UUID
    name: str = Field(min_length=1, max_length=160)
    location: str | None = Field(default=None, max_length=160)
    equipment_identifier: str | None = Field(default=None, max_length=160)
    load_entry_mode: ExerciseLoadEntryMode | None = None
    rep_count_mode: ExerciseRepCountMode | None = None
    unilateral_mode: ExerciseUnilateralMode | None = None
    bar_weight_kg: float | None = Field(default=None, ge=0)
    machine_base_load_kg: float | None = Field(default=None, ge=0)
    side_multiplier: float | None = Field(default=None, gt=0)
    notes: str | None = Field(default=None, max_length=4_000)
    is_default: bool = False
    active: bool = True


class ExercisePatch(FitnessModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    aliases: list[str] | None = Field(default=None, max_length=100)
    movement_pattern_key: str | None = Field(default=None, max_length=80)
    measurement_mode: ExerciseMeasurementMode | None = None
    rep_count_mode: ExerciseRepCountMode | None = None
    load_entry_mode: ExerciseLoadEntryMode | None = None
    default_unit: str | None = Field(default=None, max_length=40)
    unilateral_mode: ExerciseUnilateralMode | None = None
    equipment_type: str | None = Field(default=None, max_length=100)
    bodyweight_involved: bool | None = None
    progression_direction: Literal["higher", "lower", "mixed"] | None = None
    notes: str | None = Field(default=None, max_length=4_000)
    favourite: bool | None = None
    active: bool | None = None
    muscle_roles: list[MuscleRolePayload] | None = Field(default=None, max_length=50)


class ExerciseSetupPatch(FitnessModel):
    name: str | None = Field(default=None, min_length=1, max_length=160)
    location: str | None = Field(default=None, max_length=160)
    equipment_identifier: str | None = Field(default=None, max_length=160)
    load_entry_mode: ExerciseLoadEntryMode | None = None
    rep_count_mode: ExerciseRepCountMode | None = None
    unilateral_mode: ExerciseUnilateralMode | None = None
    bar_weight_kg: float | None = Field(default=None, ge=0)
    machine_base_load_kg: float | None = Field(default=None, ge=0)
    side_multiplier: float | None = Field(default=None, gt=0)
    notes: str | None = Field(default=None, max_length=4_000)
    is_default: bool | None = None
    active: bool | None = None


class StrengthSessionPayload(ClientRecord):
    title: str = Field(min_length=1, max_length=200)
    started_at_utc: datetime
    local_timezone: str = Field(min_length=1, max_length=100)
    planned_session_id: UUID | None = None
    status: Literal["in_progress", "completed", "partial", "aborted"] = "in_progress"
    ended_at_utc: datetime | None = None
    rest_timer_deadline_utc: datetime | None = None
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    perceived_performance: int | None = Field(default=None, ge=1, le=5)
    matched_plan_key: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)


class StrengthSessionExercisePayload(ClientRecord):
    activity_id: UUID
    exercise_id: UUID
    exercise_setup_id: UUID | None = None
    planned_exercise_id: UUID | None = None
    sequence: int = Field(ge=0)
    superset_group_key: str | None = Field(default=None, max_length=80)
    variation_note: str | None = Field(default=None, max_length=500)
    notes: str | None = Field(default=None, max_length=4_000)


class StrengthSetGroupPayload(ClientRecord):
    activity_id: UUID
    session_exercise_id: UUID
    planned_set_id: UUID | None = None
    sequence: int = Field(ge=0)
    training_role: Literal["warmup", "working", "backoff", "technique", "test", "other"]
    structure_type: Literal["straight", "drop", "rest_pause", "cluster", "other"]
    status: Literal["planned", "in_progress", "completed", "partial", "skipped", "aborted"]
    is_amrap: bool = False
    failure_state: Literal[
        "none", "technical", "muscular", "stopped_for_body_issue", "unknown"
    ] = "none"
    started_at_utc: datetime | None = None
    completed_at_utc: datetime | None = None
    notes: str | None = Field(default=None, max_length=4_000)


class StrengthSetComponentPayload(ClientRecord):
    set_group_id: UUID
    component_index: int = Field(ge=0)
    component_status: Literal["completed", "partial", "skipped"]
    reps: int | None = Field(default=None, ge=0)
    reps_left: int | None = Field(default=None, ge=0)
    reps_right: int | None = Field(default=None, ge=0)
    load_value: float | None = Field(default=None, ge=0)
    load_unit: str | None = Field(default=None, max_length=40)
    load_entry_mode_snapshot: str | None = Field(default=None, max_length=40)
    normalized_external_load_kg: float | None = Field(default=None, ge=0)
    added_load_kg: float | None = Field(default=None, ge=0)
    assistance_kg: float | None = Field(default=None, ge=0)
    bodyweight_kg_snapshot: float | None = Field(default=None, ge=0)
    duration_s: float | None = Field(default=None, ge=0)
    distance_m: float | None = Field(default=None, ge=0)
    rpe: float | None = Field(default=None, ge=0, le=10)
    rir: float | None = Field(default=None, ge=0, le=10)
    rest_before_s: int | None = Field(default=None, ge=0)
    tempo_text: str | None = Field(default=None, max_length=80)
    completed_at_utc: datetime | None = None
    notes: str | None = Field(default=None, max_length=4_000)
    extra_metrics: dict = Field(default_factory=dict)


class StrengthSessionFinish(FitnessModel):
    status: Literal["completed", "partial", "aborted"] = "completed"
    ended_at_utc: datetime
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    perceived_performance: int | None = Field(default=None, ge=1, le=5)
    matched_plan_key: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)


class SessionCheckinPayload(ClientRecord):
    planned_session_id: UUID | None = None
    activity_id: UUID | None = None
    timing: Literal["pre", "post"]
    captured_at_utc: datetime
    capture_quality: Literal["contemporaneous", "retrospective"]
    captured_before_activity_start: bool | None = None
    readiness_1_5: int | None = Field(default=None, ge=1, le=5)
    energy_1_5: int | None = Field(default=None, ge=1, le=5)
    soreness_1_5: int | None = Field(default=None, ge=1, le=5)
    motivation_1_5: int | None = Field(default=None, ge=1, le=5)
    session_rpe_1_10: float | None = Field(default=None, ge=1, le=10)
    perceived_performance_1_5: int | None = Field(default=None, ge=1, le=5)
    matched_plan_key: str | None = Field(default=None, max_length=80)
    notes: str | None = Field(default=None, max_length=4_000)


class BodyIssuePayload(ClientRecord):
    planned_session_id: UUID | None = None
    activity_id: UUID | None = None
    session_exercise_id: UUID | None = None
    set_group_id: UUID | None = None
    checkin_id: UUID | None = None
    observed_at_utc: datetime
    timing: Literal["pre", "during", "post", "next_day", "standalone"]
    issue_type_key: Literal["pain", "tightness", "discomfort", "weakness", "injury", "other"]
    body_location_key: str = Field(min_length=1, max_length=80)
    side: Literal["left", "right", "bilateral", "midline", "not_applicable", "unknown"]
    severity_0_10: int = Field(ge=0, le=10)
    changed_session: bool
    session_change_key: Literal[
        "none", "reduced_load", "reduced_range", "reduced_pace", "substituted",
        "stopped", "prevented_start", "other",
    ]
    trend_key: Literal["new", "existing_same", "worse", "better", "unknown"] = "unknown"
    status: Literal["active", "resolved", "unknown"] = "active"
    resolved_at_utc: datetime | None = None
    notes: str | None = Field(default=None, max_length=4_000)

    @model_validator(mode="after")
    def valid_change(self):
        if self.changed_session == (self.session_change_key == "none"):
            raise ValueError("session_change_key must describe whether the session changed")
        return self


FitnessEntityType = str


class FitnessSyncMutation(FitnessModel):
    mutation_id: UUID
    entity_type: FitnessEntityType = Field(min_length=1, max_length=100)
    entity_id: UUID
    operation: Literal["upsert", "delete"]
    payload_schema_version: int = 0
    base_revision: int | None = Field(default=None, ge=0)
    payload: dict = Field(default_factory=dict)
    created_at_client: str | None = Field(
        default=None,
        validation_alias=AliasChoices("created_at_client", "client_created_at"),
        max_length=100,
    )


class FitnessSyncRequest(FitnessModel):
    sync_protocol_version: int = 0
    client_schema_version: int = 0
    client_app_version: str = Field(
        default="",
        validation_alias=AliasChoices("client_app_version", "app_version"),
        max_length=50,
    )
    client_build: str = Field(
        default="",
        validation_alias=AliasChoices("client_build", "build_number"),
        max_length=50,
    )
    platform: Literal["ios", "web"] = "ios"
    device_id: str = Field(default="", max_length=200)
    cursor: int = Field(default=0, ge=0)
    mutations: list[FitnessSyncMutation] = Field(default_factory=list, max_length=200)


class FitnessSyncAccepted(FitnessModel):
    mutation_id: str
    entity_id: str
    revision: int


class FitnessSyncChange(FitnessModel):
    sequence: int
    entity_type: str
    entity_id: str
    revision: int
    operation: str
    data: dict | None = None
    changed_at: str


class FitnessRedirect(FitnessModel):
    entity_type: str
    source_id: str
    target_id: str
    target_summary: dict = Field(default_factory=dict)


class FitnessSyncResponse(FitnessModel):
    status: Literal["ok", "full_snapshot_required"] = "ok"
    current_sync_protocol_version: int
    current_client_schema_version: int
    minimum_supported_client_schema_version: int
    accepted: list[FitnessSyncAccepted]
    acked_mutation_ids: list[str]
    rejected_mutations: list[dict] = Field(default_factory=list)
    changes: list[FitnessSyncChange]
    redirects: list[FitnessRedirect]
    notices: list[dict]
    next_cursor: int
    snapshot_url: str | None = None
    message: str | None = None


class FitnessSnapshotEntity(FitnessModel):
    entity_type: str
    entity_id: str
    revision: int
    data: dict


class FitnessSnapshotResponse(FitnessModel):
    status: Literal["ok"] = "ok"
    current_sync_protocol_version: int
    current_client_schema_version: int
    minimum_supported_client_schema_version: int
    generated_at: str
    entities: list[FitnessSnapshotEntity]
    redirects: list[FitnessRedirect]
    next_cursor: int


PositiveNumber = Annotated[float, Field(gt=0)]
