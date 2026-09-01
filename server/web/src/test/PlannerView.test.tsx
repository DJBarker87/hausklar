import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { addDays, format, startOfWeek } from "date-fns";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { PlannerView } from "../views/PlannerView";
import { api, localISODate, localISODateTime } from "../api";
import { deleteFitnessRecord } from "../fitness/offlineStore";
import { setOfflineQueueOwner } from "../offlineQueue";
import type { CalendarEvent, FamilyMember } from "../types";

declare const process: { env: Record<string, string | undefined> };

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

vi.mock("../fitness/offlineStore", async (importOriginal) => {
  const original = await importOriginal<typeof import("../fitness/offlineStore")>();
  return { ...original, deleteFitnessRecord: vi.fn().mockResolvedValue(undefined) };
});

const apiMock = vi.mocked(api);
const deleteFitnessRecordMock = vi.mocked(deleteFitnessRecord);

const members: FamilyMember[] = [
  { id: "dom", name: "Alex", member_type: "user" },
  { id: "kat", name: "Morgan", member_type: "user" },
  { id: "max", name: "Child One", member_type: "child" },
  { id: "anna", name: "Anna", member_type: "child" },
];

function eventToday(overrides: Partial<CalendarEvent> = {}): CalendarEvent {
  const date = localISODate(new Date());
  return {
    id: "event-dom",
    title: "Alex event",
    description: "Bring the forms",
    start_time: `${date}T09:00:00Z`,
    end_time: `${date}T10:00:00Z`,
    all_day: false,
    location: "Kitchen",
    assigned_to: "dom",
    ...overrides,
  };
}

