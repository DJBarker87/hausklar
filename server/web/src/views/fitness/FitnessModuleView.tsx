import {
  Apple,
  ChartNoAxesCombined,
  CircleAlert,
  Cloud,
  Dumbbell,
  Ellipsis,
} from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";

import { Modal, SkeletonList, cn } from "../../components/ui";
import {
  dismissFitnessNotice,
  fitnessNotices,
  fitnessSyncSummary,
  flushFitnessFitImports,
  flushFitnessNutritionLabels,
  flushFitnessPlannedMealLogs,
  flushFitnessProgressPhotos,
  flushFitnessSync,
} from "../../fitness/offlineStore";
import type { FitnessCoachProposalDestination, FitnessSyncNotice } from "../../fitness/contract";
import type { FitnessSyncSummary } from "../../fitness/offlineStore";
import "./fitness.css";
import "./fitness-action-first.css";
import "./fitness-convergence.css";
import "./fitness-wave3.css";
import { FitnessOnboardingGate } from "./FitnessOnboardingView";

export type FitnessSection =
  | "today"
  | "nutrition"
  | "training"
  | "activity"
  | "strength"
  | "progress"
  | "recovery"
  | "explore"
  | "coach";

type FitnessPrimarySection = "progress" | "nutrition" | "training" | "today";

const FitnessMoreView = lazy(() => import("./FitnessMoreView").then((module) => ({ default: module.FitnessMoreView })));
const FitnessNutritionView = lazy(() => import("./FitnessNutritionView").then((module) => ({ default: module.FitnessNutritionView })));
const FitnessTrainingView = lazy(() => import("./FitnessTrainingView").then((module) => ({ default: module.FitnessTrainingView })));
const FitnessActivityView = lazy(() => import("./FitnessActivityView").then((module) => ({ default: module.FitnessActivityView })));
const FitnessStrengthView = lazy(() => import("./FitnessStrengthView").then((module) => ({ default: module.FitnessStrengthView })));
const FitnessProgressView = lazy(() => import("./FitnessProgressView").then((module) => ({ default: module.FitnessProgressView })));
const FitnessRecoveryView = lazy(() => import("./FitnessRecoveryView").then((module) => ({ default: module.FitnessRecoveryView })));
const FitnessExploreView = lazy(() => import("./FitnessExploreView").then((module) => ({ default: module.FitnessExploreView })));
const FitnessCoachView = lazy(() => import("./FitnessCoachView").then((module) => ({ default: module.FitnessCoachView })));

const sectionItems = [
  { id: "progress", label: "Review", icon: ChartNoAxesCombined },
  { id: "nutrition", label: "Food", icon: Apple },
  { id: "training", label: "Train", icon: Dumbbell },
  { id: "today", label: "More", icon: Ellipsis },
] satisfies Array<{ id: FitnessPrimarySection; label: string; icon: typeof ChartNoAxesCombined }>;

const emptySyncSummary: FitnessSyncSummary = {
  pending: 0,
  failed: 0,
  compatibilityBlocked: false,
  compatibilityMessage: null,
  lastSyncedAt: null,
};

export function fitnessPrimarySection(section: FitnessSection): FitnessPrimarySection {
  if (section === "nutrition") return "nutrition";
  if (section === "training" || section === "strength") return "training";
  if (["progress", "recovery", "explore", "activity"].includes(section)) return "progress";
  return "today";
}

