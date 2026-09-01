import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { TodayView } from "../views/TodayView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

describe("Today homework", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return {
        events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: null,
        coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [],
        birthdays: [], weather: null, unavailable: [], finance_action: null,
        homework: [{
          id: "spellings-1",
          child_id: "child-1",
          child_name: "Child One",
          test_date: "2026-08-12",
          word_count: 8,
          practice_count: 1,
          status: "upcoming",
        }],
      } as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });
  });

  it("opens the exact child's exact spelling list from the quiet School section", async () => {
    const openHomework = vi.fn();
    render(<TodayView
      userName="Alex"
      members={[{ id: "child-1", name: "Child One", member_type: "child" }]}
      revision={0}
      onAddEvent={vi.fn()}
      onAddTask={vi.fn()}
      onOpenCalendar={vi.fn()}
      onOpenFamily={vi.fn()}
      onOpenHomework={openHomework}
      onOpenLists={vi.fn()}
      onOpenFinanceAction={vi.fn()}
      onOpenFinancePurchase={vi.fn()}
      onOpenFitnessAction={vi.fn()}
      onDataChanged={vi.fn()}
    />);

    expect(await screen.findByRole("heading", { name: "School" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Child One's spellings/ }));
    expect(openHomework).toHaveBeenCalledWith("child-1", "spellings-1");
  });
});
