export type User = {
  id: string;
  name: string;
  email: string;
  role: string;
  priority: number;
  family_id: string | null;
  must_change_password?: boolean;
  avatar_url?: string | null;
};

export type OnboardingModule = "children" | "medicine_sleep" | "dog" | "home" | "fitness" | "finance";

export type OnboardingStatus = {
  family_name: string;
  people_count: number;
  adult_count: number;
  child_count: number;
  calendar_commitment_count: number;
  reminders_configured: boolean;
  selected_modules: OnboardingModule[];
  dismissed: boolean;
  completed: boolean;
  should_show: boolean;
  first_success: boolean;
};

export type FamilyInvite = {
  invite_code: string;
  expires_at: string;
  join_url: string;
};

export type FinanceSpace = {
  id: string;
  kind: "personal" | "household";
  name: string;
  is_default: boolean;
};

export type FinanceSettings = {
  id: string;
  household_timezone: string;
  default_currency: string;
  personal_space_id: string;
  household_space_id: string;
  created_at: string;
  updated_at: string;
};

export type FinanceAIConsent = {
  space_id: string;
  space_kind: "personal" | "household";
  consented: boolean;
  consent_version: string;
  consented_at: string | null;
  provider: "off" | "openai" | "hermes";
  model: string;
  store: false;
  background_processing: false;
  disclosure: string;
};

export type FinanceAnswerClaim = {
  text: string;
  evidence_ids: string[];
};

export type FinanceAnswerEstimate = {
  text: string;
  assumptions: string[];
  low_minor: number | null;
  high_minor: number | null;
  currency: string | null;
};

export type FinanceCoachAnswer = {
  kind: "analysis" | "answer" | "partial";
  headline: string;
  answer: string;
  answer_mode: "CURRENT_EXACT" | "DATED_EXACT" | "ESTIMATE" | "PARTIAL";
  data_through: string | null;
  claims: FinanceAnswerClaim[];
  estimates: FinanceAnswerEstimate[];
  suggested_actions: string[];
  analysis_view_id: string | null;
  questions: string[];
  draft?: {
    kind: string;
    title: string;
    summary: string;
    fields?: Array<{ label: string; value: string }>;
  } | null;
};

export type FinanceCaptureTurn = { role: "user" | "assistant"; text: string };
export type FinanceCaptureTargetOption = {
  id: string;
  kind: "TRANSACTION" | "PURCHASE" | "PURCHASE_LINE" | "ACCOUNT" | "PURCHASE_ONLY" | "ADULT";
  label: string;
  date: string | null;
  amount_minor: number | null;
  currency: string | null;
};
export type FinanceCaptureDraft = {
  id: string;
  space_id: string;
  title: string;
  content: Record<string, unknown> & { kind: string; uncertainties?: string[] };
  target_options: FinanceCaptureTargetOption[];
  category_options: string[];
  expires_at: string;
};
export type FinanceCaptureInterpretResponse = {
  mode: "REVIEW" | "ANSWER" | "CLARIFY";
  drafts: FinanceCaptureDraft[];
  answer: FinanceCoachAnswer | null;
  message: string | null;
  conversation_persisted: false;
};
export type FinanceCaptureConfirmResponse = {
  draft_id: string;
  status: "CONFIRMED";
  action_kind: string;
  action_id: string;
  result: Record<string, unknown>;
};

export type FinanceShare = {
  id: string;
  kind: string;
  status: "ACTIVE" | "COMPLETED" | "STOPPED";
  applies_to_future: boolean;
  shared_record_type?: string | null;
  shared_record_id?: string | null;
  rule_target?: "TRANSACTION" | "PURCHASE" | null;
  rule_match_kind?: string | null;
  rule_match_value?: string | null;
  created_at: string;
  stopped_at?: string | null;
  label: string;
  included: string[];
  sharing_mode: "ONCE" | "AUTOMATIC";
  source_updated_at: string | null;
  shared_copy_updated_at: string | null;
  stale: boolean;
  version_state: "CURRENT" | "PAST";
};

export type FinanceSharePreview = {
  kind: FinanceShare["kind"];
  label: string;
  included: string[];
  sharing_mode: "ONCE" | "AUTOMATIC";
  applies_to_future: boolean;
  source_updated_at: string | null;
  existing_share: FinanceShare | null;
};

export type FinanceContributionShareRequest = {
  id: string;
  amount_minor: number;
  currency: string;
  contribution_date: string;
};

export type FinancePurchasePlannedness =
  | "planned"
  | "routine"
  | "replacement"
  | "emergency"
  | "impulse"
  | "unknown";

export type FinancePurchaseUtility = "essential" | "useful" | "optional" | "unclear";
export type FinancePurchaseDecisionQuality = "sensible" | "mixed" | "questionable" | "poor_value" | "unknown";
export type FinancePurchaseValue = "good" | "fair" | "poor" | "unknown";
export type FinancePurchaseOutcome = "valued" | "neutral" | "regretted" | "returned" | "unused" | "unknown";

export type FinancePurchaseLineAssessment = {
  id: string;
  line_id: string;
  purchase_id: string;
  space_id: string;
  source_description: string;
  normalized_item_id: string | null;
  normalized_item_name: string | null;
  beneficiary: string | null;
  purpose: string | null;
  plannedness: FinancePurchasePlannedness | null;
  utility: FinancePurchaseUtility | null;
  decision_quality: FinancePurchaseDecisionQuality | null;
  value_for_money: FinancePurchaseValue | null;
  outcome_state: FinancePurchaseOutcome | null;
  classification_source: "USER" | "LEARNED" | "RULE" | "MODEL" | "IMPORT";
  confidence_bps: number;
  review_status: "UNREVIEWED" | "NEEDS_REVIEW" | "CONFIRMED";
  feedback_recorded: number;
  updated_at: string;
};

export type FinancePurchaseReviewItem = {
  line_id: string;
  purchase_id: string;
  space_id: string;
  purchased_on: string;
  merchant: string;
  source_description: string;
  amount_minor: number;
  currency: string;
  confidence_bps: number;
  uncertain_fields: string[];
  evidence_handle: string;
  deep_link: string;
  source_id: string;
  match_status: FinancePurchaseMatchStatus;
  receipt_file_id: string | null;
};

export type FinanceAnalysisBasis = "TRANSACTIONS" | "PURCHASE_LINES" | "RECONCILED_PURCHASE_LINES";
export type FinanceAnalysisGrouping =
  | "TOTAL" | "DAY" | "WEEK" | "MONTH" | "ACCOUNT" | "MERCHANT" | "CATEGORY"
  | "LINE_KIND" | "ITEM" | "PURPOSE" | "RECIPIENT" | "PLANNEDNESS" | "UTILITY"
  | "VALUE_FOR_MONEY" | "DECISION_QUALITY" | "OUTCOME" | "ITEMISATION";
export type FinanceAnalysisMeasure =
  | "SPEND" | "INCOME" | "COUNT" | "MEAN_SPEND" | "MEDIAN_SPEND" | "MIN_SPEND"
  | "MAX_SPEND" | "SHARE_OF_SPEND" | "MEAN_UNIT_PRICE";
export type FinanceAnalysisComparison = "NONE" | "PREVIOUS_PERIOD" | "SAME_PERIOD_LAST_YEAR";

