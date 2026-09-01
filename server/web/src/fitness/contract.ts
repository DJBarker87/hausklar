export const FITNESS_SYNC_PROTOCOL_VERSION = 1;
export const FITNESS_CLIENT_SCHEMA_VERSION = 1;

export const FITNESS_PAYLOAD_SCHEMA_VERSIONS = {
  source_record: 1,
  nutrition_settings: 1,
  goal: 1,
  goal_relationship: 1,
  training_phase: 1,
  workout_definition: 1,
  training_programme: 1,
  food: 1,
  food_version: 1,
  food_serving: 1,
  food_log_entry: 1,
  recipe: 1,
  recipe_version: 1,
  meal_template: 1,
  nutrition_target: 1,
  body_measurement: 1,
  sleep_session: 1,
  recovery_observation: 1,
  cycle_settings: 1,
  cycle_period_start: 1,
  source_priority: 1,
  exercise: 1,
  exercise_setup: 1,
  planned_session: 1,
  session_checkin: 1,
  body_issue: 1,
  gear: 1,
  manual_activity: 1,
  activity_context: 1,
  activity_gear_link: 1,
  activity_goal_link: 1,
  progress_photo: 1,
  strength_session: 1,
  strength_session_exercise: 1,
  strength_set_group: 1,
  strength_set_component: 1,
} as const;

export type FitnessEntityType = keyof typeof FITNESS_PAYLOAD_SCHEMA_VERSIONS;
export type FitnessMutationOperation = "upsert" | "delete";

export type FitnessRecordBase = {
  id: string;
  revision?: number;
  created_at?: string | null;
  updated_at?: string | null;
  deleted_at?: string | null;
  queued_offline?: boolean;
};

export type FitnessWorkspacePreference = {
  enabled: boolean;
  pinned: boolean;
  show_nutrition_today?: boolean;
};

export type FitnessOnboardingDay =
  | "Monday"
  | "Tuesday"
  | "Wednesday"
  | "Thursday"
  | "Friday"
  | "Saturday"
  | "Sunday";

export type FitnessOnboardingAvailability = {
  day: FitnessOnboardingDay;
  time_of_day: "Morning" | "Lunchtime" | "Evening" | "Flexible";
  duration_minutes: number;
};

export type FitnessOnboardingDraft = {
  main_outcome: "Feel fitter" | "Build strength" | "Run further" | "Improve energy" | "Support my weight" | "Move consistently" | null;
  availability: FitnessOnboardingAvailability[];
  activities: Array<"Walking" | "Running" | "Strength" | "Cycling" | "Swimming" | "Mobility">;
  equipment: string[];
  food_preferences: string[];
  source_connections: Array<"Apple Health" | "Garmin" | "Withings" | "Intervals.icu">;
  coach_style: "Calm and encouraging" | "Balanced and practical" | "Direct and challenging" | null;
  use_family_calendar: boolean;
  use_household_meals: boolean;
  use_weather: boolean;
  memory_enabled: boolean;
};

export type FitnessOnboardingWeekSession = {
  day: FitnessOnboardingDay;
  date: string;
  start_time: string;
  activity: FitnessOnboardingDraft["activities"][number];
  title: string;
  duration_minutes: number;
  reason: string;
};

export type FitnessOnboardingWeekPreview = {
  preview_id: string;
  week_start: string;
  summary: string;
  sessions: FitnessOnboardingWeekSession[];
};

export type FitnessOnboardingProfile = FitnessOnboardingDraft & {
  id: string;
  status: "draft" | "skipped" | "complete";
  preview: FitnessOnboardingWeekPreview | null;
  confirmation: {
    completed_at: string;
    goal_id: string;
    session_ids: string[];
  } | null;
};

export type FitnessOnboardingConfirmation = {
  status: "complete";
  completed_at: string;
  goal_id: string;
  session_ids: string[];
  week: FitnessOnboardingWeekPreview;
};

export type FitnessGoalTemplate = {
  id: "run-faster-5k" | "run-consistently" | "move-consistently" | "run-weekly-distance" | "strength-consistency" | "energy-and-wellbeing" | "body-weight-support";
  title: string;
  description: string;
  target_prompt: string;
  input_kind: "duration_minutes_seconds" | "sessions_per_week" | "kilometres_per_week" | "active_days_per_week" | "target_weight_kg";
  unit_label: string;
  minimum_value: number;
  maximum_value: number;
  step: number;
  suggested_value: number;
  supports_target_date: boolean;
};

export type FitnessGoalFromTemplateResponse = {
  goal_id: string;
  template_id: FitnessGoalTemplate["id"];
  title: string;
  target_text: string;
  starts_on: string;
  target_date?: string | null;
  priority: number;
  status: "active";
};

export type FitnessWeeklyReview = {
  week_start: string;
  week_end: string;
  totals: {
    completed_sessions: number;
    active_days: number;
    duration_minutes?: number | null;
    distance_km?: number | null;
    strength_volume_kg?: number | null;
  };
  goal?: {
    goal_id: string;
    goal_name: string;
    progress_text: string;
    progress_percent?: number | null;
  } | null;
  highlight: { title: string; detail: string };
  opportunity: {
    title: string;
    detail: string;
    destination: "today" | "plan" | "activities" | "strength" | "goals" | "measurements";
    action: "plan_session" | "log_activity" | "start_strength" | "choose_goal" | "log_weight" | "review_goal";
    action_label: string;
  };
};

export type FitnessWeightProgressPoint = {
  measurement_id: string;
  measured_at_utc: string;
  weight_kg: number;
};

export type FitnessRunningProgressPoint = {
  activity_id: string;
  started_at_utc: string;
  duration_s: number;
  source: "best_effort" | "average_pace_estimate";
};

export type FitnessRunningProgressSeries = {
  key: "5k" | "10k";
  label: "5K" | "10K";
  distance_m: 5000 | 10000;
  points: FitnessRunningProgressPoint[];
};

export type FitnessStrengthProgressChartPoint = {
  activity_id: string;
  performed_at_utc: string;
  load_kg: number;
  repetitions?: number | null;
  working_set_count: number;
};

export type FitnessStrengthProgressChartSeries = {
  key: "squat" | "chest_press" | "overhead_press";
  label: "Squat" | "Chest press" | "Overhead press";
  exercise_id?: string | null;
  exercise_name?: string | null;
  setup_id?: string | null;
  setup_name?: string | null;
  points: FitnessStrengthProgressChartPoint[];
};

export type FitnessProgressCharts = {
  weight: FitnessWeightProgressPoint[];
  running: FitnessRunningProgressSeries[];
  strength: FitnessStrengthProgressChartSeries[];
};

export type FitnessNutritionSettings = FitnessRecordBase & {
  timezone: string;
  nutrition_day_start_minutes: number;
  heart_rate_zone_boundaries_bpm?: number[] | null;
};

export type FitnessGoal = FitnessRecordBase & {
  goal_type: string;
  metric_key?: string | null;
  name: string;
  baseline_value?: number | null;
  current_value?: number | null;
  target_value?: number | null;
  unit_key?: string | null;
  starts_on: string;
  target_date?: string | null;
  priority?: number;
  acceptable_rate_min?: number | null;
  acceptable_rate_max?: number | null;
  status: "draft" | "active" | "paused" | "completed" | "abandoned" | string;
  notes?: string | null;
};

export type FitnessGoalRelationship = FitnessRecordBase & {
  source_goal_id: string;
  target_goal_id: string;
  relationship: "supports" | "conflicts" | "depends_on" | "subgoal_of";
  notes?: string | null;
};

export type FitnessPhase = FitnessRecordBase & {
  phase_type: string;
  name: string;
  starts_on: string;
  ends_on?: string | null;
  goal_links?: Array<{
    goal_id: string;
    role: "primary" | "secondary" | "constraint";
  }>;
  calorie_policy?: Record<string, unknown> | null;
  protein_policy?: Record<string, unknown> | null;
  running_priorities?: string[];
  strength_priorities?: string[];
  accepted_tradeoffs?: string[];
  active?: boolean;
  notes?: string | null;
};

