import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type {
  FitnessOnboardingDraft,
  FitnessOnboardingProfile,
  FitnessOnboardingWeekPreview,
} from "../fitness/contract";
import { FitnessOnboardingGate, openFitnessOnboarding } from "../views/fitness/FitnessOnboardingView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

const blankDraft: FitnessOnboardingDraft = {
  main_outcome: null,
  availability: [],
  activities: [],
  equipment: [],
  food_preferences: [],
  source_connections: [],
  coach_style: null,
  use_family_calendar: false,
  use_household_meals: false,
  use_weather: false,
  memory_enabled: false,
};

const week: FitnessOnboardingWeekPreview = {
  preview_id: "preview-1",
  week_start: "2026-08-03",
  summary: "Two useful sessions that fit your week.",
  sessions: [
    { day: "Monday", date: "2026-08-03", start_time: "18:00", activity: "Walking", title: "Easy family walk", duration_minutes: 30, reason: "Fits your Monday evening." },
    { day: "Saturday", date: "2026-08-08", start_time: "09:00", activity: "Strength", title: "Simple strength", duration_minutes: 35, reason: "Uses the time you chose." },
  ],
};

function profile(status: FitnessOnboardingProfile["status"] = "draft", draft: FitnessOnboardingDraft = blankDraft): FitnessOnboardingProfile {
  return { id: "onboarding-1", status, preview: null, confirmation: null, ...draft };
}

const apiMock = vi.mocked(api);

function gate() {
  const onDataChanged = vi.fn();
  const onOpenOverview = vi.fn();
  const view = render(
    <FitnessOnboardingGate onDataChanged={onDataChanged} onOpenOverview={onOpenOverview}>
      <h2>Overview content</h2>
    </FitnessOnboardingGate>,
  );
  return { ...view, onDataChanged, onOpenOverview };
}

