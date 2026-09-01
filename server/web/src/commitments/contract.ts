export type CommitmentKind = "school" | "invitation" | "outing" | "childcare" | "appointment" | "travel";
export type CommitmentVisibility = "family" | "owner";
export type CommitmentStatus = "draft" | "action_required" | "ready" | "confirmed" | "declined";

export type CommitmentSource = {
  id: string;
  kind: "document" | "email" | "share" | "manual" | "provider";
  document_id?: string | null;
  label?: string | null;
  provider_reference?: string | null;
  source_url?: string | null;
  observed_at?: string | null;
};

export type CommitmentEventDraft = {
  id: string;
  title: string;
  description?: string | null;
  start_time: string;
  end_time?: string | null;
  all_day: boolean;
  location?: string | null;
  person_ids: string[];
  affected_adult_ids: string[];
  assigned_to?: string | null;
  event_type: string;
  document_ids: string[];
};

export type CommitmentTaskDraft = {
  id: string;
  title: string;
  description?: string | null;
  due_date?: string | null;
  actionable_from?: string | null;
  assigned_to?: string | null;
  priority: number;
  document_id?: string | null;
};

export type CommitmentPreparationDraft = {
  id: string;
  event_id: string;
  name: string;
  items: string[];
  lead_hours: number;
  assigned_to?: string | null;
};

export type CommitmentExternalAction = {
  kind: "rsvp" | "book" | "register" | "contact" | "pay" | "other";
  label: string;
  target_type: "https" | "email" | "phone" | "manual";
  target: string;
  due_at?: string | null;
  requires_completion_before_confirm: boolean;
};

export type CommitmentPlan = {
  events: CommitmentEventDraft[];
  tasks: CommitmentTaskDraft[];
  preparations: CommitmentPreparationDraft[];
  external_action?: CommitmentExternalAction | null;
};

export type Commitment = {
  id: string;
  kind: CommitmentKind;
  visibility: CommitmentVisibility;
  owner_user_id: string;
  title: string;
  summary?: string | null;
  status: CommitmentStatus;
  revision: number;
  sources: CommitmentSource[];
  plan: CommitmentPlan;
  review_issues: string[];
  external_action_status: "not_required" | "pending" | "completed" | "declined";
  external_action_outcome?: string | null;
  external_action_completed_at?: string | null;
  group_key?: string | null;
  interpretation_processor?: "typed" | "fallback" | "hermes" | null;
  supersedes_id?: string | null;
  change_summary: string[];
  confirmed_at?: string | null;
  declined_at?: string | null;
  results: Array<{
    source_item_id: string;
    result_type: "calendar_event" | "task" | "preparation_task";
    result_id: string;
  }>;
  created_at: string;
  updated_at: string;
};

export type CommitmentFromSourceResponse = {
  commitment: Commitment;
  processor: "fallback" | "hermes";
  warning?: string | null;
  deduplicated: boolean;
  material_changes: string[];
};

export type FreeWindowQueryResponse = {
  windows: Array<{ start_time: string; end_time: string; duration_minutes: number }>;
  viable_outings: Array<{
    candidate_id: string;
    title: string;
    proposed_start: string;
    proposed_end: string;
    location?: string | null;
    booking_url?: string | null;
  }>;
};

export type ChildcareGap = {
  date: string;
  label: string;
  source: "explicit_holiday" | "outside_term";
};

export const OPEN_COMMITMENT_STATUSES = new Set<CommitmentStatus>(["draft", "action_required", "ready"]);

export function openCommitments(values: Commitment[]): Commitment[] {
  return values.filter((value) => OPEN_COMMITMENT_STATUSES.has(value.status));
}

function temporalValue(value?: string | null): number | null {
  if (!value) return null;
  const parsed = new Date(value.length === 10 ? `${value}T12:00:00` : value);
  return Number.isNaN(parsed.getTime()) ? null : parsed.getTime();
}

export function commitmentUrgency(commitment: Commitment): number {
  const values = [
    ...commitment.plan.events.map((event) => temporalValue(event.start_time)),
    ...commitment.plan.tasks.map((task) => temporalValue(task.due_date)),
    temporalValue(commitment.plan.external_action?.due_at),
  ].filter((value): value is number => value != null);
  return values.length ? Math.min(...values) : Number.POSITIVE_INFINITY;
}

export function commitmentKindLabel(kind: CommitmentKind): string {
  return ({
    school: "School message",
    invitation: "Invitation",
    outing: "Family outing",
    childcare: "Childcare gap",
    appointment: "Appointment",
    travel: "Travel booking",
  } as const)[kind];
}
