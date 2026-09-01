import { CalendarPlus } from "lucide-react";
import { type FormEvent, useEffect, useRef, useState } from "react";

import { api, isOfflineQueuedResult } from "../api";
import type { FacilityTimeWindow } from "../facilities";
import {
  finishUsageWorkflow,
  startSwimmingBooking,
  type UsageSurface,
  type UsageWorkflowRun,
} from "../usageMonitor";
import { Modal } from "./ui";

export type SwimmingBookingSelection = FacilityTimeWindow & {
  date: string;
  sourceSurface: UsageSurface;
};
export type WeightsBookingSelection = FacilityTimeWindow & { date: string };

type FacilityBookingKind = "swimming" | "weights";

type BookingOperation = {
  id: string;
  fingerprint: string;
  timestamp: string;
};

function addMinutes(clock: string, minutes: number): string {
  const [hour, minute] = clock.split(":").map(Number);
  const total = Math.min(23 * 60 + 59, hour * 60 + minute + minutes);
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

function defaultEnd(window: FacilityTimeWindow): string {
  const oneHourLater = addMinutes(window.start, 60);
  return oneHourLater < window.end ? oneHourLater : window.end;
}

function dateLabel(value: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "long",
    day: "numeric",
    month: "long",
    timeZone: "Europe/London",
  }).format(new Date(`${value}T12:00:00Z`));
}

