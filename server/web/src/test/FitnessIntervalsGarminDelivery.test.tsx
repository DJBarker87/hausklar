import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FitnessIntervalsConnectionStatus, FitnessPlannedSession, FitnessWorkoutDefinition } from "../fitness/contract";
import { FitnessIntervalsGarminPanel } from "../views/fitness/FitnessTrainingPlanningPanels";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const session = {
  id: "run-session-1",
  revision: 2,
  sport_key: "running",
  title: "Tuesday intervals",
  status: "scheduled",
  scheduled_start_utc: "2026-08-04T06:30:00Z",
  scheduled_date: "2026-08-04",
  workout_version_id: "run-version-1",
} as FitnessPlannedSession;
const definition = {
  id: "run-definition-1",
  revision: 1,
  sport_key: "running",
  name: "Tuesday intervals",
  active: true,
  current_version: { id: "run-version-1", revision: 1, title: "Tuesday intervals", version_source: "user", exercise_items: [], accepted_at: "2026-08-03T08:00:00Z" },
} as FitnessWorkoutDefinition;
const disconnected: FitnessIntervalsConnectionStatus = {
  configured: true,
  oauth_available: false,
  personal_api_key_available: true,
  connected: false,
  status: "not_connected",
  auth_method: null,
  oauth_scopes: ["CALENDAR:WRITE", "SETTINGS:READ", "ACTIVITY:READ"],
  athlete_id: null,
  athlete_name: null,
  garmin_training_connected: null,
  last_tested_at: null,
  last_error_code: null,
  activity_read_authorized: false,
  activity_import_enabled: false,
  activity_import_since: null,
  last_activity_import_at: null,
  last_activity_import_error_code: null,
  activity_imported_count: 0,
  activity_import_pending_count: 0,
  activity_import_error_count: 0,
};
const connected: FitnessIntervalsConnectionStatus = {
  ...disconnected,
  connected: true,
  status: "connected",
  auth_method: "personal_api_key",
  athlete_id: "i12345",
  athlete_name: "Reviewer Athlete",
  garmin_training_connected: false,
  last_tested_at: "2026-08-03T08:10:00Z",
  activity_read_authorized: true,
};

