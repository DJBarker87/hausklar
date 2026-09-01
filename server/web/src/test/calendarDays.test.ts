import { describe, expect, it } from "vitest";

import { eventCalendarDayKeys, eventTimeLabelForDay } from "../calendarDays";
import type { CalendarEvent } from "../types";

declare const process: { env: Record<string, string | undefined> };

function calendarEvent(overrides: Partial<CalendarEvent>): CalendarEvent {
  return {
    id: "event",
    title: "Event",
    start_time: "2026-07-13T09:00:00",
    all_day: false,
    ...overrides,
  };
}

const visibleStart = new Date(2026, 6, 13);
const visibleEnd = new Date(2026, 6, 19);

describe("eventCalendarDayKeys", () => {
  it("includes every local day overlapped by a timed event", () => {
    const event = calendarEvent({
      start_time: "2026-07-13T22:00:00",
      end_time: "2026-07-15T02:00:00",
    });

    expect(eventCalendarDayKeys(event, visibleStart, visibleEnd)).toEqual([
      "2026-07-13",
      "2026-07-14",
      "2026-07-15",
    ]);
  });

  it("uses the exclusive end date for a multi-day all-day event", () => {
    const event = calendarEvent({
      start_time: "2026-07-14",
      end_time: "2026-07-17",
      all_day: true,
    });

    expect(eventCalendarDayKeys(event, visibleStart, visibleEnd)).toEqual([
      "2026-07-14",
      "2026-07-15",
      "2026-07-16",
    ]);
  });

  it("does not include a day when an event ends exactly at its midnight boundary", () => {
    const event = calendarEvent({
      start_time: "2026-07-13T22:00:00",
      end_time: "2026-07-15T00:00:00",
    });

    expect(eventCalendarDayKeys(event, visibleStart, visibleEnd)).toEqual([
      "2026-07-13",
      "2026-07-14",
    ]);
    expect(eventCalendarDayKeys(event, new Date(2026, 6, 15), visibleEnd)).toEqual([]);
  });

  it("groups offset timestamps by the browser's local calendar day", () => {
    const previousTimezone = process.env.TZ;
    process.env.TZ = "Europe/London";
    try {
      const event = calendarEvent({
        // 23:30 UTC is 00:30 the following day in London in July.
        start_time: "2026-07-12T23:30:00Z",
        end_time: "2026-07-13T00:30:00Z",
      });

      expect(eventCalendarDayKeys(event, visibleStart, visibleEnd)).toEqual(["2026-07-13"]);
    } finally {
      if (previousTimezone === undefined) delete process.env.TZ;
      else process.env.TZ = previousTimezone;
    }
  });

  it("bounds long events to the visible calendar range", () => {
    const event = calendarEvent({
      start_time: "2020-01-01",
      end_time: "2030-01-01",
      all_day: true,
    });

    expect(eventCalendarDayKeys(event, visibleStart, visibleEnd)).toEqual([
      "2026-07-13",
      "2026-07-14",
      "2026-07-15",
      "2026-07-16",
      "2026-07-17",
      "2026-07-18",
      "2026-07-19",
    ]);
  });

  it("labels the start, middle, and final local days without repeating the start time", () => {
    const event = calendarEvent({
      start_time: "2026-07-13T22:00:00",
      end_time: "2026-07-15T02:00:00",
    });

    expect(eventTimeLabelForDay(event, new Date(2026, 6, 13))).toBe("22:00");
    expect(eventTimeLabelForDay(event, new Date(2026, 6, 14))).toBe("Continues");
    expect(eventTimeLabelForDay(event, new Date(2026, 6, 15))).toBe("Until 02:00");
    expect(eventTimeLabelForDay(
      calendarEvent({ start_time: "2026-07-13", end_time: "2026-07-16", all_day: true }),
      new Date(2026, 6, 14),
    )).toBe("All day");
  });

  it("retains the full time range for an event contained within one day", () => {
    const event = calendarEvent({
      start_time: "2026-07-13T09:00:00",
      end_time: "2026-07-13T10:30:00",
    });

    expect(eventTimeLabelForDay(event, new Date(2026, 6, 13))).toBe("09:00 – 10:30");
  });

  it("describes an exclusive midnight ending as midnight on the final occupied day", () => {
    const event = calendarEvent({
      start_time: "2026-07-13T22:00:00",
      end_time: "2026-07-15T00:00:00",
    });

    expect(eventTimeLabelForDay(event, new Date(2026, 6, 14))).toBe("Until midnight");
  });
});