export type FitnessFoodVersion = FitnessRecordBase & {
  food_id?: string;
  version_number?: number;
  effective_from?: string | null;
  reference_amount: number;
  reference_unit: "g" | "ml" | "item" | "serving" | "custom" | string;
  calories_kcal: number | null;
  source_energy_value?: number | null;
  source_energy_unit?: "kcal" | "kj" | null;
  protein_g?: number | null;
  carbohydrate_g?: number | null;
  sugars_g?: number | null;
  fat_g?: number | null;
  saturated_fat_g?: number | null;
  fibre_g?: number | null;
  salt_g?: number | null;
  sodium_mg?: number | null;
  micronutrients?: Record<string, number | null>;
  micronutrients_json?: Record<string, number | null>;
  source_type?: string;
  source_note?: string | null;
  confidence?: string;
  label_asset_id?: string | null;
};

export type FitnessFoodServing = FitnessRecordBase & {
  food_id: string;
  name: string;
  amount: number;
  unit: string;
  canonical_amount: number;
  canonical_unit: string;
  measurement_quality: FitnessNutritionMeasurementQuality;
  is_default?: boolean;
  active?: boolean;
};

export type FitnessFoodQuickUse = {
  last_logged_at_utc?: string | null;
  last_amount?: number | null;
  last_unit?: string | null;
  usual_amount?: number | null;
  usual_unit?: string | null;
  frequency_count?: number;
  recent_meal_keys?: FitnessMealKey[];
};

export type FitnessFoodBarcodeLookup = {
  barcode: string;
  name: string;
  brand?: string | null;
  reference_amount: 100;
  reference_unit: "g" | "ml";
  nutrients: {
    calories_kcal?: number | null;
    protein_g?: number | null;
    carbohydrate_g?: number | null;
    sugars_g?: number | null;
    fat_g?: number | null;
    saturated_fat_g?: number | null;
    fibre_g?: number | null;
    salt_g?: number | null;
    sodium_mg?: number | null;
  };
  serving?: { name: string; amount: number; unit: "g" | "ml" } | null;
  source: "open_food_facts";
  source_url: string;
  warnings: string[];
  needs_review: true;
};

export type FitnessFood = FitnessRecordBase & {
  name: string;
  brand?: string | null;
  category_key?: string | null;
  barcode?: string | null;
  household_shared?: boolean;
  favourite?: boolean;
  active?: boolean;
  editable?: boolean;
  notes?: string | null;
  merged_into_food_id?: string | null;
  search_aliases?: string[];
  aliases?: string[];
  servings?: FitnessFoodServing[];
  quick_use?: FitnessFoodQuickUse | null;
  current_version?: FitnessFoodVersion | null;
  latest_version?: FitnessFoodVersion | null;
  version?: FitnessFoodVersion | null;
  versions?: FitnessFoodVersion[];
};

export type FitnessFoodMergePreview = {
  source_id: string;
  target_id: string;
  source_name?: string;
  target_name?: string;
  already_merged: boolean;
  versions: number;
  servings: number;
  duplicate_servings?: number;
  affected_log_entries?: number;
  affected_recipe_components?: number;
  affected_template_items?: number;
  warnings?: string[];
};

export type FitnessMealKey =
  | "breakfast"
  | "lunch"
  | "dinner"
  | "snack"
  | "drink"
  | "pre_workout"
  | "during_workout"
  | "post_workout"
  | "other";

export type FitnessNutritionMeasurementQuality =
  | "weighed"
  | "measured"
  | "standard_serving"
  | "estimated"
  | "restaurant_estimate";

export type FitnessFoodLogEntry = FitnessRecordBase & {
  food_id?: string | null;
  food_version_id?: string | null;
  food_name?: string | null;
  recipe_version_id?: string | null;
  source_meal_plan_id?: string | null;
  household_meal_link_id?: string | null;
  logged_at_utc: string;
  local_timezone: string;
  nutrition_date?: string;
  meal_key: FitnessMealKey | string;
  entered_amount: number;
  entered_unit: string;
  canonical_amount: number;
  canonical_unit: string;
  calories_kcal?: number | null;
  protein_g?: number | null;
  carbohydrate_g?: number | null;
  sugars_g?: number | null;
  fat_g?: number | null;
  saturated_fat_g?: number | null;
  fibre_g?: number | null;
  salt_g?: number | null;
  measurement_quality?: FitnessNutritionMeasurementQuality | string;
  notes?: string | null;
  context_tags?: string[];
  context_tags_json?: string[];
};

export type FitnessNutritionNutrients = {
  calories_kcal: number | null;
  protein_g: number | null;
  carbohydrate_g: number | null;
  sugars_g: number | null;
  fat_g: number | null;
  saturated_fat_g: number | null;
  fibre_g: number | null;
  salt_g: number | null;
};

export type FitnessNutritionTargetMode = "fixed" | "range" | "weekly_average" | "training_rest" | "phase";

export type FitnessNutritionTarget = FitnessRecordBase & {
  metric_key: keyof FitnessNutritionNutrients | string;
  target_type: FitnessNutritionTargetMode;
  target_value?: number | null;
  target_min?: number | null;
  target_max?: number | null;
  training_day_value?: number | null;
  rest_day_value?: number | null;
  phase_id?: string | null;
  effective_from?: string | null;
  effective_until?: string | null;
  active?: boolean;
};

export type FitnessNutritionContributor = {
  key: string;
  label: string;
  kind: "food" | "recipe" | "meal" | string;
  nutrient_key: keyof FitnessNutritionNutrients | string;
  value: number;
  share?: number | null;
  entry_count?: number;
};

export type FitnessNutritionDay = {
  nutrition_date: string;
  date?: string;
  entries: FitnessFoodLogEntry[];
  totals: FitnessNutritionNutrients;
  targets?: Partial<FitnessNutritionNutrients>;
  remaining?: Partial<FitnessNutritionNutrients>;
  meal_totals?: Record<string, Partial<FitnessNutritionNutrients>>;
  contributors?: FitnessNutritionContributor[];
  uncertain_nutrients?: Array<keyof FitnessNutritionNutrients | string>;
  measured_ratio?: number | null;
  measured_share?: number | null;
  estimated_share?: number | null;
};

export type FitnessNutritionAnalysisContributor = {
  item_id: string;
  item_kind: "food" | "recipe";
  label: string;
  meal_key: FitnessMealKey | string;
  nutrient_key: keyof FitnessNutritionNutrients | string;
  total: number;
  share?: number | null;
  entry_count: number;
  sample_days: number;
  typical_amount?: number | null;
  typical_unit?: string | null;
};

export type FitnessNutritionAnalysisRecommendation = {
  food_or_meal: string;
  item_id: string;
  item_kind: "food" | "recipe";
  meal_key: FitnessMealKey | string;
  observation_period: {
    start: string;
    end: string;
    calendar_days: number;
    logged_days: number;
  };
  calculation: {
    observed_average_calories_kcal: number;
    target_average_calories_kcal: number;
    average_gap_calories_kcal: number;
    minimum_material_gap_calories_kcal: number;
    target_days: number;
  };
  frequency: {
    entries: number;
    days: number;
    per_week: number;
  };
  typical_amount: { value: number; unit: string };
  proposed_change: {
    kind: "reduce_portion";
    fraction: number;
    amount: number;
    unit: string;
    resulting_amount: number;
    description: string;
  };
  expected_effect: {
    per_occurrence_calories_kcal: number;
    period_calories_kcal: number;
    weekly_calories_kcal: number;
  };
  uncertainty: {
    nutrient_completeness: number;
    diary_day_completeness: number;
    target_day_coverage: number;
    estimated_entry_share: number;
    estimated_calorie_share?: number | null;
    description: string;
  };
  why_practical: string;
};

export type FitnessNutritionAnalysis = {
  start: string;
  end: string;
  sample_days: number;
  calendar_days: number;
  completeness: number;
  contributors?: FitnessNutritionAnalysisContributor[];
  recommendation?: FitnessNutritionAnalysisRecommendation | null;
};

export type FitnessRecipeComponent = {
  id?: string;
  food_version_id: string;
  food_name?: string | null;
  amount: number;
  unit: string;
  canonical_amount: number;
  canonical_unit: string;
  sequence?: number;
};