describe("PlannerView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    deleteFitnessRecordMock.mockReset();
    deleteFitnessRecordMock.mockResolvedValue(undefined);
    window.history.replaceState({}, "", "/");
    window.localStorage.clear();
    setOfflineQueueOwner({ id: "dom", family_id: "family" });
  });

  it("makes the weekly planner primary without reserving space for an empty task panel", async () => {
    apiMock.mockResolvedValue([]);
    render(
      <PlannerView
        members={[]}
        revision={0}
        onAddEvent={vi.fn()}
        onDataChanged={vi.fn()}
      />,
    );

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringMatching(/^\/calendar\/\?/), { signal: expect.anything() }));
    expect(apiMock).toHaveBeenCalledWith(expect.stringMatching(/^\/routines\/active\?/), { signal: expect.anything() });
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/meals/plan?"))).toBe(false);
    expect(screen.getByRole("region", { name: "Family calendar" })).toBeInTheDocument();
    expect(screen.queryByRole("complementary", { name: "Tasks needing attention" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Week" })).toHaveAttribute("aria-pressed", "true");

    fireEvent.click(screen.getByRole("button", { name: "Agenda" }));
    expect(await screen.findByText("Nothing planned")).toBeInTheDocument();
  });

  it("uses Calendar's Cycle button as a shortcut to the Fitness cycle surface", async () => {
    apiMock.mockResolvedValue([]);
    const openCycleTracking = vi.fn();
    render(
      <PlannerView
        members={[]}
        revision={0}
        onAddEvent={vi.fn()}
        onOpenCycleTracking={openCycleTracking}
        onDataChanged={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Cycle" }));
    expect(openCycleTracking).toHaveBeenCalledOnce();
    expect(screen.queryByRole("dialog", { name: "Cycle tracking" })).not.toBeInTheDocument();
  });

  it("shows an actionable error and retries both planner feeds", async () => {
    let failCalendar = true;
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/calendar-preferences") return { show_planned: true, show_completed: false };
      if (String(path).startsWith("/calendar/") && failCalendar) throw new Error("Network unavailable");
      return [];
    });
    render(
      <PlannerView
        members={[]}
        revision={0}
        onAddEvent={vi.fn()}
        onDataChanged={vi.fn()}
      />,
    );

    expect(await screen.findByRole("alert")).toHaveTextContent("Network unavailable");
    failCalendar = false;
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(screen.queryByRole("alert")).not.toBeInTheDocument());
    expect(screen.getByRole("region", { name: "Family calendar" })).toBeInTheDocument();
  });

  it("filters the planner by family member and opens a practical day view", async () => {
    const calendarEvents = [
      eventToday(),
      eventToday({ id: "event-kat", title: "Morgan event", assigned_to: "kat" }),
      eventToday({ id: "event-doctor", title: "Doctor", assigned_to: null, family_member_ids: ["kat", "max"], affected_member_ids: ["dom"] }),
      eventToday({ id: "event-shared", title: "Shared event", assigned_to: null }),
    ];
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/") ? calendarEvents : []);

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    expect(await screen.findByRole("button", { name: /Alex event/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Alex" }));
    expect(screen.getByRole("button", { name: /Alex event/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Doctor/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Morgan event/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Shared event/ })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Shared" }));
    expect(screen.getByRole("button", { name: /Shared event/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Alex event/ })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Family" }));
    fireEvent.click(screen.getByRole("button", { name: "Day" }));
    expect(await screen.findByText("Daily schedule")).toBeInTheDocument();
    expect(screen.getByText(/Kitchen · Alex/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add event" })).toBeInTheDocument();
  });

  it("offers compact native selectors for calendar view and people on phones", async () => {
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/") ? [
      eventToday(),
      eventToday({ id: "event-kat", title: "Morgan event", assigned_to: "kat" }),
    ] : []);

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    await screen.findByRole("button", { name: /Alex event/ });
    fireEvent.change(screen.getByRole("combobox", { name: "Calendar view" }), { target: { value: "month" } });
    expect(screen.getByRole("button", { name: "Month" })).toHaveAttribute("aria-pressed", "true");

    fireEvent.change(screen.getByRole("combobox", { name: "Filter calendar by family member" }), { target: { value: "kat" } });
    expect(await screen.findByRole("button", { name: /Morgan event/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Alex event/ })).not.toBeInTheDocument();
  });

  it("shows multi-day timed and all-day events on every overlapping week day", async () => {
    const monday = startOfWeek(new Date(), { weekStartsOn: 1 });
    const timedStart = new Date(monday);
    timedStart.setHours(22, 0, 0, 0);
    const timedEnd = addDays(timedStart, 2);
    timedEnd.setHours(2, 0, 0, 0);
    const midnightEnd = addDays(monday, 1);
    midnightEnd.setHours(0, 0, 0, 0);

    const calendarEvents = [
      eventToday({
        id: "multi-timed",
        title: "Family trip",
        start_time: localISODateTime(timedStart),
        end_time: localISODateTime(timedEnd),
      }),
      eventToday({
        id: "multi-all-day",
        title: "School holiday",
        start_time: localISODate(addDays(monday, 1)),
        end_time: localISODate(addDays(monday, 4)),
        all_day: true,
      }),
      eventToday({
        id: "midnight-boundary",
        title: "Evening visit",
        start_time: localISODateTime(monday),
        end_time: localISODateTime(midnightEnd),
      }),
    ];
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/") ? calendarEvents : []);

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    const calendar = await screen.findByRole("region", { name: "Family calendar" });
    const weekTripEntries = await within(calendar).findAllByRole("button", { name: /Family trip/ });
    expect(weekTripEntries).toHaveLength(3);
    expect(within(weekTripEntries[0]).getByText("22:00")).toBeInTheDocument();
    expect(within(weekTripEntries[1]).getByText("Continues")).toBeInTheDocument();
    expect(within(weekTripEntries[2]).getByText("Until 02:00")).toBeInTheDocument();
    const allDayEntries = within(calendar).getAllByRole("button", { name: /School holiday/ });
    expect(allDayEntries).toHaveLength(3);
    allDayEntries.forEach((entry) => expect(within(entry).getByText("All day")).toBeInTheDocument());
    expect(within(calendar).getAllByRole("button", { name: /Evening visit/ })).toHaveLength(1);

    fireEvent.click(within(calendar).getByRole("button", {
      name: `Open ${format(addDays(monday, 1), "EEEE, d MMMM")}`,
    }));
    expect(await within(calendar).findByRole("button", { name: /Continues Family trip/ })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Agenda" }));
    const agendaTripEntries = await within(calendar).findAllByRole("button", { name: /Family trip/ });
    expect(agendaTripEntries).toHaveLength(2);
    expect(within(agendaTripEntries[0]).getByText("Continues")).toBeInTheDocument();
    expect(within(agendaTripEntries[1]).getByText("Until 02:00")).toBeInTheDocument();
  });

  it("fetches a half-open local-offset range and shows a BST boundary event", async () => {
    const previousTimezone = process.env.TZ;
    process.env.TZ = "Europe/London";
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-14T12:00:00Z"));
    try {
      const boundaryEvent = eventToday({
        id: "bst-boundary",
        title: "Boundary handover",
        start_time: "2026-07-12T23:30:00Z",
        end_time: "2026-07-13T00:30:00Z",
      });
      apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [boundaryEvent] : []);

      render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

      expect(await screen.findByRole("button", { name: /Boundary handover/ })).toBeInTheDocument();
      expect(apiMock).toHaveBeenCalledWith(
        "/calendar/?start=2026-07-13T00:00:00%2B01:00&end=2026-07-20T00:00:00%2B01:00&limit=200",
        { signal: expect.anything() },
      );
      expect(apiMock).toHaveBeenCalledWith("/routines/active?start=2026-07-13&end=2026-07-19", { signal: expect.anything() });
      expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/meals/plan?"))).toBe(false);
    } finally {
      vi.useRealTimers();
      if (previousTimezone === undefined) delete process.env.TZ;
      else process.env.TZ = previousTimezone;
    }
  });

  it("includes routines without pulling meal planning into Calendar", async () => {
    const date = localISODate(new Date());
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/calendar/?")) return [];
      if (String(path).startsWith("/routines/active?")) return [{ routine_item_id: "school", person_id: "max", person_name: "Child One", name: "School", color: "#22b8cf", date }];
      if (String(path).startsWith("/meals/plan?")) return [{ id: "dinner", date, meal_type: "dinner", meal_name: "Pasta" }];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    expect(await screen.findByText("School")).toBeInTheDocument();
    expect(screen.queryByText("Pasta")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/meals/plan?"))).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Day" }));

    expect(await screen.findByRole("heading", { name: "Household plan" })).toBeInTheDocument();
    expect(screen.getByText("Routine · Child One")).toBeInTheDocument();
    expect(screen.queryByText("dinner")).not.toBeInTheDocument();
  });

  it("shows one leave-and-pickup timeline and changes just one day", async () => {
    const date = localISODate(new Date());
    const handoff = {
      id: `pickup:${date}`,
      handoff_id: "pickup",
      kind: "pickup",
      date,
      time_of_day: "16:20",
      term_person_id: "max",
      term_person_name: "Child One",
      owner_user_id: "max",
      owner_name: "Child One",
      label: "Child One pickup",
      is_override: false,
    };
    apiMock.mockImplementation(async (path, init) => {
      if (String(path).startsWith("/routines/handoffs?")) return [handoff] as never;
      if (path === `/routines/handoffs/pickup/dates/${date}` && init?.method === "PUT") {
        return { ...handoff, time_of_day: "16:45", is_override: true } as never;
      }
      return [] as never;
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    const timeline = await screen.findByRole("button", { name: /Leave and pickup.*Child One pickup at 16:20/ });
    expect(timeline).toHaveClass("coordination-card");
    fireEvent.click(timeline);
    const detail = screen.getByRole("dialog", { name: new RegExp(`Leave & pickup .*${format(new Date(), "d MMM")}`) });
    fireEvent.click(within(detail).getByRole("button", { name: /Child One pickup.*16:20/ }));
    const editor = screen.getByRole("dialog", { name: new RegExp(`Child One pickup .*${format(new Date(), "d MMM")}`) });
    expect(within(editor).queryByRole("combobox")).not.toBeInTheDocument();
    fireEvent.change(within(editor).getByLabelText("Time"), { target: { value: "16:45" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save for this day" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      `/routines/handoffs/pickup/dates/${date}`,
      expect.objectContaining({
        method: "PUT",
        body: expect.stringContaining('"time_of_day":"16:45"'),
      }),
    ));
    const changeCall = apiMock.mock.calls.find(([path, init]) => path === `/routines/handoffs/pickup/dates/${date}` && init?.method === "PUT");
    expect(JSON.parse(String(changeCall?.[1]?.body))).not.toHaveProperty("owner_user_id");
  });

  it("sets the term-time handoff week once from Calendar", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/routines/handoffs/schedule" && init?.method === "PUT") {
        return { items: JSON.parse(String(init.body)).items } as never;
      }
      if (path === "/routines/handoffs/schedule") return { items: [] } as never;
      return [] as never;
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    fireEvent.click(screen.getByRole("button", { name: /Handoffs/ }));
    const editor = await screen.findByRole("dialog", { name: "Leave & pickup" });
    expect(within(editor).queryByText("Who")).not.toBeInTheDocument();
    fireEvent.change(within(editor).getByLabelText("Mon Child One pickup time"), { target: { value: "16:10" } });
    fireEvent.click(within(within(editor).getByRole("group", { name: "Child pickup timetable" })).getByRole("button", { name: "Anna" }));
    fireEvent.change(within(editor).getByLabelText("Mon Anna pickup time"), { target: { value: "15:50" } });
    fireEvent.change(within(editor).getByLabelText("Alex leaves work on Mon"), { target: { value: "17:05" } });
    fireEvent.click(within(within(editor).getByRole("group", { name: "Work departure timetable" })).getByRole("button", { name: "Morgan" }));
    fireEvent.change(within(editor).getByLabelText("Morgan leaves work on Mon"), { target: { value: "16:55" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/routines/handoffs/schedule",
      expect.objectContaining({ method: "PUT" }),
    ));
    const call = apiMock.mock.calls.find(([path, init]) => path === "/routines/handoffs/schedule" && init?.method === "PUT");
    const sentItems = JSON.parse(String(call?.[1]?.body)).items;
    expect(sentItems).toEqual(expect.arrayContaining([
      { kind: "pickup", weekday: 0, time_of_day: "16:10", term_person_id: "max" },
      { kind: "pickup", weekday: 0, time_of_day: "15:50", term_person_id: "anna" },
      expect.objectContaining({ kind: "work_departure", weekday: 0, time_of_day: "17:05", owner_user_id: "dom", term_person_id: "dom" }),
      expect.objectContaining({ kind: "work_departure", weekday: 0, time_of_day: "16:55", owner_user_id: "kat", term_person_id: "kat" }),
    ]));
  });

  it("orders events, timed routines, preparation and due tasks without meals", async () => {
    const date = localISODate(new Date());
    const event = eventToday({
      id: "trip",
      title: "Leave for station",
      start_time: `${date}T09:00:00`,
      end_time: `${date}T09:30:00`,
    });
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/calendar/?")) return [event];
      if (String(path).startsWith("/routines/active?")) return [{ routine_item_id: "bags", person_id: "dom", person_name: "Alex", name: "Pack school bags", color: "#22b8cf", date, time: "07:30" }];
      if (String(path).startsWith("/meals/plan?")) return [{ id: "dinner", date, meal_type: "dinner", meal_name: "Pasta" }];
      if (String(path).startsWith("/prep-packs/suggestions?")) return [{ id: "prep", template_id: "travel", template_name: "Travel", event_id: "trip", event_title: "Leave for station", event_all_day: false, event_start: `${date}T09:00:00`, occurrence_start: `${date}T09:00:00`, items: ["Tickets", "Water"], lead_hours: 1 }];
      if (path === "/tasks/?status=pending&limit=200") return [{ id: "task", title: "Confirm taxi", due_date: `${date}T12:00:00`, category: "admin", priority: 2, assignees: [] }];
      return [];
    });
    const { container } = render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    await screen.findByRole("button", { name: /Leave for station/ });
    fireEvent.click(screen.getByRole("button", { name: "Day" }));
    await screen.findByRole("heading", { name: "The day" });

    const plan = container.querySelector(".planner-day-plan");
    expect(plan).not.toBeNull();
    expect([...plan!.querySelectorAll("strong")].map((node) => node.textContent)).toEqual([
      "Pack school bags",
      "Prepare for Leave for station",
      "Leave for station",
      "Confirm taxi",
    ]);
    expect(screen.queryByText("Pasta")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/meals/plan?"))).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Month" }));
    const calendar = screen.getByRole("region", { name: "Family calendar" });
    expect(await within(calendar).findByText("Routine")).toBeInTheDocument();
    expect(within(calendar).getByText("Prep")).toBeInTheDocument();
  });

  it("turns an event into a commitment page with clashes, prep, tasks and every document", async () => {
    const date = localISODate(new Date());
    const trip = eventToday({
      id: "trip",
      title: "Paris train",
      start_time: `${date}T09:00:00`,
      end_time: `${date}T11:00:00`,
      location: "St Pancras International",
      attachments: [
        { relation_id: "rel-ticket", role: "ticket", position: 0, id: "ticket", title: "Eurostar tickets", original_filename: "tickets.pdf", media_type: "application/pdf", file_size: 100, download_url: "/api/documents/ticket/content" },
        { relation_id: "rel-booking", role: "booking", position: 1, id: "booking", title: "Hotel booking", original_filename: "hotel.pdf", media_type: "application/pdf", file_size: 200, download_url: "/api/documents/booking/content" },
      ],
    });
    const clash = eventToday({ id: "clash", title: "School meeting", start_time: `${date}T10:00:00`, end_time: `${date}T10:30:00` });
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/calendar/?")) return [trip, clash];
      if (path === "/tasks/?status=pending&limit=200") return [{ id: "passport-task", title: "Pack passports", due_date: `${date}T08:00:00`, source_event_id: "trip", category: "admin", priority: 2, assignees: [] }];
      if (String(path).startsWith("/prep-packs/suggestions?")) return [{ id: "prep", template_id: "travel", template_name: "Travel pack", event_id: "trip", event_title: "Paris train", event_all_day: false, event_start: `${date}T09:00:00`, occurrence_start: `${date}T09:00:00`, items: ["Chargers", "Snacks"], lead_hours: 12 }];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: /Paris train/ }));
    const detail = screen.getByRole("dialog", { name: "Paris train" });

    expect(within(detail).getByRole("link", { name: "Directions" })).toHaveAttribute("href", expect.stringContaining("St%20Pancras%20International"));
    expect(within(detail).getByRole("heading", { name: "Clashes" })).toBeInTheDocument();
    expect(within(detail).getByText("School meeting")).toBeInTheDocument();
    expect(within(detail).getByText("Pack passports")).toBeInTheDocument();
    expect(within(detail).getByText("Chargers · Snacks")).toBeInTheDocument();
    expect(within(detail).getByText("Ticket")).toBeInTheDocument();
    expect(within(detail).getByText("Booking")).toBeInTheDocument();
    expect(within(detail).getByText("Eurostar tickets")).toBeInTheDocument();
    expect(within(detail).getByText("Hotel booking")).toBeInTheDocument();
  });

  it("shows planned Fitness by default, keeps completed activity off, and renders only presentation-safe fields", async () => {
    const date = localISODate(new Date());
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/calendar-layer?")) return [{
        id: "fitness-plan-1",
        owner_user_id: "dom",
        layer_kind: "planned",
        display_title: "Progression run",
        sport_key: "running",
        status: "accepted",
        scheduled_date: date,
        detail_id: "fitness-plan-1",
        notes: "private workout detail must not render",
        readiness_1_5: 2,
        route: "private route",
      }];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    expect(await screen.findByRole("button", { name: /Progression run/ })).toHaveTextContent("Alex");
    expect(screen.queryByText(/Private Fitness/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    expect(screen.getByRole("button", { name: "My training" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Completed activity" })).toHaveAttribute("aria-pressed", "false");
    expect(screen.queryByText("private workout detail must not render")).not.toBeInTheDocument();
    expect(screen.queryByText("private route")).not.toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(expect.stringMatching(/^\/fitness\/calendar-layer\?.*include_completed=false/), { signal: expect.anything() }, true, false);
  });

  it("deletes a planned exercise from Calendar only after explicit confirmation", async () => {
    const date = localISODate(new Date());
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/calendar-layer?")) return [{
        id: "fitness-plan-projection",
        owner_user_id: "dom",
        layer_kind: "planned",
        display_title: "Easy run",
        sport_key: "running",
        status: "accepted",
        scheduled_date: date,
        detail_id: "fitness-plan-record",
      }];
      return [];
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Easy run/ }));
    const detail = screen.getByRole("dialog", { name: "Easy run" });
    fireEvent.click(within(detail).getByRole("button", { name: "Delete planned exercise" }));
    expect(deleteFitnessRecordMock).not.toHaveBeenCalled();

    const confirmation = screen.getByRole("dialog", { name: "Delete planned exercise?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Delete" }));

    await waitFor(() => expect(deleteFitnessRecordMock).toHaveBeenCalledWith("planned_session", "fitness-plan-record"));
    expect(screen.queryByRole("button", { name: /Easy run/ })).not.toBeInTheDocument();
  });

  it("shows a logged activity only under the person who owns it", async () => {
    const date = localISODate(new Date());
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/calendar-layer?")) return [{
        id: "fitness-activity-1",
        owner_user_id: "dom",
        layer_kind: "completed",
        display_title: "Evening run",
        sport_key: "running",
        status: "completed",
        scheduled_start_utc: `${date}T18:00:00Z`,
        detail_id: "fitness-activity-1",
      }];
      if (path === "/fitness/calendar-preferences") {
        return { show_planned: true, show_completed: true };
      }
      return [];
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    expect(await screen.findByRole("button", { name: /Evening run/ })).toHaveTextContent("Alex");
    expect(screen.queryByText(/Private Fitness/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Morgan" }));
    expect(screen.queryByRole("button", { name: /Evening run/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Shared" }));
    expect(screen.queryByRole("button", { name: /Evening run/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Alex" }));
    expect(screen.getByRole("button", { name: /Evening run/ })).toBeInTheDocument();
  });

  it("uses the adult's server Calendar preference and saves changes across clients", async () => {
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/fitness/calendar-preferences" && !options) {
        return { show_planned: false, show_completed: true };
      }
      if (path === "/fitness/calendar-preferences" && options?.method === "PATCH") {
        expect(JSON.parse(String(options.body))).toEqual({ show_planned: true, show_completed: true });
        return { show_planned: true, show_completed: true };
      }
      return [];
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "My training" })).toHaveAttribute("aria-pressed", "false");
      expect(screen.getByRole("button", { name: "Completed activity" })).toHaveAttribute("aria-pressed", "true");
    });

    fireEvent.click(screen.getByRole("button", { name: "My training" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/calendar-preferences", {
      method: "PATCH",
      body: JSON.stringify({ show_planned: true, show_completed: true }),
    }));
  });

  it("keeps the useful local Calendar defaults when preference sync is unavailable", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/calendar-preferences") throw new Error("Preference sync unavailable");
      return [];
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/calendar-preferences"));
    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    expect(screen.getByRole("button", { name: "My training" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Completed activity" })).toHaveAttribute("aria-pressed", "false");
    expect(screen.queryByText("Preference sync unavailable")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Completed activity" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Completed activity" })).toHaveAttribute("aria-pressed", "false"));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("projects Example School availability only through the adult's chosen calendar layers", async () => {
    const date = localISODate(new Date());
    const changed = vi.fn();
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/facilities/calendar-preferences" && options?.method === "PATCH") {
        return JSON.parse(String(options.body));
      }
      if (path === "/facilities/calendar-preferences") {
        return { show_family_swimming: true, show_personal_facilities: true };
      }
      if (String(path).startsWith("/facilities/calendar-layer?")) return [
        {
          id: "swim-1", layer_kind: "family_swimming", display_title: "Family swimming",
          start_time: `${date}T12:00:00+01:00`, end_time: `${date}T17:00:00+01:00`,
          owner_user_id: null, source_document_id: "document-1",
          source_title: "Summer timetable", location: "Example School College", read_only: true,
        },
        {
          id: "weights-1", layer_kind: "weights_room", display_title: "Weights room",
          start_time: `${date}T06:00:00+01:00`, end_time: `${date}T12:00:00+01:00`,
          owner_user_id: "dom", source_document_id: "document-1",
          source_title: "Summer timetable", location: "Example School College", read_only: true,
        },
      ];
      return [];
    });

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={changed} />);
    expect(await screen.findByRole("button", { name: /Family swimming/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Weights room/ })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Shared" }));
    expect(screen.getByRole("button", { name: /Family swimming/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Weights room/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Alex" }));
    expect(screen.getByRole("button", { name: /Weights room/ })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Weights room/ }));
    const detail = screen.getByRole("dialog", { name: "Weights room" });
    expect(detail).toHaveTextContent("Read-only availability from the confirmed Example School timetable");
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Plan strength" }));
    const strengthBooking = screen.getByRole("dialog", { name: "Plan strength" });
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
    expect(await screen.findByText("Strength added to Calendar and Today.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Shared" }));
    fireEvent.click(screen.getByRole("button", { name: /Family swimming/ }));
    const swimmingDetail = screen.getByRole("dialog", { name: "Family swimming" });
    fireEvent.click(within(swimmingDetail).getByRole("button", { name: "Booked" }));
    const booking = screen.getByRole("dialog", { name: "Add booked swimming" });
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
    expect(await screen.findByText("Swimming added to the family calendar.")).toBeInTheDocument();
    expect(changed).toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    const familyToggle = screen.getByRole("button", { name: "Family swimming" });
    expect(familyToggle).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(familyToggle);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/facilities/calendar-preferences",
      {
        method: "PATCH",
        body: JSON.stringify({
          show_family_swimming: false,
          show_personal_facilities: true,
        }),
      },
    ));
  });

  it("previews and explicitly confirms a new Example School Word timetable", async () => {
    const changed = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path === "/facilities/calendar-preferences") {
        return { show_family_swimming: false, show_personal_facilities: false };
      }
      if (path === "/facilities/example_school/preview") return {
        filename: "Summer 26 timetable.docx", title: "Summer 26 timetable",
        sha256: "a".repeat(64), valid_from: "2026-06-27", valid_to: "2026-09-06",
        counts: {
          days: 72, family_swimming_sessions: 64, lane_swimming_sessions: 50,
          weights_room_open_days: 52, pool_closed_days: 5, weights_room_closed_days: 20,
        },
        changes: { added_days: 72, changed_days: 0, removed_days: 0 },
        sample_days: [{
          date: "2026-06-27", covered: true,
          family_swimming: [{ start: "12:00", end: "17:00" }],
          lane_swimming: [], weights_room: [{ start: "08:00", end: "12:00" }],
          pool_closed: false, weights_room_status: "open", weights_relevant: true,
        }], issues: [], already_imported: false, can_confirm: true,
      };
      if (path === "/facilities/example_school/import") return {
        version_id: "version-1", document_id: "document-1", imported: true,
        preview: {},
      };
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={changed} />);

    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    fireEvent.click(screen.getByRole("button", { name: /Update Example School timetable/ }));
    const file = new File(["word bytes"], "Summer 26 timetable.docx", {
      type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    });
    fireEvent.change(screen.getByLabelText("Choose Example School timetable file"), {
      target: { files: [file] },
    });

    const review = await screen.findByRole("dialog", { name: "Update Example School timetable" });
    expect(review).toHaveTextContent("27 Jun – 6 Sep 2026");
    expect(review).toHaveTextContent("64");
    expect(review).toHaveTextContent("Family swim 12:00–17:00");
    expect(review).toHaveTextContent("Weights 08:00–12:00");
    expect(review).toHaveTextContent("Lane swimming and weights are shown only to Alex.");
    expect(review).toHaveTextContent("Nothing changes until you confirm");
    expect(apiMock.mock.calls.find(([path]) => path === "/facilities/example_school/preview")?.[1]?.body).toBeInstanceOf(FormData);

    fireEvent.click(within(review).getByRole("button", { name: "Use this timetable" }));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => path === "/facilities/example_school/import")).toBe(true));
    expect(await screen.findByText("Example School swimming and weights times updated.")).toBeInTheDocument();
    expect(changed).toHaveBeenCalled();
  });

  it("shows term ranges and days off in a family year overview", async () => {
    const year = new Date().getFullYear();
    apiMock.mockImplementation(async (path) => {
      if (path === "/routines/terms") return [{ id: "term-1", person_id: "max", label: "Autumn term", start_date: `${year}-09-03`, end_date: `${year}-12-18` }];
      if (String(path).startsWith("/routines/holidays?")) return [{ id: "holiday-1", person_id: "max", date: `${year}-10-23`, label: "Inset day" }];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(screen.getByRole("button", { name: "Year" }));

    expect(await screen.findByLabelText(`Family year overview for ${year}`)).toBeInTheDocument();
    expect(await screen.findByRole("img", { name: /Child One, October: Autumn term, Inset day/ })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Child One" })).toBeInTheDocument();
  });

  it("edits all event details through the calendar contract", async () => {
    const calendarEvent = eventToday();
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [calendarEvent] : []);
    const changed = vi.fn();
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={changed} />);

    fireEvent.click(await screen.findByRole("button", { name: /Alex event/ }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Alex event" })).getByRole("button", { name: "Edit" }));
    const editor = await screen.findByRole("dialog", { name: "Edit event" });
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Updated football" } });
    fireEvent.click(within(editor).getByLabelText("Morgan"));
    fireEvent.click(within(editor).getByLabelText("Alex"));
    fireEvent.change(within(editor).getByLabelText("Ends"), { target: { value: "11:30" } });
    fireEvent.change(within(editor).getByLabelText("Repeat"), { target: { value: "weekly" } });
    fireEvent.change(within(editor).getByLabelText("Location (optional)"), { target: { value: "Playing fields" } });
    fireEvent.change(within(editor).getByLabelText("Notes (optional)"), { target: { value: "Bring boots" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/event-dom", expect.objectContaining({ method: "PUT" })));
    const updateCall = apiMock.mock.calls.find(([path, init]) => path === "/calendar/event-dom" && init?.method === "PUT");
    const body = JSON.parse(String(updateCall?.[1]?.body));
    expect(body).toMatchObject({
      title: "Updated football",
      assigned_to: "kat",
      family_member_ids: ["kat"],
      end_time: expect.stringContaining("T11:30:00"),
      recurrence_rule: expect.stringMatching(/^FREQ=WEEKLY;BYDAY=/),
      location: "Playing fields",
      description: "Bring boots",
    });
    expect(changed).toHaveBeenCalled();
  });

  it("opens and overrides an imported event from its detail card", async () => {
    const importedEvent = eventToday({
      id: "school-feed-event",
      title: "Wrong term date",
      source_name: "School calendar",
      read_only: true,
    });
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [importedEvent] : []);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Wrong term date/ }));
    const detail = screen.getByRole("dialog", { name: "Wrong term date" });
    expect(detail).toHaveTextContent("Editing makes a HausKlar override without changing the source calendar.");
    expect(within(detail).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Edit" }));

    const editor = await screen.findByRole("dialog", { name: "Edit event" });
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Correct term date" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/school-feed-event",
      expect.objectContaining({ method: "PUT" }),
    ));
    const updateCall = apiMock.mock.calls.find(([path, init]) => path === "/calendar/school-feed-event" && init?.method === "PUT");
    expect(JSON.parse(String(updateCall?.[1]?.body))).toMatchObject({ title: "Correct term date" });
  });

  it("makes away rugby obvious and switches venue without generic editing", async () => {
    const homeFixture = eventToday({
      id: "rugby-fixture",
      title: "HOME — Colts C rugby v Dulwich College",
      start_time: `${localISODate(new Date())}T12:00:00Z`,
      end_time: `${localISODate(new Date())}T18:00:00Z`,
      location: "HOME",
      source_name: "Example School Colts C rugby",
      source_color: "#2563EB",
      event_type: "rugby_fixture",
      rugby_venue: "home",
      rugby_venue_overridden: false,
      family_member_ids: ["dom"],
      affected_member_ids: ["kat"],
      read_only: true,
    });
    const awayFixture = {
      ...homeFixture,
      title: "AWAY — Colts C rugby v Dulwich College",
      location: "AWAY",
      source_color: "#DC2626",
      rugby_venue: "away" as const,
      rugby_venue_overridden: true,
    };
    const changed = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/calendar/rugby/fixtures/rugby-fixture/venue" && init?.method === "PUT") return awayFixture;
      if (String(path).startsWith("/calendar/?")) return [homeFixture];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={changed} />);

    const calendarButton = await screen.findByRole("button", { name: /HOME — Colts C rugby/ });
    expect(calendarButton.getAttribute("style")).toContain("--member-color: #2563EB");
    fireEvent.click(calendarButton);
    const detail = screen.getByRole("dialog", { name: homeFixture.title });
    expect(detail).toHaveTextContent("Home fixture");
    expect(detail).toHaveTextContent("Reserved in the planner from 1:00 to 7:00 pm.");
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Mark as AWAY" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/rugby/fixtures/rugby-fixture/venue",
      { method: "PUT", body: JSON.stringify({ venue: "away" }) },
    ));
    const awayDetail = await screen.findByRole("dialog", { name: awayFixture.title });
    expect(awayDetail).toHaveTextContent("AWAY");
    expect(awayDetail).toHaveTextContent("Away fixture — travel blocked out");
    expect(within(awayDetail).getByRole("button", { name: "Mark as HOME" })).toBeInTheDocument();
    expect(changed).toHaveBeenCalledOnce();
  });

  it("shows calculated cycle events without ordinary edit controls", async () => {
    const cycleEvent = eventToday({
      id: "cycle:kat:predicted-period",
      title: "Predicted period",
      start_time: localISODate(new Date()),
      end_time: null,
      all_day: true,
      assigned_to: "kat",
      event_type: "cycle_predicted_period",
      source_name: "Cycle tracking",
      read_only: true,
    });
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [cycleEvent] : []);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Predicted period/ }));
    const detail = screen.getByRole("dialog", { name: "Predicted period" });
    expect(detail).toHaveTextContent("Calculated by cycle tracking.");
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
  });

  it("shows safe Finance dates behind the separate Money preference", async () => {
    const managedEvent = eventToday({
      id: "finance-renewal:r1:2026-08-01",
      title: "Car insurance renewal due",
      description: "£900 from Household current account",
      event_type: "finance_commitment",
      read_only: true,
      managed_source: {
        kind: "finance_renewal",
        source_id: "r1",
        deep_link: "/?view=finance&section=more&renewal=r1",
        label: "Household renewal",
      },
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/projection-preferences" && init?.method === "PATCH") return { show_money: false, show_deliveries: true };
      if (path === "/finance/projection-preferences") return { show_money: true, show_deliveries: true };
      if (String(path).startsWith("/calendar/?")) return [managedEvent];
      return [];
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} financeEnabled />);

    fireEvent.click(await screen.findByRole("button", { name: /Car insurance renewal due/ }));
    const detail = screen.getByRole("dialog", { name: "Car insurance renewal due" });
    expect(detail).toHaveTextContent("Financial details stay there");
    expect(detail).not.toHaveTextContent("£900");
    expect(within(detail).getByRole("link", { name: /Open Household renewal/ })).toHaveAttribute("href", "/?view=finance&section=more&renewal=r1");
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Close" }));

    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    const moneyToggle = screen.getByRole("button", { name: "Money" });
    await waitFor(() => expect(moneyToggle).toBeEnabled());
    fireEvent.click(moneyToggle);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/finance/projection-preferences", expect.objectContaining({ method: "PATCH" })));
    await waitFor(() => expect(screen.queryByRole("button", { name: /Car insurance renewal due/ })).not.toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Deliveries" })).toHaveAttribute("aria-pressed", "true");
  });

  it("previews an attached original and returns to the event detail", async () => {
    const attachedEvent = eventToday({
      title: "Doctor appointment",
      source_document_id: "doctor-letter",
      source_document: {
        id: "doctor-letter",
        title: "Doctor letter",
        original_filename: "doctor.pdf",
        media_type: "application/pdf",
        file_size: 2048,
        download_url: "/api/documents/doctor-letter/content",
      },
    });
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [attachedEvent] : []);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Doctor appointment/ }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Doctor appointment" })).getByRole("button", { name: /Doctor letter/ }));
    const viewer = screen.getByRole("dialog", { name: "Doctor letter" });
    expect(await within(viewer).findByTitle("Doctor letter")).toHaveAttribute("src", "/api/documents/doctor-letter/content");
    fireEvent.click(within(viewer).getByRole("button", { name: "Close preview" }));

    const restored = await screen.findByRole("dialog", { name: "Doctor appointment" });
    expect(within(restored).getByRole("button", { name: /Doctor letter/ })).toBeInTheDocument();
  });

  it("anchors to and opens a linked event outside the current week", async () => {
    const distantEvent = eventToday({
      id: "distant-event",
      title: "Future school meeting",
      start_time: "2027-02-17T16:00:00Z",
      end_time: "2027-02-17T17:00:00Z",
    });
    window.history.replaceState({}, "", "/?view=planner&event=distant-event&event_date=2027-02-17");
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [distantEvent] : []);

    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    expect(await screen.findByRole("dialog", { name: "Future school meeting" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(expect.stringMatching(/^\/calendar\/\?start=2027-02/), { signal: expect.anything() });
    expect(new URL(window.location.href).searchParams.has("event")).toBe(false);
    expect(new URL(window.location.href).searchParams.has("event_date")).toBe(false);
  });

  it("requires a plain-language scope before deleting a generated occurrence", async () => {
    const occurrence = eventToday({
      id: "series-1::2026-07-15T09:00:00+00:00",
      series_id: "series-1",
      is_generated_occurrence: true,
      recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
      title: "Weekly football",
    });
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [occurrence] : []);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Weekly football/ }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Weekly football" })).getByRole("button", { name: "Delete" }));
    const scopeDialog = await screen.findByRole("dialog", { name: "Delete repeating event?" });
    expect(within(scopeDialog).getByRole("button", { name: /Only this event/ })).toBeInTheDocument();
    expect(within(scopeDialog).getByRole("button", { name: /This and later events/ })).toBeInTheDocument();
    expect(within(scopeDialog).getByRole("button", { name: /Every event in series/ })).toBeInTheDocument();
    fireEvent.click(within(scopeDialog).getByRole("button", { name: /Only this event/ }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/series-1/occurrences/delete",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    const call = apiMock.mock.calls.find(([path]) => path === "/calendar/series-1/occurrences/delete");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
      scope: "only_this",
      occurrence_start: occurrence.start_time,
    });
  });

  it("chooses a future-series edit scope before opening the editor", async () => {
    const occurrence = eventToday({
      id: "series-2::2026-07-15T09:00:00+00:00",
      series_id: "series-2",
      is_generated_occurrence: true,
      recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
      title: "Weekly swimming",
    });
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? [occurrence] : []);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Weekly swimming/ }));
    const detail = screen.getByRole("dialog", { name: "Weekly swimming" });
    expect(detail).toHaveTextContent("HausKlar asks which events to change");
    fireEvent.click(within(detail).getByRole("button", { name: "Edit" }));
    const scopeDialog = await screen.findByRole("dialog", { name: "Edit repeating event?" });
    fireEvent.click(within(scopeDialog).getByRole("button", { name: /This and later events/ }));

    const editor = await screen.findByRole("dialog", { name: "Edit event" });
    expect(editor).toHaveTextContent("Earlier events stay unchanged. This event starts a new series.");
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Later swimming" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/series-2/occurrences/edit",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    const call = apiMock.mock.calls.find(([path]) => path === "/calendar/series-2/occurrences/edit");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
      scope: "this_and_later",
      occurrence_start: occurrence.start_time,
      updates: { title: "Later swimming" },
    });
  });

  it("shows matching Toast bookings as shaded windows on each child's lane", async () => {
    const date = localISODate(new Date());
    const toast = [
      eventToday({ id: "toast-max", title: "Toast · Child One", start_time: `${date}T16:45:00`, end_time: `${date}T17:30:00`, event_type: "toast_club", read_only: true }),
      eventToday({ id: "toast-anna", title: "Toast · Anna", start_time: `${date}T16:45:00`, end_time: `${date}T17:30:00`, event_type: "toast_club", read_only: true }),
    ];
    apiMock.mockImplementation(async (path) => String(path).startsWith("/calendar/?") ? toast : []);

    const { container } = render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    const timeline = await screen.findByRole("button", { name: /Leave and pickup.*Child One can be collected 16:45 to 17:30/ });
    expect(timeline).toHaveAccessibleName(/Anna can be collected 16:45 to 17:30/);
    expect(container.querySelectorAll(".coordination-card")).toHaveLength(1);
    expect(container.querySelectorAll(".coordination-window")).toHaveLength(2);
    expect(timeline).toHaveTextContent("Child One");
    expect(timeline).toHaveTextContent("Anna");
  });

  it("adds a term-time club from Calendar", async () => {
    apiMock.mockResolvedValue([]);
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    fireEvent.click(screen.getByRole("button", { name: /Clubs/ }));
    const manager = await screen.findByRole("dialog", { name: "Clubs" });
    fireEvent.click(within(manager).getByRole("button", { name: "Add club" }));
    fireEvent.change(within(manager).getByLabelText("Club"), { target: { value: "Football" } });
    fireEvent.change(within(manager).getByLabelText("Child"), { target: { value: "max" } });
    fireEvent.change(within(manager).getByLabelText("Starts"), { target: { value: "15:45" } });
    fireEvent.change(within(manager).getByLabelText("Ends"), { target: { value: "16:45" } });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/clubs/" && init?.method === "POST") return await new Promise(() => undefined) as never;
      return [] as never;
    });
    fireEvent.click(within(manager).getByRole("button", { name: "Save" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/clubs/",
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"name":"Football"') }),
    ));
  });

  it("keeps a cancelled club visible and changes only that date", async () => {
    const date = localISODate(new Date());
    const club = eventToday({
      id: "club-football",
      title: "Football · Child One",
      start_time: `${date}T15:45:00`,
      end_time: `${date}T16:45:00`,
      event_type: "school_club",
      read_only: true,
      managed_source: { kind: "school_club", source_id: "football", deep_link: "/clubs/football", label: "Football" },
    });
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/calendar/?")) return [club] as never;
      return [] as never;
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Football/ }));
    const detail = screen.getByRole("dialog", { name: "Football · Child One" });
    apiMock.mockImplementation(async (path, init) => {
      if (path === `/clubs/football/dates/${date}/cancel` && init?.method === "PUT") return await new Promise(() => undefined) as never;
      if (String(path).startsWith("/calendar/?")) return [club] as never;
      return [] as never;
    });
    fireEvent.click(within(detail).getByRole("button", { name: "Cancel this date" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      `/clubs/football/dates/${date}/cancel`,
      expect.objectContaining({ method: "PUT" }),
    ));
  });

  it("reviews a Toast form before using its dates", async () => {
    const preview = {
      sha256: "a".repeat(64), source_title: "Toast Autumn 2026", child_id: "max", child_name: "Child One",
      valid_from: "2026-08-31", valid_to: "2026-12-18", base_start_time: "15:30",
      booked_days: 42, until_1630: 0, until_1730: 42,
      changes: { added: 42, changed: 0, removed: 0, unchanged: 0 }, already_imported: false, can_confirm: true,
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/toast-club/status") return [] as never;
      if (path === "/toast-club/preview" && init?.method === "POST") return preview as never;
      return [] as never;
    });
    render(<PlannerView members={members} revision={0} onAddEvent={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(screen.getByRole("button", { name: "Choose calendars" }));
    fireEvent.click(screen.getByRole("button", { name: /Toast Club/ }));
    const file = new File(["docx"], "toast.docx", { type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document" });
    fireEvent.change(screen.getByLabelText("Choose Toast booking form"), { target: { files: [file] } });
    const manager = await screen.findByRole("dialog", { name: "Toast Club" });
    expect(await within(manager).findByText("42 days")).toBeInTheDocument();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/toast-club/import" && init?.method === "POST") return await new Promise(() => undefined) as never;
      if (path === "/toast-club/status") return [] as never;
      return [] as never;
    });
    fireEvent.click(within(manager).getByRole("button", { name: "Use these dates" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/toast-club/import",
      expect.objectContaining({ method: "POST", body: expect.any(FormData) }),
      true,
      false,
    ));
  });
});