export type FinanceAnalysisFilters = {
  account_ids: string[];
  merchants: string[];
  categories: string[];
  transaction_types: string[];
  line_kinds: Array<"product" | "service" | "delivery" | "fee" | "tax" | "unknown">;
  normalized_items: string[];
  purposes: string[];
  beneficiaries: string[];
  plannedness: FinancePurchasePlannedness[];
  utilities: FinancePurchaseUtility[];
  decision_qualities: FinancePurchaseDecisionQuality[];
  value_for_money: FinancePurchaseValue[];
  outcomes: FinancePurchaseOutcome[];
  itemisation: Array<"ITEMISED" | "UNITEMISED">;
};

export type FinanceAnalysisRequest = {
  space_id: string;
  scope?: "mine" | "household";
  basis: FinanceAnalysisBasis;
  start_date: string;
  end_date: string;
  currency: string;
  grouping: FinanceAnalysisGrouping;
  measure: FinanceAnalysisMeasure;
  comparison: FinanceAnalysisComparison;
  pending_policy: "EXCLUDE" | "INCLUDE";
  refund_policy: "NET" | "EXCLUDE";
  transfer_policy: "EXCLUDE" | "INCLUDE";
  filters: FinanceAnalysisFilters;
  save_as: string | null;
};

export type FinanceExactValue = { numerator: number; denominator: number };
export type FinanceAnalysisGroup = {
  key: string;
  value: FinanceExactValue;
  record_count: number;
  evidence_handles: string[];
};
export type FinanceAnalysisEvidence = {
  handle: string;
  kind: "transaction" | "purchase-line";
  record_id: string;
  deep_link: string;
};
export type FinanceAnalysisCoverage = {
  eligible_minor: number;
  itemised_minor: number;
  coverage_bps: number;
};
export type FinanceSavedAnalysisView = {
  id: string;
  space_id: string;
  name: string;
  request: FinanceAnalysisRequest;
  deep_link: string;
  created_at: string;
  updated_at: string;
};
export type FinanceAnalysisResponse = {
  basis: FinanceAnalysisBasis;
  currency: string;
  total: FinanceExactValue;
  groups: FinanceAnalysisGroup[];
  comparison_groups: FinanceAnalysisGroup[];
  comparison_total: FinanceExactValue | null;
  comparison_start_date: string | null;
  comparison_end_date: string | null;
  data_through: string | null;
  itemisation_coverage: FinanceAnalysisCoverage | null;
  evidence: FinanceAnalysisEvidence[];
  saved_view: FinanceSavedAnalysisView | null;
};

export type FinanceEvidenceDetail = {
  handle: string;
  kind: "transaction" | "purchase-line";
  record_id: string;
  space_id: string;
  deep_link: string;
  source_evidence_id: string;
  source_description: string;
  amount_minor: number;
  currency: string;
  occurred_on: string;
  source_kind?: string | null;
  line_kind?: string | null;
};

export type FinanceCalendarItem = {
  id: string;
  space_id: string;
  item_kind: "GROCERY_DELIVERY" | "PARCEL_DELIVERY";
  source_id: string;
  starts_at: string;
  ends_at: string | null;
  all_day: boolean;
  status: "ACTIVE" | "CANCELLED";
  created_at: string;
  updated_at: string;
};

export type FinanceCalendarItemPrefill = {
  item_kind: "GROCERY_DELIVERY" | "PARCEL_DELIVERY";
  starts_at: string;
  ends_at: string | null;
  all_day: boolean;
};

export type FinanceRecurringSeries = {
  id: string;
  space_id: string;
  detection_key: string | null;
  name: string;
  series_type: "SALARY" | "BILL" | "SUBSCRIPTION" | "RECURRING_COST";
  interval_kind: "MONTHLY" | "FOUR_WEEKLY" | "ANNUAL" | "IRREGULAR";
  expected_minor: number;
  low_minor: number | null;
  high_minor: number | null;
  currency: string;
  next_expected_date: string | null;
  working_day_adjustment: "PREVIOUS" | "NEXT" | null;
  evidence_refs: string[];
  confidence_bps: number;
  status: "CANDIDATE" | "CONFIRMED" | "REJECTED" | "EXPIRED";
  confirmed_at: string | null;
  updated_at: string;
};

export type FinanceMaterialQuestion = {
  id: string;
  space_id: string;
  question_kind: "SALARY" | "NURSERY" | "MISSING_CARD" | "LARGE_UNITEMISED_PURCHASE";
  prompt: string;
  evidence_refs: string[];
  action_kind: "CONFIRM_RECURRING" | "IDENTIFY_SALARY" | "SAVE_NURSERY_PLAN" | "ADD_CREDIT_CARD" | "ITEMISE_PURCHASE";
  action_target_id: string | null;
  next_action_method: "GET" | "POST" | "PUT";
  next_action_route: string;
  priority_minor: number;
  currency: string;
  status: "OPEN" | "CONFIRMED" | "CORRECTED" | "DISMISSED" | "EXPIRED";
  answer_text: string | null;
  resolved_at: string | null;
  updated_at: string;
};

export type FinancePatternScan = {
  space_id: string;
  data_through_date: string | null;
  recurring_series: FinanceRecurringSeries[];
  questions: FinanceMaterialQuestion[];
};

export type FinanceFinding = {
  id: string;
  space_id: string;
  finding_type: "TREND_CHANGE" | "SEASONAL" | "REPEATED_ONE_OFF" | "PRICE_DRIFT" | "DUPLICATE_REPLACEMENT" | "REPEATED_RETURN" | "ANNUALISED_SMALL_COST";
  title: string;
  observation: string;
  evidence_refs: string[];
  baseline: Record<string, unknown>;
  saving_low_minor: number;
  saving_high_minor: number;
  currency: string;
  confidence_bps: number;
  effort: number;
  overlap_group: string | null;
  status: "OPEN" | "ACCEPTED" | "DISMISSED" | "SNOOZED" | "EXPIRED";
  data_through_date: string;
  updated_at: string;
};

export type FinanceCoachingReport = {
  id: string;
  space_id: string;
  member_user_id: string;
  report_kind: "DAILY" | "DRIFT" | "WEEKLY" | "MONTHLY";
  local_date: string;
  household_timezone: string;
  locale: "en" | "de";
  currency: string;
  input_digest: string;
  data_through_at: string | null;
  itemised_coverage_bps: number | null;
  trajectory_status: "ON_PLAN" | "WATCH" | "OFF_PLAN" | "UNKNOWN";
  expected_durable_saving_minor: number;
  primary_action: Record<string, unknown> | null;
  optional_observation: Record<string, unknown> | null;
  summary: Record<string, unknown>;
  explanation: string;
  created_at: string;
};

