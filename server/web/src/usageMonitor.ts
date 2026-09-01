import { api, ApiError } from "./api";

type UsageView = "today" | "calendar" | "fitness" | "family" | "lists" | "home" | "finance";
export type UsageSurface = "today_facilities" | "calendar_event";
type UsageOutcome = "started" | "completed" | "failed" | "cancelled";

type UsageDescriptor = {
  module: string;
  action: string;
  surface: string;
  workflow?: string;
};

type UsageEvent = {
  id: string;
  event_kind: "screen_view" | "control" | "workflow";
  module: string;
  action: string;
  outcome: "viewed" | "tapped" | UsageOutcome;
  surface: string;
  workflow?: string;
  workflow_run_id?: string;
  duration_bucket: "under_10s" | "under_1m" | "under_5m" | "over_5m" | "unknown";
  interaction_count?: number;
  connectivity: "online" | "offline" | "queued" | "unknown";
  failure_class?: "validation" | "network" | "authorization" | "conflict" | "provider" | "server" | "cancelled" | "unknown";
  occurred_at: string;
};

export type UsageWorkflowRun = {
  id: string;
  startedAt: number;
  descriptor: UsageDescriptor;
};

let monitoringIdentity: string | null = null;
let monitoringEnabled: boolean | null = null;
let preferenceRequest: Promise<boolean> | null = null;

export function setUsageMonitoringIdentity(identity: string | null): void {
  if (monitoringIdentity === identity) return;
  monitoringIdentity = identity;
  monitoringEnabled = null;
  preferenceRequest = null;
}

export function setUsageMonitoringConsent(enabled: boolean): void {
  monitoringEnabled = enabled;
  preferenceRequest = null;
}

async function isEnabled(): Promise<boolean> {
  if (!monitoringIdentity) return false;
  if (monitoringEnabled !== null) return monitoringEnabled;
  if (preferenceRequest) return preferenceRequest;
  const identity = monitoringIdentity;
  preferenceRequest = api<{ enabled: boolean }>(
    "/usage-history/preferences",
    { cache: "no-store" },
    true,
    false,
  )
    .then((preference) => {
      if (monitoringIdentity === identity) monitoringEnabled = preference.enabled;
      return monitoringIdentity === identity && preference.enabled;
    })
    .catch(() => false)
    .finally(() => { preferenceRequest = null; });
  return preferenceRequest;
}

function durationBucket(startedAt?: number): UsageEvent["duration_bucket"] {
  if (startedAt === undefined) return "unknown";
  const duration = Math.max(Date.now() - startedAt, 0);
  if (duration < 10_000) return "under_10s";
  if (duration < 60_000) return "under_1m";
  if (duration < 300_000) return "under_5m";
  return "over_5m";
}

function failureClass(error: unknown): NonNullable<UsageEvent["failure_class"]> {
  if (!(error instanceof ApiError)) return navigator.onLine ? "unknown" : "network";
  if (error.status === 401 || error.status === 403) return "authorization";
  if (error.status === 409) return "conflict";
  if (error.status >= 500) return "server";
  if (error.status === 408 || error.status === 0) return "network";
  return "unknown";
}

async function submit(event: UsageEvent): Promise<void> {
  if (!await isEnabled()) return;
  try {
    // Telemetry must not occupy the durable queue reserved for real family
    // actions. Server-confirmed writes still provide the authoritative usage
    // fact after an offline action eventually syncs.
    await api(
      "/usage-history/events",
      { method: "POST", body: JSON.stringify({ events: [event] }) },
      true,
      false,
    );
  } catch {
    // Product monitoring must never interrupt or alter the family workflow.
  }
}

function send(
  descriptor: UsageDescriptor,
  eventKind: UsageEvent["event_kind"],
  outcome: UsageEvent["outcome"],
  options: Partial<Pick<UsageEvent, "workflow_run_id" | "interaction_count" | "connectivity" | "failure_class">> & { startedAt?: number } = {},
): void {
  const event: UsageEvent = {
    id: crypto.randomUUID(),
    event_kind: eventKind,
    module: descriptor.module,
    action: descriptor.action,
    outcome,
    surface: descriptor.surface,
    workflow: descriptor.workflow,
    workflow_run_id: options.workflow_run_id,
    duration_bucket: durationBucket(options.startedAt),
    interaction_count: options.interaction_count === undefined
      ? undefined
      : Math.min(Math.max(options.interaction_count, 0), 100),
    connectivity: options.connectivity ?? "unknown",
    failure_class: options.failure_class,
    occurred_at: new Date().toISOString(),
  };
  void submit(event);
}

export function recordUsageScreen(view: UsageView): void {
  const surface = view === "home" ? "house" : view;
  send({ module: surface, action: `view_${surface}`, surface }, "screen_view", "viewed");
}

export type UsageControl =
  | "open_capture"
  | "open_add"
  | "open_search"
  | "open_more"
  | "open_fitness_log"
  | "open_fitness_coach";

export function recordUsageControl(control: UsageControl, view: UsageView): void {
  const surface = view === "home" ? "house" : view;
  const module = control === "open_capture" || control === "open_add"
    ? "capture"
    : control === "open_search"
      ? "search"
      : control === "open_more"
        ? "navigation"
        : "fitness";
  send({ module, action: control, surface }, "control", "tapped");
}

export function recordSwimmingBookingOpen(surface: UsageSurface): void {
  send(
    { module: "facilities", action: "open_swimming_booking", surface, workflow: "book_swimming" },
    "control",
    "tapped",
  );
}

export function startSwimmingBooking(surface: UsageSurface): UsageWorkflowRun {
  const run = {
    id: crypto.randomUUID(),
    startedAt: Date.now(),
    descriptor: { module: "facilities", action: "book_swimming", surface, workflow: "book_swimming" },
  };
  send(run.descriptor, "workflow", "started", { workflow_run_id: run.id });
  return run;
}

export function startStravaPull(): UsageWorkflowRun {
  const run = {
    id: crypto.randomUUID(),
    startedAt: Date.now(),
    descriptor: { module: "fitness", action: "pull_strava", surface: "fitness_training", workflow: "pull_strava" },
  };
  send(run.descriptor, "workflow", "started", { workflow_run_id: run.id });
  return run;
}

export function finishUsageWorkflow(
  run: UsageWorkflowRun,
  outcome: UsageOutcome,
  options: { interactions?: number; queued?: boolean; error?: unknown } = {},
): void {
  const failed = outcome === "failed";
  send(run.descriptor, "workflow", outcome, {
    workflow_run_id: run.id,
    startedAt: run.startedAt,
    interaction_count: options.interactions,
    connectivity: options.queued ? "queued" : navigator.onLine ? "online" : "offline",
    failure_class: outcome === "cancelled" ? "cancelled" : failed ? failureClass(options.error) : undefined,
  });
}
