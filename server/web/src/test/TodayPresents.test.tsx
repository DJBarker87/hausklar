import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { TodayView } from "../views/TodayView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

function renderToday(onOpenPresent = vi.fn()) {
  render(<TodayView
    userName="Alex"
    members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
    revision={0}
    onAddEvent={vi.fn()}
    onAddTask={vi.fn()}
    onOpenCalendar={vi.fn()}
    onOpenFamily={vi.fn()}
    onOpenPresent={onOpenPresent}
    onOpenLists={vi.fn()}
    onOpenFinanceAction={vi.fn()}
    onOpenFinancePurchase={vi.fn()}
    onOpenFitnessAction={vi.fn()}
    onDataChanged={vi.fn()}
  />);
  return onOpenPresent;
}

describe("Today gift preparation", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return {
        events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: null,
        coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [],
        birthdays: [], homework: [], weather: null, unavailable: [], finance_action: null,
        presents: [{
          id: "gift-1",
          child_id: "child-1",
          recipient_name: "Child One",
          title: "Wooden castle",
          deadline: "2026-08-14",
          days_until_due: 5,
          status: "arrived",
          owner_id: "dom",
          owner_name: "Alex",
          action: "Wrap Wooden castle",
        }],
      } as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });
  });

  it("stays quiet except for due preparation and opens the exact gift", async () => {
    const openPresent = renderToday();
    expect(await screen.findByRole("heading", { name: "Gifts" })).toBeInTheDocument();
    expect(screen.getByText("Child One · Due in 5 days · Alex")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Wrap Wooden castle/ }));
    expect(openPresent).toHaveBeenCalledWith("child-1", "gift-1");
  });
});