export type FinancePlanStrategy = "MINIMAL_DISRUPTION" | "TARGET_DATE" | "AGGRESSIVE" | "RESILIENT";
export type FinancePlanEffortLevel = "EASY" | "MEDIUM" | "HARD";
export type FinancePlanAnswerBasis = "EXACT" | "ESTIMATED" | "BOUNDED";
export type FinancePlanCategory = {
  category_id: string;
  name: string;
  baseline_minor: number;
  floor_minor: number;
  protected: boolean;
  weight: number;
  reduction_minor: number;
  budget_minor: number;
};
export type FinancePlan = {
  id: string;
  proposal_group_id: string;
  space_id: string;
  version: number;
  strategy: FinancePlanStrategy;
  /** Present on three-tier plans. Older saved plans are mapped from strategy in the client. */
  effort_level?: FinancePlanEffortLevel;
  /** Confidence-bearing planning fields are optional only for older saved plan rows. */
  answer_basis?: FinancePlanAnswerBasis;
  confidence_bps?: number;
  required_monthly_minor?: number;
  planned_monthly_saving_minor?: number;
  projected_amount_at_target_minor?: number;
  goal_shortfall_at_target_minor?: number;
  forecast_coverage_end?: string | null;
  assumptions?: string[];
  currency: string;
  goal_id: string;
  source_plan_id: string | null;
  recovery_mode: string | null;
  target_date: string;
  supported_goal_date: string | null;
  monthly_change_minor: number;
  household_buffer_minor: number;
  required_reduction_minor: number;
  achieved_reduction_minor: number;
  shortfall_minor: number;
  feasible: boolean;
  protected_category_count: number;
  status: "PROPOSED" | "ACTIVE" | "SUPERSEDED" | "REJECTED";
  rationale: string;
  categories: FinancePlanCategory[];
  activated_at: string | null;
  created_at: string;
};
export type FinancePlanSet = {
  proposal_group_id: string;
  version: number;
  recommendation_strategy?: FinancePlanStrategy;
  recommendation_effort_level?: FinancePlanEffortLevel;
  plans: FinancePlan[];
};

export type FinancePaydayAction = {
  id: string;
  space_id: string;
  plan_id: string;
  due_date: string;
  source_account_id: string;
  destination_account_id: string;
  amount_minor: number;
  safe_after_transfer_minor: number;
  answer_mode?: "CURRENT_EXACT" | "DATED_EXACT";
  data_through_at?: string | null;
  currency: string;
  date_tolerance_days: number;
  grace_days: number;
  status: "PENDING" | "MATCHED" | "DONE" | "SKIPPED" | "CHANGED" | "RECALCULATED" | "EXPIRED";
  matched_relation_id: string | null;
  matched_at: string | null;
  changed_amount_minor: number | null;
  recalculated_action_id: string | null;
  resolution_note: string | null;
  updated_at: string;
};

export type FinanceHabit = {
  id: string;
  space_id: string;
  finding_id: string | null;
  slot: "PRIMARY" | "SECONDARY";
  name: string;
  trigger: string;
  filters: Record<string, unknown>;
  baseline_start: string;
  baseline_end: string;
  baseline_minor: number;
  start_date: string;
  review_date: string;
  expected_saving_low_minor: number;
  expected_saving_high_minor: number;
  actual_spend_minor: number;
  realised_saving_minor: number;
  displacement_minor: number;
  friction_rating: number | null;
  fallback: string;
  currency: string;
  status: "PROPOSED" | "ACTIVE" | "PAUSED" | "COMPLETED" | "ABANDONED";
  review_decision: "KEEP" | "ADJUST" | "STOP" | null;
  evidence_refs: string[];
  updated_at: string;
};

export type FinancePurchaseProposal = {
  id: string;
  space_id: string;
  source_kind: string;
  name: string;
  amount_low_minor: number;
  amount_high_minor: number;
  desired_date: string;
  recurrence: string;
  payment_account_id: string;
  purpose: string | null;
  beneficiary: string | null;
  lines: Array<Record<string, unknown>>;
  cheaper_alternative_minor: number | null;
  later_date: string | null;
  uncertainties: string[];
  currency: string;
  status: "CONFIRMED" | "EVALUATED" | "APPROVED" | "DISMISSED";
  approved_scenario: string | null;
  created_at: string;
  updated_at: string;
};

export type FinancePurchaseScenario = {
  scenario: "BUY_NOW" | "BUY_LATER" | "CHEAPER" | "DO_NOTHING";
  status: string;
  purchase_date?: string | null;
  amount_minor?: number;
  passed: boolean;
  minimum_household_free_minor?: number;
  estimated_household_free_range_minor?: [number, number];
  minimum_household_free_date?: string;
  estimated_goal_delay_months?: number | null;
  assumptions?: string[];
};
export type FinancePurchaseEvaluation = {
  id: string;
  proposal_id: string;
  forecast_id: string;
  verdict: "YES" | "YES_IF" | "NOT_YET" | "NO_UNDER_CURRENT_PLAN";
  rationale: string;
  scenarios: FinancePurchaseScenario[];
  historical_context: Record<string, unknown>;
  evidence_refs: string[];
  data_through_at: string | null;
  created_at: string;
};

export type FinanceReportPreference = {
  id: string;
  space_id: string;
  member_user_id: string;
  locale: "en" | "de";
  daily_time: string;
  enabled: boolean;
  notification_channel: "IN_APP" | "BROWSER";
  notification_mode: "ACTION_ONLY" | "DAILY" | "NEVER";
  show_more_by_default: boolean;
  quiet_hours_start: string | null;
  quiet_hours_end: string | null;
  underfunded_commitment_threshold_minor: number;
  goal_movement_threshold_minor: number;
  missed_payday_alerts: boolean;
  selected_return_deadline_alerts: boolean;
  tone: "GENTLE" | "BALANCED" | "BLUNT";
  default_spend_account_id: string | null;
  extra_cash_buffer_minor: number;
  writing_mode: "LOCAL" | "CLOUD_WITH_CONSENT";
  allow_dated_estimates: boolean;
  ordinary_purchase_alerts: false;
  group_related_alerts: true;
  updated_at: string;
};

export type FinanceTodayAction = {
  id: string;
  kind: "PAYDAY_TRANSFER" | "PURCHASE_REVIEW" | "HABIT_REVIEW";
  space_id: string;
  space_kind: "PERSONAL" | "HOUSEHOLD";
  space_name: string;
  due_date: string | null;
  review_date: string | null;
  title: string | null;
  amount_minor: number | null;
  currency: string | null;
  source_account_id: string | null;
  source_account_label: string | null;
  destination_account_id: string | null;
  destination_account_label: string | null;
  line_id: string | null;
  purchase_id: string | null;
  source_id: string | null;
};

export type FinanceEmailAddress = {
  id: string;
  space_id: string;
  alias_kind: "PERSONAL" | "HOUSEHOLD";
  address: string;
  enabled: boolean;
  last_received_at: string | null;
  last_parsed_at: string | null;
  last_test_sent_at: string | null;
  created_at: string;
};

export type FinanceEmailAddresses = {
  configured: boolean;
  addresses: FinanceEmailAddress[];
  gmail_instructions: string;
  outlook_instructions: string;
};

export type FinanceEmailEnrollment = {
  id: string;
  alias_id: string;
  space_id: string;
  expected_forwarder_address: string;
  retailer_domain: string;
  transport_marker: string;
  status: "PENDING" | "ACTIVE" | "DISABLED";
  verified_at: string | null;
  last_received_at: string | null;
  last_success_at: string | null;
};

export type FinanceEmailHealth = {
  alias: FinanceEmailAddress;
  health: Array<{
    source_kind: string;
    health_status: "HEALTHY" | "DEGRADED" | "QUARANTINED" | "UNSUPPORTED";
    last_received_at: string | null;
    last_parsed_at: string | null;
    consecutive_failures: number;
    latest_issue_code: string | null;
  }>;
  enrollments: FinanceEmailEnrollment[];
  open_exception_count: number;
};