describe("Fitness Wave 3 onboarding", () => {
  beforeEach(() => {
    window.localStorage.clear();
    apiMock.mockReset();
    let saved = profile();
    apiMock.mockImplementation(async (path, options = {}) => {
      if (path === "/fitness/onboarding" && options.method === "PUT") {
        const patch = JSON.parse(String(options.body ?? "{}")) as Partial<FitnessOnboardingDraft>;
        saved = { ...saved, ...patch, status: "draft" };
        return saved as never;
      }
      if (path === "/fitness/onboarding") return saved as never;
      if (path === "/fitness/onboarding/preview-week") return week as never;
      if (path === "/fitness/onboarding/skip") {
        saved = { ...saved, status: "skipped" };
        return saved as never;
      }
      if (path === "/fitness/onboarding/confirm") {
        saved = { ...saved, status: "complete", preview: week };
        return { status: "complete", completed_at: "2026-08-03T10:00:00Z", goal_id: "goal-1", session_ids: ["session-1", "session-2"], week } as never;
      }
      throw new Error(`Unexpected request: ${String(path)}`);
    });
  });

  it("previews a human-readable week and makes no plan write before explicit confirmation", async () => {
    const { onDataChanged, onOpenOverview } = gate();
    expect(await screen.findByRole("heading", { name: "Set up Fitness" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Finish later" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Skip this step" })).not.toBeInTheDocument();

    expect(screen.getAllByRole("radio", { name: /Feel fitter|Build strength|Run further|Improve energy|Support my weight|Move consistently/ })).toHaveLength(6);
    fireEvent.click(screen.getByRole("radio", { name: "Feel fitter" }));
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));
    expect(await screen.findByText("When can you realistically move?")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("heading", { name: "Step 2 of 4: Time" })).toHaveFocus());
    fireEvent.click(screen.getByRole("checkbox", { name: "Monday" }));
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));

    expect(await screen.findByText("What do you actually enjoy?")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: "Walking" }));
    expect(screen.queryByText(/equipment/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/food preferences/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/coach/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/apps or devices/i)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));

    expect(await screen.findByRole("heading", { name: "Your first week" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Step 4 of 4: Your week, ready to review" })).toHaveFocus();
    expect(screen.getByText("Easy family walk")).toBeInTheDocument();
    expect(screen.getByText("Simple strength")).toBeInTheDocument();
    expect(screen.getByText("Nothing is added to your plan until you confirm.")).toBeInTheDocument();
    expect(document.body.textContent).not.toMatch(/\b(metric|model|provider|confidence|evidence)\b/i);

    const pathsBeforeConfirm = apiMock.mock.calls.map(([path]) => String(path));
    expect(pathsBeforeConfirm).not.toContain("/fitness/onboarding/confirm");
    expect(pathsBeforeConfirm.every((path) => path.startsWith("/fitness/onboarding"))).toBe(true);
    expect(pathsBeforeConfirm).not.toEqual(expect.arrayContaining(["/fitness/goals", "/fitness/planned-sessions"]));
    const savedPayloads = apiMock.mock.calls
      .filter(([path, options]) => path === "/fitness/onboarding" && options?.method === "PUT")
      .map(([, options]) => JSON.parse(String(options?.body)));
    expect(savedPayloads.at(-1)).toEqual({
      main_outcome: "Feel fitter",
      availability: [{ day: "Monday", time_of_day: "Evening", duration_minutes: 30 }],
      activities: ["Walking"],
    });

    fireEvent.click(screen.getByRole("button", { name: "Confirm my week" }));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => path === "/fitness/onboarding/confirm")).toBe(true));
    expect(await screen.findByRole("heading", { name: "Overview content" })).toBeInTheDocument();
    expect(onDataChanged).toHaveBeenCalledTimes(1);
    expect(onOpenOverview).toHaveBeenCalledTimes(1);
  });

  it("skips the whole setup without trapping the user and resumes later", async () => {
    gate();
    fireEvent.click(await screen.findByRole("button", { name: "Finish later" }));
    expect(await screen.findByRole("heading", { name: "Overview content" })).toBeInTheDocument();
    expect(screen.queryByText("Make Fitness yours")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Finish setup" })).not.toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/onboarding/skip", { method: "POST" }, true, false));

    await act(async () => { openFitnessOnboarding(); });
    expect(await screen.findByRole("heading", { name: "Set up Fitness" })).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/onboarding", { method: "PUT", body: JSON.stringify({}) }, true, false));
  });

  it("keeps the selected draft in place when a step save fails", async () => {
    apiMock.mockImplementation(async (path, options = {}) => {
      if (path === "/fitness/onboarding" && options.method === "PUT") throw new Error("Could not save that choice");
      if (path === "/fitness/onboarding") return profile() as never;
      throw new Error(`Unexpected request: ${String(path)}`);
    });
    gate();
    const choice = await screen.findByRole("radio", { name: "Build strength" });
    fireEvent.click(choice);
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Could not save that choice");
    expect(choice).toBeChecked();
    expect(screen.getByText("What would make Fitness useful right now?")).toBeInTheDocument();
  });

  it("moves keyboard and screen-reader focus to the new step after Continue and Back", async () => {
    gate();
    fireEvent.click(await screen.findByRole("radio", { name: "Move consistently" }));
    fireEvent.click(screen.getByRole("button", { name: /Continue/ }));
    const timeHeading = await screen.findByRole("heading", { name: "Step 2 of 4: Time" });
    await waitFor(() => expect(timeHeading).toHaveFocus());

    fireEvent.click(screen.getByRole("button", { name: "Back" }));
    const goalHeading = await screen.findByRole("heading", { name: "Step 1 of 4: Outcome" });
    await waitFor(() => expect(goalHeading).toHaveFocus());
    expect(screen.getByRole("radio", { name: "Move consistently" })).toBeChecked();
  });

  it("does not mount or fetch the selected destination before onboarding status resolves", async () => {
    let resolveProfile!: (value: FitnessOnboardingProfile) => void;
    apiMock.mockReset();
    apiMock.mockReturnValueOnce(new Promise((resolve) => { resolveProfile = resolve; }) as never);
    const destinationMounted = vi.fn();
    function Destination() {
      useEffect(() => { destinationMounted(); }, []);
      return <h2>Log destination</h2>;
    }
    const onOpenChange = vi.fn();
    render(<FitnessOnboardingGate onDataChanged={vi.fn()} onOpenOverview={vi.fn()} onOpenChange={onOpenChange}><Destination /></FitnessOnboardingGate>);

    expect(screen.getByRole("status")).toHaveTextContent("Opening Fitness…");
    expect(screen.queryByRole("heading", { name: "Log destination" })).not.toBeInTheDocument();
    expect(destinationMounted).not.toHaveBeenCalled();
    expect(onOpenChange).toHaveBeenLastCalledWith(true);

    await act(async () => { resolveProfile(profile("complete")); });
    expect(await screen.findByRole("heading", { name: "Log destination" })).toBeInTheDocument();
    expect(destinationMounted).toHaveBeenCalledTimes(1);
    expect(onOpenChange).toHaveBeenLastCalledWith(false);
  });

  it("falls through to normal Fitness when onboarding status cannot be loaded", async () => {
    apiMock.mockReset();
    apiMock.mockRejectedValueOnce(new Error("Unavailable"));
    render(<FitnessOnboardingGate onDataChanged={vi.fn()} onOpenOverview={vi.fn()}><h2>Overview fallback</h2></FitnessOnboardingGate>);
    expect(screen.getByRole("status")).toHaveTextContent("Opening Fitness…");
    expect(await screen.findByRole("heading", { name: "Overview fallback" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Set up Fitness" })).not.toBeInTheDocument();
  });
});