export type FitnessRecipeVersion = FitnessRecordBase & {
  recipe_id?: string;
  version_number?: number;
  components: FitnessRecipeComponent[];
  finished_weight_g?: number | null;
  servings?: number | null;
  calories_kcal?: number | null;
  protein_g?: number | null;
  carbohydrate_g?: number | null;
  sugars_g?: number | null;
  fat_g?: number | null;
  saturated_fat_g?: number | null;
  fibre_g?: number | null;
  salt_g?: number | null;
  per_100_g?: Partial<FitnessNutritionNutrients> | null;
  lower_calories_kcal?: number | null;
  upper_calories_kcal?: number | null;
  confidence?: string;
  source_note?: string | null;
};

export type FitnessRecipe = FitnessRecordBase & {
  name: string;
  notes?: string | null;
  household_shared?: boolean;
  favourite?: boolean;
  active?: boolean;
  editable?: boolean;
  current_version?: FitnessRecipeVersion | null;
  latest_version?: FitnessRecipeVersion | null;
  versions?: FitnessRecipeVersion[];
};

export type FitnessHouseholdMealLink = {
  id: string;
  meal_id: string;
  meal_name: string;
  recipe_id: string;
  recipe_version_id: string;
  recipe_name: string;
  linked_at: string;
};

export type FitnessPlannedHouseholdMeal = {
  meal_plan_id: string;
  date: string;
  meal_type: "breakfast" | "lunch" | "dinner";
  meal_id: string;
  meal_name: string;
  link_id: string;
  recipe_id: string;
  recipe_version_id: string;
  recipe_name: string;
  suggested_portion: number;
  suggested_unit: "serving" | "g";
};

export type FitnessPrivatePlannedMealLog = {
  id: string;
  source_meal_plan_id: string;
  household_meal_link_id: string;
  recipe_version_id: string;
  nutrition_date: string;
  meal_type: string;
  logged_at_utc: string;
  portion: number;
  unit: "serving" | "g";
  calories_kcal?: number | null;
  protein_g?: number | null;
};

export type FitnessMealTemplateItem = {
  id?: string;
  food_version_id?: string | null;
  recipe_version_id?: string | null;
  label?: string | null;
  amount: number;
  unit: string;
  canonical_amount: number;
  canonical_unit: string;
  measurement_quality: FitnessNutritionMeasurementQuality | string;
  sequence?: number;
};

export type FitnessMealTemplate = FitnessRecordBase & {
  name: string;
  meal_key: FitnessMealKey | string;
  time_relevance?: string | null;
  favourite?: boolean;
  active?: boolean;
  items: FitnessMealTemplateItem[];
};

export type FitnessNutritionQuickPick = {
  key: string;
  kind: "food" | "template";
  label: string;
  reason: "recent" | "favourite" | "frequent" | "usual" | "time_relevant";
  food_id?: string;
  food_version_id?: string;
  template_id?: string;
  amount?: number | null;
  unit?: string | null;
};

export type FitnessBodyMeasurement = FitnessRecordBase & {
  metric_key: string;
  measured_at_utc: string;
  local_timezone: string;
  value: number;
  unit_key: string;
  measurement_quality?: string;
  canonical_state?: string;
  duplicate_of_measurement_id?: string | null;
  source_record_id?: string | null;
  source?: FitnessExternalSource | null;
  manual_canonical_override?: boolean;
  notes?: string | null;
  canonical?: boolean;
};

export type FitnessCanonicalMeasurementOverride = {
  canonical_measurement_id: string;
  group_member_ids: string[];
  manual_override: boolean;
};

export type FitnessWeightTrend = {
  current_kg?: number | null;
  seven_day_average_kg?: number | null;
  change_kg?: number | null;
  weekly_rate_kg?: number | null;
  points?: Array<{
    date?: string;
    measured_at_utc?: string;
    value_kg: number;
    trend_kg?: number | null;
    seven_reading_average_kg?: number | null;
  }>;
  sample_size?: number;
  sample_count?: number;
};

export type FitnessMeasurementMetric = "weight" | "body_fat" | "blood_pressure";

export type FitnessMeasurementHistoryPoint = {
  id: string;
  measured_at_utc: string;
  raw_value: number;
  trend_value: number;
  source_label?: string | null;
};

export type FitnessMeasurementHistorySeries = {
  key: string;
  label: string;
  unit: string;
  points: FitnessMeasurementHistoryPoint[];
};

export type FitnessMeasurementHistory = {
  metric: FitnessMeasurementMetric;
  title: string;
  unit: string;
  smoothing_method: "time_weighted_exponential" | string;
  smoothing_half_life_days: number;
  series: FitnessMeasurementHistorySeries[];
  sample_count: number;
  last_updated_at?: string | null;
};

export type FitnessWithingsConnectionStatus = {
  configured: boolean;
  connected: boolean;
  status: "not_configured" | "not_connected" | "connected" | "reauth_required" | "provider_down" | "disconnected" | string;
  last_sync_at?: string | null;
  data_through_at?: string | null;
  last_error_code?: string | null;
  webhook_status?: "pending" | "active" | "error" | "disabled" | string | null;
  subscribed_categories: number[];
  imported_measurement_count: number;
};

export type FitnessWithingsSyncResult = {
  status: "synced";
  imported: number;
  updated: number;
  unchanged: number;
  ignored: number;
  data_through_at?: string | null;
};

export type FitnessExternalSource = {
  transport_key: "healthkit" | "garmin_api" | "manual_fit" | "file_import" | "manual" | string;
  origin_provider_key: "apple" | "garmin" | "withings" | "manual" | string;
  source_namespace: string;
  source_device_identifier?: string | null;
  source_name?: string | null;
  product_name?: string | null;
  state?: "active" | "deleted" | "superseded" | string;
};

export type FitnessSleepStage = {
  stage: "awake" | "core" | "deep" | "rem" | "asleep" | "in_bed" | string;
  start_at_utc: string;
  end_at_utc: string;
  duration_s: number;
};

export type FitnessSleepSession = FitnessRecordBase & {
  sleep_start_utc: string;
  sleep_end_utc: string;
  duration_s: number;
  awake_duration_s?: number | null;
  source_quality?: "manual" | "wearable" | "corrected" | "estimated" | string | null;
  source_stages?: FitnessSleepStage[];
  source?: FitnessExternalSource | null;
  notes?: string | null;
};

export type FitnessRecoveryObservation = FitnessRecordBase & {
  metric_key: string;
  observed_at_utc: string;
  value_number?: number | null;
  value_text?: string | null;
  unit_key?: string | null;
  source_quality?: "manual" | "wearable" | "corrected" | "estimated" | string | null;
  source?: FitnessExternalSource | null;
  notes?: string | null;
};

export type FitnessCycleSettings = FitnessRecordBase & {
  owner_user_id?: string | null;
  owner_name?: string | null;
  is_owner?: boolean;
  cycle_length_days: number;
  show_period_starts: boolean;
  show_predicted_period: boolean;
  show_estimated_ovulation: boolean;
  share_period_starts_with_adults: boolean;
  share_predicted_period_with_adults: boolean;
  share_estimated_ovulation_with_adults: boolean;
};

export type FitnessCyclePeriodStart = FitnessRecordBase & {
  owner_user_id?: string | null;
  started_on: string;
};

export type FitnessCycleProfile = FitnessCycleSettings & {
  owner_name: string;
  is_owner: boolean;
  latest_period_start?: string | null;
  predicted_next_period?: string | null;
  estimated_ovulation?: string | null;
  period_starts: FitnessCyclePeriodStart[];
};

export type FitnessSourcePriority = FitnessRecordBase & {
  metric_key: string;
  origin_provider_key: string;
  transport_key?: string | null;
  source_namespace?: string | null;
  priority: number;
};

export type FitnessRecoverySummary = {
  window: {
    from_date: string;
    to_date: string;
    expected_days: number;
    days_with_sleep: number;
  };
  sleep: {
    average_duration_s?: number | null;
    average_bedtime_minutes?: number | null;
    average_wake_time_minutes?: number | null;
    timing_regularity_minutes?: number | null;
  };
  baselines: Array<{
    metric_key: string;
    label: string;
    unit_key?: string | null;
    current_value?: number | null;
    baseline_value?: number | null;
    deviation_absolute?: number | null;
    deviation_percent?: number | null;
    status: "within_baseline" | "above_baseline" | "below_baseline" | "insufficient_data" | string;
    window_days: number;
    observed_at_utc?: string | null;
    source_name?: string | null;
    missing_reason?: string | null;
  }>;
  relationships: Array<{
    label: string;
    summary: string;
    sample_size: number;
    limitation?: string | null;
  }>;
};

