import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { format } from "date-fns";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FamilyMember, TomorrowCard } from "../types";
import { TodayView } from "../views/TodayView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const members: FamilyMember[] = [
  { id: "dom", name: "Alex", member_type: "user" },
  { id: "kat", name: "Morgan", member_type: "user" },
  { id: "child", name: "Child", member_type: "child" },
];
const card: TomorrowCard = {
  target_date: "2026-07-13",
  visible: true,
  acknowledged: false,
  events: [{ id: "event", title: "Nursery", start_time: "2026-07-13T08:30:00+01:00", all_day: false }],
  tasks: [],
  load_prompt: { task_id: "task", title: "Buy party present", due_date: "2026-07-14", priority: 3 },
};

function dashboard(overrides: Record<string, unknown> = {}) {
  return {
    generated_at: new Date().toISOString(), date: format(new Date(), "yyyy-MM-dd"),
    events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: null,
    coordination: card, memories: [], insights: [], prep_suggestions: [], medicine: [],
    birthdays: [], weather: null, family_members: members, illness_readings: {}, unavailable: [], finance_action: null,
    ...overrides,
  };
}

function renderToday(onOpenFitnessAction = vi.fn(), onOpenFamily = vi.fn(), fitnessEnabled = true) {
  return render(<TodayView
    userName="Alex" members={members} revision={0}
    onAddEvent={vi.fn()} onAddTask={vi.fn()} onOpenCalendar={vi.fn()}
    onOpenFamily={onOpenFamily} onOpenLists={vi.fn()}
    onOpenFinanceAction={vi.fn()} onOpenFinancePurchase={vi.fn()}
    onOpenFitnessAction={onOpenFitnessAction}
    onDataChanged={vi.fn()}
    fitnessEnabled={fitnessEnabled}
  />);
}