function FacilityBookingDialog({
  kind,
  selection,
  onOpenChange,
  onBooked,
}: {
  kind: FacilityBookingKind;
  selection: (SwimmingBookingSelection | WeightsBookingSelection) | null;
  onOpenChange: (open: boolean) => void;
  onBooked: (message: string) => void;
}) {
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [operation, setOperation] = useState<BookingOperation | null>(null);
  const errorRef = useRef<HTMLParagraphElement>(null);
  const usageRun = useRef<UsageWorkflowRun | null>(null);
  const usageInteractions = useRef(1);

  useEffect(() => {
    if (!selection) return;
    setStart(selection.start);
    setEnd(defaultEnd(selection));
    setSubmitting(false);
    setError("");
    setOperation(null);
    usageInteractions.current = 1;
    if (kind === "swimming") {
      if (usageRun.current) {
        finishUsageWorkflow(usageRun.current, "cancelled", { interactions: 1 });
      }
      usageRun.current = startSwimmingBooking(
        (selection as SwimmingBookingSelection).sourceSurface,
      );
    }
  }, [selection]);

  function close() {
    if (usageRun.current) {
      finishUsageWorkflow(usageRun.current, "cancelled", {
        interactions: usageInteractions.current,
      });
      usageRun.current = null;
    }
    onOpenChange(false);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selection || submitting) return;
    if (start < selection.start || end > selection.end || end <= start) {
      setError(`Choose a start and end within ${selection.start}–${selection.end}.`);
      window.requestAnimationFrame(() => errorRef.current?.focus());
      return;
    }
    if (kind === "swimming" && !usageRun.current) {
      usageRun.current = startSwimmingBooking(
        (selection as SwimmingBookingSelection).sourceSurface,
      );
    }

    const fingerprint = JSON.stringify({ kind, date: selection.date, start, end });
    const nextOperation = operation?.fingerprint === fingerprint
      ? operation
      : { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
    setOperation(nextOperation);
    setSubmitting(true);
    setError("");
    try {
      const result = await api(
        kind === "swimming"
          ? "/facilities/swimming-bookings"
          : "/facilities/weights-bookings",
        {
        method: "POST",
        body: JSON.stringify({
          id: nextOperation.id,
          date: selection.date,
          start,
          end,
          client_id: nextOperation.id,
          client_timestamp: nextOperation.timestamp,
        }),
        offlineOperationId: nextOperation.id,
        },
      );
      setOperation(null);
      if (usageRun.current) {
        finishUsageWorkflow(usageRun.current, "completed", {
          interactions: usageInteractions.current,
          queued: isOfflineQueuedResult(result),
        });
        usageRun.current = null;
      }
      onOpenChange(false);
      if (kind === "swimming") {
        onBooked(
          isOfflineQueuedResult(result)
            ? "Swimming saved offline. It will be added to the family calendar when HausKlar reconnects."
            : "Swimming added to the family calendar.",
        );
      } else {
        onBooked(
          isOfflineQueuedResult(result)
            ? "Strength saved offline. It will appear when HausKlar reconnects."
            : "Strength added to Calendar and Today.",
        );
      }
    } catch (requestError) {
      if (usageRun.current) {
        finishUsageWorkflow(usageRun.current, "failed", {
          interactions: usageInteractions.current,
          error: requestError,
        });
        usageRun.current = null;
      }
      setError(
        requestError instanceof Error
          ? requestError.message
          : kind === "swimming"
            ? "Swimming could not be added to the calendar."
            : "Strength could not be planned.",
      );
      window.requestAnimationFrame(() => errorRef.current?.focus());
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal
      open={selection !== null}
      onOpenChange={(open) => { if (!open) close(); }}
      title={kind === "swimming" ? "Add booked swimming" : "Plan strength"}
      description={selection ? `${dateLabel(selection.date)} · Available ${selection.start}–${selection.end}` : undefined}
    >
      {selection ? (
        <form className="form-stack facility-booking-form" onSubmit={submit}>
          <div className="form-grid">
            <div className="field">
              <label htmlFor={`${kind}-booking-start`}>Starts</label>
              <input
                id={`${kind}-booking-start`}
                type="time"
                min={selection.start}
                max={selection.end}
                value={start}
                autoComplete="off"
                aria-invalid={error ? "true" : undefined}
                aria-describedby={error ? `${kind}-booking-error` : `${kind}-booking-help`}
                onChange={(event) => {
                  usageInteractions.current += 1;
                  setStart(event.target.value);
                }}
              />
            </div>
            <div className="field">
              <label htmlFor={`${kind}-booking-end`}>Ends</label>
              <input
                id={`${kind}-booking-end`}
                type="time"
                min={selection.start}
                max={selection.end}
                value={end}
                autoComplete="off"
                aria-invalid={error ? "true" : undefined}
                aria-describedby={error ? `${kind}-booking-error` : `${kind}-booking-help`}
                onChange={(event) => {
                  usageInteractions.current += 1;
                  setEnd(event.target.value);
                }}
              />
            </div>
          </div>
          <p id={`${kind}-booking-help`} className="facility-booking-help">
            {kind === "swimming"
              ? "Use the exact slot you booked. Everyone will see it in the family calendar."
              : "It will appear in Calendar and on Today."}
          </p>
          {error ? (
            <p id={`${kind}-booking-error`} ref={errorRef} className="form-error" role="alert" tabIndex={-1}>
              {error}
            </p>
          ) : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={submitting} onClick={close}>
              Cancel
            </button>
            <button type="submit" className="button button--primary" disabled={submitting} aria-busy={submitting}>
              <CalendarPlus aria-hidden="true" size={17} />
              {submitting ? "Adding…" : kind === "swimming" ? "Add to calendar" : "Add strength"}
            </button>
          </div>
        </form>
      ) : null}
    </Modal>
  );
}

export function SwimmingBookingDialog(props: {
  selection: SwimmingBookingSelection | null;
  onOpenChange: (open: boolean) => void;
  onBooked: (message: string) => void;
}) {
  return <FacilityBookingDialog kind="swimming" {...props} />;
}

export function WeightsBookingDialog(props: {
  selection: WeightsBookingSelection | null;
  onOpenChange: (open: boolean) => void;
  onBooked: (message: string) => void;
}) {
  return <FacilityBookingDialog kind="weights" {...props} />;
}
