import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FitnessCoachMessageResponse, FitnessCoachProposal } from "../fitness/contract";
import { setOfflineQueueOwner } from "../offlineQueue";
import {
  FitnessCoachContextPreferencesCard,
  FitnessCoachRemindersCard,
  FitnessCoachView,
} from "../views/fitness/FitnessCoachView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);
const consent = {
  consented: true,
  version: "2026-07-13",
  consented_at: "2026-08-03T08:00:00Z",
  provider: "OpenAI",
  disclosure: "Explicit requests only.",
  background_processing: false,
};
const viewProps = { online: true, revision: 0, onDataChanged: vi.fn(), onSectionChange: vi.fn() };

function proposal(overrides: Partial<FitnessCoachProposal> = {}): FitnessCoachProposal {
  return {
    id: "proposal-wave5",
    kind: "shopping_list",
    payload: { internal_id: "must-never-render" },
    preview: { change: ["Add Bananas to Shopping — 6 · Fruit"], visibility: "Visible to your family" },
    validation: { valid: true, issues: [] },
    warnings: [],
    confirmable: true,
    expires_at: "2099-08-03T12:00:00Z",
    ...overrides,
  };
}

function installCoach(response: FitnessCoachMessageResponse, extra?: (path: string, init?: RequestInit) => unknown | Promise<unknown>) {
  apiMock.mockImplementation(async (path, init) => {
    const requestPath = String(path);
    if (requestPath === "/auth/ai-consent") return consent as never;
    if (requestPath === "/fitness/coach/status") return { status: "available", provider: "hidden", model: "hidden", intents: ["discussion", "weekly", "run_plan", "strength_plan"] } as never;
    if (requestPath === "/fitness/coach/memory/settings") return { enabled: false } as never;
    if (requestPath === "/fitness/coach/message" && init?.method === "POST") return response as never;
    if (extra) return await extra(requestPath, init) as never;
    throw new Error(`Unexpected request: ${requestPath}`);
  });
}

async function requestProposal() {
  const composer = await screen.findByLabelText("Message your Fitness coach");
  fireEvent.change(composer, { target: { value: "Help with my family week" } });
  const sendButton = screen.getByRole("button", { name: "Send" });
  await waitFor(() => expect(sendButton).toBeEnabled());
  fireEvent.click(sendButton);
}