export type FinanceAssetClass = "OPERATING_CASH" | "PROTECTED_RESERVE" | "GOAL_CASH" | "ACCESSIBLE_SAVINGS" | "BROKERAGE_INVESTMENT" | "PENSION_LOCKED" | "STABLE_CRYPTO" | "VOLATILE_CRYPTO" | "PROPERTY" | "OTHER_ASSET" | "LIABILITY";
export type FinanceAssetHoldingInput = {
  asset_key: string;
  asset_name: string;
  asset_class: FinanceAssetClass;
  position_kind: "HOLDING" | "DEBT" | "EQUITY" | "EXPOSURE" | "UNREALISED_PNL";
  include_in_net_worth: boolean;
  quantity: string;
  quantity_unit: string;
  value_minor: number | null;
  unit_price_minor: number | null;
  price_source: string | null;
  instrument_id_kind?: "ISIN" | "SEDOL" | "TICKER" | "OTHER" | null;
  instrument_id?: string | null;
  quote_symbol?: string | null;
  quote_currency?: string | null;
};
export type FinanceHLActivityInput = {
  activity_type: "CONTRIBUTION" | "WITHDRAWAL" | "BUY" | "SELL" | "INCOME" | "FEE";
  occurred_on: string;
  amount_minor: number;
  currency: string;
  description: string;
};
export type FinanceHLPreview = {
  id: string;
  label: string;
  account_wrapper: "ISA" | "SIPP" | "GENERAL" | "JUNIOR_ISA" | "OTHER";
  as_of_date: string;
  currency: string;
  cash_value_minor: number;
  reported_total_minor: number | null;
  calculated_known_total_minor: number;
  unknown_value_count: number;
  reconciliation_difference_minor: number | null;
  can_confirm: boolean;
  holdings: FinanceAssetHoldingInput[];
  activities: FinanceHLActivityInput[];
  expires_at: string;
};
export type FinanceAssetSource = {
  id: string;
  space_id: string;
  source_kind: "HL_REPORT" | "SOLANA_PUBLIC" | "HYPERLIQUID_PUBLIC";
  label: string;
  public_address: string | null;
  status: "ACTIVE" | "PAUSED";
};
export type FinanceAssetSnapshot = {
  id: string;
  source: FinanceAssetSource;
  as_of_at: string;
  snapshot_kind: "REVIEWED_REPORT" | "WATCH_ONLY";
  data_status: "COMPLETE" | "PARTIAL";
  position_count: number;
};
export type FinanceAssetPriceRefresh = {
  source_id: string;
  source_label: string;
  priced_holding_count: number;
  retained_holding_count: number;
  price_observed_at: string | null;
  price_sources: string[];
};
export type FinanceNetWorthLayer = {
  layer: FinanceAssetClass;
  amount_minor: number | null;
  known_components_minor: number;
  unknown_component_count: number;
  included_in_total: boolean;
  data_through: string | null;
  note: string | null;
};
export type FinanceNetWorth = {
  space_id: string;
  currency: string;
  total_net_worth_minor: number | null;
  known_net_worth_minor: number;
  data_through: string | null;
  layers: FinanceNetWorthLayer[];
};

export type FinanceNetWorthPoint = {
  as_of_date: string;
  total_minor: number;
  unknown_component_count: number;
  layers: Array<{ layer: FinanceAssetClass; amount_minor: number }>;
  contributions_minor: number;
  withdrawals_minor: number;
  market_movement_minor: number | null;
};

export type FinanceNetWorthHolding = {
  key: string;
  source_id: string | null;
  source_label: string;
  name: string;
  layer: FinanceAssetClass;
  value_minor: number;
  currency: string;
  as_of_at: string;
  quantity: string | null;
  quantity_unit: string | null;
  instrument_id_kind: "ISIN" | "SEDOL" | "TICKER" | "OTHER" | null;
  instrument_id: string | null;
  quote_symbol: string | null;
  unit_price_minor: number | null;
  price_source: string;
  using_last_known_price: boolean;
};

export type FinanceNetWorthHistory = {
  space_id: string;
  currency: string;
  points: FinanceNetWorthPoint[];
  current_total_minor: number;
  change_minor: number;
  period_contributions_minor: number;
  period_withdrawals_minor: number;
  period_market_movement_minor: number;
  holdings: FinanceNetWorthHolding[];
  price_observed_at: string | null;
  price_sources: string[];
  using_last_known_prices: boolean;
};

export type FinanceProductPriceObservation = {
  id: string;
  normalized_item_id: string;
  normalized_item_name: string;
  source_kind: "PURCHASE_LINE" | "RETAILER_RESEARCH";
  source_line_id: string | null;
  retailer_name: string;
  product_name: string;
  pack_quantity: string;
  pack_unit: string;
  comparable_quantity: string;
  unit_basis: string;
  price_minor: number;
  currency: string;
  observed_on: string;
  confidence_bps: number;
  evidence_refs: string[];
};
export type FinanceRetailerResearchResult = {
  id: string;
  request_id: string;
  match_kind: "EXACT" | "REALISTIC_SUBSTITUTE" | "BEHAVIOURAL_ALTERNATIVE";
  retailer_name: string;
  product_name: string;
  brand_variant: string | null;
  pack_quantity: string;
  pack_unit: string;
  comparable_quantity: string;
  unit_basis: string;
  price_minor: number;
  currency: string;
  observed_on: string;
  delivery_low_minor: number;
  delivery_high_minor: number;
  travel_low_minor: number;
  travel_high_minor: number;
  likely_waste_low_bps: number;
  likely_waste_high_bps: number;
  inconvenience_note: string;
  confidence_bps: number;
  source_label: string;
};
export type FinanceProductHistory = {
  normalized_item_id: string;
  normalized_item_name: string;
  data_through: string | null;
  observations: FinanceProductPriceObservation[];
};
export type FinanceProductComparison = {
  id: string;
  normalized_item_id: string;
  normalized_item_name: string;
  research_result_id: string;
  period_start: string;
  period_end: string;
  actual_quantity: string;
  actual_spend_minor: number;
  currency: string;
  comparison_mode: "EXACT" | "RANGE";
  candidate_low_minor: number;
  candidate_high_minor: number;
  saving_low_minor: number;
  saving_high_minor: number;
  unmatched_observation_count: number;
  confidence_bps: number;
  overlap_group: string;
  evidence_refs: string[];
  data_through: string;
  price_observed_on: string;
  inconvenience_note: string;
  status: "OPEN" | "ACCEPTED" | "DISMISSED" | "SUPERSEDED";
};
export type FinanceOpportunityAction = {
  id: string;
  comparison_id: string;
  overlap_group: string;
  action_kind: "PREFERENCE" | "HABIT_EXPERIMENT";
  status: "CREATED" | "READY_FOR_CONFIRMATION";
  action_payload: Record<string, unknown>;
  target_preference_id: string | null;
};

export type FinanceBalance = {
  booked_minor: number;
  available_minor: number | null;
  credit_limit_minor: number | null;
  provider_at: string | null;
  observed_at: string;
};

export type FinanceAccountType =
  | "CURRENT"
  | "SAVINGS"
  | "CREDIT_CARD"
  | "CASH"
  | "INVESTMENT"
  | "CRYPTO";

export type FinanceAccountPurpose =
  | "OPERATING_CURRENT"
  | "SAVINGS"
  | "CREDIT_CARD"
  | "GOAL"
  | "IGNORED"
  | "INVESTMENT_LIKE";

