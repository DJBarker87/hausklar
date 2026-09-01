import { CalendarHeart, ChevronRight, LockKeyhole, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import type {
  FitnessCyclePeriodStart,
  FitnessCycleProfile,
  FitnessCycleSettings,
} from "../../fitness/contract";
import { cacheFitnessRecords } from "../../fitness/offlineStore";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessLoadingOrError,
  FitnessStat,
  formatFitnessDate,
  localDateValue,
  submitForm,
  useFitnessCachedRecords,
  useFitnessEndpoint,
  useFitnessSave,
} from "./shared";

type CycleSettingsDraft = Omit<Pick<
  FitnessCycleSettings,
  | "cycle_length_days"
  | "show_period_starts"
  | "show_predicted_period"
  | "show_estimated_ovulation"
  | "share_period_starts_with_adults"
  | "share_predicted_period_with_adults"
  | "share_estimated_ovulation_with_adults"
>, "cycle_length_days"> & { cycle_length_days: string };

type CycleEndpointResponse =
  | FitnessCycleProfile[]
  | {
      items?: FitnessCycleProfile[];
      profiles?: FitnessCycleProfile[];
      own_profile?: FitnessCycleProfile | null;
      shared_profiles?: FitnessCycleProfile[];
    };

const defaultSettings: CycleSettingsDraft = {
  cycle_length_days: "28",
  show_period_starts: true,
  show_predicted_period: true,
  show_estimated_ovulation: true,
  share_period_starts_with_adults: false,
  share_predicted_period_with_adults: false,
  share_estimated_ovulation_with_adults: false,
};

function normalizeProfiles(response: CycleEndpointResponse): FitnessCycleProfile[] {
  if (Array.isArray(response)) return response;
  if (response.profiles) return response.profiles;
  if (response.items) return response.items;
  return [
    ...(response.own_profile ? [response.own_profile] : []),
    ...(response.shared_profiles ?? []),
  ];
}

function profileSettings(profile: FitnessCycleProfile): FitnessCycleSettings {
  return {
    id: profile.id,
    revision: profile.revision,
    created_at: profile.created_at,
    updated_at: profile.updated_at,
    owner_user_id: profile.owner_user_id,
    owner_name: profile.owner_name,
    is_owner: profile.is_owner,
    cycle_length_days: profile.cycle_length_days,
    show_period_starts: profile.show_period_starts,
    show_predicted_period: profile.show_predicted_period,
    show_estimated_ovulation: profile.show_estimated_ovulation,
    share_period_starts_with_adults: profile.share_period_starts_with_adults ?? false,
    share_predicted_period_with_adults: profile.share_predicted_period_with_adults ?? false,
    share_estimated_ovulation_with_adults: profile.share_estimated_ovulation_with_adults ?? false,
  };
}

function settingsDraft(settings: FitnessCycleSettings): CycleSettingsDraft {
  return {
    cycle_length_days: String(settings.cycle_length_days),
    show_period_starts: settings.show_period_starts,
    show_predicted_period: settings.show_predicted_period,
    show_estimated_ovulation: settings.show_estimated_ovulation,
    share_period_starts_with_adults: settings.share_period_starts_with_adults ?? false,
    share_predicted_period_with_adults: settings.share_predicted_period_with_adults ?? false,
    share_estimated_ovulation_with_adults: settings.share_estimated_ovulation_with_adults ?? false,
  };
}

function datePlusDays(value: string, days: number): string {
  const date = new Date(`${value}T12:00:00`);
  date.setDate(date.getDate() + days);
  return localDateValue(date);
}

function cycleLengthError(value: string): string | null {
  if (!/^\d+$/.test(value.trim())) return "Enter a whole number of days.";
  const number = Number(value);
  if (number < 10 || number > 365) return "Cycle length must be between 10 and 365 days.";
  return null;
}

function calculatedDates(periods: FitnessCyclePeriodStart[], cycleLength: number) {
  const latest = [...periods]
    .sort((left, right) => right.started_on.localeCompare(left.started_on))[0]?.started_on ?? null;
  const next = latest ? datePlusDays(latest, cycleLength) : null;
  const ovulation = next ? datePlusDays(next, -14) : null;
  return {
    latest,
    next,
    ovulation: latest && ovulation && ovulation > latest ? ovulation : null,
  };
}