describe("Today coordination", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard() as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });
  });

  it("loads the household dashboard and owner-private Fitness card separately", async () => {
    renderToday();

    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    await waitFor(() => {
      expect(apiMock).toHaveBeenCalledWith(
        expect.stringMatching(/^\/briefing\/dashboard\?/),
        expect.objectContaining({ onReadSource: expect.any(Function) }),
      );
      expect(apiMock).toHaveBeenCalledWith("/fitness/today-card");
      expect(apiMock).toHaveBeenCalledWith("/fitness/quick-entry-preferences", {}, true, false);
      expect(apiMock).toHaveBeenCalledWith("/commitments/?open_only=true&limit=50");
    });
  });

  it("does not request or show Fitness when this adult has hidden the workspace", async () => {
    renderToday(vi.fn(), vi.fn(), false);

    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/today-card");
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/quick-entry-preferences", {}, true, false);
    expect(screen.queryByRole("heading", { name: "Add exercise" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /More today/ }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      expect.stringMatching(/^\/fitness\/vi-schedule\?start=\d{4}-\d{2}-\d{2}&end=\d{4}-\d{2}-\d{2}$/),
      {},
      true,
      false,
    ));
  });

  it("describes a date-only task as due today instead of inventing a midnight time", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        coordination: null,
        tasks: [{ id: "task-today", title: "Pack swim kit", status: "pending", due_date: format(new Date(), "yyyy-MM-dd"), category: "school" }],
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByText("Due today")).toBeInTheDocument();
    expect(screen.queryByText("Due 00:00")).not.toBeInTheDocument();
  });

  it("shows the accepted session beside the schedule with its exact actions", async () => {
    const openFitnessAction = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") return {
        date: format(new Date(), "yyyy-MM-dd"),
        session: {
          id: "session-1",
          kind: "planned_session",
          title: "Easy 5 km",
          sport_key: "running",
          status: "accepted",
          starts_at: null,
          scheduled_date: "2026-08-03",
          duration_minutes: 45,
          movable: true,
        },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "session-1" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "session-1" },
      } as never;
      return [] as never;
    });

    renderToday(openFitnessAction);
    expect(await screen.findByRole("heading", { name: "Easy 5 km" })).toBeInTheDocument();
    expect(screen.getByText("My Fitness · Any time · 45 min")).toBeInTheDocument();
    expect(screen.queryByText("Nothing scheduled yet")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Start" }));
    expect(openFitnessAction).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "start_session", target_id: "session-1" }),
      expect.objectContaining({ id: "session-1", sport_key: "running" }),
    );
  });

  it("offers one-tap live strength instead of retrospective exercise entry on an empty day", async () => {
    const openFitnessAction = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") return {
        date: format(new Date(), "yyyy-MM-dd"),
        has_completed_activity_today: false,
        session: null,
        primary_action: { kind: "start_strength", label: "Start workout", destination: "plan", target_id: null },
        secondary_action: null,
        nutrition: null,
      } as never;
      return [] as never;
    });

    renderToday(openFitnessAction);

    expect(await screen.findByRole("heading", { name: "Strength workout" })).toBeInTheDocument();
    expect(screen.getByText("My Fitness · Nothing logged today")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Add exercise" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Start workout" }));
    expect(openFitnessAction).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "start_strength", target_id: null }),
      undefined,
    );
  });

  it("shows the opted-in calorie and protein running totals and opens food logging", async () => {
    const openFitnessAction = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") return {
        date: format(new Date(), "yyyy-MM-dd"),
        session: null,
        primary_action: null,
        secondary_action: null,
        nutrition: {
          calories_kcal: 1_245,
          calorie_target_kcal: 2_000,
          protein_g: 78,
          protein_target_g: 120,
          entry_count: 4,
          calories_complete: true,
          protein_complete: false,
        },
      } as never;
      return [] as never;
    });

    renderToday(openFitnessAction);
    expect(await screen.findByRole("heading", { name: "Nutrition today" })).toBeInTheDocument();
    expect(screen.getByText("1,245 kcal")).toBeInTheDocument();
    expect(screen.getByText("of 2,000 kcal")).toBeInTheDocument();
    expect(screen.getByText("≥ 78 g")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Calories: 1245 of 2000 kcal" })).toHaveValue(1_245);
    expect(screen.getByRole("progressbar", { name: "Calories: 1245 of 2000 kcal" })).toHaveClass("is-calories");
    expect(screen.getByRole("progressbar", { name: "Protein: at least 78 of 120 g" })).toHaveClass("is-protein");
    fireEvent.click(screen.getByRole("button", { name: "Log food" }));
    expect(openFitnessAction).toHaveBeenCalledWith({
      kind: "log_food",
      label: "Log food",
      destination: "log",
      target_id: null,
    });
  });

  it("shows empty goal tracks and sets both daily goals directly from Today", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") return {
        date: today,
        session: null,
        primary_action: null,
        secondary_action: null,
        nutrition: {
          calories_kcal: 0,
          calorie_target_kcal: null,
          protein_g: 0,
          protein_target_g: null,
          entry_count: 0,
          calories_complete: true,
          protein_complete: true,
        },
      } as never;
      if (path.startsWith("/fitness/nutrition/targets?")) return [] as never;
      if (path === "/fitness/nutrition/targets") return {} as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByRole("progressbar", { name: "Calories goal not set" })).toHaveValue(0);
    expect(screen.getByRole("progressbar", { name: "Protein goal not set" })).toHaveValue(0);
    fireEvent.click(screen.getByRole("button", { name: "Set goals" }));
    fireEvent.change(await screen.findByRole("textbox", { name: /Calories/ }), { target: { value: "2000" } });
    fireEvent.change(screen.getByRole("textbox", { name: /Protein/ }), { target: { value: "120" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => {
      const writes = apiMock.mock.calls.filter(([path, options]) => (
        path === "/fitness/nutrition/targets" && options?.method === "POST"
      ));
      expect(writes).toHaveLength(2);
      expect(writes.map(([, options]) => JSON.parse(String(options?.body))).sort((left, right) => left.metric_key.localeCompare(right.metric_key))).toEqual([
        expect.objectContaining({ metric_key: "calories_kcal", target_value: 2000, effective_from: today }),
        expect.objectContaining({ metric_key: "protein_g", target_value: 120, effective_from: today }),
      ]);
    });
  });

  it("silently omits optional Fitness when the private request fails", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") throw new Error("Fitness unavailable");
      return [] as never;
    });

    renderToday();
    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    expect(screen.queryByText("Fitness unavailable")).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Add exercise" })).not.toBeInTheDocument();
  });

  it("silently rejects a Fitness card that belongs to a previous day", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null }) as never;
      if (path === "/fitness/today-card") return {
        date: "2020-01-01",
        session: {
          id: "old-session",
          kind: "planned_session",
          title: "Yesterday's run",
          sport_key: "running",
          status: "accepted",
          starts_at: "2020-01-01T08:00:00Z",
          scheduled_date: "2020-01-01",
          duration_minutes: 30,
          movable: true,
        },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "old-session" },
        secondary_action: null,
      } as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/today-card"));
    expect(screen.queryByText("Yesterday's run")).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Add exercise" })).not.toBeInTheDocument();
  });

  it("keeps ordinary cached family data quietly but never presents cached medicine timing", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/briefing/dashboard")) {
        init?.onReadSource?.("cache");
        return dashboard({
          coordination: null,
          tasks: [{ id: "cached-task", title: "Pack swim kit", status: "pending", due_date: null, category: "school" }],
          illnesses: [{ id: "cached-illness", child_id: "child", started_at: new Date().toISOString(), notes: "Resting" }],
          medicine: [{ child_name: "Child", medicine_name: "Calpol", is_safe_now: true, next_safe_at: null }],
        }) as never;
      }
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    const openFamily = vi.fn();
    renderToday(vi.fn(), openFamily);
    expect(await screen.findByText("Pack swim kit")).toBeInTheDocument();
    expect(screen.getByText("Child is unwell")).toBeInTheDocument();
    expect(screen.queryByText(/Calpol:/)).not.toBeInTheDocument();
    expect(screen.queryByText(/live household information|cached|last updated/i)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Review" }));
    expect(openFamily).toHaveBeenCalledWith("medicine");
  });

  it("does not turn a previous-day dashboard into current events, naps or medicine", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/briefing/dashboard")) {
        init?.onReadSource?.("network");
        return dashboard({
          date: "2020-01-01",
          coordination: null,
          events: [{ id: "old-event", title: "Old pickup", start_time: "2020-01-01T15:00:00Z", end_time: "2020-01-01T16:00:00Z", all_day: false }],
          tasks: [{ id: "durable-task", title: "Renew passport", status: "pending", due_date: null, category: "admin" }],
          naps: [{ id: "old-nap", child_id: "child", started_at: "2020-01-01T12:00:00Z", sleep_type: "nap" }],
          medicine: [{ child_name: "Child", medicine_name: "Calpol", is_safe_now: true, next_safe_at: null }],
        }) as never;
      }
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByText("Renew passport")).toBeInTheDocument();
    expect(screen.queryByText("Old pickup")).not.toBeInTheDocument();
    expect(screen.queryByText(/Child is sleeping/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Calpol:/)).not.toBeInTheDocument();
    expect(screen.getByText("Medicine timing needs checking")).toBeInTheDocument();
  });

  it("filters same-response events to those that overlap the current local day", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        coordination: null,
        events: [
          { id: "old-event", title: "Old pickup", start_time: "2020-01-01T15:00:00Z", end_time: "2020-01-01T16:00:00Z", all_day: false },
          { id: "today-event", title: "Today pickup", start_time: `${today}T23:00:00`, end_time: `${today}T23:30:00`, all_day: false },
        ],
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByText("Today pickup")).toBeInTheDocument();
    expect(screen.queryByText("Old pickup")).not.toBeInTheDocument();
  });

  it("shows one calm money action using the shared Today card and an explicit confirmation", async () => {
    apiMock.mockImplementation(async (path, options) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        coordination: null,
        finance_action: {
          id: "payday-1",
          kind: "PAYDAY_TRANSFER",
          space_id: "personal-dom",
          space_kind: "PERSONAL",
          space_name: "Alex",
          due_date: "2026-08-02",
          review_date: null,
          title: null,
          amount_minor: 25_000,
          currency: "GBP",
          source_account_id: "current",
          source_account_label: "Everyday account",
          destination_account_id: "savings",
          destination_account_label: "Protected savings",
          line_id: null,
          purchase_id: null,
          source_id: null,
        },
      }) as never;
      if (path === "/finance/payday-actions/payday-1/resolve") {
        expect(options).toMatchObject({ method: "POST" });
        return {} as never;
      }
      return [] as never;
    });

    renderToday();
    const heading = await screen.findByRole("heading", { name: /Move £250\.00/ });
    expect(heading.closest(".module-action-card")).toHaveClass("today-money-card");
    expect(screen.getByText(/HausKlar records your confirmation; it never moves money/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "I moved it" }));
    expect(await screen.findByText(/Marked done/)).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: /Move £250\.00/ })).not.toBeInTheDocument();
  });

  it("adds a suggested preparation task in one press", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ insights: [{
          id: "swim-gap",
          kind: "prep",
          message: "Swimming is today but no kit task is ready",
          suggested_task_title: "Pack swim kit and towels",
        }] }) as never;
      if (path === "/insights/swim-gap/add-task") {
        return { status: "task_added", title: "Pack swim kit and towels" } as never;
      }
      return [] as never;
    });

    renderToday();
    fireEvent.click(await screen.findByRole("button", { name: /More today/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Pack swim kit and towels" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/insights/swim-gap/add-task",
      { method: "POST" },
    ));
    expect(await screen.findByText("Task added: Pack swim kit and towels")).toBeInTheDocument();
  });

  it("adds every task in a matching preparation pack in one press", async () => {
    apiMock.mockImplementation(async (path, options) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({ coordination: null, prep_suggestions: [{
        id: "swim:event:occurrence",
        template_id: "swim",
        template_name: "Swimming",
        event_id: "event",
        event_title: "Swimming",
        event_all_day: false,
        event_start: new Date().toISOString(),
        occurrence_start: "2026-07-12T09:00:00Z",
        items: ["Pack swim kit", "Pack towels"],
        lead_hours: 24,
      }] }) as never;
      if (path === "/prep-packs/apply") {
        expect(options).toMatchObject({ method: "POST" });
        return { task_ids: ["task-one", "task-two"] } as never;
      }
      return [] as never;
    });

    renderToday();
    fireEvent.click(await screen.findByRole("button", { name: /More today/ }));
    expect(await screen.findByRole("heading", { name: "Things to pack for Swimming" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Add 2 tasks" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/prep-packs/apply", expect.objectContaining({ method: "POST" })));
    expect(await screen.findByText("2 tasks added for Swimming.")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Things to pack for Swimming" })).not.toBeInTheDocument();
  });

  it("shows one calm tomorrow check and acknowledges it", async () => {
    renderToday();
    fireEvent.click(await screen.findByRole("button", { name: /More today/ }));
    expect(await screen.findByRole("heading", { name: "Tomorrow, sorted" })).toBeInTheDocument();
    expect(screen.getByText("Nursery")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Looks right" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/coordination/tomorrow/ack", {
      method: "POST", body: JSON.stringify({ target_date: "2026-07-13" }),
    }));
    expect(screen.queryByRole("heading", { name: "Tomorrow, sorted" })).not.toBeInTheDocument();
  });

  it("keeps today's Example School fact compact and includes relevant weights in tomorrow's summary", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        facility_quick_fact: {
          provider: "Example School College",
          source_title: "Summer 26 Permit & Staff timetable",
          source_document_id: "document-1",
          current_from: "2026-06-27",
          current_to: "2026-09-06",
          update_due: false,
          today: {
            date: "2026-08-09", covered: true,
            family_swimming: [{ start: "12:00", end: "17:00" }], lane_swimming: [],
            weights_room: [], pool_closed: false,
            weights_room_status: "closed", weights_relevant: true,
          },
          tomorrow: {
            date: "2026-08-10", covered: true,
            family_swimming: [{ start: "15:00", end: "17:00" }],
            lane_swimming: [{ start: "06:00", end: "09:30" }],
            weights_room: [{ start: "06:00", end: "12:00" }], pool_closed: false,
            weights_room_status: "open", weights_relevant: true,
          },
        },
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      if (path === "/facilities/timetable?start=2026-08-09&days=14") {
        return Array.from({ length: 14 }, (_, index) => ({
          date: `2026-08-${String(index + 9).padStart(2, "0")}`,
          covered: true,
          family_swimming: index === 0 ? [{ start: "12:00", end: "17:00" }] : [],
          lane_swimming: [],
          weights_room: [],
          pool_closed: false,
          weights_room_status: "closed",
          weights_relevant: true,
        })) as never;
      }
      return [] as never;
    });

    renderToday();
    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    const quickFact = await screen.findByRole("button", {
      name: "See Example School swimming and weights times for today and tomorrow",
    });
    expect(quickFact).toHaveTextContent("Family swim 12:00–17:00");
    expect(quickFact).toHaveTextContent("Tomorrow: Family swim 15:00–17:00");
    expect(quickFact).toHaveTextContent("Weights 06:00–12:00");

    fireEvent.click(quickFact);
    const detail = screen.getByRole("dialog", { name: "Example School swimming & weights" });
    expect(detail).toBeInTheDocument();
    expect(screen.getByText("Lane swimming")).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith(expect.stringMatching(/^\/facilities\/timetable/));
    expect(within(detail).getByRole("link", { name: "Book swimming" })).toHaveAttribute(
      "href",
      "https://bookings.example.invalid",
    );
    fireEvent.click(within(detail).getByRole("button", { name: /Booked swimming on Sunday, 9 August within 12:00–17:00/ }));
    const booking = screen.getByRole("dialog", { name: "Add booked swimming" });
    expect(booking).toHaveTextContent("Available 12:00–17:00");
    expect(within(booking).getByLabelText("Starts")).toHaveValue("12:00");
    expect(within(booking).getByLabelText("Ends")).toHaveValue("13:00");
    fireEvent.change(within(booking).getByLabelText("Starts"), { target: { value: "13:30" } });
    fireEvent.change(within(booking).getByLabelText("Ends"), { target: { value: "14:30" } });
    fireEvent.click(within(booking).getByRole("button", { name: "Add to calendar" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/facilities/swimming-bookings",
      expect.objectContaining({
        method: "POST",
        offlineOperationId: expect.any(String),
        body: expect.stringContaining('"start":"13:30","end":"14:30"'),
      }),
    ));
    expect(await within(detail).findByText("Swimming added to the family calendar.")).toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", {
      name: "Plan strength on Monday, 10 August within 06:00–12:00",
    }));
    const strengthBooking = screen.getByRole("dialog", { name: "Plan strength" });
    expect(strengthBooking).toHaveTextContent("Available 06:00–12:00");
    expect(within(strengthBooking).getByLabelText("Starts")).toHaveValue("06:00");
    expect(within(strengthBooking).getByLabelText("Ends")).toHaveValue("07:00");
    fireEvent.change(within(strengthBooking).getByLabelText("Starts"), { target: { value: "07:00" } });
    fireEvent.change(within(strengthBooking).getByLabelText("Ends"), { target: { value: "08:00" } });
    fireEvent.click(within(strengthBooking).getByRole("button", { name: "Add strength" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/facilities/weights-bookings",
      expect.objectContaining({
        method: "POST",
        offlineOperationId: expect.any(String),
        body: expect.stringContaining('"start":"07:00","end":"08:00"'),
      }),
    ));
    expect(await within(detail).findByText("Strength added to Calendar and Today.")).toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Next 2 weeks" }));
    expect(await within(detail).findByText("Next 2 weeks")).toBeInTheDocument();
    expect(await within(detail).findByText(/Saturday, 22 August/)).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/facilities/timetable?start=2026-08-09&days=14",
    );
    fireEvent.click(within(detail).getByRole("button", { name: "Close" }));

    fireEvent.click(screen.getByRole("button", { name: /More today/ }));
    const tomorrow = screen.getByRole("heading", { name: "Tomorrow, sorted" }).closest("section");
    expect(tomorrow).toHaveTextContent("Family swim 15:00–17:00");
    expect(tomorrow).toHaveTextContent("Weights 06:00–12:00");
    expect(screen.queryByText("Find a family photo")).not.toBeInTheDocument();
  });

  it("assigns the single ownership prompt without showing children", async () => {
    renderToday();
    expect(await screen.findByRole("heading", { name: /Who’s handling/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Child" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Morgan" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/coordination/load/task/assign", {
      method: "POST",
      body: JSON.stringify({ assignee_id: "kat" }),
    }));
    expect(screen.queryByRole("heading", { name: /Who’s handling/ })).not.toBeInTheDocument();
  });

  it("keeps the primary scan to the next event, three tasks and one decision", async () => {
    const past = new Date(Date.now() - 3_600_000).toISOString();
    const future = new Date(Date.now() + 3_600_000).toISOString();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        events: [
        { id: "past", title: "Already finished", start_time: past, end_time: past, all_day: false },
        { id: "next", title: "School pickup", start_time: future, end_time: future, all_day: false },
        ],
        tasks: [1, 2, 3, 4].map((number) => ({
        id: `task-${number}`, title: `Task ${number}`, status: "pending", due_date: future,
        })),
      }) as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByText("School pickup")).toBeInTheDocument();
    expect(screen.queryByText("Already finished")).not.toBeInTheDocument();
    expect(screen.getByText("Task 3")).toBeInTheDocument();
    expect(screen.queryByText("Task 4")).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /Who’s handling/ })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Tomorrow, sorted" })).not.toBeInTheDocument();
  });

  it("only raises safety and family context when it genuinely needs attention", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        medicine: [
          { child_name: "Child", medicine_name: "Calpol", is_safe_now: false, next_safe_at: "2026-07-13T16:00:00Z" },
          { child_name: "Child", medicine_name: "Ibuprofen", is_safe_now: true, next_safe_at: null },
        ],
        birthdays: [{ id: "birthday", person_name: "Grandma", age: 70, days_until: 0 }],
        coordination: null,
      }) as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByRole("heading", { name: "Needs attention" })).toBeInTheDocument();
    expect(screen.getByText("Calpol: minimum interval has not passed")).toBeInTheDocument();
    expect(screen.getByText("Ibuprofen: minimum interval has passed")).toBeInTheDocument();
    expect(screen.getByText(/Check before recording/)).toBeInTheDocument();
    expect(screen.getByText("Grandma's birthday")).toBeInTheDocument();
  });

  it("does not invent an age for an unknown-year birthday", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        birthdays: [{ id: "birthday", person_name: "Grandpa", age: null, days_until: 0 }],
        coordination: null,
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    renderToday();
    expect(await screen.findByText("Grandpa's birthday")).toBeInTheDocument();
    expect(screen.getByText("Birthday today")).toBeInTheDocument();
    expect(screen.queryByText(/Turns/)).not.toBeInTheDocument();
  });

  it("keeps routine dog care and meal admin off Today", async () => {
    const openFamily = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        coordination: null,
        dog: {
          dog_name: "Mabel",
          walked_today: true,
          fed_breakfast_today: true,
          fed_dinner_today: false,
          walk_state: "overdue",
          breakfast_state: "done",
          dinner_state: "due",
          active_walk: null,
        },
        meals: [{
          id: "breakfast",
          date: "2026-08-09",
          meal_type: "breakfast",
          meal_name: "Toast",
        }],
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    renderToday(vi.fn(), openFamily);
    expect(await screen.findByRole("heading", { name: "Up next" })).toBeInTheDocument();
    expect(screen.queryByText("Mabel", { exact: false })).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "At home" })).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Meals" })).not.toBeInTheDocument();
    expect(screen.queryByText("Breakfast")).not.toBeInTheDocument();
    expect(openFamily).not.toHaveBeenCalledWith("dog");
  });

  it("makes a school first day sparkly in both Today and Tomorrow", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    const milestone = {
      id: "ottie-first-day",
      title: "Child Two’s first day at Example Primary School",
      description: null,
      start_time: `${today}T08:40:00`,
      end_time: `${today}T13:10:00`,
      all_day: false,
      location: "Example Primary School",
      assigned_to: null,
      family_member_ids: ["child"],
      event_type: "school_milestone",
    };
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/briefing/dashboard")) return dashboard({
        events: [milestone],
        coordination: {
          ...card,
          load_prompt: null,
          events: [{ ...card.events[0], title: milestone.title, event_type: "school_milestone" }],
        },
      }) as never;
      if (path === "/fitness/today-card") return null as never;
      return [] as never;
    });

    const { container } = renderToday();
    expect(await screen.findAllByText(milestone.title)).not.toHaveLength(0);
    expect(container.querySelector(".today-event-row.is-school-milestone .today-milestone-sprinkles")).not.toBeNull();

    fireEvent.click(screen.getByRole("button", { name: /More today/ }));
    expect(container.querySelector(".tomorrow-card li.is-school-milestone .today-milestone-sprinkles")).not.toBeNull();
  });
});