export type FinanceAccount = {
  id: string;
  space_id: string;
  label: string;
  institution: string | null;
  account_type: FinanceAccountType;
  purpose: FinanceAccountPurpose;
  currency: string;
  last_four: string | null;
  include_in_cashflow: boolean;
  include_in_net_worth: boolean;
  primary_spending_account: boolean;
  minimum_balance_minor: number;
  card_paid_in_full: boolean;
  card_settlement_account_id: string | null;
  card_statement_close_day: number | null;
  card_repayment_day: number | null;
  fresh_through_date: string | null;
  data_through_at: string | null;
  provider_presence_status?: "ACTIVE" | "OMITTED";
  balance: FinanceBalance | null;
};

export type FinanceConnectionStatus =
  | "CONNECTED"
  | "REAUTH_REQUIRED"
  | "EXPIRED"
  | "PROVIDER_DOWN"
  | "PARTIAL"
  | "DISCONNECTED";

export type FinanceConnectedAccount = Omit<FinanceAccount, "space_id" | "balance">;

export type FinanceDerivedRefresh = {
  hook: "PURCHASE_REMATCH" | "FORECAST" | "PAYDAY_MATCH" | "COACH_REPORT";
  status: "SUCCEEDED" | "FAILED";
  last_attempt_at: string;
  last_success_at: string | null;
  last_error_code:
    | "PURCHASE_REMATCH_FAILED"
    | "FORECAST_REFRESH_FAILED"
    | "PAYDAY_MATCH_FAILED"
    | "COACH_REPORT_REFRESH_FAILED"
    | null;
};

export type FinanceConnection = {
  id: string;
  space_id: string;
  can_manage: boolean;
  provider: "TRUELAYER" | "ENABLE_BANKING";
  institution: string;
  status: FinanceConnectionStatus;
  granted_capabilities: Array<"accounts" | "balances" | "cards" | "transactions">;
  consent_created_at: string | null;
  consent_expires_at: string | null;
  last_success_at: string | null;
  last_error_code: string | null;
  data_through_at: string | null;
  derived_refreshes?: FinanceDerivedRefresh[];
  accounts: FinanceConnectedAccount[];
};

export type FinanceConnectionSyncResult = {
  connection_id: string;
  status: FinanceConnectionStatus;
  accounts_seen: number;
  balances_created: number;
  source_created: number;
  canonical_created: number;
  duplicates: number;
  pending_superseded: number;
  partial_issue_codes: string[];
  derived_refreshes?: FinanceDerivedRefresh[];
};

export type FinanceHistoryEntry = {
  id: string;
  record_type: string;
  record_id: string;
  changed_at: string;
  changed_by_name: string | null;
  changed_by_current_user: boolean;
  previous_values: Record<string, string | number | boolean | null>;
};

export type FinanceHistoryPage = {
  scope: "mine" | "household";
  offset: number;
  limit: number;
  has_more: boolean;
  items: FinanceHistoryEntry[];
};

export type FinanceImportIssue = {
  row_number: number | null;
  code: string;
  message: string;
  severity: "ERROR" | "WARNING";
};

export type FinanceImportSampleRow = {
  row_number: number;
  booking_date: string;
  value_date: string | null;
  amount_minor: number;
  currency: string;
  description: string;
  source_transaction_id: string | null;
};

export type FinanceImportRepair = {
  relationship: "NO_IMPORTABLE_ROWS" | "NEW_HISTORY" | "GAP" | "CONTIGUOUS" | "OVERLAP";
  imported_start: string | null;
  imported_end: string | null;
  existing_start: string | null;
  existing_end: string | null;
  gap_start: string | null;
  gap_end: string | null;
  overlap_start: string | null;
  overlap_end: string | null;
};

export type FinanceImportPreview = {
  batch_id: string;
  source_kind: "CSV" | "OFX";
  space_id: string;
  account_id: string;
  currency: string;
  total_rows: number;
  importable_rows: number;
  invalid_rows: number;
  duplicate_rows: number;
  can_confirm: boolean;
  date_from: string | null;
  date_to: string | null;
  issue_count: number;
  issues_truncated: boolean;
  issues: FinanceImportIssue[];
  sample_rows: FinanceImportSampleRow[];
  repair: FinanceImportRepair;
};

export type FinanceImportResult = {
  source_created: number;
  canonical_created: number;
  duplicates: number;
  pending_superseded: number;
  transaction_ids: string[];
  relation_suggestion_ids: string[];
};

export type FinanceForecastEventKind =
  | "income"
  | "expense"
  | "commitment"
  | "reserve"
  | "goal"
  | "planned"
  | "transfer"
  | "card_purchase"
  | "refund";

export type FinanceForecastLimit = {
  kind: "ACCOUNT_FLOOR" | "HOUSEHOLD_BUFFER";
  day: string;
  event_id: string | null;
  account_id: string | null;
  required_minor: number;
  actual_minor: number;
  shortfall_minor: number;
};

export type FinanceForecastEvent = {
  event_id: string;
  day: string;
  account_id: string;
  amount_minor: number;
  currency: string;
  kind: FinanceForecastEventKind;
  destination_account_id: string | null;
  sequence: number;
  provenance: string | null;
};

export type FinanceForecastAccountDay = {
  account_id: string;
  balance_minor: number;
  floor_minor: number;
  headroom_minor: number;
};

export type FinanceForecastDay = {
  day: string;
  accounts: FinanceForecastAccountDay[];
  household_liquid_minor: number;
  household_free_minor: number;
  constraints_passed_through_day: boolean;
};

export type FinanceForecast = {
  id: string;
  space_id: string;
  input_snapshot_digest: string;
  engine_version: string;
  household_timezone: string;
  currency: string;
  start_date: string;
  end_date: string;
  household_buffer_minor: number;
  passed: boolean;
  limiting_event: FinanceForecastLimit | null;
  minimum_household_free_minor: number;
  minimum_household_free_date: string;
  data_through_at: string | null;
  source: "SAVED" | "LEGACY_EXPLICIT";
  data_status: "CURRENT" | "STALE" | "PARTIAL";
  input_notes: string[];
  events: FinanceForecastEvent[];
  days: FinanceForecastDay[];
  created_at: string;
};

export type FinanceForecastOverviewDay = Omit<FinanceForecastDay, "accounts">;

export type FinanceForecastOverview = Omit<FinanceForecast, "days"> & {
  opening_accounts: FinanceForecastAccountDay[];
  days: FinanceForecastOverviewDay[];
};

export type FinanceSafeToSpendStatus =
  | "OK"
  | "NO_SAFE_AMOUNT"
  | "CANNOT_MODEL_DIRECT_ROUTE"
  | "CANNOT_MODEL_CARD_ROUTE"
  | "CANNOT_MODEL_NON_MONOTONE_ROUTE"
  | "CANNOT_MODEL_UNBOUNDED_ROUTE";

export type FinanceSafeToSpend = {
  forecast_id: string;
  input_snapshot_digest: string;
  status: FinanceSafeToSpendStatus;
  answer_mode: "CURRENT_EXACT" | "DATED_EXACT" | "ESTIMATED_RANGE" | "CANNOT_MODEL";
  currency: string;
  amount_minor: number | null;
  low_minor: number | null;
  high_minor: number | null;
  data_through: string | null;
  evaluated_through: string;
  limiting_event: FinanceForecastLimit | null;
  refusal_reasons: string[];
};