export type FitnessProgressPhotoPose = "front" | "side_left" | "side_right" | "back" | "custom";

export type FitnessProgressPhoto = FitnessRecordBase & {
  captured_at: string;
  pose: FitnessProgressPhotoPose;
  body_weight_kg?: number | null;
  measurement_snapshot_json?: Record<string, number | string | null> | null;
  phase_id?: string | null;
  phase_name?: string | null;
  original_asset_id: string;
  thumbnail_asset_id?: string | null;
  original_state?: "pending" | "staged" | "ready" | "missing" | "deleted" | string;
  thumbnail_state?: "pending" | "ready" | "missing" | "regenerating" | "error" | string;
  notes?: string | null;
  metadata_acknowledged?: boolean;
};

export type FitnessPrivateAssetUploadResult = {
  asset_id: string;
  state: "staged" | string;
  storage_class: "private_required" | string;
  upload_acknowledged: boolean;
};

export type FitnessExercise = FitnessRecordBase & {
  seed_key?: string | null;
  name: string;
  aliases?: string[];
  movement_pattern_key?: string | null;
  measurement_mode?: string;
  rep_count_mode?: string;
  load_entry_mode?: string;
  default_unit?: string;
  unilateral_mode?: string;
  equipment_type?: string | null;
  bodyweight_involved?: boolean;
  progression_direction?: "higher" | "lower" | "mixed" | string;
  muscle_roles?: Array<{
    muscle_group_key: string;
    role: string;
    contribution_weight?: number;
  }>;
  favourite?: boolean;
  active?: boolean;
};

export type FitnessExerciseSetup = FitnessRecordBase & {
  exercise_id: string;
  name: string;
  location?: string | null;
  equipment_identifier?: string | null;
  load_entry_mode?: string;
  rep_count_mode?: string;
  unilateral_mode?: string;
  bar_weight_kg?: number | null;
  machine_base_load_kg?: number | null;
  side_multiplier?: number | null;
  is_default?: boolean;
  active?: boolean;
  notes?: string | null;
};

export type FitnessPlannedSession = FitnessRecordBase & {
  sport_key: string;
  title: string;
  status: "proposed" | "accepted" | "scheduled" | "in_progress" | "completed" | "partially_completed" | "skipped" | "cancelled" | string;
  session_source?: "user" | "coach" | "imported" | string;
  scheduled_start_utc?: string | null;
  time_window_start_utc?: string | null;
  time_window_end_utc?: string | null;
  local_timezone?: string;
  scheduled_date?: string | null;
  expected_duration_s?: number | null;
  priority?: number;
  movable?: boolean;
  visibility?: "private" | "logistics_shared" | string;
  shared_title?: string | null;
  training_programme_id?: string | null;
  workout_version_id?: string | null;
  expected_distance_m?: number | null;
  expected_pace_s_per_km?: number | null;
  reason_for_placement?: string | null;
  completion_activity_id?: string | null;
  completion_state?: string | null;
  intended_gear_ids?: string[];
  goal_links?: Array<{ goal_id: string; role: "primary" | "secondary" | "maintenance" | "constraint" }>;
  exercise_items?: Array<{
    id: string;
    exercise_id: string;
    exercise_setup_id?: string | null;
    sequence: number;
    superset_group_key?: string | null;
    substitution_exercise_ids: string[];
    notes?: string | null;
    planned_sets: Array<{
      id: string;
      sequence: number;
      training_role: "warmup" | "working" | "backoff" | "technique" | "test" | "other";
      structure_type: "straight" | "drop" | "rest_pause" | "cluster" | "other";
      component_count: number;
      reps_min?: number | null;
      reps_max?: number | null;
      load_min?: number | null;
      load_max?: number | null;
      load_unit?: string | null;
      rpe_min?: number | null;
      rpe_max?: number | null;
      rir_min?: number | null;
      rir_max?: number | null;
      rest_s?: number | null;
      is_amrap: boolean;
      notes?: string | null;
    }>;
  }>;
};

export type FitnessStravaStatus = {
  configured: boolean;
  connected: boolean;
  status: "not_configured" | "not_connected" | "connected" | "reauth_required" | "provider_down" | "disconnected" | string;
  athlete_name?: string | null;
  last_sync_at?: string | null;
  data_through_at?: string | null;
  imported_activity_count: number;
  last_error_code?: string | null;
};

export type FitnessStravaSync = {
  imported_count: number;
  updated_count: number;
  unchanged_count: number;
  latest_activity?: {
    id: string;
    title: string;
    sport_key: string;
    started_at_utc: string;
    duration_s?: number | null;
    distance_m?: number | null;
  } | null;
  status: FitnessStravaStatus;
};

export type FitnessWorkoutVersion = FitnessRecordBase & {
  title: string;
  purpose?: string | null;
  estimated_duration_s?: number | null;
  estimated_distance_m?: number | null;
  structured_summary?: Record<string, unknown>;
  version_source: "user" | "coach" | "import";
  exercise_items: NonNullable<FitnessPlannedSession["exercise_items"]>;
  run_steps?: FitnessRunWorkoutStep[];
  run_cues?: FitnessRunWorkoutCue[];
  accepted_at?: string | null;
};

export type FitnessWorkoutDefinition = FitnessRecordBase & {
  sport_key: string;
  name: string;
  description?: string | null;
  active: boolean;
  version?: FitnessWorkoutVersion | null;
  current_version?: FitnessWorkoutVersion | null;
  versions?: FitnessWorkoutVersion[];
};

export type FitnessTrainingProgramme = FitnessRecordBase & {
  name: string;
  purpose?: string | null;
  starts_on: string;
  ends_on?: string | null;
  status: "draft" | "active" | "paused" | "completed" | "abandoned";
  phase_id?: string | null;
  programme_source: "user" | "coach" | "import";
  goal_links: Array<{ goal_id: string; role: "primary" | "secondary" | "constraint" }>;
};

export type FitnessRunDurationType = "distance_m" | "time_s" | "lap_button" | "open" | "calories";
export type FitnessRunTargetType = "pace_s_per_km" | "heart_rate_bpm" | "heart_rate_zone" | "power_w" | "power_zone" | "cadence_spm" | "rpe" | "none";

export type FitnessRunWorkoutStep = {
  id: string;
  parent_step_id?: string | null;
  sequence: number;
  step_kind: "step" | "repeat_block";
  repeat_count?: number | null;
  duration_type: FitnessRunDurationType;
  duration_value?: number | null;
  target_type: FitnessRunTargetType;
  target_low?: number | null;
  target_high?: number | null;
  target_unit?: string | null;
  intensity_label?: string | null;
  display_name: string;
  instruction_text?: string | null;
  mental_cue_text?: string | null;
  spoken_cue_text?: string | null;
  allow_manual_advance?: boolean;
  kilometre_index?: number | null;
  notes?: string | null;
  children?: FitnessRunWorkoutStep[];
};

export type FitnessRunWorkoutCue = {
  id: string;
  step_id?: string | null;
  sequence: number;
  trigger_type: "workout_start" | "step_start" | "step_end" | "distance_from_workout_start_m" | "distance_from_step_start_m" | "time_from_workout_start_s" | "time_from_step_start_s" | "halfway" | "final_kilometre" | "manual";
  trigger_value?: number | null;
  short_text: string;
  spoken_text?: string | null;
  priority: number;
};

export type FitnessImportStatus = "queued" | "uploading" | "processing" | "complete" | "error";