function ownerPeriods(
  records: FitnessCyclePeriodStart[],
  ownerUserId: string | null | undefined,
): FitnessCyclePeriodStart[] {
  return records
    .filter((period) => !ownerUserId || !period.owner_user_id || period.owner_user_id === ownerUserId)
    .sort((left, right) => right.started_on.localeCompare(left.started_on));
}

function SettingToggle({
  checked,
  label,
  detail,
  onChange,
}: {
  checked: boolean;
  label: string;
  detail: string;
  onChange: (checked: boolean) => void;
}) {
  return <label className="fitness-module__cycle-toggle">
    <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
    <span><strong>{label}</strong><small>{detail}</small></span>
  </label>;
}

export function FitnessCycleTracking({
  online,
  revision,
  onDataChanged,
  forceVisible = false,
  onRelevanceChange,
}: {
  online: boolean;
  revision: number;
  onDataChanged: () => void;
  forceVisible?: boolean;
  onRelevanceChange?: (relevant: boolean, settled: boolean) => void;
}) {
  const endpoint = useFitnessEndpoint<CycleEndpointResponse>("/fitness/cycles", [], revision);
  const cachedSettings = useFitnessCachedRecords<FitnessCycleSettings>("cycle_settings", revision);
  const cachedPeriods = useFitnessCachedRecords<FitnessCyclePeriodStart>("cycle_period_start", revision);
  const settingsSave = useFitnessSave(onDataChanged);
  const periodSave = useFitnessSave(onDataChanged);
  const periodDelete = useFitnessSave(onDataChanged);
  const [draft, setDraft] = useState<CycleSettingsDraft>(defaultSettings);
  const [draftDirty, setDraftDirty] = useState(false);
  const [lengthError, setLengthError] = useState<string | null>(null);
  const [settingsId, setSettingsId] = useState<string>(() => crypto.randomUUID());
  const [periodDate, setPeriodDate] = useState(localDateValue());
  const [optimisticSettings, setOptimisticSettings] = useState<FitnessCycleSettings | null>(null);
  const [optimisticPeriods, setOptimisticPeriods] = useState<FitnessCyclePeriodStart[] | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [removeId, setRemoveId] = useState<string | null>(null);
  const settingsDetailsRef = useRef<HTMLDetailsElement>(null);
  const cycleLengthRef = useRef<HTMLInputElement>(null);
  const regionRef = useRef<HTMLDivElement>(null);

  const profiles = useMemo(() => normalizeProfiles(endpoint.data), [endpoint.data]);
  const remoteOwner = profiles.find((profile) => profile.is_owner) ?? null;
  const sharedProfiles = profiles.filter((profile) => !profile.is_owner);
  const storedSettings = cachedSettings.data.find((settings) => settings.id === remoteOwner?.id)
    ?? cachedSettings.data.find((settings) => settings.is_owner !== false)
    ?? null;
  const currentSettings = optimisticSettings ?? storedSettings ?? (remoteOwner ? profileSettings(remoteOwner) : null);
  const ownerUserId = currentSettings?.owner_user_id ?? remoteOwner?.owner_user_id;
  const remotePeriods = remoteOwner?.period_starts ?? [];
  const storedPeriods = ownerPeriods(cachedPeriods.data, ownerUserId);
  const currentPeriods = optimisticPeriods
    ?? (storedPeriods.length || !remotePeriods.length ? storedPeriods : remotePeriods);
  const dates = calculatedDates(
    currentPeriods,
    currentSettings?.cycle_length_days ?? (Number(draft.cycle_length_days) || 28),
  );
  const hasCachedCycle = Boolean(currentSettings || currentPeriods.length);
  const loading = !hasCachedCycle && (cachedSettings.loading || cachedPeriods.loading || endpoint.loading);
  const error = cachedSettings.error ?? cachedPeriods.error ?? (!hasCachedCycle ? endpoint.error : null);

  useEffect(() => {
    onRelevanceChange?.(hasCachedCycle, !loading);
  }, [hasCachedCycle, loading, onRelevanceChange]);

  useEffect(() => {
    if (!remoteOwner) return;
    const settings = profileSettings(remoteOwner);
    const periods = remoteOwner.period_starts.map((period) => ({
      ...period,
      owner_user_id: remoteOwner.owner_user_id,
    }));
    void Promise.all([
      cacheFitnessRecords("cycle_settings", [settings]),
      cacheFitnessRecords("cycle_period_start", periods),
    ]).then(() => {
      cachedSettings.reload();
      cachedPeriods.reload();
    }).catch(() => undefined);
  }, [remoteOwner?.id, remoteOwner?.revision, remoteOwner?.updated_at]);

  useEffect(() => {
    if (!currentSettings || draftDirty) return;
    setSettingsId(currentSettings.id);
    setDraft(settingsDraft(currentSettings));
    setLengthError(null);
  }, [currentSettings?.id, currentSettings?.revision, currentSettings?.updated_at, draftDirty]);

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    if (query.get("cycle") !== "1") return;
    window.requestAnimationFrame(() => regionRef.current?.focus());
  }, []);

  function updateDraft<K extends keyof CycleSettingsDraft>(key: K, value: CycleSettingsDraft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setDraftDirty(true);
  }

  function openSettings() {
    if (settingsDetailsRef.current) settingsDetailsRef.current.open = true;
    window.requestAnimationFrame(() => cycleLengthRef.current?.focus());
  }

  async function saveSettings() {
    setNotice(null);
    const validationError = cycleLengthError(draft.cycle_length_days);
    setLengthError(validationError);
    if (validationError) return;
    const payload = { ...draft, cycle_length_days: Number(draft.cycle_length_days) };
    try {
      const saved = await settingsSave.save("cycle_settings", payload, {
        entityId: currentSettings?.id ?? settingsId,
        baseRevision: currentSettings?.revision ?? null,
      });
      setOptimisticSettings({
        ...currentSettings,
        ...payload,
        id: saved.id,
        revision: saved.revision ?? currentSettings?.revision,
        owner_user_id: currentSettings?.owner_user_id ?? remoteOwner?.owner_user_id,
        owner_name: currentSettings?.owner_name ?? remoteOwner?.owner_name ?? "You",
        is_owner: true,
        queued_offline: true,
      });
      setSettingsId(saved.id);
      setDraftDirty(false);
      cachedSettings.reload();
      setNotice(online ? "Cycle settings saved on this device and queued for sync." : "Cycle settings saved offline. They will sync when you reconnect.");
    } catch {
      // FitnessFormStatus provides the actionable error.
    }
  }

  async function recordPeriodStart() {
    if (!currentSettings || !periodDate) return;
    setNotice(null);
    try {
      const saved = await periodSave.save("cycle_period_start", {
        started_on: periodDate,
      });
      const next = ownerPeriods([
        {
          id: saved.id,
          revision: saved.revision,
          started_on: periodDate,
          owner_user_id: ownerUserId ?? null,
          queued_offline: true,
        },
        ...currentPeriods.filter((period) => period.id !== saved.id),
      ], ownerUserId);
      setOptimisticPeriods(next);
      cachedPeriods.reload();
      setNotice(online ? "Period start saved on this device and queued for sync." : "Period start saved offline. It will sync when you reconnect.");
    } catch {
      // FitnessFormStatus provides the actionable error.
    }
  }

  async function deletePeriodStart(period: FitnessCyclePeriodStart) {
    setNotice(null);
    try {
      await periodDelete.save("cycle_period_start", {}, {
        entityId: period.id,
        baseRevision: period.revision ?? null,
        operation: "delete",
      });
      setOptimisticPeriods(currentPeriods.filter((item) => item.id !== period.id));
      setRemoveId(null);
      cachedPeriods.reload();
      setNotice(online ? "Period start removal saved and queued for sync." : "Removal saved offline. It will sync when you reconnect.");
    } catch {
      // FitnessFormStatus provides the actionable error.
    }
  }

  if (!forceVisible && !hasCachedCycle) return null;

  return <div className="fitness-module__cycle" ref={regionRef} tabIndex={-1} aria-label="Cycle tracking">
    <FitnessCard
      title="Cycle tracking"
      detail="A private planning view for actual period starts and optional calendar dates."
      className="fitness-module__cycle-card"
    >
      <FitnessLoadingOrError loading={loading} error={error} retry={() => { endpoint.reload(); cachedSettings.reload(); cachedPeriods.reload(); }} />

      {!loading && !error ? <>
        {currentSettings ? <>
          <div className="fitness-module__cycle-summary">
            <div className="fitness-module__cycle-summary-heading">
              <span className="fitness-module__cycle-icon" aria-hidden="true"><CalendarHeart size={20} /></span>
              <div><strong>Your cycle at a glance</strong><small>Calculated from the latest recorded start and your {currentSettings.cycle_length_days}-day cycle.</small></div>
            </div>
            <div className="fitness-module__stats">
              <FitnessStat label="Latest start" value={formatFitnessDate(dates.latest)} />
              <FitnessStat label="Predicted next period" value={formatFitnessDate(dates.next)} detail="estimate" />
              <FitnessStat label="Estimated ovulation" value={formatFitnessDate(dates.ovulation)} detail="estimate" />
            </div>
          </div>

          <form className="fitness-module__cycle-record" onSubmit={submitForm(recordPeriodStart)}>
            <label className="fitness-module__field">Record a period start<input type="date" required value={periodDate} onChange={(event) => setPeriodDate(event.target.value)} /></label>
            <button type="submit" className="button button--primary" disabled={periodSave.saving || !periodDate}>Period started</button>
            <FitnessFormStatus saving={periodSave.saving} saved={periodSave.saved} error={periodSave.saveError} />
          </form>
        </> : <div className="fitness-module__cycle-empty">
          <span className="fitness-module__cycle-icon" aria-hidden="true"><CalendarHeart size={22} /></span>
          <div><strong>Set up cycle tracking when it is useful</strong><p>Choose an expected cycle length first. Nothing is shared with another adult unless you later enable a specific category.</p></div>
          <button type="button" className="button button--primary" onClick={openSettings}>Set up cycle tracking</button>
        </div>}

        {notice ? <p className="fitness-module__form-status is-saved" role="status">{notice}</p> : null}

        <details className="fitness-module__cycle-details" ref={settingsDetailsRef}>
          <summary><span><LockKeyhole aria-hidden="true" size={17} /> Calendar and privacy settings</span><ChevronRight aria-hidden="true" size={17} /></summary>
          <form className="fitness-module__form" onSubmit={submitForm(saveSettings)}>
            <label className="fitness-module__field fitness-module__cycle-length">Cycle length<input ref={cycleLengthRef} type="text" inputMode="numeric" required value={draft.cycle_length_days} aria-invalid={lengthError ? "true" : undefined} aria-describedby="fitness-cycle-length-help fitness-cycle-length-error" onBlur={() => setLengthError(cycleLengthError(draft.cycle_length_days))} onChange={(event) => { updateDraft("cycle_length_days", event.target.value); if (lengthError) setLengthError(null); }} /><small id="fitness-cycle-length-help">Used only to calculate planning estimates.</small>{lengthError ? <small id="fitness-cycle-length-error" className="fitness-module__field-error" role="alert">{lengthError}</small> : null}</label>

            <fieldset className="fitness-module__cycle-fieldset">
              <legend>Show on my calendar</legend>
              <p>These controls affect only your own Calendar.</p>
              <SettingToggle checked={draft.show_period_starts} label="Period starts" detail="Dates you recorded" onChange={(checked) => updateDraft("show_period_starts", checked)} />
              <SettingToggle checked={draft.show_predicted_period} label="Predicted next period" detail="Latest start plus cycle length" onChange={(checked) => updateDraft("show_predicted_period", checked)} />
              <SettingToggle checked={draft.show_estimated_ovulation} label="Estimated ovulation" detail="Fourteen days before the predicted period" onChange={(checked) => updateDraft("show_estimated_ovulation", checked)} />
            </fieldset>

            <fieldset className="fitness-module__cycle-fieldset is-private">
              <legend>Share with other adults</legend>
              <p>Sharing is off by default. Turning on a Calendar date above does not share it. Enable only the categories you want another signed-in household adult to see.</p>
              <SettingToggle checked={draft.share_period_starts_with_adults} label="Share period starts" detail="Other adults can see the dates you recorded" onChange={(checked) => updateDraft("share_period_starts_with_adults", checked)} />
              <SettingToggle checked={draft.share_predicted_period_with_adults} label="Share predicted next period" detail="Other adults can see this calculated date" onChange={(checked) => updateDraft("share_predicted_period_with_adults", checked)} />
              <SettingToggle checked={draft.share_estimated_ovulation_with_adults} label="Share estimated ovulation" detail="Other adults can see this calculated date" onChange={(checked) => updateDraft("share_estimated_ovulation_with_adults", checked)} />
            </fieldset>

            <div className="fitness-module__form-footer">
              <button type="submit" className="button button--secondary" disabled={settingsSave.saving}>{currentSettings ? "Save settings" : "Finish setup"}</button>
              <FitnessFormStatus saving={settingsSave.saving} saved={settingsSave.saved} error={settingsSave.saveError} />
            </div>
          </form>
        </details>

        {currentSettings ? <details className="fitness-module__cycle-details">
          <summary><span>Recorded starts <small>{currentPeriods.length}</small></span><ChevronRight aria-hidden="true" size={17} /></summary>
          {currentPeriods.length ? <ul className="fitness-module__cycle-history">
            {currentPeriods.slice(0, 24).map((period) => <li key={period.id}>
              <span><strong>{formatFitnessDate(period.started_on)}</strong>{period.queued_offline ? <small>Waiting to sync</small> : null}</span>
              {removeId === period.id ? <span className="fitness-module__cycle-remove-confirm"><span>Remove?</span><button type="button" className="button button--secondary" onClick={() => setRemoveId(null)}>Cancel</button><button type="button" className="button button--danger" disabled={periodDelete.saving} onClick={() => void deletePeriodStart(period)}>Remove</button></span> : <button type="button" className="icon-button" aria-label={`Remove period start ${period.started_on}`} onClick={() => setRemoveId(period.id)}><Trash2 aria-hidden="true" size={16} /></button>}
            </li>)}
          </ul> : <div className="fitness-module__empty"><CalendarHeart aria-hidden="true" size={22} /><strong>No period starts recorded</strong><span>Record the first actual start above to calculate planning dates.</span></div>}
          <FitnessFormStatus saving={periodDelete.saving} saved={periodDelete.saved} error={periodDelete.saveError} />
        </details> : null}

        {sharedProfiles.length ? <details className="fitness-module__cycle-details">
          <summary><span>Shared with you <small>{sharedProfiles.length}</small></span><ChevronRight aria-hidden="true" size={17} /></summary>
          <div className="fitness-module__cycle-shared">
            {sharedProfiles.map((profile) => <article key={profile.id}>
              <strong>{profile.owner_name}</strong>
              <dl>
                {profile.latest_period_start ? <div><dt>Latest start</dt><dd>{formatFitnessDate(profile.latest_period_start)}</dd></div> : null}
                {profile.predicted_next_period ? <div><dt>Predicted next period</dt><dd>{formatFitnessDate(profile.predicted_next_period)}</dd></div> : null}
                {profile.estimated_ovulation ? <div><dt>Estimated ovulation</dt><dd>{formatFitnessDate(profile.estimated_ovulation)}</dd></div> : null}
              </dl>
            </article>)}
          </div>
        </details> : null}

        <div className="fitness-module__cycle-boundary">
          <LockKeyhole aria-hidden="true" size={17} />
          <p>Cycle data is not sent to Coach and never changes training recommendations. Dates are estimates for planning only, not medical advice or contraception guidance.</p>
        </div>
      </> : null}
    </FitnessCard>
  </div>;
}
