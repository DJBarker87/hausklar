import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api, localISODate } from "../api";
import type { CalendarEvent, FamilyMember, FamilyTask } from "../types";
import { PlannerView } from "../views/PlannerView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const members: FamilyMember[] = [{ id: "child", name: "Child One", member_type: "child" }];

describe("Planner preparation checklist", () => {
  beforeEach(() => {
    apiMock.mockReset();
  });

  it("turns a reusable suggestion into an independent checklist for this occurrence", async () => {
    const day = localISODate(new Date());
    const start = `${day}T10:00:00Z`;
    const event: CalendarEvent = {
      id: "swim-series",
      title: "Swimming",
      start_time: start,
      end_time: `${day}T11:00:00Z`,
      all_day: false,
      assigned_to: "child",
      family_member_ids: ["child"],
    };
    const task: FamilyTask = {
      id: "towel-task",
      title: "Pack towel",
      category: "household",
      priority: 2,
      source_event_id: "swim-series",
      prep_occurrence_id: "occurrence-1",
      prep_occurrence_start: start,
      assignees: [{ id: "a", assignee_id: "child", assignee_type: "child", assignee_name: "Child One" }],
    };
    let applied = false;
    apiMock.mockImplementation(async (path, options) => {
      if (String(path).startsWith("/calendar/?")) return [event] as never;
      if (path === "/tasks/?status=pending&limit=200") return (applied ? [task] : []) as never;
      if (String(path).startsWith("/prep-packs/suggestions")) return (applied ? [] : [{
        id: `pack:swim:${start}`,
        template_id: "pack",
        template_name: "Swim kit",
        event_id: "swim-series",
        event_title: "Swimming",
        event_all_day: false,
        event_start: start,
        occurrence_start: start,
        items: ["Pack towel"],
        lead_hours: 24,
        assigned_to: "child",
      }]) as never;
      if (path === "/prep-packs/apply" && options?.method === "POST") {
        applied = true;
        return { status: "added", occurrence_id: "occurrence-1", task_ids: ["towel-task"], task_count: 1 } as never;
      }
      if (path === "/fitness/calendar-preferences") return { show_planned: false, show_completed: false } as never;
      return [] as never;
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    const eventButtons = await screen.findAllByRole("button", { name: /Swimming/ });
    fireEvent.click(eventButtons.find((button) => !button.textContent?.includes("Prepare for")) ?? eventButtons[0]);
    expect(await screen.findByText("1 things · Child One")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Use checklist" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/prep-packs/apply",
      expect.objectContaining({ method: "POST", body: expect.stringContaining("swim-series") }),
    ));
    expect(await screen.findByText("1 remaining")).toBeInTheDocument();
    expect(screen.getAllByText("Pack towel").length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole("button", { name: "Pack Pack towel" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/tasks/towel-task/complete",
      { method: "PATCH" },
    ));
  });
});