export type FitnessImportResult = {
  id: string;
  status: FitnessImportStatus;
  activity_id?: string | null;
  file_name?: string | null;
  error?: string | null;
  retryable?: boolean;
  source_retained: boolean;
  source_record_id?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type FitnessGearItem = FitnessRecordBase & {
  gear_type_key: "running_shoe" | "walking_shoe" | "bike" | "rowing_shell" | "wearable" | "other" | string;
  name: string;
  brand?: string | null;
  model?: string | null;
  variant?: string | null;
  started_at?: string | null;
  retired_at?: string | null;
  initial_usage_distance_m?: number | null;
  default_for_sport_key?: string | null;
  notes?: string | null;
  active?: boolean;
  activity_count?: number;
  usage_distance_m?: number;
  usage_duration_s?: number;
};

export type FitnessActivityMetric = {
  metric_key: string;
  label?: string | null;
  value_number?: number | null;
  value_text?: string | null;
  value_bool?: boolean | null;
  unit_key?: string | null;
  origin?: "source" | "derived" | "user" | string;
  quality?: string | null;
};

export type FitnessActivitySportDefinition = {
  key: string;
  display_name: string;
  family?: string;
  distance_meaningful?: boolean;
  planner_type?: string;
  default_panels?: string[];
};

export type FitnessActivityRegistry = {
  sports: FitnessActivitySportDefinition[];
  metrics: Array<{
    key: string;
    display_name: string;
    canonical_unit?: string | null;
  }>;
};

export type FitnessActivityInterval = {
  id: string;
  parent_interval_id?: string | null;
  sequence: number;
  interval_kind: string;
  origin?: string | null;
  start_offset_ms: number;
  end_offset_ms: number;
  start_distance_m?: number | null;
  end_distance_m?: number | null;
  label?: string | null;
  metrics?: Record<string, number | string | null>;
  metrics_json?: Record<string, number | string | null>;
};

export type FitnessDataQualityFinding = {
  id?: string;
  key: string;
  severity: "info" | "warning" | "error" | string;
  message: string;
  start_offset_ms?: number | null;
  end_offset_ms?: number | null;
  limits_analysis_keys?: string[];
};

export type FitnessActivitySummary = FitnessRecordBase & {
  title: string;
  sport_key: string;
  started_at_utc: string;
  local_timezone?: string | null;
  planned_session_id?: string | null;
  planned_session_title?: string | null;
  status?: "importing" | "complete" | "error" | "regenerating" | string;
  workout_classification?: string | null;
  phase_id?: string | null;
  phase_name?: string | null;
  distance_m?: number | null;
  duration_s?: number | null;
  elapsed_duration_s?: number | null;
  timer_duration_s?: number | null;
  moving_duration_s?: number | null;
  energy_kcal?: number | null;
  energy_estimation_method?: string | null;
  energy_estimation_weight_kg?: number | null;
  energy_estimation_weight_measured_at_utc?: string | null;
  energy_estimation_met?: number | null;
  notes?: string | null;
  route_preview?: Array<[number, number]> | null;
  primary_metrics?: FitnessActivityMetric[];
  gear?: FitnessGearItem[];
  strength_summary?: {
    exercise_count: number;
    set_count: number;
    working_set_count: number;
    failure_set_count: number;
    volume_kg: number;
  } | null;
  import_error?: string | null;
};

export type FitnessManualActivityInput = {
  id?: string;
  sport_key: string;
  title?: string | null;
  started_at_utc: string;
  local_timezone: string;
  duration_s: number;
  distance_m?: number | null;
  session_rpe?: number | null;
  workout_classification?: string | null;
  notes?: string | null;
  estimate_energy: boolean;
};

export type FitnessManualActivityDefaults = {
  latest_weight_kg: number | null;
  latest_weight_measured_at_utc: string | null;
  energy_estimation_method: "adult_compendium_2024_met" | string;
};

export type FitnessActivitySource = {
  id: string;
  source_type: string;
  provider?: string | null;
  device_name?: string | null;
  status?: string | null;
  attached_at?: string | null;
  is_primary?: boolean;
  data_quality?: string | null;
};

export type FitnessActivityRecord = {
  id: string;
  record_key: string;
  label: string;
  value: string;
  achieved_at_offset_ms?: number | null;
  is_personal_best?: boolean;
};

export type FitnessAnalysisFinding = {
  key: string;
  title: string;
  summary: string;
  status?: "valid" | "limited" | "unavailable" | string;
  value?: number | string | null;
  unit_key?: string | null;
  quality?: string | null;
  confidence?: number | null;
  calculation_version?: string | null;
  evidence?: Array<{
    label: string;
    value: string;
    interval_id?: string | null;
    activity_id?: string | null;
  }>;
};

export type FitnessComparableRun = {
  activity: FitnessActivitySummary;
  score: number;
  reasons: string[];
  component_scores?: Record<string, number | null>;
  selected?: boolean;
  is_previous_similar_distance?: boolean;
  automatic_comparison?: {
    algorithm_version: string;
    distance_label: string;
    current_distance_m: number;
    previous_distance_m: number;
    distance_delta_m: number;
    current_duration_s: number;
    previous_duration_s: number;
    duration_delta_s: number;
    duration_improvement_s: number;
    current_pace_s_per_km: number;
    previous_pace_s_per_km: number;
    pace_delta_s_per_km: number;
    pace_improvement_s_per_km: number;
  };
};

export type FitnessPlanAdherence = {
  status?: "complete" | "partial" | "unavailable" | string;
  completed_distance_m?: number | null;
  planned_distance_m?: number | null;
  completed_duration_s?: number | null;
  planned_duration_s?: number | null;
  time_in_target_s?: number | null;
  target_time_s?: number | null;
  explanation?: string | null;
  steps?: Array<{
    id: string;
    label: string;
    state: "completed" | "partial" | "skipped" | "extended" | string;
    actual: string;
    planned: string;
    target_adherence_pct?: number | null;
  }>;
};

export type FitnessActivityDetail = {
  activity: FitnessActivitySummary;
  sources: FitnessActivitySource[];
  summary_metrics: FitnessActivityMetric[];
  available_stream_metrics: string[];
  recommended_panels?: string[];
  intervals: FitnessActivityInterval[];
  records?: FitnessActivityRecord[];
  achievements?: FitnessActivityRecord[];
  notes?: string | null;
  session_rpe?: number | null;
  planned_session?: FitnessPlannedSession | null;
  checkins?: FitnessSessionCheckin[];
  body_issues?: FitnessBodyIssue[];
  gear?: FitnessGearItem[];
  goal_links?: FitnessActivityGoalLink[];
  data_quality?: FitnessDataQualityFinding[];
  adherence?: FitnessPlanAdherence | null;
};

export type FitnessActivityGoalLink = FitnessRecordBase & {
  activity_id: string;
  goal_id: string;
  role: "planned" | "user_assigned" | "inferred_reviewed";
};

export type FitnessActivityStream = {
  activity_id: string;
  clock: "elapsed" | "timer";
  offset_ms: number[];
  distance_m?: Array<number | null>;
  series: Record<string, Array<number | null>>;
  units: Record<string, string>;
  downsampled: boolean;
  source_point_count?: number | null;
  requested_range?: { from_offset_ms: number; to_offset_ms: number } | null;
};

export type FitnessPrivateMapAvailability = {
  available: boolean;
  format?: "png" | "jpg" | "webp" | "pbf" | null;
  min_zoom?: number | null;
  max_zoom?: number | null;
  bounds?: [number, number, number, number] | null;
  style_url?: string | null;
  tilejson_url?: string | null;
  has_sprites?: boolean | null;
  has_glyphs?: boolean | null;
};

export type FitnessCalendarLayerItem = {
  id: string;
  owner_user_id: string;
  layer_kind: "planned" | "completed";
  display_title: string;
  sport_key: string;
  status: string;
  scheduled_start_utc?: string | null;
  scheduled_date?: string | null;
  time_window_start_utc?: string | null;
  time_window_end_utc?: string | null;
  duration_s?: number | null;
  detail_id: string;
};

export type FitnessAnalysisClassification = "descriptive" | "correlational" | "plan_arithmetic";
export type FitnessAnalysisChartType =
  | "line"
  | "rolling_average"
  | "bar"
  | "stacked_bar"
  | "scatter"
  | "histogram"
  | "calendar_heatmap"
  | "range_band"
  | "table";

export type FitnessAnalysisFilterValue = string | number | boolean;

export type FitnessAnalysisFilterDefinition = {
  key: string;
  label: string;
  value_type: "string" | "number" | "boolean" | "date" | "registered_key";
  operators: Array<"eq" | "not_eq" | "in" | "gte" | "lte" | "between">;
  values?: Array<{ key: string; label: string }>;
  max_values?: number;
};

export type FitnessAnalysisRegistry = {
  dimensions: Array<{
    key: string;
    label: string;
    value_type: "date" | "category" | "number" | string;
    description?: string | null;
  }>;
  measures: Array<{
    key: string;
    label: string;
    description?: string | null;
    unit_key?: string | null;
    supported_dimensions: string[];
    chart_types: FitnessAnalysisChartType[];
    allowed_filter_keys: string[];
    comparison_forms?: string[];
    default_chart_type?: FitnessAnalysisChartType;
    classification: FitnessAnalysisClassification;
    minimum_sample_size?: number;
  }>;
  chart_types: Array<{ key: FitnessAnalysisChartType; label: string }>;
  filters: FitnessAnalysisFilterDefinition[];
  comparisons: Array<{ key: string; label: string; description?: string | null }>;
  limits: {
    max_window_days: number;
    max_output_points: number;
    max_filters: number;
    heavy_poll_interval_ms?: number;
  };
  default_queries: Array<{
    key: string;
    label: string;
    description?: string | null;
    dimension_key: string;
    measure_key: string;
    chart_type_key: FitnessAnalysisChartType;
    date_window_days: number;
    filters?: FitnessAnalysisFilter[];
    comparison_key?: string | null;
    surface?: "explore" | "progress" | "both";
    category?: "nutrition" | "body" | "recovery" | "running" | "strength" | "issues" | "gear" | "goals" | string;
  }>;
};

export type FitnessAnalysisFilter = {
  key: string;
  operator: "eq" | "not_eq" | "in" | "gte" | "lte" | "between";
  value: FitnessAnalysisFilterValue | FitnessAnalysisFilterValue[];
};

export type FitnessAnalysisQuery = {
  measure_key: string;
  dimension_key: string;
  chart_type_key: FitnessAnalysisChartType;
  date_range: { start: string; end: string };
  filters: FitnessAnalysisFilter[];
  comparison_key: string | null;
  max_points: number;
};

export type FitnessAnalysisPoint = {
  key: string;
  label: string;
  x?: string | number | null;
  x_value?: number | null;
  value?: number | null;
  low?: number | null;
  high?: number | null;
  sample_size?: number | null;
  missing_rate?: number | null;
  quality?: string | null;
};

export type FitnessAnalysisSeries = {
  key: string;
  label: string;
  unit_key?: string | null;
  points: FitnessAnalysisPoint[];
};

export type FitnessAnalysisMetadata = {
  period: { start: string; end: string; label?: string | null };
  sample_size: number;
  missing_count?: number | null;
  missing_rate: number;
  source_quality: string[];
  measurement_quality: string[];
  canonical_policy: string;
  duplicate_policy: string;
  classification: FitnessAnalysisClassification;
};

export type FitnessAnalysisQueryResult = {
  id?: string | null;
  status: "complete" | "queued" | "processing" | "empty" | "insufficient_sample" | "error";
  job_id?: string | null;
  poll_after_ms?: number | null;
  title: string;
  description?: string | null;
  dimension_key: string;
  measure_key: string;
  chart_type_key: FitnessAnalysisChartType;
  unit_key?: string | null;
  series: FitnessAnalysisSeries[];
  metadata: FitnessAnalysisMetadata;
  summary?: string | null;
  difference?: { value: number; unit_key?: string | null; label: string } | null;
  limitations: string[];
};

export type FitnessSavedChartDefinition = FitnessRecordBase & {
  name: string;
  measure_key: string;
  dimension_key: string;
  chart_type_key: FitnessAnalysisChartType;
  filter_keys: string[];
  comparison_key?: string | null;
  date_window_days: number;
};

export type FitnessCoachIntent = "discussion" | "morning" | "post_workout" | "evening" | "weekly" | "run_plan" | "strength_plan";

export type FitnessCoachStatus = {
  status: "available" | "unavailable";
  provider?: string | null;
  model?: string | null;
  message?: string | null;
  intents?: FitnessCoachIntent[];
};

export type FitnessCoachPreferences = {
  personality_preset: "scientific_hard_driving" | "balanced_supportive" | "calm_encouraging" | "custom";
  directness: 1 | 2 | 3 | 4 | 5;
  challenge_bias: "conservative" | "balanced" | "ambitious";
  detail_level: "brief" | "standard" | "detailed";
  custom_instruction: string | null;
  coach_memory_enabled?: boolean;
  updated_at?: string | null;
};

export type FitnessCoachMemorySettings = {
  enabled: boolean;
  enabled_at?: string | null;
};

export type FitnessCoachMemoryCandidate = {
  category?: string | null;
  content: string;
};

export type FitnessCoachMemory = FitnessRecordBase & {
  category?: string | null;
  content: string;
  confirmed_at?: string | null;
};

export type FitnessCoachConversationSummary = {
  id: string;
  title?: string | null;
  preview?: string | null;
  message_count?: number;
  created_at?: string | null;
  updated_at?: string | null;
  last_message_at?: string | null;
  revision?: number;
};

export type FitnessCoachConversationMessage = {
  id: string;
  conversation_id?: string;
  sequence?: number;
  role: "user" | "assistant";
  content: string;
  intent?: FitnessCoachIntent | null;
  evidence?: FitnessCoachEvidence[];
  recommendation?: FitnessCoachRecommendation | null;
  proposal?: FitnessCoachProposal | null;
  created_at?: string | null;
};

export type FitnessCoachConversation = FitnessCoachConversationSummary & {
  messages: FitnessCoachConversationMessage[];
};

export type FitnessCoachMemoryClearResponse = {
  conversations: number;
  messages: number;
  memories: number;
};

export type FitnessCoachHistoryTurn = {
  role: "user" | "assistant";
  content: string;
};

export type FitnessCoachEvidence = {
  id: string;
  kind: string;
  label: string;
  summary: string;
  period?: { start: string; end: string } | null;
  sample_size?: number | null;
  completeness?: number | null;
  source_ids?: string[];
};

export type FitnessCoachProposalKind =
  | "run_workout"
  | "strength_workout"
  | "training_week"
  | "nutrition_change"
  | "goal_adjustment"
  | "calendar_change"
  | "family_calendar_event"
  | "planned_meal_log"
  | "shopping_list"
  | "family_task"
  | "fitness_reminder"
  | "chart";

export type FitnessCoachProposalPreview = {
  change: string[];
  visibility: "Private to you" | "Visible to your family";
};

export type FitnessCoachValidationIssue = {
  code?: string | null;
  path?: string | null;
  message: string;
};

export type FitnessCoachProposal = {
  id: string;
  kind: FitnessCoachProposalKind;
  payload: Record<string, unknown>;
  preview?: FitnessCoachProposalPreview | null;
  validation: {
    valid: boolean;
    issues: FitnessCoachValidationIssue[];
  };
  warnings: Array<string | { code?: string | null; message: string }>;
  confirmable: boolean;
  review_only_reason?: string | null;
  expires_at: string;
};

export type FitnessCoachMessageResponse = {
  status: "complete" | "unavailable";
  answer: string;
  evidence: FitnessCoachEvidence[];
  recommendation?: FitnessCoachRecommendation | null;
  proposal?: FitnessCoachProposal | null;
  conversation_id?: string | null;
  memory_candidates?: FitnessCoachMemoryCandidate[];
};

export type FitnessCoachProposalDecision = {
  status: "confirmed" | "declined" | "expired" | "invalid";
  message: string;
  result_ids?: string[];
  next_destinations: FitnessCoachProposalDestination[];
};

export type FitnessCoachProposalDestination = {
  kind:
    | "planned_session"
    | "nutrition_target"
    | "meal_template"
    | "goal"
    | "analysis_chart"
    | "calendar_event"
    | "food_log"
    | "shopping"
    | "task"
    | "fitness_reminder";
  target: string;
  label: string;
};

export type FitnessCoachContextPreferences = {
  family_calendar: boolean;
  household_meals: boolean;
  weather: boolean;
};

export type FitnessCoachReminder = {
  id: string;
  title: string;
  remind_at_utc: string;
  notes?: string | null;
  planned_session_id?: string | null;
  status: "active" | "completed";
};

export type FitnessCoachProposalUndo = {
  status: "undone" | "already_undone" | "conflict" | "invalid";
  message: string;
  affected_ids: string[];
};

export type FitnessCoachFeedback =
  | "accepted"
  | "rejected"
  | "tried_worked"
  | "tried_too_hard"
  | "tried_too_hungry"
  | "unavailable"
  | "disliked"
  | "analysis_inaccurate"
  | "other";

export type FitnessCoachRecommendation = FitnessRecordBase & {
  recommendation_type: string;
  recommendation_text: string;
  evidence?: FitnessCoachEvidence[];
  finding_references?: string[];
  expected_effect?: string | Record<string, unknown> | null;
  status: string;
  user_feedback?: FitnessCoachFeedback | null;
  followed_state?: string | null;
  outcome_review?: string | null;
  model_provider?: string | null;
  model_id?: string | null;
};

export type FitnessGarminExport = {
  id: string;
  workout_version_id: string;
  status: "queued" | "generating" | "ready" | "error" | string;
  file_name?: string | null;
  last_error?: string | null;
  mapping_report?: Array<{
    field: string;
    status: "exported" | "shortened" | "omitted" | "approximated" | string;
    detail: string;
  }>;
};

export type FitnessIntervalsConnectionStatus = {
  configured: boolean;
  oauth_available: boolean;
  personal_api_key_available: boolean;
  connected: boolean;
  status: "not_configured" | "not_connected" | "connected" | "reauth_required" | "provider_down" | "disconnected" | string;
  auth_method: "oauth" | "personal_api_key" | null;
  oauth_scopes: string[];
  athlete_id?: string | null;
  athlete_name?: string | null;
  garmin_training_connected: boolean | null;
  last_tested_at?: string | null;
  last_error_code?: string | null;
  activity_read_authorized: boolean;
  activity_import_enabled: boolean;
  activity_import_since?: string | null;
  last_activity_import_at?: string | null;
  last_activity_import_error_code?: string | null;
  activity_imported_count: number;
  activity_import_pending_count: number;
  activity_import_error_count: number;
};

export type FitnessIntervalsActivityImportSync = {
  discovered_count: number;
  queued_count: number;
  existing_count: number;
  skipped_count: number;
  status: FitnessIntervalsConnectionStatus;
};

export type FitnessIntervalsWorkoutDelivery = {
  planned_session_id: string;
  state: "not_sent" | "pending" | "sent" | "cancelled" | "error" | string;
  operation: "none" | "created" | "updated" | "retried" | "unchanged" | "cancelled" | string;
  external_id?: string | null;
  provider_event_id?: string | null;
  sent_at?: string | null;
  last_error_code?: string | null;
  push_errors: string[];
};

export type FitnessSessionCheckin = FitnessRecordBase & {
  planned_session_id?: string | null;
  activity_id?: string | null;
  captured_at_utc: string;
  timing: "pre" | "post";
  capture_quality: "contemporaneous" | "retrospective";
  captured_before_activity_start?: boolean | null;
  readiness_1_5?: number | null;
  energy_1_5?: number | null;
  soreness_1_5?: number | null;
  motivation_1_5?: number | null;
  session_rpe_1_10?: number | null;
  notes?: string | null;
};

export type FitnessBodyIssue = FitnessRecordBase & {
  planned_session_id?: string | null;
  activity_id?: string | null;
  session_exercise_id?: string | null;
  set_group_id?: string | null;
  checkin_id?: string | null;
  observed_at_utc: string;
  issue_type_key: "pain" | "tightness" | "discomfort" | "weakness" | "injury" | "other";
  body_location_key: string;
  side?: "left" | "right" | "bilateral" | "midline" | "not_applicable" | "unknown";
  severity_0_10: number;
  timing: "pre" | "during" | "post" | "next_day" | "standalone";
  changed_session: boolean;
  session_change_key: "none" | "reduced_load" | "reduced_range" | "reduced_pace" | "substituted" | "stopped" | "prevented_start" | "other";
  trend_key?: "new" | "existing_same" | "worse" | "better" | "unknown";
  status?: "active" | "resolved" | "unknown";
  resolved_at_utc?: string | null;
  notes?: string | null;
};

export type FitnessBodyLocation = FitnessRecordBase & {
  location_key: string;
  parent_key?: string | null;
  display_name: string;
  active: boolean;
};

export type FitnessStrengthSetComponent = FitnessRecordBase & {
  set_group_id: string;
  component_index: number;
  component_status: "completed" | "partial" | "skipped";
  reps?: number | null;
  reps_left?: number | null;
  reps_right?: number | null;
  load_value?: number | null;
  load_unit?: string | null;
  load_entry_mode_snapshot?: string | null;
  normalized_external_load_kg?: number | null;
  added_load_kg?: number | null;
  assistance_kg?: number | null;
  bodyweight_kg_snapshot?: number | null;
  duration_s?: number | null;
  distance_m?: number | null;
  rir?: number | null;
  rpe?: number | null;
  rest_before_s?: number | null;
  tempo_text?: string | null;
  notes?: string | null;
  extra_metrics?: Record<string, number | string | boolean | null>;
  extra_metrics_json?: Record<string, number | string | boolean | null>;
  completed_at_utc?: string | null;
};

export type FitnessStrengthComparisonKey = {
  exercise_id: string;
  setup_id: string;
  load_entry_mode: string;
  rep_count_mode: string;
  unilateral_mode: string;
};

export type FitnessStrengthSetGroup = FitnessRecordBase & {
  activity_id: string;
  session_exercise_id: string;
  planned_set_id?: string | null;
  sequence: number;
  training_role: "warmup" | "working" | "backoff" | "technique" | "test" | "other";
  structure_type: "straight" | "drop" | "rest_pause" | "cluster" | "other";
  status: "planned" | "in_progress" | "completed" | "partial" | "skipped" | "aborted";
  is_amrap?: boolean;
  failure_state?: "none" | "technical" | "muscular" | "stopped_for_body_issue" | "unknown";
  started_at_utc?: string | null;
  completed_at_utc?: string | null;
  notes?: string | null;
  source_setup_label?: string | null;
  comparison_key?: FitnessStrengthComparisonKey;
  components?: FitnessStrengthSetComponent[];
};

export type FitnessStrengthSessionExercise = FitnessRecordBase & {
  activity_id: string;
  exercise_id: string;
  exercise_setup_id?: string | null;
  exercise_setup_name_snapshot?: string | null;
  load_entry_mode_snapshot?: string | null;
  rep_count_mode_snapshot?: string | null;
  unilateral_mode_snapshot?: string | null;
  source_setup_label?: string | null;
  planned_exercise_id?: string | null;
  exercise_name?: string;
  exercise?: FitnessExercise;
  setup?: FitnessExerciseSetup;
  sequence: number;
  superset_group_key?: string | null;
  variation_note?: string | null;
  notes?: string | null;
  set_groups?: FitnessStrengthSetGroup[];
};

export type FitnessStrengthSession = FitnessRecordBase & {
  title: string;
  planned_session_id?: string | null;
  status: "in_progress" | "completed" | "partial" | "aborted";
  started_at_utc: string;
  local_timezone: string;
  ended_at_utc?: string | null;
  rest_timer_deadline_utc?: string | null;
  session_rpe?: number | null;
  perceived_performance?: number | null;
  matched_plan_key?: string | null;
  notes?: string | null;
  exercises?: FitnessStrengthSessionExercise[];
};

export type FitnessExerciseMergePreview = {
  source_id: string;
  target_id: string;
  already_merged: boolean;
  planned_exercises: number;
  session_exercises: number;
  moved_setups: number;
};

export type FitnessExerciseSetupMergePreview = {
  source_id: string;
  target_id: string;
  already_merged: boolean;
  planned_exercises: number;
  session_exercises: number;
};

export type FitnessStrengthObservedSet = FitnessStrengthSetComponent & {
  activity_id: string;
  activity_title: string;
  started_at_utc: string;
  group_id: string;
  setup_id: string;
  source_setup_label?: string | null;
  comparison_key: FitnessStrengthComparisonKey;
  structure_type: FitnessStrengthSetGroup["structure_type"];
  training_role: FitnessStrengthSetGroup["training_role"];
  failure_state: FitnessStrengthSetGroup["failure_state"];
};

export type FitnessStrengthRecentEvidence = {
  group_id: string;
  activity_id: string;
  activity_title: string;
  performed_at: string;
  source_setup_label: string;
  training_role: FitnessStrengthSetGroup["training_role"];
  failure_state: FitnessStrengthSetGroup["failure_state"];
  components: Array<{
    component_index: number;
    reps: number | null;
    reps_left: number | null;
    reps_right: number | null;
    load_kg: number | null;
    rpe: number | null;
    rir: number | null;
  }>;
};

export type FitnessStrengthSuggestion = {
  planned_exercise_id: string | null;
  exercise_id: string;
  exercise_name: string;
  exercise_setup_id: string;
  setup_name: string;
  original_exercise_id: string;
  sequence: number;
  included_in_time_budget: boolean;
  estimated_minutes: number;
  progression: {
    action: "increase_load" | "hold_load" | "hold_or_reduce" | "insufficient_context";
    reason: string;
    evidence_group_ids: string[];
    missing_context: string[];
  };
  recent_evidence: FitnessStrengthRecentEvidence[];
  active_body_issues: FitnessBodyIssue[];
  reasons: string[];
};

export type FitnessStrengthSuggestionsResponse = {
  generated_at: string;
  planned_session: {
    id: string;
    title: string;
    status: string;
    expected_duration_s: number | null;
  } | null;
  session_candidate: {
    kind: "planned_strength_session";
    exercise_ids: string[];
    estimated_minutes: number;
    reason: string;
  };
  exercise_candidates: FitnessStrengthSuggestion[];
  recent_running_load: {
    window_days: number;
    session_count: number;
    distance_m: number;
    duration_s: number;
    latest_at: string | null;
  };
  active_body_issues: FitnessBodyIssue[];
  missing_context: string[];
};

export type FitnessStrengthExerciseProgress = {
  exercise: FitnessExercise;
  redirect?: { source_id: string; target_id: string } | null;
  logical_set_groups: Array<FitnessStrengthSetGroup & {
    activity_title?: string;
    summary?: {
      working_sets?: number;
      hard_sets?: number;
      unknown_hardness_sets?: number;
      primary_volume_kg_reps?: number;
    };
  }>;
  observed_sets: FitnessStrengthObservedSet[];
  records: {
    heaviest?: FitnessStrengthObservedSet | null;
    best_by_rep_band?: Record<string, FitnessStrengthObservedSet | null>;
  };
  estimated_1rm: Array<{ estimated_1rm_kg: number; source_set: FitnessStrengthObservedSet }>;
};

export type FitnessStrengthMuscleSummary = {
  muscle_group_key: string;
  direct_working_sets: number;
  indirect_set_equivalents: number;
  direct_hard_sets: number;
  unknown_hardness_sets: number;
  frequency_days: number;
  days_since_last_trained: number;
  last_trained_at?: string | null;
  contributing_exercise_ids: string[];
  planned_working_sets?: number | null;
};

export type FitnessNextActionVerb =
  | "open_body_issue"
  | "record_readiness"
  | "open_recovery"
  | "open_coach"
  | "open_planned_session"
  | "open_today";

export type FitnessNextActionLink = {
  kind: FitnessNextActionVerb;
  target: string;
  label: string;
};

export type FitnessNextAction = {
  title: string;
  body: string;
  urgency: "routine" | "attention" | "urgent";
  evidence: Array<{
    id: string;
    kind: string;
    label: string;
    summary: string;
  }>;
  action: FitnessNextActionLink;
  secondary_action: FitnessNextActionLink | null;
  expires_at: string;
  source: string;
};

export type FitnessToday = {
  date?: string;
  settings?: FitnessNutritionSettings | null;
  active_phase?: FitnessPhase | null;
  active_goals?: FitnessGoal[];
  goals?: FitnessGoal[];
  planned_session?: FitnessPlannedSession | null;
  planned_sessions?: FitnessPlannedSession[];
  active_strength_session?: FitnessStrengthSession | null;
  nutrition?: {
    calories_kcal?: number | null;
    calorie_target_kcal?: number | null;
    protein_g?: number | null;
    protein_target_g?: number | null;
  } | null;
  weight_trend?: FitnessWeightTrend | null;
  recovery?: {
    sleep_hours?: number | null;
    readiness?: number | null;
    summary?: string | null;
  } | null;
  next_action?: FitnessNextAction | null;
  recommendation?: { id?: string; title?: string; message?: string } | string | null;
};

export type FitnessProgress = {
  active_goals?: FitnessGoal[];
  completed_goals?: FitnessGoal[];
  active_phase?: FitnessPhase | null;
  weight?: FitnessWeightTrend | null;
  recent_strength_sessions?: FitnessStrengthSession[];
  goals?: FitnessGoal[];
  weight_trend?: FitnessWeightTrend | null;
  recent_sessions?: FitnessStrengthSession[];
  exercise_progress?: Array<{
    exercise_id: string;
    exercise_name: string;
    latest_performance?: string | null;
    trend?: string | null;
  }>;
  muscle_groups?: Array<{ key: string; name: string; hard_sets: number } | FitnessStrengthMuscleSummary>;
};

export type FitnessSyncMutation = {
  mutation_id: string;
  entity_type: FitnessEntityType;
  entity_id: string;
  operation: FitnessMutationOperation;
  payload_schema_version: number;
  base_revision: number | null;
  payload: Record<string, unknown>;
  created_at_client: string;
};

export type FitnessSyncRedirect = {
  entity_type: FitnessEntityType | string;
  source_id: string;
  target_id: string;
};

export type FitnessSyncChange = {
  sequence?: number;
  entity_type: FitnessEntityType | string;
  entity_id: string;
  revision?: number;
  operation: FitnessMutationOperation;
  data?: Record<string, unknown> | null;
};

export type FitnessSyncNotice = {
  id: string;
  entity_type?: string;
  entity_id?: string;
  message: string;
  created_at?: string;
  [key: string]: unknown;
};

export type FitnessSyncResponse = {
  status: "ok" | "full_snapshot_required";
  current_sync_protocol_version: number;
  current_client_schema_version: number;
  minimum_supported_client_schema_version: number;
  accepted: Array<{ mutation_id: string; entity_id: string; revision: number }>;
  acked_mutation_ids?: string[];
  rejected_mutations?: Array<{ mutation_id: string; code: string; message: string }>;
  notices: FitnessSyncNotice[];
  redirects: FitnessSyncRedirect[];
  changes: FitnessSyncChange[];
  next_cursor: number;
  snapshot_url?: string | null;
  message?: string | null;
};

export type FitnessSnapshotEntity = {
  entity_type: FitnessEntityType | string;
  entity_id: string;
  revision: number;
  data: Record<string, unknown>;
};

export type FitnessSnapshotResponse = {
  status: "ok";
  current_sync_protocol_version: number;
  current_client_schema_version: number;
  minimum_supported_client_schema_version: number;
  generated_at: string;
  entities: FitnessSnapshotEntity[];
  redirects: FitnessSyncRedirect[];
  next_cursor: number;
};

export type FitnessSyncCapabilities = {
  current_sync_protocol_version: number;
  supported_sync_protocol_versions: number[];
  minimum_supported_client_schema_version: number;
  current_client_schema_version: number;
  supported_payload_schema_versions_by_entity: Record<string, number[]>;
};

export function asFitnessArray<T>(value: T[] | { items?: T[]; results?: T[]; entries?: T[] } | null | undefined): T[] {
  if (Array.isArray(value)) return value;
  return value?.items ?? value?.results ?? value?.entries ?? [];
}

export function fitnessRecordLabel(entityType: FitnessEntityType): string {
  const labels: Record<FitnessEntityType, string> = {
    source_record: "source record",
    nutrition_settings: "nutrition settings",
    goal: "goal",
    goal_relationship: "goal relationship",
    training_phase: "training phase",
    workout_definition: "workout template",
    training_programme: "training programme",
    food: "food",
    food_version: "food version",
    food_serving: "food serving",
    food_log_entry: "food log entry",
    recipe: "recipe",
    recipe_version: "recipe version",
    meal_template: "meal template",
    nutrition_target: "nutrition target",
    body_measurement: "body measurement",
    sleep_session: "sleep session",
    recovery_observation: "recovery observation",
    cycle_settings: "cycle settings",
    cycle_period_start: "period start",
    source_priority: "source priority",
    exercise: "exercise",
    exercise_setup: "exercise setup",
    planned_session: "planned session",
    session_checkin: "readiness check-in",
    body_issue: "body issue",
    gear: "gear item",
    manual_activity: "manual activity",
    activity_context: "activity context",
    activity_gear_link: "activity gear link",
    activity_goal_link: "activity goal link",
    progress_photo: "progress photo",
    strength_session: "strength session",
    strength_session_exercise: "session exercise",
    strength_set_group: "set",
    strength_set_component: "set result",
  };
  return labels[entityType];
}
