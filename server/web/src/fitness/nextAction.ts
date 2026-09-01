import type { FitnessNextAction, FitnessNextActionLink } from "./contract";
import { currentOfflineQueueOwner } from "../offlineQueue";

export type FitnessNextActionSection = "today" | "training" | "recovery" | "coach";

export type FitnessNextActionDestination = {
  section: FitnessNextActionSection;
  query?: { key: string; value: string };
};

const DISMISSED_PREFIX = "hausklar:fitness-next-action:dismissed:";

export function fitnessNextActionDestination(link: FitnessNextActionLink): FitnessNextActionDestination {
  if (link.kind === "open_planned_session") return { section: "training", query: { key: "session", value: link.target } };
  if (link.kind === "record_readiness") return { section: "today", query: { key: "fitness-readiness", value: link.target } };
  if (link.kind === "open_body_issue") return { section: "recovery", query: { key: "fitness-issue", value: link.target } };
  if (link.kind === "open_recovery") return { section: "recovery", query: { key: "fitness-recovery", value: link.target } };
  if (link.kind === "open_coach") return { section: "coach", query: { key: "fitness-recommendation", value: link.target } };
  return { section: "today" };
}

export function openFitnessNextAction(
  link: FitnessNextActionLink,
  onSectionChange: (section: FitnessNextActionSection) => void,
) {
  const destination = fitnessNextActionDestination(link);
  const url = new URL(window.location.href);
  for (const key of ["session", "fitness-readiness", "fitness-issue", "fitness-recovery", "fitness-recommendation"]) {
    url.searchParams.delete(key);
  }
  if (destination.query) url.searchParams.set(destination.query.key, destination.query.value);
  window.history.replaceState({}, "", url);
  onSectionChange(destination.section);
}

function localDigest(value: string): string {
  let first = 0x811c9dc5;
  let second = 0x9e3779b9;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    first = Math.imul(first ^ code, 0x01000193);
    second = Math.imul(second ^ code, 0x85ebca6b);
  }
  return `${(first >>> 0).toString(16).padStart(8, "0")}${(second >>> 0).toString(16).padStart(8, "0")}`;
}

function actionFingerprint(action: FitnessNextAction): string {
  return JSON.stringify({
    title: action.title,
    body: action.body,
    urgency: action.urgency,
    evidence: action.evidence.map((item) => ({ id: item.id, kind: item.kind, label: item.label, summary: item.summary })),
    action: action.action,
    secondary_action: action.secondary_action,
    expires_at: action.expires_at,
    source: action.source,
  });
}

function dismissalKey(action: FitnessNextAction): string | null {
  const owner = currentOfflineQueueOwner();
  if (!owner) return null;
  const ownerKey = `${owner.familyId}:${owner.userId}`;
  return `${DISMISSED_PREFIX}${localDigest(`${ownerKey}\u0000${actionFingerprint(action)}`)}`;
}

export function isFitnessNextActionDismissed(action?: FitnessNextAction | null): boolean {
  if (!action || typeof window === "undefined") return false;
  const key = dismissalKey(action);
  if (!key) return false;
  const value = window.localStorage.getItem(key);
  if (!value) return false;
  const dismissedUntil = Date.parse(value);
  const actionExpiresAt = Date.parse(action.expires_at);
  if (!Number.isFinite(dismissedUntil) || dismissedUntil <= Date.now() || dismissedUntil !== actionExpiresAt) {
    window.localStorage.removeItem(key);
    return false;
  }
  return true;
}

export function dismissFitnessNextAction(action: FitnessNextAction): void {
  if (typeof window === "undefined") return;
  const key = dismissalKey(action);
  if (!key) return;
  window.localStorage.setItem(key, action.expires_at);
}
