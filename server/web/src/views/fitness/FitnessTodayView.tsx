import {
  Apple,
  CalendarPlus,
  Dumbbell,
  HeartPulse,
  Link2,
  MessageCircle,
  MoveRight,
  Play,
  Route,
} from "lucide-react";
import { useMemo } from "react";

import type { FitnessBodyMeasurement, FitnessPlannedSession, FitnessStrengthSession } from "../../fitness/contract";
import { strengthSessionIsResumable } from "../../fitness/strengthWorkout";
import { FitnessOverviewWeightChart } from "./FitnessProgressCharts";
import type { FitnessViewProps } from "./FitnessModuleView";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessLoadingOrError,
  FitnessPageHeading,
  formatFitnessDate,
  formatFitnessDateTime,
  localDateValue,
  useFitnessCachedRecords,
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessSave,
} from "./shared";

type FitnessExperienceActionKind =
  | "resume_activity"
  | "start_session"
  | "open_session"
  | "move_session"
  | "log_food"
  | "record_readiness"
  | "open_recovery"
  | "open_body_issue"
  | "open_coach"
  | "open_overview"
  | "create_session";

type FitnessExperienceAction = {
  kind: FitnessExperienceActionKind;
  label: string;
  destination: "overview" | "log" | "plan" | "progress" | "coach";
  target_id: string | null;
};

type FitnessExperienceSession = {
  id: string;
  kind: "planned_session" | "active_activity";
  title: string;
  sport_key: string;
  status: "accepted" | "scheduled" | "in_progress";
  starts_at: string | null;
  scheduled_date: string | null;
  duration_minutes: number | null;
  movable: boolean;
};

type FitnessOverview = {
  date: string;
  focus: {
    outcome: "Feel fitter" | "Build strength" | "Run further" | "Improve energy" | "Support my weight" | "Move consistently";
    label: string;
    value: string;
    detail: string | null;
    destination: "overview" | "log" | "plan" | "progress" | "coach";
  } | null;
  session: FitnessExperienceSession | null;
  primary_action: FitnessExperienceAction | null;
  secondary_action: FitnessExperienceAction | null;
  quick_actions: FitnessExperienceAction[];
  coach_nudge: { title: string; message: string; action: FitnessExperienceAction } | null;
  safety_adjustment: { title: string; message: string; action: FitnessExperienceAction } | null;
};

const emptyOverview: FitnessOverview = {
  date: "",
  focus: null,
  session: null,
  primary_action: null,
  secondary_action: null,
  quick_actions: [],
  coach_nudge: null,
  safety_adjustment: null,
};

function actionIcon(kind: FitnessExperienceActionKind) {
  if (kind === "log_food") return Apple;
  if (kind === "open_coach") return MessageCircle;
  if (kind === "open_recovery" || kind === "open_body_issue") return HeartPulse;
  if (kind === "create_session" || kind === "move_session" || kind === "open_session") return CalendarPlus;
  if (kind === "start_session") return Dumbbell;
  if (kind === "resume_activity") return Play;
  return Route;
}

function sessionTiming(session: FitnessExperienceSession): string {
  const parts = [session.sport_key.replaceAll("_", " ")];
  if (session.starts_at) parts.push(formatFitnessDateTime(session.starts_at));
  else if (session.scheduled_date) parts.push(formatFitnessDate(session.scheduled_date));
  if (session.duration_minutes != null) parts.push(`${session.duration_minutes} min`);
  return parts.join(" · ");
}