export type FinanceCurrencySummary = {
  currency: string;
  account_movement_minor: number;
  income_minor: number;
  gross_spending_minor: number;
  refunds_minor: number;
  reimbursements_minor: number;
  fees_minor: number;
  net_household_cost_minor: number;
};

export type FinanceLedgerSummary = {
  space_id: string;
  data_through_at: string | null;
  currencies: FinanceCurrencySummary[];
};

export type FinanceSpendingType = "FIXED" | "FLEXIBLE" | "DISCRETIONARY" | "UNCATEGORISED";

export type FinanceOverviewCategory = {
  category_key: string;
  name: string;
  spending_type: FinanceSpendingType;
  spent_minor: number;
  share_bps: number;
};

export type FinanceOverviewBudget = {
  category_key: string;
  name: string;
  budget_minor: number;
  spent_minor: number;
  remaining_minor: number;
};

export type FinanceOverviewCommitment = {
  name: string;
  due_date: string;
  amount_minor: number;
};

export type FinanceOverview = {
  scope: "mine" | "household";
  month_start: string;
  through_date: string;
  currency: string;
  account_count: number;
  income_minor: number;
  spending_minor: number;
  spending_by_category: FinanceOverviewCategory[];
  budget_buckets: FinanceOverviewBudget[];
  current_available_minor: number | null;
  next_paycheck_date: string | null;
  next_paycheck_minor: number | null;
  left_until_payday_minor: number | null;
  commitments_before_payday_minor: number;
  commitments_before_payday_count: number;
  upcoming_commitments: FinanceOverviewCommitment[];
  savings_balance_minor: number | null;
  savings_change_minor: number | null;
  savings_series: Array<{ date: string; balance_minor: number }>;
};

export type FinanceTransactionState = "PENDING" | "POSTED" | "SUPERSEDED" | "VOID";

export type FinanceTransaction = {
  id: string;
  space_id: string;
  account_id: string;
  canonical_date: string;
  amount_minor: number;
  currency: string;
  state: FinanceTransactionState;
  transaction_kind: "CASEY" | "FEE" | "CASH_WITHDRAWAL";
  source_kind: string;
  description: string;
  merchant_text: string | null;
  merchant_id: string | null;
  primary_category_id: string | null;
  primary_category_name: string;
  primary_spending_type: FinanceSpendingType;
  superseded_by_id: string | null;
  data_through_at: string;
  relations?: Array<{
    id: string;
    from_transaction_id: string;
    to_transaction_id: string;
    relation_type: string;
    status: "SUGGESTED" | "CONFIRMED" | "REJECTED";
    method: string;
    confidence_bps: number;
  }>;
  splits?: Array<{
    id: string;
    transaction_id: string;
    amount_minor: number;
    category_id: string | null;
    category_name: string;
    spending_type: FinanceSpendingType;
    label: string | null;
    created_at: string;
  }>;
};

export type FinancePlanningStatus = "ACTIVE" | "PAUSED" | "COMPLETED" | "CANCELLED";

export type FinanceCommitment = {
  id: string;
  space_id: string;
  name: string;
  amount_mode: "EXACT" | "RANGE" | "FORECAST";
  exact_minor: number | null;
  expected_minor: number | null;
  low_minor: number | null;
  high_minor: number | null;
  currency: string;
  recurrence: "ONE_OFF" | "MONTHLY" | "ANNUAL" | "TERMLY" | "CUSTOM";
  reviewed_dates: string[];
  next_due_date: string | null;
  priority: "PROTECTED" | "IMPORTANT" | "OPTIONAL";
  funding_account_id: string | null;
  payment_handling?: FinancePaymentHandling;
  show_in_calendar?: boolean;
  show_in_tasks?: boolean;
  responsible_user_id?: string | null;
  already_reserved_minor: number;
  required_minor: number;
  remaining_minor: number;
  funding_status: "FUNDED" | "PARTLY_FUNDED" | "UNFUNDED" | "UNDERFUNDED";
  status: FinancePlanningStatus;
  notes: string | null;
  created_at: string;
  updated_at: string;
};

export type FinanceReserve = {
  id: string;
  space_id: string;
  name: string;
  allocated_minor: number;
  target_minor: number | null;
  remaining_minor: number | null;
  funding_status: "UNTARGETED" | "UNFUNDED" | "PARTLY_FUNDED" | "FUNDED" | "OVERFUNDED";
  currency: string;
  linked_account_id: string | null;
  status: FinancePlanningStatus;
  created_at: string;
  updated_at: string;
};

export type FinanceGoal = {
  id: string;
  space_id: string;
  name: string;
  target_minor: number;
  deadline: string;
  currently_allocated_minor: number;
  remaining_minor: number;
  currency: string;
  priority: "PROTECTED" | "IMPORTANT" | "OPTIONAL";
  allowed_funding_sources: string[];
  emergency_buffer_minor: number;
  feasibility: "ACHIEVED" | "INFEASIBLE" | "UNASSESSED";
  shortfall_minor: number | null;
  status: "ACTIVE" | "PAUSED" | "ACHIEVED" | "CANCELLED";
  notes: string | null;
  created_at: string;
  updated_at: string;
};

export type FinancePurchaseMatchStatus = "MATCHED" | "PARTIAL" | "UNMATCHED";

export type FinancePurchaseEvidence = {
  id: string;
  space_id: string;
  external_source_id: string;
  source_kind: string;
  corrects_source_id: string | null;
  parser_version: string | null;
  extraction_status: "PARSED" | "QUARANTINED" | "UNSUPPORTED";
  confidence_bps: number | null;
  raw_payload: Record<string, unknown>;
  issues: Array<{ code: string; message: string }>;
  storage_area: "finance-evidence";
  storage_key: string | null;
  provider_message_id?: string | null;
  visible_sender?: string | null;
  email_subject?: string | null;
  files?: Array<{
    id: string;
    file_role: "MESSAGE" | "ATTACHMENT";
    filename: string;
    media_type: string;
    byte_size: number;
    storage_status: "STORED" | "REJECTED_TYPE" | "REJECTED_SIZE" | "REJECTED_UNSAFE";
  }>;
  received_at: string;
  parsed_at: string | null;
  created_at: string;
};

export type FinancePurchaseEvidenceUploadResponse = {
  source: FinancePurchaseEvidence;
  purchase: FinancePurchaseDetail | null;
  exception: FinancePurchaseException | null;
  duplicate: boolean;
};

export type FinancePurchaseLine = {
  id: string;
  line_ref: string;
  position: number;
  line_kind: "product" | "service" | "delivery" | "fee" | "tax" | "unknown";
  raw_description: string;
  quantity_decimal: string;
  unit_description: string | null;
  unit_price_minor: number | null;
  line_gross_minor: number | null;
  line_discount_minor: number | null;
  line_net_minor: number | null;
  evidence_status:
    | "observed_structured"
    | "observed_document"
    | "user_confirmed"
    | "inferred"
    | "unitemised";
  source_refs: Array<Record<string, string>>;
  seller: string | null;
  product_reference: string | null;
  replaces_description: string | null;
};

export type FinancePurchaseTender = {
  id: string;
  tender_ref: string;
  tender_kind: "bank" | "card" | "cash" | "gift_card" | "credit" | "unknown";
  amount_minor: number;
  provider_transaction_id: string | null;
  card_suffix: string | null;
  source_refs: Array<Record<string, string>>;
};

export type FinancePurchaseRefund = {
  id: string;
  refund_ref: string;
  line_id: string;
  line_ref: string;
  amount_minor: number;
  quantity_decimal: string | null;
  source_refs: Array<Record<string, string>>;
};

