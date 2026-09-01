import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { ApiError, api } from "../api";
import type { AIConsentStatus } from "../types";
import type { FitnessCoachMessageResponse, FitnessCoachRecommendation } from "../fitness/contract";
import { FitnessCoachView } from "../views/fitness/FitnessCoachView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    code: string | null;
    body: unknown;
    constructor(message: string, status: number, code: string | null = null, body: unknown = null) { super(message); this.status = status; this.code = code; this.body = body; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);
const consented: AIConsentStatus = {
  consented: true,
  version: "2026-07-13",
  consented_at: "2026-08-02T10:00:00Z",
  provider: "OpenAI",
  disclosure: "Only the evidence needed for an explicit request is sent to OpenAI. Chats are not stored by HausKlar.",
  background_processing: false,
};
const notConsented: AIConsentStatus = { ...consented, consented: false, consented_at: null };
const props = { online: true, revision: 0, onDataChanged: vi.fn(), onSectionChange: vi.fn() };

function deterministicResponse(path: string, plannedSessions: Array<Record<string, unknown>> = []) {
  if (path === "/fitness/today") {
    const plannedSession = plannedSessions[0];
    return {
      planned_sessions: plannedSessions,
      next_action: plannedSession ? {
        title: "Review the proposed plan",
        body: "This plan is still proposed, so it is not treated as executable.",
        urgency: "attention",
        evidence: [],
        action: { kind: "open_planned_session", target: String(plannedSession.id), label: "Review proposed plan" },
        secondary_action: null,
        expires_at: "2099-08-03T23:59:59Z",
        source: `test:planned:${String(plannedSession.id)}`,
      } : {
        title: "Next useful action",
        body: "Keep today’s next step small and evidence-led.",
        urgency: "routine",
        evidence: [],
        action: { kind: "open_today", target: "today", label: "Open today" },
        secondary_action: null,
        expires_at: "2099-08-03T23:59:59Z",
        source: "test:next-useful-action",
      },
    };
  }
  if (path === "/fitness/goals") return [{ id: "goal-1", name: "Run consistently", goal_type: "performance", starts_on: "2026-07-01", status: "active" }];
  if (path === "/fitness/planned-sessions") return plannedSessions;
  if (path === "/fitness/body-issues") return [];
  if (path === "/fitness/session-checkins") return [];
  return undefined;
}

function installCoachApi(options?: {
  consent?: AIConsentStatus;
  message?: FitnessCoachMessageResponse | Error;
  recommendations?: FitnessCoachRecommendation[];
  plannedSessions?: Array<Record<string, unknown>>;
}) {
  const currentConsent = options?.consent ?? consented;
  apiMock.mockImplementation(async (path, init) => {
    const deterministic = deterministicResponse(String(path), options?.plannedSessions);
    if (deterministic !== undefined) return deterministic as never;
    if (path === "/auth/ai-consent" && init?.method === "PUT") return consented as never;
    if (path === "/auth/ai-consent") return currentConsent as never;
    if (path === "/fitness/coach/status") return { status: "available", provider: "openai", model: "gpt-health", intents: ["discussion", "morning", "weekly", "run_plan", "strength_plan"] } as never;
    if (path === "/fitness/coach/recommendations") return (options?.recommendations ?? []) as never;
    if (path === "/fitness/coach/context-preferences") return { family_calendar: false, household_meals: false, weather: false } as never;
    if (path === "/fitness/coach/reminders") return [] as never;
    if (path === "/fitness/coach/preferences") return { personality_preset: "balanced_supportive", directness: 3, challenge_bias: "balanced", detail_level: "standard", custom_instruction: null } as never;
    if (path === "/fitness/coach/memory/settings") return { enabled: false } as never;
    if (path === "/fitness/coach/conversations" || path === "/fitness/coach/memories") return [] as never;
    if (path === "/fitness/coach/message" && init?.method === "POST") {
      if (options?.message instanceof Error) throw options.message;
      return (options?.message ?? { status: "complete", answer: "Keep the next action small.", evidence: [], recommendation: null, proposal: null }) as never;
    }
    if (String(path).endsWith("/confirm") && init?.method === "POST") return { status: "confirmed", message: "Workout version and planned session saved.", result_ids: ["workout-1", "session-1"] } as never;
    if (String(path).endsWith("/decline") && init?.method === "POST") return { status: "declined", message: "Draft declined." } as never;
    if (String(path).endsWith("/feedback") && init?.method === "POST") return { status: "recorded" } as never;
    throw new Error(`Unexpected request: ${path}`);
  });
}