describe("Fitness Coach Wave 5", () => {
  beforeEach(() => {
    apiMock.mockReset();
    viewProps.onDataChanged.mockReset();
    viewProps.onSectionChange.mockReset();
    window.history.replaceState({}, "", "/?view=fitness&section=coach");
    window.localStorage.clear();
    setOfflineQueueOwner({ id: "owner-a", family_id: "family-a" });
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", { configurable: true, value: vi.fn() });
    Object.defineProperty(window, "matchMedia", { configurable: true, value: vi.fn().mockReturnValue({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }) });
  });

  it("puts starter prompts and the composer first with one exact disclaimer and no service internals", async () => {
    installCoach({ status: "complete", answer: "Keep today simple.", evidence: [], recommendation: null, proposal: null });
    render(<FitnessCoachView {...viewProps} />);

    expect(await screen.findByRole("heading", { name: "Ask Coach" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Review my week" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Plan a run" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Plan strength" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "What should I do today?" })).toBeInTheDocument();
    expect(screen.getAllByText("Reminders and coaching only — not medical advice.")).toHaveLength(1);
    expect(screen.queryByText("hidden")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/today" || path === "/fitness/planned-sessions" || path === "/fitness/coach/recommendations")).toBe(false);
  });

  it("renders the exact Shopping preview, hides payload internals, and keeps writes behind Confirm", async () => {
    let resolveConfirm: ((value: unknown) => void) | undefined;
    const confirmResult = new Promise((resolve) => { resolveConfirm = resolve; });
    const value = proposal();
    installCoach({ status: "complete", answer: "I have prepared the shopping change.", evidence: [], recommendation: null, proposal: value }, (path, init) => {
      if (path === "/fitness/coach/proposals/proposal-wave5/confirm" && init?.method === "POST") return confirmResult;
      throw new Error(`Unexpected request: ${path}`);
    });
    const openDestination = vi.fn();
    render(<FitnessCoachView {...viewProps} onOpenCoachDestination={openDestination} />);
    await requestProposal();

    const review = await screen.findByRole("article", { name: "Shopping list proposal" });
    expect(within(review).getByText("Add Bananas to Shopping — 6 · Fruit")).toBeInTheDocument();
    expect(within(review).getByText("Visible to your family")).toBeInTheDocument();
    expect(screen.queryByText("must-never-render")).not.toBeInTheDocument();
    expect(within(review).getAllByRole("button").map((button) => button.textContent?.trim())).toEqual(["Confirm", "Edit", "Discard"]);
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("/proposals/") || String(path).startsWith("/shopping") || String(path).startsWith("/tasks"))).toBe(false);

    const callsBeforeEdit = apiMock.mock.calls.length;
    fireEvent.click(within(review).getByRole("button", { name: "Edit" }));
    expect(screen.getByLabelText("Message your Fitness coach")).toHaveValue("Please revise this suggestion: Add Bananas to Shopping — 6 · Fruit.");
    expect(apiMock).toHaveBeenCalledTimes(callsBeforeEdit);

    const confirm = within(review).getByRole("button", { name: "Confirm" });
    fireEvent.click(confirm);
    fireEvent.click(confirm);
    expect(apiMock.mock.calls.filter(([path]) => path === "/fitness/coach/proposals/proposal-wave5/confirm")).toHaveLength(1);
    await act(async () => {
      resolveConfirm?.({ status: "confirmed", message: "Saved.", result_ids: ["shopping-1"], next_destinations: [{ kind: "shopping", target: "shopping-1", label: "Open shopping item" }] });
    });
    fireEvent.click(await screen.findByRole("button", { name: "Open shopping item" }));
    expect(openDestination).toHaveBeenCalledWith({ kind: "shopping", target: "shopping-1", label: "Open shopping item" });
  });

  it("retries an ambiguous decision against the same proposal without duplicating a click", async () => {
    let attempts = 0;
    installCoach({ status: "complete", answer: "Ready to review.", evidence: [], recommendation: null, proposal: proposal() }, (path, init) => {
      if (path === "/fitness/coach/proposals/proposal-wave5/confirm" && init?.method === "POST") {
        attempts += 1;
        if (attempts === 1) throw new TypeError("Connection ended");
        return { status: "confirmed", message: "Saved.", result_ids: ["shopping-1"], next_destinations: [] };
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    render(<FitnessCoachView {...viewProps} />);
    await requestProposal();
    fireEvent.click(await screen.findByRole("button", { name: "Confirm" }));
    fireEvent.click(await screen.findByRole("button", { name: "Try again" }));

    expect(await screen.findByText("Saved")).toBeInTheDocument();
    expect(apiMock.mock.calls.filter(([path]) => path === "/fitness/coach/proposals/proposal-wave5/confirm")).toHaveLength(2);
  });

  it.each([
    ["missing shared preview", proposal({ preview: null })],
    ["too many shared rows", proposal({ preview: { change: Array.from({ length: 81 }, (_, index) => `Change ${index}`), visibility: "Visible to your family" } })],
    ["oversized shared row", proposal({ preview: { change: ["x".repeat(1_201)], visibility: "Visible to your family" } })],
    ["null legacy payload", proposal({ kind: "chart", payload: null as never, preview: null })],
    ["malformed strength payload", proposal({ kind: "strength_workout", payload: { exercises: [null] }, preview: null })],
    ["incomplete nutrition payload", proposal({ kind: "nutrition_change", payload: { food_or_meal: "Breakfast", proposed_change: "Add protein" }, preview: null })],
    ["future proposal kind", proposal({ kind: "future_house_action" as never, payload: { title: "Internal future payload" }, preview: null })],
  ])("fails closed for %s without rendering a partial review", async (_caseName, value) => {
    installCoach({ status: "complete", answer: "Please review this.", evidence: [], recommendation: null, proposal: value as FitnessCoachProposal });
    render(<FitnessCoachView {...viewProps} />);
    await requestProposal();

    expect(await screen.findByText("Ask Coach to make this suggestion again before saving it.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Edit" })).toBeDisabled();
    expect(screen.queryByText("Internal future payload")).not.toBeInTheDocument();
  });

  it("accepts the full shared 80-row preview bound", async () => {
    const rows = Array.from({ length: 80 }, (_, index) => `Shopping change ${index + 1}`);
    installCoach({ status: "complete", answer: "Review these changes.", evidence: [], recommendation: null, proposal: proposal({ preview: { change: rows, visibility: "Visible to your family" } }) });
    render(<FitnessCoachView {...viewProps} />);
    await requestProposal();

    expect(await screen.findByText("Shopping change 80")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Confirm" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Edit" })).toBeEnabled();
  });

  it("saves the three context choices explicitly and removes only the chosen private reminder", async () => {
    let reminders = [{ id: "reminder-1", title: "Pack running shoes", remind_at_utc: "2026-08-04T16:30:00Z", notes: "Before leaving", planned_session_id: null, status: "active" }];
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/context-preferences" && init?.method === "PATCH") return JSON.parse(String(init.body)) as never;
      if (path === "/fitness/coach/context-preferences") return { family_calendar: false, household_meals: false, weather: false } as never;
      if (path === "/fitness/coach/reminders/reminder-1" && init?.method === "DELETE") { reminders = []; return undefined as never; }
      if (path === "/fitness/coach/reminders") return reminders as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(<><FitnessCoachContextPreferencesCard online revision={0} /><FitnessCoachRemindersCard online revision={0} /></>);

    fireEvent.click(await screen.findByRole("checkbox", { name: /Family Calendar/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /Household meals/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: /Weather/ }));
    fireEvent.click(screen.getByRole("button", { name: "Save choices" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/context-preferences", {
      method: "PATCH",
      body: JSON.stringify({ family_calendar: true, household_meals: true, weather: true }),
    }, true, false));

    expect(await screen.findByText("Pack running shoes")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    expect(apiMock.mock.calls.some(([path, init]) => path === "/fitness/coach/reminders/reminder-1" && init?.method === "DELETE")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Remove reminder" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/reminders/reminder-1", { method: "DELETE" }, true, false));
    expect(await screen.findByText("No private reminders")).toBeInTheDocument();
  });

  it("consumes a handoff once, never overwrites a nonempty composer, and clears owner UI state", async () => {
    installCoach({ status: "complete", answer: "Owner A answer", evidence: [], recommendation: null, proposal: null }, (path) => {
      if (path === "/fitness/coach/context-preferences") return { family_calendar: false, household_meals: false, weather: false };
      if (path === "/fitness/coach/reminders" || path === "/fitness/coach/recommendations" || path === "/fitness/coach/conversations" || path === "/fitness/coach/memories") return [];
      if (path === "/fitness/coach/preferences") return { personality_preset: "balanced_supportive", directness: 3, challenge_bias: "balanced", detail_level: "standard", custom_instruction: null };
      throw new Error(`Unexpected request: ${path}`);
    });
    const consumed = vi.fn();
    const result = render(<FitnessCoachView {...viewProps} coachDraft={{ text: "Exact Bismarck draft", nonce: 1 }} onCoachDraftConsumed={consumed} />);
    const composer = await screen.findByLabelText("Message your Fitness coach");
    await waitFor(() => {
      expect(composer).toHaveValue("Exact Bismarck draft");
      expect(consumed).toHaveBeenCalledTimes(1);
    });

    fireEvent.change(composer, { target: { value: "My unfinished Coach draft" } });
    result.rerender(<FitnessCoachView {...viewProps} coachDraft={{ text: "A newer Bismarck draft", nonce: 2 }} onCoachDraftConsumed={consumed} />);
    await waitFor(() => {
      expect(screen.getByLabelText("Message your Fitness coach")).toHaveValue("My unfinished Coach draft");
      expect(consumed).toHaveBeenCalledTimes(2);
    });
    fireEvent.click(screen.getByText("Personalise coach"));
    expect(await screen.findByText("Use alongside Fitness")).toBeInTheDocument();

    setOfflineQueueOwner({ id: "owner-b", family_id: "family-a" });
    result.rerender(<FitnessCoachView {...viewProps} revision={1} coachDraft={null} onCoachDraftConsumed={consumed} />);
    await waitFor(() => expect(screen.getByLabelText("Message your Fitness coach")).toHaveValue(""));
    expect(screen.getByText("Personalise coach").closest("details")).not.toHaveAttribute("open");
    expect(screen.queryByText("Use alongside Fitness")).not.toBeInTheDocument();
  });
});