export function cachedFitnessOverview(
  plans: FitnessPlannedSession[],
  strengthSessions: FitnessStrengthSession[],
  now = new Date(),
): FitnessOverview {
  const activeStrength = strengthSessions
    .filter((item) => strengthSessionIsResumable(item, now))
    .sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc))[0] ?? null;
  if (activeStrength) {
    const session: FitnessExperienceSession = {
      id: activeStrength.id,
      kind: "active_activity",
      title: activeStrength.title,
      sport_key: "strength",
      status: "in_progress",
      starts_at: activeStrength.started_at_utc,
      scheduled_date: null,
      duration_minutes: null,
      movable: false,
    };
    return {
      ...emptyOverview,
      date: localDateValue(now),
      session,
      primary_action: { kind: "resume_activity", label: "Resume", destination: "plan", target_id: session.id },
      quick_actions: [],
    };
  }

  const today = localDateValue(now);
  const planCandidates = plans
    .filter((item) => ["accepted", "scheduled", "in_progress"].includes(item.status))
    .map((item) => {
      const timestampDates = [item.scheduled_start_utc, item.time_window_start_utc, item.time_window_end_utc]
        .filter((value): value is string => Boolean(value))
        .map((value) => localDateValue(new Date(value)));
      const dates = [item.scheduled_date, ...timestampDates].filter((value): value is string => Boolean(value));
      const isToday = dates.includes(today);
      const futureDates = dates.filter((value) => value > today).sort();
      const nextDate = isToday ? today : futureDates[0] ?? null;
      const sortTime = [item.scheduled_start_utc, item.time_window_start_utc, item.time_window_end_utc, item.scheduled_date]
        .filter((value): value is string => Boolean(value))
        .sort()[0] ?? "9999";
      return { item, isToday, nextDate, sortTime };
    })
    .filter((candidate) => candidate.nextDate !== null)
    .sort((left, right) => Number(right.isToday) - Number(left.isToday) || left.nextDate!.localeCompare(right.nextDate!) || left.sortTime.localeCompare(right.sortTime));
  const plan = planCandidates[0]?.item ?? null;
  if (!plan) {
    return {
      ...emptyOverview,
      date: today,
      primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null },
      quick_actions: [],
    };
  }

  const session: FitnessExperienceSession = {
    id: plan.id,
    kind: "planned_session",
    title: plan.title,
    sport_key: plan.sport_key,
    status: plan.status as FitnessExperienceSession["status"],
    starts_at: plan.scheduled_start_utc ?? plan.time_window_start_utc ?? null,
    scheduled_date: plan.scheduled_date ?? null,
    duration_minutes: plan.expected_duration_s == null ? null : Math.round(plan.expected_duration_s / 60),
    movable: plan.movable ?? false,
  };
  const startableStrength = plan.sport_key === "strength" && plan.status !== "in_progress";
  return {
    ...emptyOverview,
    date: today,
    session,
    primary_action: {
      kind: startableStrength ? "start_session" : "open_session",
      label: startableStrength ? "Start" : "Open",
      destination: "plan",
      target_id: plan.id,
    },
    secondary_action: plan.movable ? { kind: "move_session", label: "Move", destination: "plan", target_id: plan.id } : null,
    quick_actions: [
      { kind: "record_readiness", label: "Readiness", destination: "log", target_id: plan.id },
    ],
  };
}

