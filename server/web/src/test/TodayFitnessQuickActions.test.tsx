import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import {
  TodayExerciseQuickAction,
  TodayFitnessQuickActions,
  TodayViAvailabilityCard,
} from "../components/TodayFitnessQuickActions";
import { rememberFitnessViSchedule } from "../fitness/quickEntry";

const offlineMocks = vi.hoisted(() => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  flushFitnessSync: vi.fn().mockResolvedValue({ status: "ok" }),
  saveFitnessRecords: vi.fn().mockResolvedValue([{ id: "saved-1", queued_offline: true }]),
}));

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

vi.mock("../fitness/offlineStore", () => offlineMocks);

const apiMock = vi.mocked(api);
const breakfastNow = new Date("2026-08-12T08:10:00");

const preferences = {
  meal_times: { breakfast: "08:00", lunch: "12:30", dinner: "18:30" },
};

describe("Today Fitness quick actions", () => {
  beforeEach(() => {
    localStorage.clear();
    apiMock.mockReset();
    offlineMocks.cacheFitnessRecords.mockClear();
    offlineMocks.cachedFitnessRecords.mockReset().mockResolvedValue([]);
    offlineMocks.flushFitnessSync.mockReset().mockResolvedValue({ status: "ok" });
    offlineMocks.saveFitnessRecords.mockReset().mockResolvedValue([{ id: "saved-1", queued_offline: true }]);
    Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  });

  it("offers yesterday’s corresponding meal around the configured time", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/quick-entry-preferences") return preferences as never;
      if (path === "/fitness/food-log?date=2026-08-12") return { entries: [] } as never;
      if (path === "/fitness/food-log?date=2026-08-11") return { entries: [{
        id: "toast-entry",
        food_version_id: "toast-version",
        food_name: "Toast",
        logged_at_utc: "2026-08-11T08:05:00Z",
        nutrition_date: "2026-08-11",
        local_timezone: "Europe/London",
        meal_key: "breakfast",
        entered_amount: 2,
        entered_unit: "slice",
        canonical_amount: 70,
        canonical_unit: "g",
        measurement_quality: "estimated",
      }] } as never;
      if (path === "/fitness/foods") return [{
        id: "toast",
        name: "Toast",
        active: true,
        current_version: {
          id: "toast-version",
          reference_amount: 100,
          reference_unit: "g",
        },
        servings: [{
          id: "toast-slice",
          name: "slice",
          amount: 1,
          unit: "slice",
          canonical_amount: 35,
          canonical_unit: "g",
          measurement_quality: "estimated",
          active: true,
        }],
      }] as never;
      if (path === "/fitness/nutrition/settings") return { id: "settings", timezone: "Europe/London", nutrition_day_start_minutes: 240 } as never;
      return [] as never;
    });

    const changed = vi.fn();
    render(<TodayFitnessQuickActions ownerID="dom" revision={0} onDataChanged={changed} onOpenFullFoodLog={vi.fn()} now={breakfastNow} />);

    expect(await screen.findByRole("heading", { name: "Fill in breakfast" })).toBeInTheDocument();
    expect(await screen.findByText("Toast")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Use yesterday’s breakfast" }));

    const amount = await screen.findByRole("textbox", { name: "Amount" });
    expect(amount).toHaveValue("2");
    fireEvent.change(amount, { target: { value: "3" } });
    expect(offlineMocks.saveFitnessRecords).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Complete meal" }));

    await waitFor(() => expect(offlineMocks.saveFitnessRecords).toHaveBeenCalledOnce());
    expect(offlineMocks.saveFitnessRecords).toHaveBeenCalledWith([
      expect.objectContaining({
        entityType: "food_log_entry",
        payload: expect.objectContaining({
          food_version_id: "toast-version",
          meal_key: "breakfast",
          entered_amount: 3,
          canonical_amount: 105,
          nutrition_date: "2026-08-12",
        }),
      }),
    ]);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/fitness/nutrition/meal-completions",
      expect.objectContaining({ method: "POST" }),
    ));
    expect(screen.queryByRole("heading", { name: "Fill in breakfast" })).not.toBeInTheDocument();
    expect(changed).toHaveBeenCalledTimes(2);
  });

  it("keeps the compact fill-in path useful when the catalogue is empty", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/quick-entry-preferences") return preferences as never;
      if (path.startsWith("/fitness/food-log?")) return { entries: [] } as never;
      if (path === "/fitness/nutrition/settings") return { id: "settings", timezone: "Europe/London", nutrition_day_start_minutes: 240 } as never;
      if (["/fitness/foods", "/fitness/recipes", "/fitness/meal-templates"].includes(path)) return [] as never;
      return [] as never;
    });
    const openFull = vi.fn();
    render(<TodayFitnessQuickActions ownerID="dom" revision={0} onDataChanged={vi.fn()} onOpenFullFoodLog={openFull} now={breakfastNow} />);

    fireEvent.click(await screen.findByRole("button", { name: "Add food" }));
    const search = await screen.findByRole("searchbox", { name: "Search foods" });
    fireEvent.change(search, { target: { value: "mango" } });
    expect(screen.getByRole("button", { name: "Look up “mango”" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Add it manually" }));
    expect(openFull).toHaveBeenCalledOnce();
  });

  it("uses the same search, amount and multi-food flow on Today as the full Nutrition log", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/quick-entry-preferences") return preferences as never;
      if (path.startsWith("/fitness/food-log?")) return { entries: [] } as never;
      if (path.startsWith("/fitness/nutrition/meal-completions?")) return [] as never;
      if (path === "/fitness/foods") return [
        { id: "banana", name: "Banana", active: true, current_version: { id: "banana-v1", reference_amount: 100, reference_unit: "g" }, servings: [] },
        { id: "yoghurt", name: "Greek yoghurt", active: true, current_version: { id: "yoghurt-v1", reference_amount: 100, reference_unit: "g" }, servings: [] },
      ] as never;
      if (["/fitness/recipes", "/fitness/meal-templates"].includes(path)) return [] as never;
      return {} as never;
    });
    render(<TodayFitnessQuickActions ownerID="dom" revision={0} onDataChanged={vi.fn()} onOpenFullFoodLog={vi.fn()} now={breakfastNow} />);

    fireEvent.click(await screen.findByRole("button", { name: "Add food" }));
    const dialog = screen.getByRole("dialog", { name: "Add breakfast foods" });
    let search = await within(dialog).findByRole("searchbox", { name: "Search foods" });
    fireEvent.change(search, { target: { value: "banana" } });
    fireEvent.click(within(dialog).getByRole("button", { name: /Banana.*Saved food/ }));
    fireEvent.change(within(dialog).getByRole("textbox", { name: "Amount" }), { target: { value: "120" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add food" }));

    search = within(dialog).getByRole("searchbox", { name: "Search foods" });
    fireEvent.change(search, { target: { value: "yoghurt" } });
    fireEvent.click(within(dialog).getByRole("button", { name: /Greek yoghurt.*Saved food/ }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Add food" }));
    expect(within(dialog).getByText("Banana")).toBeInTheDocument();
    expect(within(dialog).getByText("Greek yoghurt")).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Complete meal" }));
    await waitFor(() => expect(offlineMocks.saveFitnessRecords).toHaveBeenCalledWith([
      expect.objectContaining({ payload: expect.objectContaining({ food_version_id: "banana-v1", entered_amount: 120 }) }),
      expect.objectContaining({ payload: expect.objectContaining({ food_version_id: "yoghurt-v1", entered_amount: 100 }) }),
    ]));
  });

  it("uses the documented meal-time defaults offline without leaving a loading placeholder", async () => {
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false });

    render(<TodayFitnessQuickActions ownerID="dom" revision={0} onDataChanged={vi.fn()} onOpenFullFoodLog={vi.fn()} now={breakfastNow} />);

    expect(await screen.findByRole("heading", { name: "Fill in breakfast" })).toBeInTheDocument();
    expect(screen.queryByLabelText("Loading meal shortcut")).not.toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/quick-entry-preferences", {}, true, false);
  });

  it("uses owner-specific strength windows as suggestions and saves only kind and exact start", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/quick-entry-preferences") return preferences as never;
      if (path.startsWith("/fitness/strength-availability")) return {
        provider: "school_weights_room",
        source_title: "Example School staff timetable",
        days: [{ date: "2026-08-12", covered: true, windows: [{ start: "17:00", end: "20:00" }] }],
      } as never;
      return [] as never;
    });

    render(<TodayExerciseQuickAction online onDataChanged={vi.fn()} now={new Date("2026-08-12T15:00:00")} />);
    fireEvent.click(await screen.findByRole("button", { name: "Strength" }));
    fireEvent.click(await screen.findByRole("button", { name: "17:00–20:00" }));
    expect(screen.getByLabelText("Start time")).toHaveValue("17:00");
    fireEvent.click(screen.getByRole("button", { name: "Add strength" }));

    await waitFor(() => expect(offlineMocks.saveFitnessRecords).toHaveBeenCalledOnce());
    expect(offlineMocks.saveFitnessRecords).toHaveBeenCalledWith([
      expect.objectContaining({
        entityType: "planned_session",
        payload: expect.objectContaining({
          sport_key: "strength",
          title: "Strength",
          scheduled_date: "2026-08-12",
          status: "accepted",
          visibility: "private",
        }),
      }),
    ]);
    expect(await screen.findByText("Strength added for 17:00.")).toBeInTheDocument();
  });

  it("keeps manual strength entry available when this owner has no loaded timetable", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/quick-entry-preferences") return preferences as never;
      if (path.startsWith("/fitness/strength-availability")) return {
        provider: "vi_training",
        source_title: "Vi Training",
        source_url: "https://www.vitraininggym.co.uk/class-schedule/",
        unavailable_reason: "The live Vi schedule has not been loaded yet.",
        days: [{ date: "2026-08-12", covered: false, windows: [] }],
      } as never;
      return [] as never;
    });

    render(<TodayExerciseQuickAction online onDataChanged={vi.fn()} now={new Date("2026-08-12T15:00:00")} />);
    fireEvent.click(await screen.findByRole("button", { name: "Strength" }));
    expect(await screen.findByText("The live Vi schedule has not been loaded yet.")).toBeInTheDocument();
    expect(screen.getByLabelText("Start time")).toBeEnabled();
    expect(screen.getByRole("button", { name: "Add strength" })).toBeEnabled();
  });
});

