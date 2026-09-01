import { eachDayOfInterval, format, isSameDay, parseISO, startOfDay } from "date-fns";

import { localISODate } from "./api";
import type { CalendarEvent } from "./types";

function validDate(value: string): Date | null {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/**
 * Return the local calendar dates on which an event overlaps the visible range.
 *
 * Event ends are exclusive, matching calendar/ICS semantics. An event ending at
 * local midnight therefore appears on the preceding day only. Missing or invalid
 * ends keep the event on its start day. The visible range bounds the expansion so
 * an unusually long imported event cannot create an unbounded number of entries.
 */
export function eventCalendarDayKeys(
  event: CalendarEvent,
  visibleStart: Date,
  visibleEnd: Date,
): string[] {
  const eventStart = validDate(event.start_time);
  if (!eventStart) return [];

  const parsedEnd = event.end_time ? validDate(event.end_time) : null;
  const eventEnd = parsedEnd && parsedEnd > eventStart
    ? new Date(parsedEnd.getTime() - 1)
    : eventStart;

  const firstVisibleDay = startOfDay(visibleStart);
  const lastVisibleDay = startOfDay(visibleEnd);
  const firstEventDay = startOfDay(eventStart);
  const lastEventDay = startOfDay(eventEnd);
  const firstDay = firstEventDay > firstVisibleDay ? firstEventDay : firstVisibleDay;
  const lastDay = lastEventDay < lastVisibleDay ? lastEventDay : lastVisibleDay;

  if (firstDay > lastDay) return [];
  return eachDayOfInterval({ start: firstDay, end: lastDay }).map(localISODate);
}

/** Describe a timed event honestly within one of its rendered day entries. */
export function eventTimeLabelForDay(event: CalendarEvent, day: Date): string {
  if (event.all_day || event.start_time.length === 10) return "All day";

  const eventStart = validDate(event.start_time);
  if (!eventStart) return "";
  const eventEnd = event.end_time ? validDate(event.end_time) : null;
  if (isSameDay(eventStart, day)) {
    if (eventEnd && eventEnd > eventStart && isSameDay(eventStart, eventEnd)) {
      return `${format(eventStart, "HH:mm")} – ${format(eventEnd, "HH:mm")}`;
    }
    return format(eventStart, "HH:mm");
  }

  if (!eventEnd || eventEnd <= eventStart) return format(eventStart, "HH:mm");

  const finalOccupiedInstant = new Date(eventEnd.getTime() - 1);
  if (!isSameDay(finalOccupiedInstant, day)) return "Continues";

  const endsAtMidnight = eventEnd.getHours() === 0
    && eventEnd.getMinutes() === 0
    && eventEnd.getSeconds() === 0
    && eventEnd.getMilliseconds() === 0;
  return endsAtMidnight ? "Until midnight" : `Until ${format(eventEnd, "HH:mm")}`;
}