export function FitnessModuleView({
  online,
  revision,
  section,
  onSectionChange,
  onOpenCalendar,
  onDataChanged,
  onSetupOpenChange,
  coachDraft,
  onCoachDraftConsumed,
  onOpenCoachDestination,
  onAskCoachAboutActivity,
}: {
  online: boolean;
  revision: number;
  section: FitnessSection;
  onSectionChange: (section: FitnessSection) => void;
  onOpenCalendar?: () => void;
  onDataChanged: () => void;
  onSetupOpenChange?: (open: boolean) => void;
  coachDraft?: { text: string; nonce: number; contextIds?: string[] } | null;
  onCoachDraftConsumed?: () => void;
  onOpenCoachDestination?: (destination: FitnessCoachProposalDestination) => void;
  onAskCoachAboutActivity?: (activityId: string, title: string) => void;
}) {
  const onDataChangedRef = useRef(onDataChanged);
  const syncingRef = useRef(false);
  const [setupOpen, setSetupOpen] = useState(false);
  const [syncSummary, setSyncSummary] = useState<FitnessSyncSummary>(emptySyncSummary);
  const [syncNotices, setSyncNotices] = useState<FitnessSyncNotice[]>([]);
  const [problemInboxOpen, setProblemInboxOpen] = useState(false);
  const [noticeError, setNoticeError] = useState<string | null>(null);

  useEffect(() => {
    onDataChangedRef.current = onDataChanged;
  }, [onDataChanged]);

  const refreshDataStatus = useCallback(async () => {
    try {
      const [summary, notices] = await Promise.all([
        fitnessSyncSummary(),
        fitnessNotices(),
      ]);
      setSyncSummary(summary);
      setSyncNotices(notices);
    } catch {
      // The local store may not be ready during account activation. The next
      // change or normal refresh will populate this quiet status line.
    }
  }, []);

  const syncSilently = useCallback(async () => {
    if (!navigator.onLine || syncingRef.current) return;
    syncingRef.current = true;
    try {
      const response = await flushFitnessSync();
      if (response && (
        response.status === "full_snapshot_required"
        || response.accepted.length > 0
        || response.changes.length > 0
        || response.redirects.length > 0
      )) onDataChangedRef.current();
    } catch {
      // Fitness writes remain queued and are retried when connectivity returns.
    } finally {
      syncingRef.current = false;
      void refreshDataStatus();
    }
  }, [refreshDataStatus]);

  useEffect(() => {
    if (!online) return;
    void syncSilently();
    void flushFitnessFitImports().catch(() => undefined);
    void flushFitnessProgressPhotos().catch(() => undefined);
    void flushFitnessNutritionLabels().catch(() => undefined);
    void flushFitnessPlannedMealLogs().catch(() => undefined);
  }, [online, syncSilently]);

  useEffect(() => {
    void refreshDataStatus();
    const refresh = () => void refreshDataStatus();
    window.addEventListener("hausklar:fitness-sync-changed", refresh);
    return () => window.removeEventListener("hausklar:fitness-sync-changed", refresh);
  }, [refreshDataStatus, revision]);

  async function dismissNotice(noticeId: string) {
    setNoticeError(null);
    try {
      await dismissFitnessNotice(noticeId);
      await refreshDataStatus();
    } catch {
      setNoticeError("That item could not be cleared yet. Try again when you are connected.");
    }
  }

  const sharedProps = { online, revision, onDataChanged, onSectionChange, onOpenCalendar, coachDraft, onCoachDraftConsumed, onOpenCoachDestination, onAskCoachAboutActivity };
  const activePrimarySection = fitnessPrimarySection(section);
  const handleSetupOpenChange = useCallback((open: boolean) => {
    setSetupOpen(open);
    onSetupOpenChange?.(open);
  }, [onSetupOpenChange]);
  const hasDataProblem = syncSummary.failed > 0 || syncSummary.compatibilityBlocked || syncNotices.length > 0;
  const dataStatusText = hasDataProblem
    ? "Some saved Fitness changes need attention"
    : online
      ? `${syncSummary.pending} ${syncSummary.pending === 1 ? "change is" : "changes are"} finishing`
      : `${syncSummary.pending} ${syncSummary.pending === 1 ? "change" : "changes"} saved on this device`;

  return (
    <section className="fitness-module" aria-labelledby="fitness-module-title">
      <header className="fitness-module__header fitness-module__header--compact">
        <div>
          <h1 id="fitness-module-title">Fitness</h1>
          <p>Training, food and progress in one place.</p>
        </div>
      </header>

      {!setupOpen ? <nav className="fitness-module__nav fitness-module__nav--primary" aria-label="Fitness sections">
        {sectionItems.map((item) => {
          const Icon = item.icon;
          const active = activePrimarySection === item.id;
          return (
            <button
              type="button"
              key={item.id}
              className={cn(active && "is-active")}
              aria-current={active ? "page" : undefined}
              onClick={() => onSectionChange(item.id)}
            >
              <Icon aria-hidden="true" size={18} />
              <span>{item.label}</span>
            </button>
          );
        })}
      </nav> : null}

      {!setupOpen && (hasDataProblem || syncSummary.pending > 0) ? (
        <div className={cn("fitness-module__data-status", hasDataProblem && "has-problem")} role="status">
          {hasDataProblem ? <CircleAlert aria-hidden="true" size={16} /> : <Cloud aria-hidden="true" size={16} />}
          <span>{dataStatusText}</span>
          {hasDataProblem ? <button type="button" onClick={() => setProblemInboxOpen(true)}>Review</button> : null}
        </div>
      ) : null}

      <div className="fitness-module__content">
        <FitnessOnboardingGate onDataChanged={onDataChanged} onOpenOverview={() => onSectionChange("progress")} onOpenChange={handleSetupOpenChange}>
          <Suspense fallback={<SkeletonList rows={5} />}>
            {section === "today" ? <FitnessMoreView {...sharedProps} /> : null}
            {section === "nutrition" ? <FitnessNutritionView {...sharedProps} /> : null}
            {section === "training" ? <FitnessTrainingView {...sharedProps} /> : null}
            {section === "activity" ? <FitnessActivityView {...sharedProps} /> : null}
            {section === "strength" ? <FitnessStrengthView {...sharedProps} /> : null}
            {section === "progress" ? <FitnessProgressView {...sharedProps} /> : null}
            {section === "recovery" ? <FitnessRecoveryView {...sharedProps} /> : null}
            {section === "explore" ? <FitnessExploreView {...sharedProps} /> : null}
            {section === "coach" ? <FitnessCoachView {...sharedProps} /> : null}
          </Suspense>
        </FitnessOnboardingGate>
      </div>

      <Modal
        open={problemInboxOpen}
        onOpenChange={setProblemInboxOpen}
        title="Fitness changes to review"
        description="Your records remain on this device while HausKlar finishes them safely."
      >
        <div className="fitness-module__problem-inbox">
          {syncSummary.compatibilityBlocked ? <p>Update HausKlar before these saved changes can finish.</p> : null}
          {syncSummary.failed > 0 && syncNotices.length === 0 ? <p>{online ? "HausKlar will try these saved changes again." : "Reconnect and HausKlar will try these saved changes again."}</p> : null}
          {syncNotices.length ? (
            <ul className="fitness-module__list">
              {syncNotices.map((notice) => (
                <li key={notice.id}>
                  <span>{notice.message || "A saved change needs your attention."}</span>
                  <button type="button" className="button button--secondary button--compact" disabled={!online} onClick={() => void dismissNotice(notice.id)}>Done</button>
                </li>
              ))}
            </ul>
          ) : null}
          {noticeError ? <p className="fitness-module__form-status is-error" role="alert">{noticeError}</p> : null}
          <div className="fitness-module__button-row">
            <button type="button" className="button button--primary" disabled={!online} onClick={() => void syncSilently()}>{online ? "Try again" : "Reconnect to try again"}</button>
            <button type="button" className="button button--secondary" onClick={() => setProblemInboxOpen(false)}>Close</button>
          </div>
        </div>
      </Modal>
    </section>
  );
}

export type FitnessViewProps = {
  online: boolean;
  revision: number;
  onDataChanged: () => void;
  onSectionChange: (section: FitnessSection) => void;
  onOpenCalendar?: () => void;
  coachDraft?: { text: string; nonce: number; contextIds?: string[] } | null;
  onCoachDraftConsumed?: () => void;
  onOpenCoachDestination?: (destination: FitnessCoachProposalDestination) => void;
  onAskCoachAboutActivity?: (activityId: string, title: string) => void;
};