describe("Fitness Stage 15 coaching", () => {
  beforeEach(() => {
    apiMock.mockReset();
    props.onDataChanged.mockReset();
    props.onSectionChange.mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("reuses the explicit OpenAI consent gate and loads only the deterministic fallback before permission", async () => {
    installCoachApi({ consent: notConsented });
    render(<FitnessCoachView {...props} />);

    expect(await screen.findByRole("heading", { name: "Allow Fitness Coach to use OpenAI?" })).toBeInTheDocument();
    expect(screen.getByText(/shares your message and the relevant Fitness records/)).toBeInTheDocument();
    expect(screen.getByText(/Private conversation memory stays off/)).toBeInTheDocument();
    expect(screen.getByText(/No plan or record changes automatically/)).toBeInTheDocument();
    const scope = screen.getByText("What may be included").closest("details");
    expect(scope).not.toHaveAttribute("open");
    fireEvent.click(screen.getByText("What may be included"));
    expect(scope).toHaveAttribute("open");
    expect(screen.getByText(notConsented.disclosure)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Read the privacy policy" })).toHaveAttribute("href", "/privacy-policy");
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/today" || path === "/fitness/planned-sessions")).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/coach/status")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Allow and continue" }));
    expect(await screen.findByText("Ask Coach")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/auth/ai-consent", { method: "PUT", body: JSON.stringify({ accepted: true, version: consented.version }) });
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/coach/message", expect.anything(), expect.anything(), expect.anything());
  });

  it("does not duplicate Today recommendations inside Coach", async () => {
    installCoachApi({ consent: notConsented, plannedSessions: [{ id: "proposal-session", title: "Coach lower day", sport_key: "strength", status: "proposed", scheduled_date: "2026-08-03" }] });
    render(<FitnessCoachView {...props} />);
    expect(await screen.findByRole("heading", { name: "Allow Fitness Coach to use OpenAI?" })).toBeInTheDocument();
    expect(screen.queryByText("Review the proposed plan")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/today" || path === "/fitness/planned-sessions")).toBe(false);
  });

  it("sends a bounded in-memory history and treats model text as plain text", async () => {
    installCoachApi({ message: {
      status: "complete",
      answer: "Use <strong>recorded</strong> pace, not a guessed score.",
      evidence: [{ id: "analysis-1", kind: "analysis", label: "Comparable easy runs", summary: "Four owner-scoped runs", period: { start: "2026-07-01", end: "2026-08-02" }, sample_size: 4, completeness: 0.8, source_ids: ["run-1"] }],
      recommendation: null,
      proposal: null,
    } });
    render(<FitnessCoachView {...props} />);
    expect(await screen.findByText("Ask Coach")).toBeInTheDocument();
    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "How is my running going?" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByText("Use <strong>recorded</strong> pace, not a guessed score.")).toBeInTheDocument();
    expect(document.querySelector(".fitness-module__coach-message strong strong")).toBeNull();
    expect(screen.queryByText("Comparable easy runs")).not.toBeInTheDocument();
    const call = apiMock.mock.calls.find(([path]) => path === "/fitness/coach/message");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({ message: "How is my running going?", intent: "discussion", history: [] });
    expect(JSON.parse(String(call?.[1]?.body)).history).toHaveLength(0);
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("/proposals/"))).toBe(false);
  });

  it("sends selected activity context only after the handoff message is submitted", async () => {
    installCoachApi();
    const consumed = vi.fn();
    render(<FitnessCoachView {...props} coachDraft={{ text: "Review Evening ride in context.", nonce: 7, contextIds: ["ride-1"] }} onCoachDraftConsumed={consumed} />);

    const composer = await screen.findByLabelText("Message your Fitness coach");
    await waitFor(() => expect(composer).toHaveValue("Review Evening ride in context."));
    expect(screen.getByText("Using this activity and nearby sessions as context")).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/coach/message")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => path === "/fitness/coach/message")).toBe(true));
    const call = apiMock.mock.calls.find(([path]) => path === "/fitness/coach/message");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
      message: "Review Evening ride in context.",
      context_ids: ["ride-1"],
    });
    expect(consumed).toHaveBeenCalledTimes(1);
    await waitFor(() => expect(screen.queryByText("Using this activity and nearby sessions as context")).not.toBeInTheDocument());
  });

  it("caps both displayed and wire history at eight in-memory role/content turns", async () => {
    installCoachApi({ message: { status: "complete", answer: "Bounded answer", evidence: [], recommendation: null, proposal: null } });
    render(<FitnessCoachView {...props} />);
    const composer = await screen.findByLabelText("Message your Fitness coach");
    for (let index = 1; index <= 6; index += 1) {
      fireEvent.change(composer, { target: { value: `Question ${index}` } });
      fireEvent.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => expect(screen.getAllByText("Bounded answer")).toHaveLength(Math.min(index, 4)));
    }
    const calls = apiMock.mock.calls.filter(([path]) => path === "/fitness/coach/message");
    const finalBody = JSON.parse(String(calls.at(-1)?.[1]?.body));
    expect(finalBody.history).toHaveLength(8);
    expect(finalBody.history.every((turn: Record<string, unknown>) => Object.keys(turn).sort().join(",") === "content,role")).toBe(true);
    expect(document.querySelectorAll(".fitness-module__coach-message")).toHaveLength(8);
  });

  it("shows a whitelisted validated run draft and writes it only after explicit confirmation", async () => {
    installCoachApi({ message: {
      status: "complete",
      answer: "Here is a controlled progression run based on your recent comparable sessions.",
      evidence: [{ id: "runs-1", kind: "run_comparison", label: "Comparable progression runs", summary: "Three recorded runs", sample_size: 3 }],
      recommendation: null,
      proposal: {
        id: "proposal-1",
        kind: "run_workout",
        payload: {
          title: "Controlled progression",
          purpose: "Build 10K control",
          estimated_distance_m: 6000,
          estimated_duration_s: 2100,
          expected_difficulty: "Moderate",
          route_assumption: "Mostly flat",
          raw_html: "<img src=x onerror=steal()>",
          steps: [{ display_name: "Warm-up", duration_type: "distance_m", duration_value: 1000 }, { display_name: "Controlled repeats", step_kind: "repeat_block", repeat_count: 3, children: [{ display_name: "Kilometre 1", duration_type: "distance_m", duration_value: 1000, target_low: 345, target_high: 355, target_unit: "s_per_km", instruction_text: "Start controlled.", mental_cue_text: "Relax shoulders." }] }],
        },
        validation: { valid: true, issues: [] },
        warnings: [{ code: "garmin_cue", message: "Spoken cues may be shortened on Garmin." }],
        confirmable: true,
        review_only_reason: null,
        expires_at: "2099-08-02T12:00:00Z",
      },
    } });
    render(<FitnessCoachView {...props} />);
    await screen.findByText("Ask Coach");
    fireEvent.click(await screen.findByRole("button", { name: "Plan a run" }));
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByRole("article", { name: "Run proposal" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Controlled progression", level: 4 })).toBeInTheDocument();
    expect(screen.getByText(/Kilometre 1/)).toBeInTheDocument();
    expect(screen.getByText("Repeat 3×")).toBeInTheDocument();
    expect(screen.queryByText("Spoken cues may be shortened on Garmin.")).not.toBeInTheDocument();
    expect(screen.queryByText(/onerror=steal/)).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/coach/proposals/proposal-1/confirm")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
    expect(await screen.findByText("Saved")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/coach/proposals/proposal-1/confirm", { method: "POST" }, true, false);
    expect(props.onDataChanged).toHaveBeenCalledTimes(1);
  });

  it("shows exact strength load, rep, RIR, structure, and component ranges before decline", async () => {
    installCoachApi({ message: {
      status: "complete",
      answer: "A reviewable session using your canonical setup.", evidence: [], recommendation: null,
      proposal: {
        id: "proposal-strength", kind: "strength_workout",
        payload: { title: "Lower body maintenance", location: "Home", estimated_duration_s: 2400, exercises: [{ exercise_name: "Goblet squat", setup_name: "Home adjustable dumbbell", sets: [{ training_role: "working", structure_type: "rest_pause", component_count: 2, load_min: 28, load_max: 30, load_unit: "kg", reps_min: 8, reps_max: 10, rir_min: 2, rir_max: 3 }] }] },
        validation: { valid: true, issues: [] }, warnings: [], confirmable: true, review_only_reason: null, expires_at: "2099-08-02T12:00:00Z",
      },
    } });
    render(<FitnessCoachView {...props} />);
    await screen.findByText("Ask Coach");
    fireEvent.click(await screen.findByRole("button", { name: "Plan strength" }));
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByText("Goblet squat")).toBeInTheDocument();
    expect(screen.getByText(/rest pause \(2 components\) · 28–30 kg × 8–10 reps · RIR 2–3/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Discard" }));
    expect(await screen.findByText("Discarded")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/coach/proposals/proposal-strength/decline", { method: "POST" }, true, false);
    expect(props.onDataChanged).not.toHaveBeenCalled();
  });

  it("shows review-only nutrition guidance without an executable confirm control", async () => {
    installCoachApi({ message: {
      status: "complete", answer: "Review the pattern before changing a target.", evidence: [], recommendation: null,
      proposal: {
        id: "proposal-review", kind: "nutrition_change",
        payload: { action_type: "review_only", food_or_meal: "Workday breakfast", observation_period: "Last 14 days", proposed_change: "Compare hunger on higher-protein mornings.", expected_effect: "Better evidence for a later target." },
        validation: { valid: true, issues: [] }, warnings: [], confirmable: false, review_only_reason: "No typed nutrition target or meal template was proposed.", expires_at: "2099-08-02T12:00:00Z",
      },
    } });
    render(<FitnessCoachView {...props} />);
    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "Review my breakfast pattern" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByText("Review the pattern before changing a target.")).toBeInTheDocument();
    expect(screen.queryByText("No typed nutrition target or meal template was proposed.")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
  });

  it("keeps in-memory discussion and deterministic guidance visible through a bridge outage", async () => {
    installCoachApi({ message: new ApiError("Bridge unavailable", 503) });
    render(<FitnessCoachView {...props} />);
    await screen.findByText("Ask Coach");
    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "Review today without changing anything" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByText("Review today without changing anything")).toBeInTheDocument();
    expect(screen.getByText(/Coach is temporarily unavailable/i)).toBeInTheDocument();
    expect(screen.queryByText("Next useful action")).not.toBeInTheDocument();
    expect(screen.getByText("Review today without changing anything")).toBeInTheDocument();
  });

  it("records explicit recommendation feedback for later coaching context", async () => {
    const recommendation: FitnessCoachRecommendation = {
      id: "rec-1", revision: 1, created_at: "2026-08-01T10:00:00Z", updated_at: "2026-08-01T10:00:00Z",
      recommendation_type: "nutrition", recommendation_text: "Add a repeatable protein breakfast.", status: "accepted", user_feedback: "accepted", outcome_review: null,
    };
    installCoachApi({ recommendations: [recommendation] });
    render(<FitnessCoachView {...props} />);
    fireEvent.click(await screen.findByText("Personalise coach"));
    expect(await screen.findByText("Add a repeatable protein breakfast.")).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Outcome for Add a repeatable protein breakfast."), { target: { value: "tried_worked" } });
    fireEvent.click(screen.getByRole("button", { name: "Save outcome" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/recommendations/rec-1/feedback", { method: "POST", body: JSON.stringify({ feedback: "tried_worked" }) }, true, false));
  });
});
