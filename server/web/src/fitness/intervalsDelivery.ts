import { api } from "../api";
import type {
  FitnessIntervalsActivityImportSync,
  FitnessIntervalsConnectionStatus,
  FitnessIntervalsWorkoutDelivery,
} from "./contract";

const INTERVALS_INTEGRATION_PATH = "/fitness/integrations/intervals";

export function loadIntervalsConnection() {
  return api<FitnessIntervalsConnectionStatus>(`${INTERVALS_INTEGRATION_PATH}/status`, {}, true, false);
}

export function connectIntervalsWithApiKey(apiKey: string) {
  return api<FitnessIntervalsConnectionStatus>(`${INTERVALS_INTEGRATION_PATH}/connect`, {
    method: "POST",
    body: JSON.stringify({ api_key: apiKey }),
  }, true, false);
}

export function startIntervalsOAuth() {
  return api<{ authorization_url: string; expires_at: string }>(`${INTERVALS_INTEGRATION_PATH}/oauth/start`, {
    method: "POST",
    body: JSON.stringify({ return_surface: "web" }),
  }, true, false);
}

export function testIntervalsConnection() {
  return api<FitnessIntervalsConnectionStatus>(`${INTERVALS_INTEGRATION_PATH}/test`, { method: "POST" }, true, false);
}

export function disconnectIntervals() {
  return api<{ status: "disconnected"; retained_publication_count: number }>(INTERVALS_INTEGRATION_PATH, { method: "DELETE" }, true, false);
}

export function updateIntervalsActivityImport(enabled: boolean, lookbackDays = 30) {
  return api<FitnessIntervalsConnectionStatus>(`${INTERVALS_INTEGRATION_PATH}/activity-import`, {
    method: "PUT",
    body: JSON.stringify({ enabled, lookback_days: lookbackDays }),
  }, true, false);
}

export function syncIntervalsActivities() {
  return api<FitnessIntervalsActivityImportSync>(`${INTERVALS_INTEGRATION_PATH}/activity-import/sync`, {
    method: "POST",
  }, true, false);
}

function workoutDeliveryPath(plannedSessionId: string) {
  return `${INTERVALS_INTEGRATION_PATH}/workouts/${encodeURIComponent(plannedSessionId)}`;
}

export function loadIntervalsWorkoutDelivery(plannedSessionId: string) {
  return api<FitnessIntervalsWorkoutDelivery>(workoutDeliveryPath(plannedSessionId), {}, true, false);
}

export function sendIntervalsWorkout(plannedSessionId: string) {
  return api<FitnessIntervalsWorkoutDelivery>(workoutDeliveryPath(plannedSessionId), { method: "POST" }, true, false);
}

export function cancelIntervalsWorkout(plannedSessionId: string) {
  return api<FitnessIntervalsWorkoutDelivery>(workoutDeliveryPath(plannedSessionId), { method: "DELETE" }, true, false);
}