describe("Vi Today availability", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  });

  it("hands off to Vi then records the chosen class with a stable retry id", async () => {
    let bookingAttempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/fitness/vi-schedule")) return {
        relevant: true,
        provider: "vi_training",
        source_title: "Vi Training Example School",
        source_url: "https://www.vitraininggym.co.uk/class-schedule/",
        unavailable_reason: null,
        days: [{ date: "2026-08-12", covered: true, classes: [{
          start: "18:00", end: "19:00", label: "Mobility flow", classification: "mobility", booking_url: "https://book.vi.example/class-1",
        }] }],
      } as never;
      if (path === "/fitness/vi-bookings") {
        bookingAttempts += 1;
        if (bookingAttempts === 1) throw new Error("Network hiccup");
        return { status: "booked", event_id: "event-1", title: "Mobility flow", start_time: "2026-08-12T18:00:00+01:00", end_time: "2026-08-12T19:00:00+01:00", location: "Vi Training", classification: "mobility" } as never;
      }
      return [] as never;
    });
    const changed = vi.fn();
    render(<TodayViAvailabilityCard ownerID="kat" onDataChanged={changed} now={new Date("2026-08-12T10:00:00")} />);

    expect(await screen.findByRole("heading", { name: "Classes today" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Book in Vi" })).toHaveAttribute("href", "https://book.vi.example/class-1");
    fireEvent.click(screen.getByRole("button", { name: "Booked" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Network hiccup");
    fireEvent.click(screen.getByRole("button", { name: "Booked" }));

    expect(await screen.findByText("Mobility flow added to your calendar at 18:00.")).toBeInTheDocument();
    const bookingCalls = apiMock.mock.calls.filter(([path]) => path === "/fitness/vi-bookings");
    expect(bookingCalls).toHaveLength(2);
    const first = JSON.parse(String(bookingCalls[0][1]?.body));
    const second = JSON.parse(String(bookingCalls[1][1]?.body));
    expect(second.id).toBe(first.id);
    expect(first).toMatchObject({
      date: "2026-08-12",
      start: "18:00",
      end: "19:00",
      label: "Mobility flow",
      classification: "mobility",
      provider: "vi_training",
    });
    expect(changed).toHaveBeenCalledOnce();
  });

  it("shows every relevant Vi group class rather than filtering to strength", async () => {
    apiMock.mockResolvedValue({
      relevant: true,
      provider: "vi_training",
      source_title: "Vi Training Example School",
      source_url: "https://www.vitraininggym.co.uk/class-schedule/",
      unavailable_reason: null,
      days: [{ date: "2026-08-12", covered: true, classes: [
        { start: "07:00", end: "08:00", label: "Run club", classification: "run", booking_url: null },
        { start: "18:00", end: "19:00", label: "Small-group strength", classification: "strength", booking_url: null },
        { start: "19:00", end: "20:00", label: "Mobility flow", classification: "mobility", booking_url: null },
      ] }],
    } as never);
    render(<TodayViAvailabilityCard ownerID="kat" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);
    expect(await screen.findByText("Run club")).toBeInTheDocument();
    expect(screen.getByText("Small-group strength")).toBeInTheDocument();
    expect(screen.getByText("Mobility flow")).toBeInTheDocument();
    expect(screen.getAllByRole("link", { name: "Book in Vi" })).toHaveLength(3);
    expect(screen.getAllByRole("button", { name: "Booked" })).toHaveLength(3);
  });

  it("labels server-retained Vi times as stale and sends Morgan to the live schedule", async () => {
    apiMock.mockResolvedValue({
      relevant: true,
      provider: "vi_training",
      source_title: "Vi Training Example School",
      source_url: "https://www.vitraininggym.co.uk/class-schedule/",
      unavailable_reason: "Vi could not refresh, so these are the last recently loaded times.",
      days: [{ date: "2026-08-12", covered: true, classes: [{
        start: "18:00", end: "19:00", label: "Mobility flow", classification: "mobility", booking_url: "https://book.vi.example/stale-class",
      }] }],
    } as never);

    render(<TodayViAvailabilityCard ownerID="kat" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);

    expect(await screen.findByRole("status")).toHaveTextContent("these are the last recently loaded times");
    expect(screen.getByRole("link", { name: "Check in Vi" })).toHaveAttribute("href", "https://www.vitraininggym.co.uk/class-schedule/");
    expect(screen.getByRole("button", { name: "Booked" })).toBeEnabled();
  });

  it("does not show the Vi card when the schedule is irrelevant to this owner", async () => {
    apiMock.mockResolvedValue({
      relevant: false,
      provider: "vi_training",
      source_title: "Vi Training",
      source_url: null,
      unavailable_reason: null,
      days: [],
    } as never);
    render(<TodayViAvailabilityCard ownerID="dom" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("/fitness/vi-schedule"), {}, true, false));
    expect(screen.queryByRole("heading", { name: "Classes today" })).not.toBeInTheDocument();
  });

  it("shows Morgan’s last valid Vi schedule offline with a clear stale hand-off", async () => {
    rememberFitnessViSchedule("kat", {
      relevant: true,
      provider: "vi_training",
      source_title: "Vi Training Example School",
      source_url: "https://www.vitraininggym.co.uk/class-schedule/",
      unavailable_reason: null,
      days: [{ date: "2026-08-12", covered: true, classes: [{
        start: "18:00", end: "19:00", label: "Mobility flow", classification: "mobility", booking_url: "https://book.vi.example/stale-class",
      }] }],
    }, "2026-08-12T07:30:00Z");
    Object.defineProperty(navigator, "onLine", { configurable: true, value: false });

    const view = render(<TodayViAvailabilityCard ownerID="kat" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);

    expect(await screen.findByRole("heading", { name: "Classes today" })).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Offline · showing the Vi schedule saved");
    expect(screen.getByRole("link", { name: "Check in Vi" })).toHaveAttribute("href", "https://www.vitraininggym.co.uk/class-schedule/");
    expect(screen.getByRole("button", { name: "Booked" })).toBeDisabled();
    expect(apiMock).not.toHaveBeenCalled();

    view.rerender(<TodayViAvailabilityCard ownerID="dom" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);
    await waitFor(() => expect(screen.queryByRole("heading", { name: "Classes today" })).not.toBeInTheDocument());
  });

  it("keeps cached Vi details visible through a refresh error and recovers on retry", async () => {
    rememberFitnessViSchedule("kat", {
      relevant: true,
      provider: "vi_training",
      source_title: "Vi Training Example School",
      source_url: "https://www.vitraininggym.co.uk/class-schedule/",
      unavailable_reason: null,
      days: [{ date: "2026-08-12", covered: true, classes: [{ start: "18:00", end: "19:00", label: "Mobility flow", classification: "mobility", booking_url: null }] }],
    }, "2026-08-12T07:30:00Z");
    let attempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/fitness/vi-schedule")) {
        attempts += 1;
        if (attempts === 1) throw new Error("Vi did not answer");
        return {
          relevant: true,
          provider: "vi_training",
          source_title: "Vi Training Example School",
          source_url: "https://www.vitraininggym.co.uk/class-schedule/",
          unavailable_reason: null,
          days: [{ date: "2026-08-12", covered: true, classes: [{
            start: "19:00", end: "20:00", label: "Fresh class", classification: "conditioning", booking_url: "https://book.vi.example/fresh-class",
          }] }],
        } as never;
      }
      return [] as never;
    });

    render(<TodayViAvailabilityCard ownerID="kat" onDataChanged={vi.fn()} now={new Date("2026-08-12T10:00:00")} />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Couldn’t refresh Vi");
    expect(screen.getByText("Mobility flow")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Check in Vi" })).toHaveAttribute("href", "https://www.vitraininggym.co.uk/class-schedule/");
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));

    expect(await screen.findByText("Fresh class")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Book in Vi" })).toHaveAttribute("href", "https://book.vi.example/fresh-class");
  });
});
