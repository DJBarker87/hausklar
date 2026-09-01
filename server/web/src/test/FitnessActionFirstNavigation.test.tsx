import { fireEvent, render, screen, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { FitnessModuleView, fitnessPrimarySection } from "../views/fitness/FitnessModuleView";
import { fitnessNotices, fitnessSyncSummary } from "../fitness/offlineStore";

vi.mock("../views/fitness/FitnessTodayView", () => ({
  FitnessTodayView: () => <div>Today content</div>,
}));

vi.mock("../api", () => ({
  api: vi.fn().mockResolvedValue({ id: "setup", status: "complete", main_outcome: null, availability: [], activities: [], equipment: [], food_preferences: [], source_connections: [], coach_style: null, use_family_calendar: false, use_household_meals: false, use_weather: false, memory_enabled: false, preview: null, confirmation: null }),
  ApiError: class ApiError extends Error { status = 500; },
}));

vi.mock("../fitness/offlineStore", () => ({
  dismissFitnessNotice: vi.fn().mockResolvedValue(undefined),
  fitnessNotices: vi.fn().mockResolvedValue([]),
  fitnessSyncSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, compatibilityBlocked: false, compatibilityMessage: null, lastSyncedAt: null }),
  flushFitnessFitImports: vi.fn().mockResolvedValue([]),
  flushFitnessNutritionLabels: vi.fn().mockResolvedValue([]),
  flushFitnessProgressPhotos: vi.fn().mockResolvedValue([]),
  flushFitnessPlannedMealLogs: vi.fn().mockResolvedValue([]),
  flushFitnessSync: vi.fn().mockResolvedValue(null),
}));

describe("Fitness action-first navigation", () => {
  beforeEach(() => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    vi.mocked(fitnessSyncSummary).mockResolvedValue({ pending: 0, failed: 0, compatibilityBlocked: false, compatibilityMessage: null, lastSyncedAt: null });
    vi.mocked(fitnessNotices).mockResolvedValue([]);
  });

  it("keeps one calm local data status and one problem inbox inside Fitness", async () => {
    vi.mocked(fitnessSyncSummary).mockResolvedValue({ pending: 1, failed: 1, compatibilityBlocked: false, compatibilityMessage: null, lastSyncedAt: null });
    vi.mocked(fitnessNotices).mockResolvedValue([{ id: "notice-1", message: "Two copies of an exercise were combined." }]);
    render(<FitnessModuleView online revision={0} section="today" onSectionChange={vi.fn()} onDataChanged={vi.fn()} />);

    const status = (await screen.findByText("Some saved Fitness changes need attention"))
      .closest("[role='status']") as HTMLElement;
    fireEvent.click(within(status).getByRole("button", { name: "Review" }));
    expect(await screen.findByRole("dialog", { name: "Fitness changes to review" })).toBeInTheDocument();
    expect(screen.getByText("Two copies of an exercise were combined.")).toBeInTheDocument();
    expect(screen.queryByText(/protocol|schema|mutation|conflict/i)).not.toBeInTheDocument();
  });

  it("keeps Review, Food and Train primary while putting occasional tools under More", async () => {
    render(<FitnessModuleView online revision={0} section="today" onSectionChange={vi.fn()} onDataChanged={vi.fn()} />);

    const navigation = await screen.findByRole("navigation", { name: "Fitness sections" });
    expect(within(navigation).getAllByRole("button").map((button) => button.textContent?.trim())).toEqual([
      "Review", "Food", "Train", "More",
    ]);
    expect(screen.queryByText(/More fitness areas/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Private to you|Up to date|syncing|waiting|Retry/i)).not.toBeInTheDocument();
  });

  it("selects the visible parent tab for every legacy detail section", () => {
    expect(fitnessPrimarySection("strength")).toBe("training");
    expect(fitnessPrimarySection("activity")).toBe("progress");
    expect(fitnessPrimarySection("recovery")).toBe("progress");
    expect(fitnessPrimarySection("explore")).toBe("progress");
    expect(fitnessPrimarySection("coach")).toBe("today");
  });
});