export function FitnessTodayView({ online, revision, onDataChanged, onSectionChange }: FitnessViewProps) {
  const overview = useFitnessEndpoint<FitnessOverview>("/fitness/overview", emptyOverview, revision);
  const measurements = useFitnessCollection<FitnessBodyMeasurement>("/fitness/body/measurements?metric_key=body.weight_kg", "body_measurement", revision);
  const cachedPlans = useFitnessCachedRecords<FitnessPlannedSession>("planned_session", revision);
  const cachedStrengthSessions = useFitnessCachedRecords<FitnessStrengthSession>("strength_session", revision);
  const readinessSave = useFitnessSave(onDataChanged);
  const cachedOverview = useMemo(
    () => cachedFitnessOverview(cachedPlans.data, cachedStrengthSessions.data),
    [cachedPlans.data, cachedStrengthSessions.data],
  );
  const hasServerOverview = Boolean(overview.data.date);
  const data = hasServerOverview ? overview.data : cachedOverview;
  const loading = !hasServerOverview && (cachedPlans.loading || cachedStrengthSessions.loading);

  function openAction(action: FitnessExperienceAction) {
    const targetID = action.target_id;
    const url = new URL(window.location.href);
    ["activity", "session", "fitness-strength-start", "fitness-body-issue", "fitness-recovery"].forEach((key) => url.searchParams.delete(key));

    if (action.kind === "resume_activity") {
      if (targetID) url.searchParams.set("activity", targetID);
      window.history.replaceState({}, "", url);
      onSectionChange(data.session?.sport_key === "strength" ? "strength" : "activity");
      return;
    }
    if (action.kind === "start_session" && data.session?.sport_key === "strength") {
      if (targetID) url.searchParams.set("fitness-strength-start", targetID);
      window.history.replaceState({}, "", url);
      onSectionChange("strength");
      return;
    }
    if (action.kind === "open_session" || action.kind === "move_session") {
      if (targetID) url.searchParams.set("session", targetID);
      window.history.replaceState({}, "", url);
      onSectionChange("training");
      return;
    }
    if (action.kind === "log_food") {
      window.history.replaceState({}, "", url);
      onSectionChange("nutrition");
      return;
    }
    if (action.kind === "open_recovery" || action.kind === "open_body_issue") {
      if (targetID) url.searchParams.set(action.kind === "open_body_issue" ? "fitness-body-issue" : "fitness-recovery", targetID);
      window.history.replaceState({}, "", url);
      onSectionChange("recovery");
      return;
    }
    if (action.kind === "open_coach") {
      window.history.replaceState({}, "", url);
      onSectionChange("coach");
      return;
    }
    if (action.kind === "create_session") {
      window.history.replaceState({}, "", url);
      onSectionChange("training");
    }
  }

  async function recordReadiness(value: number, action: FitnessExperienceAction) {
    await readinessSave.save("session_checkin", {
      planned_session_id: action.target_id ?? data.session?.id ?? null,
      activity_id: data.session?.kind === "active_activity" ? data.session.id : null,
      timing: "pre",
      captured_at_utc: new Date().toISOString(),
      capture_quality: "contemporaneous",
      captured_before_activity_start: data.session?.kind !== "active_activity",
      readiness_1_5: value,
      energy_1_5: null,
      soreness_1_5: null,
      motivation_1_5: null,
      session_rpe_1_10: null,
      notes: null,
    });
  }

  function openConnection(kind: "training" | "withings") {
    const url = new URL(window.location.href);
    if (kind === "training") {
      url.searchParams.set("intervals", "setup");
      window.history.replaceState(window.history.state, "", url);
      onSectionChange("training");
      return;
    }
    url.searchParams.set("fitness-progress", "measurements");
    url.searchParams.set("fitness-connect", "withings");
    window.history.replaceState(window.history.state, "", url);
    onSectionChange("progress");
  }

  function openWeightProgress() {
    const url = new URL(window.location.href);
    url.searchParams.set("fitness-progress", "measurements");
    window.history.replaceState(window.history.state, "", url);
    onSectionChange("progress");
  }

  function openActivityHistory() {
    const url = new URL(window.location.href);
    url.searchParams.delete("activity");
    window.history.replaceState(window.history.state, "", url);
    onSectionChange("activity");
  }

  const session = data.session;
  const primaryAction = data.primary_action;
  const quickActions = data.quick_actions ?? [];
  const readinessAction = quickActions.slice(0, 3).find((action) => action.kind === "record_readiness") ?? null;
  const quickButtons = quickActions.slice(0, 3).filter((action) => action.kind !== "record_readiness");
  const usefulNote = data.safety_adjustment ?? data.coach_nudge;

  return (
    <section aria-labelledby="fitness-overview-title">
      <FitnessPageHeading title="Overview" detail="What you can do next." />
      <FitnessLoadingOrError loading={loading} error={null} retry={overview.reload} />

      {!loading ? (
        <div className="fitness-module__overview-stack">
          <FitnessCard className="fitness-module__session-card">
            <div className="fitness-module__session-card-copy">
              <span className="fitness-module__pill">{session?.kind === "active_activity" ? "In progress" : session ? "Up next" : "Today"}</span>
              <h3>{session?.title ?? "Choose your next session"}</h3>
              <p>{session ? sessionTiming(session) : "A short plan now makes the next action obvious."}</p>
            </div>
            <div className="fitness-module__button-row fitness-module__session-actions">
              {primaryAction ? (() => {
                const Icon = actionIcon(primaryAction.kind);
                return <button type="button" className="button button--primary button--large" onClick={() => openAction(primaryAction)}><Icon aria-hidden="true" size={18} /> {primaryAction.label}</button>;
              })() : null}
              {data.secondary_action ? <button type="button" className="button button--secondary" onClick={() => openAction(data.secondary_action!)}><MoveRight aria-hidden="true" size={17} /> {data.secondary_action.label}</button> : null}
            </div>
          </FitnessCard>

          <FitnessCard className="fitness-module__history-doorway">
            <div>
              <Route aria-hidden="true" size={20} />
              <div><h3>Activity history</h3><p>Past runs, rides and workouts.</p></div>
            </div>
            <button type="button" className="button button--secondary" onClick={openActivityHistory}>View activities</button>
          </FitnessCard>

          {data.focus ? (
            <FitnessCard className="fitness-module__focus-card">
              <div>
                <span className="fitness-module__pill">{data.focus.outcome}</span>
                <h3>{data.focus.label}</h3>
                <strong>{data.focus.value}</strong>
                {data.focus.detail ? <p>{data.focus.detail}</p> : null}
              </div>
              <button type="button" className="button button--secondary" onClick={() => onSectionChange("progress")}>View progress</button>
            </FitnessCard>
          ) : null}

          <FitnessOverviewWeightChart
            measurements={measurements.data}
            loading={measurements.loading}
            error={measurements.error}
            retry={measurements.reload}
            onOpen={openWeightProgress}
            online={online}
            revision={revision}
            onDataChanged={onDataChanged}
          />

          {quickActions.length ? (
            <FitnessCard title="Quick actions" className="fitness-module__quick-card">
              <div className="fitness-module__quick-actions">
                {quickButtons.map((action) => {
                  const Icon = actionIcon(action.kind);
                  return <button type="button" className="button button--secondary" key={`${action.kind}:${action.target_id ?? "none"}`} onClick={() => openAction(action)}><Icon aria-hidden="true" size={17} /> {action.label}</button>;
                })}
                {readinessAction ? (
                  <div className="fitness-module__overview-readiness">
                    <span>{readinessAction.label}</span>
                    <div className="fitness-module__readiness fitness-module__readiness--choices" role="group" aria-label="Record readiness from one to five">
                      {[1, 2, 3, 4, 5].map((value) => <button aria-label={`Record readiness ${value} of 5`} disabled={readinessSave.saving} key={value} onClick={() => void recordReadiness(value, readinessAction).catch(() => undefined)} type="button">{value}</button>)}
                    </div>
                  </div>
                ) : null}
              </div>
              <FitnessFormStatus saving={readinessSave.saving} saved={readinessSave.saved} error={readinessSave.saveError} />
            </FitnessCard>
          ) : null}

          {usefulNote ? (
            <FitnessCard className="fitness-module__useful-note">
              <div>
                <h3>{usefulNote.title}</h3>
                <p>{usefulNote.message}</p>
              </div>
              <button type="button" className="button button--secondary" onClick={() => openAction(usefulNote.action)}>{usefulNote.action.label}</button>
            </FitnessCard>
          ) : null}


          <FitnessCard className="fitness-module__connections-card">
            <details>
              <summary><Link2 aria-hidden="true" size={17} /> Connect an app or device</summary>
              <div className="fitness-module__connections-body">
                <p>Set each connection up where you will use it. Nothing is connected merely by choosing a name.</p>
                <div className="fitness-module__button-row">
                  <button type="button" className="button button--secondary" onClick={() => openConnection("training")}>Garmin / Intervals.icu</button>
                  <button type="button" className="button button--secondary" onClick={() => openConnection("withings")}>Withings</button>
                </div>
              </div>
            </details>
          </FitnessCard>
        </div>
      ) : null}
    </section>
  );
}