describe("Intervals.icu Garmin delivery", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.localStorage.clear();
    window.sessionStorage.clear();
    window.history.replaceState({}, "", "/?view=fitness&section=training");
  });

  it("connects without browser persistence, discloses the bounded share, and sends a scheduled run", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/integrations/intervals/status") return { ...disconnected, oauth_available: true } as never;
      if (path === "/fitness/integrations/intervals/connect" && init?.method === "POST") return connected as never;
      if (path === "/fitness/integrations/intervals/activity-import" && init?.method === "PUT") return { ...connected, activity_import_enabled: true } as never;
      if (path === "/fitness/integrations/intervals/activity-import/sync" && init?.method === "POST") return { discovered_count: 1, queued_count: 1, existing_count: 0, skipped_count: 0, status: { ...connected, activity_import_enabled: true, activity_import_pending_count: 1, last_activity_import_at: "2026-08-03T08:16:00Z" } } as never;
      if (path === "/fitness/integrations/intervals/workouts/run-session-1" && !init?.method) return { planned_session_id: session.id, state: "not_sent", operation: "none", external_id: null, provider_event_id: null, sent_at: null, last_error_code: null, push_errors: [] } as never;
      if (path === "/fitness/integrations/intervals/workouts/run-session-1" && init?.method === "POST") return { planned_session_id: session.id, state: "sent", operation: "created", external_id: "event-1", provider_event_id: "provider-1", sent_at: "2026-08-03T08:15:00Z", last_error_code: null, push_errors: [] } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessIntervalsGarminPanel definitions={[definition]} sessions={[session]} online />);

    expect(await screen.findByText(/Send planned workouts and import completed activities through Intervals.icu/i)).toBeInTheDocument();
    const fallback = screen.getByText("Advanced fallback: download a Garmin FIT file").closest("details");
    expect(fallback).not.toHaveAttribute("open");

    fireEvent.click(screen.getByText("Use a personal API key instead"));
    fireEvent.change(await screen.findByLabelText("Personal API key"), { target: { value: "secret-personal-key" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect Intervals.icu" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals/connect", { method: "POST", body: JSON.stringify({ api_key: "secret-personal-key" }) }, true, false));
    expect(window.localStorage.length).toBe(0);
    expect(window.sessionStorage.length).toBe(0);
    expect(await screen.findByText(/Connected as Reviewer Athlete/)).toBeInTheDocument();
    expect(screen.getByText(/enable planned-workout upload in Intervals.icu/i)).toBeInTheDocument();

    fireEvent.click(screen.getByLabelText("Import automatically"));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals/activity-import", { method: "PUT", body: JSON.stringify({ enabled: true, lookback_days: 30 }) }, true, false));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals/activity-import/sync", { method: "POST" }, true, false));
    expect(await screen.findByText("1 Garmin activity is being imported.")).toBeInTheDocument();
    expect(screen.getByText(/Activity data may include data from Garmin devices/i)).toBeInTheDocument();

    fireEvent.click(await screen.findByRole("button", { name: "Send to Garmin" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals/workouts/run-session-1", { method: "POST" }, true, false));
    expect((await screen.findAllByText("Sent to Intervals.icu")).length).toBeGreaterThan(0);
  });

  it("surfaces Garmin push errors, retries into pending, and disconnects without deleting publications", async () => {
    const readyConnection = { ...connected, garmin_training_connected: true };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/integrations/intervals/status") return readyConnection as never;
      if (path === "/fitness/integrations/intervals/workouts/run-session-1" && !init?.method) return { planned_session_id: session.id, state: "error", operation: "none", external_id: null, provider_event_id: null, sent_at: null, last_error_code: "garmin_push_failed", push_errors: ["Garmin rejected the planned workout upload."] } as never;
      if (path === "/fitness/integrations/intervals/workouts/run-session-1" && init?.method === "POST") return { planned_session_id: session.id, state: "pending", operation: "retried", external_id: "event-1", provider_event_id: "provider-1", sent_at: null, last_error_code: null, push_errors: [] } as never;
      if (path === "/fitness/integrations/intervals/workouts/run-session-1" && init?.method === "DELETE") return { planned_session_id: session.id, state: "cancelled", operation: "cancelled", external_id: null, provider_event_id: null, sent_at: null, last_error_code: null, push_errors: [] } as never;
      if (path === "/fitness/integrations/intervals" && init?.method === "DELETE") return { status: "disconnected", retained_publication_count: 1 } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessIntervalsGarminPanel definitions={[definition]} sessions={[session]} online />);

    expect(await screen.findByText("Garmin rejected the planned workout upload.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect((await screen.findAllByText("Updating Intervals.icu…")).length).toBeGreaterThan(0);

    fireEvent.click(screen.getByRole("button", { name: "Remove from Intervals.icu" }));
    const removal = screen.getByText("Remove this workout from Intervals.icu?").closest<HTMLElement>('[role="alert"]');
    expect(removal).not.toBeNull();
    fireEvent.click(within(removal!).getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals/workouts/run-session-1", { method: "DELETE" }, true, false));
    expect(await screen.findByText(/accepted HausKlar plan is unchanged/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Disconnect" }));
    const confirmation = screen.getByText("Disconnect Intervals.icu?").closest<HTMLElement>('[role="alert"]');
    expect(confirmation).not.toBeNull();
    fireEvent.click(within(confirmation!).getByRole("button", { name: "Disconnect" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/intervals", { method: "DELETE" }, true, false));
    expect(await screen.findByText(/Previously sent workouts stay on Intervals.icu/)).toBeInTheDocument();
  });
});