export type FinancePurchasePayment = {
  id: string;
  allocation_ref: string;
  transaction_id: string | null;
  line_id: string | null;
  tender_kind: "bank" | "card" | "cash" | "gift_card" | "credit" | "unknown";
  allocated_minor: number;
  transaction_amount_minor: number | null;
  transaction_date: string | null;
  match_method: "AUTO_EXACT" | "REVIEWED" | "EVIDENCED_NON_BANK";
  status: "PROPOSED" | "CONFIRMED" | "REJECTED";
};

export type FinancePurchaseSummary = {
  id: string;
  space_id: string;
  merchant: string;
  item_descriptions?: string[];
  order_reference: string | null;
  purchased_on: string;
  currency: string;
  lines_subtotal_minor: number;
  shipping_minor: number;
  vat_included_minor: number;
  order_discount_minor: number;
  final_total_minor: number;
  refunded_minor: number;
  behavioural_net_minor: number;
  status:
    | "pending"
    | "partly_fulfilled"
    | "fulfilled"
    | "partly_refunded"
    | "refunded"
    | "cancelled";
  source_kind: string;
  match_status: FinancePurchaseMatchStatus;
  unmatched_purchase_minor: number;
  unmatched_refund_minor: number;
  cashflow_source: "canonical_transactions";
  purchase_total_added_to_cashflow: false;
  supersedes_purchase_id: string | null;
  superseded_by_id: string | null;
  created_at: string;
};

export type FinancePurchaseDetail = FinancePurchaseSummary & {
  evidence: FinancePurchaseEvidence;
  lines: FinancePurchaseLine[];
  tenders: FinancePurchaseTender[];
  refunds: FinancePurchaseRefund[];
  payment_allocations: FinancePurchasePayment[];
};

export type FinancePurchaseException = {
  id: string;
  space_id: string;
  source_id: string;
  purchase_id: string | null;
  exception_kind:
    | "QUARANTINED_EVIDENCE"
    | "UNSUPPORTED_SOURCE"
    | "AMBIGUOUS_MATCH"
    | "UNMATCHED_PURCHASE"
    | "PARTIAL_ITEMISATION";
  title: string;
  detail: string;
  amount_minor: number | null;
  currency: string | null;
  status: "OPEN" | "RESOLVED" | "DISMISSED";
  priority: number;
  created_at: string;
};

export type AIConsentStatus = {
  consented: boolean;
  version: string;
  consented_at?: string | null;
  provider: string;
  disclosure: string;
  background_processing: boolean;
};

export type FamilyMember = {
  id: string;
  name: string;
  member_type: "user" | "child";
  avatar_url?: string | null;
};

export type LinkedDocument = {
  id: string;
  title: string;
  original_filename: string;
  media_type: string;
  file_size: number;
  download_url: string;
};

export type CalendarEventAttachmentRole =
  | "ticket"
  | "booking"
  | "school_letter"
  | "insurance"
  | "other";

export type CalendarEventAttachment = LinkedDocument & {
  relation_id: string;
  role: CalendarEventAttachmentRole;
  position: number;
};

export type ManagedSource = {
  kind: "finance_commitment" | "finance_renewal" | "finance_order" | "library_loan" | "school_club" | "toast_club";
  source_id: string;
  deep_link: string;
  label: string;
};

export type FinanceProjectionPreferences = {
  show_money: boolean;
  show_deliveries: boolean;
};

export type Child = {
  id: string;
  name: string;
  date_of_birth: string;
};

export type CalendarEvent = {
  id: string;
  title: string;
  description?: string | null;
  start_time: string;
  end_time?: string | null;
  all_day: boolean;
  recurrence_rule?: string | null;
  location?: string | null;
  assigned_to?: string | null;
  family_member_ids?: string[] | null;
  affected_member_ids?: string[] | null;
  event_type?: string | null;
  series_id?: string | null;
  is_generated_occurrence?: boolean;
  calendar_source_id?: string | null;
  source_name?: string | null;
  source_color?: string | null;
  rugby_venue?: "home" | "away" | null;
  rugby_venue_overridden?: boolean;
  read_only?: boolean;
  overridden_event_id?: string | null;
  managed_source?: ManagedSource | null;
  source_document_id?: string | null;
  source_document?: LinkedDocument | null;
  attachments?: CalendarEventAttachment[];
};

export type CalendarRecurrenceMutationScope =
  | "only_this"
  | "this_and_later"
  | "entire_series";

export type CyclePeriodStart = {
  id: string;
  started_on: string;
  created_at: string;
  updated_at: string;
};

export type CycleProfile = {
  id: string;
  owner_user_id: string;
  owner_name: string;
  is_owner: boolean;
  cycle_length_days: number;
  share_with_adults: boolean;
  show_period_starts: boolean;
  show_predicted_period: boolean;
  show_estimated_ovulation: boolean;
  latest_period_start?: string | null;
  predicted_next_period?: string | null;
  estimated_ovulation?: string | null;
  period_starts: CyclePeriodStart[];
  created_at: string;
  updated_at: string;
};

export type CalendarSource = {
  id: string;
  name: string;
  hostname: string;
  assigned_to?: string | null;
  color: string;
  enabled: boolean;
  last_synced_at?: string | null;
  last_success_at?: string | null;
  last_error?: string | null;
  created_at: string;
  updated_at: string;
};

export type CalendarFeedStatus = {
  configured: boolean;
  token_prefix?: string | null;
  feed_url?: string | null;
};

export type SchoolRugbyTeam = {
  id: string;
  name: string;
};

export type SchoolRugbyTeamList = {
  season: string;
  teams: SchoolRugbyTeam[];
};

export type SchoolRugbySettings = {
  configured: boolean;
  source_id?: string | null;
  team_id?: string | null;
  team_name?: string | null;
  season?: string | null;
  owner_user_id?: string | null;
  owner_name?: string | null;
  affected_user_ids: string[];
  affected_names: string[];
  fixture_count: number;
  last_synced_at?: string | null;
  last_success_at?: string | null;
  last_error?: string | null;
};

export type ReminderPreferences = {
  event_reminders_enabled: boolean;
  event_minutes_before: number;
  task_reminders_enabled: boolean;
  morning_summary_enabled: boolean;
  morning_summary_time: string;
  evening_summary_enabled: boolean;
  evening_summary_time: string;
  quiet_start: string;
  quiet_end: string;
  privacy_mode: boolean;
};

export type PushStatus = { configured: boolean; subscribed: boolean; public_key?: string | null };
export type ReminderPreviewItem = { id: string; kind: string; title: string; detail: string; scheduled_for: string; url: string };

export type TaskAssignee = {
  id: string;
  assignee_id: string;
  assignee_name?: string | null;
  assignee_type: "user" | "child";
  completed_at?: string | null;
  completed_by?: string | null;
};

export type TaskCategory = "bins" | "household" | "shopping" | "admin" | "other";

export type FamilyTask = {
  id: string;
  title: string;
  description?: string | null;
  assigned_to?: string | null;
  due_date?: string | null;
  completed_at?: string | null;
  category: TaskCategory;
  recurrence_rule?: string | null;
  priority: number;
  actionable_from?: string | null;
  source_document_id?: string | null;
  source_document?: LinkedDocument | null;
  source_event_id?: string | null;
  prep_occurrence_id?: string | null;
  prep_occurrence_start?: string | null;
  created_at?: string;
  updated_at?: string;
  created_by?: string | null;
  read_only?: boolean;
  managed_source?: ManagedSource | null;
  assignees: TaskAssignee[];
};

export type RenewalStatus = "overdue" | "due_soon" | "upcoming";
export type RenewalCategory =
  | "document"
  | "vehicle"
  | "insurance"
  | "subscription"
  | "utility"
  | "membership"
  | "medical"
  | "other";
export type FinancePaymentHandling = "UNSPECIFIED" | "AUTOMATIC" | "MANUAL" | "RENEWAL";

export type Renewal = {
  id: string;
  title: string;
  category: RenewalCategory;
  due_date: string;
  days_until: number;
  status: RenewalStatus;
  recurrence_months: number | null;
  cost_pence: number | null;
  reminder_days_before: number;
  source_document_id: string | null;
  source_document?: LinkedDocument | null;
  provider?: string | null;
  reference?: string | null;
  action_url?: string | null;
  comparison_url?: string | null;
  contact_url?: string | null;
  notes: string | null;
  finance_commitment_id: string | null;
  show_in_calendar?: boolean;
  show_in_tasks?: boolean;
  responsible_user_id?: string | null;
  responsible_user_name?: string | null;
  payment_handling?: FinancePaymentHandling;
  reminders_enabled?: boolean;
  escalate_after_days?: number | null;
  checklist?: Array<{
    id: string;
    title: string;
    checked_at: string | null;
    position: number;
  }>;
  history?: Array<{
    id: string;
    outcome: "renewed" | "not_renewing";
    due_date: string;
    decided_at: string;
    cost_pence: number | null;
    next_due_date: string | null;
    notes: string | null;
  }>;
  previous_cost_pence?: number | null;
  cost_change_pence?: number | null;
  created_at: string;
};

export type RenewalDraftPreview = {
  title: string | null;
  category: RenewalCategory;
  due_date: string | null;
  recurrence_months: number | null;
  cost_pence: number | null;
  provider: string | null;
  reference: string | null;
  action_url: string | null;
  source_document_id: string | null;
  uncertain_fields: string[];
};

export type LibraryAccount = {
  id: string;
  provider: "local_authority_spydus";
  label: string;
  card_last_four: string;
  sync_enabled: boolean;
  reminder_days_before: number;
  status: "pending" | "connected" | "needs_attention" | "temporarily_unavailable";
  last_sync_at: string | null;
  last_success_at: string | null;
  next_sync_at: string | null;
  error_message: string | null;
};

export type LibraryLoan = {
  id: string;
  account_id: string;
  account_label: string;
  title: string;
  author: string | null;
  material_format: string | null;
  due_date: string;
  days_until: number;
  status: "overdue" | "due_soon" | "current";
  provider_status: string | null;
  renewable: boolean | null;
  renewal_count: number | null;
  renew_url: string | null;
};

export type LibraryOverview = {
  accounts: LibraryAccount[];
  loans: LibraryLoan[];
};

export type DocumentPerson = {
  id: string;
  person_id: string;
  person_name: string;
  person_type: "user" | "child";
};

export type DocumentSuggestion = {
  id: string;
  document_id: string;
  kind: "event" | "task";
  title: string;
  details?: string | null;
  start_time?: string | null;
  end_time?: string | null;
  due_date?: string | null;
  all_day: boolean;
  assigned_to?: string | null;
  assigned_to_name?: string | null;
  confidence: number;
  source_text?: string | null;
  status: "pending" | "accepted" | "dismissed";
  result_id?: string | null;
  result_status: "pending" | "dismissed" | "open" | "completed" | "scheduled" | "unavailable";
  result_completed_at?: string | null;
  created_at: string;
  updated_at: string;
};

export type FamilyDocument = {
  id: string;
  title: string;
  original_filename: string;
  media_type: string;
  file_size: number;
  source: string;
  category: string;
  category_confidence?: number | null;
  status: "inbox" | "filed" | "archived" | "failed";
  document_date?: string | null;
  document_date_confidence?: number | null;
  page_count: number;
  extracted_text?: string | null;
  notes?: string | null;
  processor: "device" | "hermes" | "fallback";
  people: DocumentPerson[];
  suggestions: DocumentSuggestion[];
  linked_events: Array<{
    id: string;
    title: string;
    start_time: string;
    end_time?: string | null;
    all_day: boolean;
  }>;
  linked_tasks: Array<{
    id: string;
    title: string;
    due_date?: string | null;
    completed_at?: string | null;
  }>;
  pending_suggestion_count: number;
  ready_for_batch_filing?: boolean;
  download_url: string;
  created_at: string;
  updated_at: string;
};

export type CaptureProposal = {
  id: string;
  kind: "event" | "task";
  title: string;
  details?: string | null;
  start_time?: string | null;
  end_time?: string | null;
  due_date?: string | null;
  all_day: boolean;
  assigned_to?: string | null;
  assigned_to_name?: string | null;
  confidence: number;
};

export type CaptureResponse = {
  proposals: CaptureProposal[];
  processor: "hermes" | "fallback";
  warning?: string | null;
};

export type TomorrowCard = {
  target_date: string;
  visible: boolean;
  acknowledged: boolean;
  events: Array<Pick<CalendarEvent, "id" | "title" | "start_time" | "all_day" | "location" | "assigned_to" | "event_type">>;
  tasks: Array<{ id: string; title: string; due_date?: string | null; priority: number; assignee_names: string[] }>;
  load_prompt?: { task_id: string; title: string; due_date?: string | null; priority: number } | null;
};

export type ShareDraft = { id: string; text: string };

export type GlobalSearchResultKind =
  | "event"
  | "task"
  | "document"
  | "person"
  | "photo"
  | "artwork"
  | "homework"
  | "health"
  | "renewal"
  | "birthday";

export type GlobalSearchResult = {
  id: string;
  kind: GlobalSearchResultKind;
  title: string;
  subtitle?: string | null;
  date?: string | null;
  image_url?: string | null;
  child_id?: string | null;
  path: string;
};

export type GlobalSearchResponse = {
  query: string;
  results: GlobalSearchResult[];
  has_more: boolean;
};

export type AssistantActionKind =
  | "calendar_event"
  | "home_lights"
  | "create_task"
  | "complete_task"
  | "shopping_item";

export type AssistantActionPreview =
  | {
      kind: "calendar_event";
      title: string;
      description?: string | null;
      start_time: string;
      end_time?: string | null;
      all_day: boolean;
      recurrence_rule?: string | null;
      assigned_to?: string | null;
      term_time_only?: boolean;
    }
  | {
      kind: "create_task";
      title: string;
      description?: string | null;
      due_date?: string | null;
      recurrence_rule?: string | null;
      assigned_to?: string | null;
      category: TaskCategory;
      priority: number;
    }
  | {
      kind: "shopping_item";
      name: string;
      quantity?: string | null;
      category?: string | null;
    };

export type AssistantAction = {
  id: string;
  kind: AssistantActionKind;
  summary: string;
  status: "pending" | "executing" | "executed" | "declined" | "failed" | "expired";
  expires_at: string;
  message?: string;
  editable?: boolean;
  preview?: AssistantActionPreview | null;
  result_id?: string | null;
};

export type AssistantMessage = {
  id: string;
  role: "user" | "assistant";
  content: string;
  actions: AssistantAction[];
};
