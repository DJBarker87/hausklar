import {
  Camera,
  Columns2,
  ImageOff,
  Images,
  LoaderCircle,
  RefreshCw,
  ShieldCheck,
  SlidersHorizontal,
  Trash2,
  UploadCloud,
  WifiOff,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import { cn } from "../../components/ui";
import {
  asFitnessArray,
  type FitnessPhase,
  type FitnessProgressPhoto,
  type FitnessProgressPhotoPose,
} from "../../fitness/contract";
import {
  cacheFitnessProgressPhotos,
  fitnessProgressPhotoLocalBlob,
  fitnessProgressPhotosOnDevice,
  queueFitnessProgressPhoto,
  removeFitnessProgressPhotoFromDevice,
  retryFitnessProgressPhoto,
  type FitnessPendingProgressPhoto,
} from "../../fitness/offlineStore";
import {
  FitnessCard,
  FitnessLoadingOrError,
  formatFitnessDate,
  formatFitnessDateTime,
  localDateTimeValue,
  localDateValue,
  useFitnessCollection,
} from "./shared";

type PhotoItem = {
  photo: FitnessProgressPhoto;
  local: FitnessPendingProgressPhoto | null;
};

const poseLabels: Record<FitnessProgressPhotoPose, string> = {
  front: "Front",
  side_left: "Left side",
  side_right: "Right side",
  back: "Back",
  custom: "Custom",
};

function useObjectUrl(blob: Blob | null): string | null {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!blob) {
      setUrl(null);
      return;
    }
    const next = URL.createObjectURL(blob);
    setUrl(next);
    return () => URL.revokeObjectURL(next);
  }, [blob]);
  return url;
}

function usePhotoSource(item: PhotoItem, variant: "thumbnail" | "original", online: boolean): string | null {
  const [localBlob, setLocalBlob] = useState<Blob | null>(null);
  useEffect(() => {
    let cancelled = false;
    if (!item.local?.hasLocalOriginal) {
      setLocalBlob(null);
      return () => { cancelled = true; };
    }
    void fitnessProgressPhotoLocalBlob(item.photo.id)
      .then((blob) => { if (!cancelled) setLocalBlob(blob); })
      .catch(() => { if (!cancelled) setLocalBlob(null); });
    return () => { cancelled = true; };
  }, [item.local?.hasLocalOriginal, item.photo.id]);
  const localUrl = useObjectUrl(localBlob);
  if (localUrl) return localUrl;
  if (!online) return null;
  if (variant === "original" && (item.photo.original_state === "missing" || item.photo.original_state === "deleted")) return null;
  if (variant === "thumbnail" && item.photo.thumbnail_state !== "ready") return null;
  const suffix = variant === "thumbnail" ? "thumbnail" : "original";
  return `/api/fitness/progress-photos/${encodeURIComponent(item.photo.id)}/${suffix}`;
}

function PhotoMedia({ item, online, variant, alt, className }: {
  item: PhotoItem;
  online: boolean;
  variant: "thumbnail" | "original";
  alt: string;
  className?: string;
}) {
  const source = usePhotoSource(item, variant, online);
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [source]);
  if (!source || failed) {
    const missingOriginal = item.photo.original_state === "missing";
    return <div className={cn("fitness-module__photo-unavailable", className)} role="img" aria-label={alt}>
      {online ? <ImageOff aria-hidden="true" size={28} /> : <WifiOff aria-hidden="true" size={28} />}
      <strong>{missingOriginal ? "Original missing" : online ? "Preview unavailable" : "Protected image offline"}</strong>
      <span>{missingOriginal ? "This required private asset needs reconciliation." : online ? "The original remains private; try regenerating its thumbnail." : "Reconnect to retrieve this protected server image."}</span>
    </div>;
  }
  return <img className={className} src={source} alt={alt} loading="lazy" onError={() => setFailed(true)} />;
}

function queueStatus(record: FitnessPendingProgressPhoto): { label: string; detail: string; tone: "neutral" | "warning" | "success" } {
  if (record.state === "ready") return { label: "Private", detail: "Original and metadata acknowledged.", tone: "success" };
  if (record.state === "error") return { label: "Needs attention", detail: record.error ?? "Retry the private upload.", tone: "warning" };
  if (record.state === "uploaded_waiting_metadata" || record.state === "saving_metadata") return { label: "Finishing", detail: "Original staged; metadata acknowledgement is still required. Local original retained.", tone: "warning" };
  if (record.state === "uploading") return { label: "Uploading", detail: "Uploading the staged private original. Local original retained.", tone: "neutral" };
  return { label: "On this device", detail: "Waiting to upload. The durable local original is retained.", tone: "neutral" };
}

function measurementSummary(photo: FitnessProgressPhoto): string[] {
  const values = Object.entries(photo.measurement_snapshot_json ?? {})
    .filter(([, value]) => value !== null && value !== "")
    .map(([key, value]) => `${key.replaceAll("_", " ")} ${value}`);
  if (photo.body_weight_kg != null) values.unshift(`${photo.body_weight_kg.toFixed(1)} kg`);
  return values;
}

function Comparison({ before, after, online }: { before: PhotoItem; after: PhotoItem; online: boolean }) {
  const [mode, setMode] = useState<"side-by-side" | "slider">("side-by-side");
  const [position, setPosition] = useState(50);
  const [alignment, setAlignment] = useState(false);
  const beforeSource = usePhotoSource(before, "original", online);
  const afterSource = usePhotoSource(after, "original", online);
  const canCompare = Boolean(beforeSource && afterSource);
  return <FitnessCard title="Private comparison" detail="Originals are retrieved through owner-authenticated routes. They are never sent to the coach." className="is-wide">
    <div className="fitness-module__visual-toolbar">
      <div className="fitness-module__choice-grid" aria-label="Comparison mode">
        <button type="button" className={cn(mode === "side-by-side" && "is-active")} aria-pressed={mode === "side-by-side"} onClick={() => setMode("side-by-side")}><Columns2 aria-hidden="true" size={16} /> Side by side</button>
        <button type="button" className={cn(mode === "slider" && "is-active")} aria-pressed={mode === "slider"} onClick={() => setMode("slider")}><SlidersHorizontal aria-hidden="true" size={16} /> Slider</button>
      </div>
      <label className="fitness-module__check"><input type="checkbox" checked={alignment} onChange={(event) => setAlignment(event.target.checked)} /> Alignment guide</label>
    </div>
    {!canCompare ? <div className="fitness-module__notice" role="status">Reconnect to load both protected originals for comparison. Pending local originals remain viewable on this device.</div> : mode === "side-by-side" ? <div className="fitness-module__photo-comparison-grid">
      <figure><div className={cn("fitness-module__comparison-photo", alignment && "has-guide")}><img src={beforeSource ?? ""} alt={`${poseLabels[before.photo.pose]} progress photograph from ${formatFitnessDate(before.photo.captured_at)}`} /></div><figcaption><strong>Before</strong><span>{formatFitnessDate(before.photo.captured_at)}</span></figcaption></figure>
      <figure><div className={cn("fitness-module__comparison-photo", alignment && "has-guide")}><img src={afterSource ?? ""} alt={`${poseLabels[after.photo.pose]} progress photograph from ${formatFitnessDate(after.photo.captured_at)}`} /></div><figcaption><strong>After</strong><span>{formatFitnessDate(after.photo.captured_at)}</span></figcaption></figure>
    </div> : <div className="fitness-module__slider-comparison">
      <div className={cn("fitness-module__comparison-photo", alignment && "has-guide")}>
        <img src={beforeSource ?? ""} alt={`${poseLabels[before.photo.pose]} progress photograph from ${formatFitnessDate(before.photo.captured_at)}`} />
        <div className="fitness-module__comparison-overlay" style={{ clipPath: `inset(0 ${100 - position}% 0 0)` }}><img src={afterSource ?? ""} alt={`${poseLabels[after.photo.pose]} progress photograph from ${formatFitnessDate(after.photo.captured_at)}`} /></div>
        <i aria-hidden="true" style={{ left: `${position}%` }} />
      </div>
      <label className="fitness-module__field">Reveal after photograph: {position}%<input type="range" min="0" max="100" value={position} onChange={(event) => setPosition(Number(event.target.value))} /></label>
    </div>}
    <p className="fitness-module__privacy-note"><ShieldCheck aria-hidden="true" size={15} /> These photographs are visual records only. HausKlar does not estimate body-fat percentage from images.</p>
  </FitnessCard>;
}

export function FitnessProgressPhotos({ online, revision, onDataChanged }: { online: boolean; revision: number; onDataChanged: () => void }) {
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const [deviceRecords, setDeviceRecords] = useState<FitnessPendingProgressPhoto[]>([]);
  const [serverPhotos, setServerPhotos] = useState<FitnessProgressPhoto[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadNonce, setReloadNonce] = useState(0);
  const [poseFilter, setPoseFilter] = useState("");
  const [phaseFilter, setPhaseFilter] = useState("");
  const [fromDate, setFromDate] = useState(() => localDateValue(new Date(Date.now() - 365 * 86_400_000)));
  const [toDate, setToDate] = useState(localDateValue());
  const [captureOpen, setCaptureOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [capturedAt, setCapturedAt] = useState(localDateTimeValue());
  const [pose, setPose] = useState<FitnessProgressPhotoPose>("front");
  const [weight, setWeight] = useState("");
  const [waist, setWaist] = useState("");
  const [chest, setChest] = useState("");
  const [hips, setHips] = useState("");
  const [capturePhase, setCapturePhase] = useState("");
  const [notes, setNotes] = useState("");
  const [alignmentGuide, setAlignmentGuide] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [comparisonIds, setComparisonIds] = useState<string[]>([]);
  const [deleteId, setDeleteId] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [regeneratingIds, setRegeneratingIds] = useState<Set<string>>(new Set());
  const filePreview = useObjectUrl(file);

  const refreshDevice = useCallback(async () => {
    const records = await fitnessProgressPhotosOnDevice();
    setDeviceRecords(records);
    return records;
  }, []);

  useEffect(() => {
    const changed = () => { void refreshDevice().catch(() => undefined); };
    window.addEventListener("hausklar:fitness-progress-photos-changed", changed);
    return () => window.removeEventListener("hausklar:fitness-progress-photos-changed", changed);
  }, [refreshDevice]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setLoadError(null);
    if (online) setServerPhotos([]);
    void (async () => {
      const local = await fitnessProgressPhotosOnDevice().catch(() => []);
      if (!cancelled) setDeviceRecords(local);
      if (!online) return;
      const params = new URLSearchParams({ from_date: fromDate, to_date: toDate });
      if (poseFilter) params.set("pose", poseFilter);
      if (phaseFilter) params.set("phase_id", phaseFilter);
      const response = await api<FitnessProgressPhoto[] | { items?: FitnessProgressPhoto[] }>(`/fitness/progress-photos?${params.toString()}`, {}, true, false);
      const photos = asFitnessArray(response);
      if (cancelled) return;
      setServerPhotos(photos);
      await cacheFitnessProgressPhotos(photos).catch(() => undefined);
      if (!cancelled) await refreshDevice();
    })().catch((error) => {
      if (!cancelled) setLoadError(error instanceof Error ? error.message : "Progress photographs could not be loaded.");
    }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [fromDate, online, phaseFilter, poseFilter, refreshDevice, reloadNonce, revision, toDate]);

  const items = useMemo(() => {
    const byId = new Map<string, PhotoItem>();
    for (const remote of serverPhotos) byId.set(remote.id, { photo: remote, local: null });
    for (const local of deviceRecords) {
      // Online list responses are authoritative for acknowledged records in
      // the requested filter window. Only genuinely pending local work may be
      // added back; cached ready rows are an offline fallback, not a way to
      // resurrect a server-deleted photograph.
      if (!online || !local.metadataAcknowledged) {
        byId.set(local.id, { photo: local.photo, local });
      }
    }
    return [...byId.values()]
      .filter(({ photo }) => !poseFilter || photo.pose === poseFilter)
      .filter(({ photo }) => !phaseFilter || photo.phase_id === phaseFilter)
      .filter(({ photo }) => photo.captured_at.slice(0, 10) >= fromDate && photo.captured_at.slice(0, 10) <= toDate)
      .sort((left, right) => right.photo.captured_at.localeCompare(left.photo.captured_at));
  }, [deviceRecords, fromDate, online, phaseFilter, poseFilter, serverPhotos, toDate]);
  const selectedItems = comparisonIds.map((id) => items.find((item) => item.photo.id === id)).filter((item): item is PhotoItem => Boolean(item));

  function toggleComparison(id: string) {
    setComparisonIds((current) => current.includes(id)
      ? current.filter((value) => value !== id)
      : [...current.slice(-1), id]);
  }

  async function capturePhoto() {
    if (!file) {
      setSaveError("Choose a photograph first.");
      return;
    }
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    const measurementSnapshot = Object.fromEntries(Object.entries({ waist_cm: waist, chest_cm: chest, hips_cm: hips }).filter(([, value]) => value !== "").map(([key, value]) => [key, Number(value)]));
    try {
      await queueFitnessProgressPhoto(file, {
        captured_at: new Date(capturedAt).toISOString(),
        pose,
        body_weight_kg: weight ? Number(weight) : null,
        measurement_snapshot_json: Object.keys(measurementSnapshot).length ? measurementSnapshot : null,
        phase_id: capturePhase || null,
        notes: notes.trim() || null,
      });
      await refreshDevice();
      setFile(null);
      setWeight("");
      setWaist("");
      setChest("");
      setHips("");
      setNotes("");
      setSaved(true);
      setCaptureOpen(false);
      onDataChanged();
    } catch (error) {
      setSaveError(error instanceof Error ? error.message : "The photograph could not be saved on this device.");
    } finally {
      setSaving(false);
    }
  }

  async function retryPhoto(id: string) {
    setActionError(null);
    try {
      await retryFitnessProgressPhoto(id);
      await refreshDevice();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "The photograph could not be retried.");
    }
  }

  async function regenerateThumbnail(id: string) {
    if (!online) return;
    setActionError(null);
    setRegeneratingIds((current) => new Set(current).add(id));
    try {
      const response = await api<{ status: "queued" | "ready" }>(`/fitness/progress-photos/${encodeURIComponent(id)}/thumbnail/regenerate`, { method: "POST" }, true, false);
      if (response.status === "ready") setReloadNonce((value) => value + 1);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Thumbnail regeneration could not be queued.");
      setRegeneratingIds((current) => { const next = new Set(current); next.delete(id); return next; });
    }
  }

  async function deletePhoto(item: PhotoItem) {
    setDeleting(true);
    setActionError(null);
    try {
      if (!item.local || item.local.metadataAcknowledged) {
        if (!online) throw new Error("Reconnect before deleting a server-stored private photograph.");
        await api<void>(`/fitness/progress-photos/${encodeURIComponent(item.photo.id)}`, { method: "DELETE" }, true, false);
      } else if (item.local.uploadAcknowledged) {
        if (!online) throw new Error("Reconnect before discarding the staged private server asset.");
        await api<void>(`/fitness/files/private/${encodeURIComponent(item.local.originalAssetId)}`, { method: "DELETE" }, true, false);
      }
      await removeFitnessProgressPhotoFromDevice(item.photo.id);
      setServerPhotos((current) => current.filter((photo) => photo.id !== item.photo.id));
      setComparisonIds((current) => current.filter((id) => id !== item.photo.id));
      setDeleteId(null);
      onDataChanged();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "The photograph could not be deleted.");
    } finally {
      setDeleting(false);
    }
  }

  return <section className="fitness-module__progress-photos" aria-labelledby="fitness-progress-photos-title">
    <header className="fitness-module__subheading"><div><div className="fitness-module__eyebrow"><ShieldCheck aria-hidden="true" size={14} /> Owner authenticated</div><h3 id="fitness-progress-photos-title">Progress photographs</h3><p>Originals are private required assets. Thumbnails can be regenerated.</p></div><button type="button" className="button button--primary" onClick={() => setCaptureOpen((value) => !value)}><Camera aria-hidden="true" size={17} /> Capture or upload</button></header>

    <div className="fitness-module__notice fitness-module__notice--sync" role="status"><span>Photo bytes stay inside the private asset flow and are never supplied to the coach or used for body-fat estimation.</span><ShieldCheck aria-hidden="true" size={18} /></div>

    {captureOpen ? <FitnessCard title="Save a private photograph" detail="Use similar distance, lighting, clothing, and time of day when practical.">
      <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void capturePhoto(); }}>
        <div className="fitness-module__capture-layout">
          <div className={cn("fitness-module__capture-preview", alignmentGuide && "has-guide")}>
            {filePreview ? <img src={filePreview} alt={`Selected ${poseLabels[pose].toLocaleLowerCase()} progress photograph preview`} /> : <div><UploadCloud aria-hidden="true" size={30} /><strong>Choose a photograph</strong><span>JPEG, PNG, HEIC, or HEIF · up to 25 MB</span></div>}
          </div>
          <div className="fitness-module__form">
            <input id="fitness-progress-photo-file" className="fitness-module__file-input" type="file" accept="image/jpeg,image/png,image/heic,image/heif,.heic,.heif" capture="environment" onChange={(event) => setFile(event.target.files?.[0] ?? null)} />
            <label htmlFor="fitness-progress-photo-file" className="button button--secondary"><Camera aria-hidden="true" size={17} /> {file ? "Choose another" : "Choose photograph"}</label>
            {file ? <small className="fitness-module__muted">{file.name} · {(file.size / 1_048_576).toFixed(1)} MB</small> : null}
            <label className="fitness-module__check"><input type="checkbox" checked={alignmentGuide} onChange={(event) => setAlignmentGuide(event.target.checked)} /> Show alignment guide</label>
          </div>
        </div>
        <div className="fitness-module__fields">
          <label className="fitness-module__field">Pose<select value={pose} onChange={(event) => setPose(event.target.value as FitnessProgressPhotoPose)}><option value="front">Front</option><option value="side_left">Left side</option><option value="side_right">Right side</option><option value="back">Back</option><option value="custom">Custom</option></select></label>
          <label className="fitness-module__field">Captured at<input type="datetime-local" required value={capturedAt} onChange={(event) => setCapturedAt(event.target.value)} /></label>
          <label className="fitness-module__field">Body weight (kg, optional)<input type="text" inputMode="decimal" value={weight} onChange={(event) => setWeight(event.target.value)} /></label>
          <label className="fitness-module__field">Training phase<select value={capturePhase} onChange={(event) => setCapturePhase(event.target.value)}><option value="">No linked phase</option>{phases.data.map((phase) => <option value={phase.id} key={phase.id}>{phase.name}</option>)}</select></label>
          <label className="fitness-module__field">Waist (cm, optional)<input type="text" inputMode="decimal" value={waist} onChange={(event) => setWaist(event.target.value)} /></label>
          <label className="fitness-module__field">Chest (cm, optional)<input type="text" inputMode="decimal" value={chest} onChange={(event) => setChest(event.target.value)} /></label>
          <label className="fitness-module__field">Hips (cm, optional)<input type="text" inputMode="decimal" value={hips} onChange={(event) => setHips(event.target.value)} /></label>
          <label className="fitness-module__field is-wide">Note (optional)<textarea value={notes} onChange={(event) => setNotes(event.target.value)} /></label>
        </div>
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={saving || !file} aria-busy={saving}>{saving ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <ShieldCheck aria-hidden="true" size={16} />} {saving ? "Saving on this device…" : "Save private photograph"}</button><button type="button" className="button button--secondary" onClick={() => setCaptureOpen(false)}>Cancel</button>{saveError ? <span className="fitness-module__form-status is-error" role="alert">{saveError}</span> : null}</div>
      </form>
    </FitnessCard> : null}
    {saved ? <div className="fitness-module__notice fitness-module__notice--sync" role="status"><span>Saved privately on this device. The original stays here until upload and metadata are both acknowledged.</span></div> : null}

    <FitnessCard title="Private gallery" detail="Newest first. Select two photographs to compare." className="is-wide">
      <div className="fitness-module__fields fitness-module__photo-filters">
        <label className="fitness-module__field">Pose<select value={poseFilter} onChange={(event) => setPoseFilter(event.target.value)}><option value="">All poses</option>{Object.entries(poseLabels).map(([key, label]) => <option value={key} key={key}>{label}</option>)}</select></label>
        <label className="fitness-module__field">Phase<select value={phaseFilter} onChange={(event) => setPhaseFilter(event.target.value)}><option value="">All phases</option>{phases.data.map((phase) => <option value={phase.id} key={phase.id}>{phase.name}</option>)}</select></label>
        <label className="fitness-module__field">From<input type="date" value={fromDate} max={toDate} onChange={(event) => setFromDate(event.target.value)} /></label>
        <label className="fitness-module__field">To<input type="date" value={toDate} min={fromDate} max={localDateValue()} onChange={(event) => setToDate(event.target.value)} /></label>
      </div>
      {!online && items.some((item) => !item.local?.hasLocalOriginal) ? <div className="fitness-module__notice" role="status">Gallery metadata is available offline. Reconnect to retrieve server-stored protected images.</div> : null}
      {actionError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{actionError}</div> : null}
      <FitnessLoadingOrError loading={loading} error={loadError} retry={() => setReloadNonce((value) => value + 1)} />
      {!loading && !loadError && !items.length ? <div className="fitness-module__empty"><Images aria-hidden="true" size={28} /><strong>No progress photographs in this view</strong><span>Capture a private front, side, or back record, or widen the filters.</span><button type="button" className="button button--secondary" onClick={() => setCaptureOpen(true)}>Capture first photograph</button></div> : null}
      {items.length ? <div className="fitness-module__photo-gallery">{items.map((item) => {
        const selected = comparisonIds.includes(item.photo.id);
        const status = item.local ? queueStatus(item.local) : { label: "Private", detail: "Server-stored private original.", tone: "success" as const };
        const measurements = measurementSummary(item.photo);
        const thumbnailMissing = item.photo.thumbnail_state === "missing" || item.photo.thumbnail_state === "error";
        const originalMissing = item.photo.original_state === "missing";
        const regenerating = item.photo.thumbnail_state === "regenerating" || regeneratingIds.has(item.photo.id);
        const deletionNeedsNetwork = !item.local || item.local.metadataAcknowledged || item.local.uploadAcknowledged;
        return <article className={cn("fitness-module__photo-card", selected && "is-selected")} key={item.photo.id}>
          <div className="fitness-module__photo-frame"><PhotoMedia item={item} online={online} variant="thumbnail" alt={`${poseLabels[item.photo.pose]} progress photograph from ${formatFitnessDate(item.photo.captured_at)}`} /></div>
          <div className="fitness-module__photo-card-body"><header><div><strong>{poseLabels[item.photo.pose]}</strong><small>{formatFitnessDateTime(item.photo.captured_at)}</small></div><span className={cn("fitness-module__pill", status.tone === "success" ? "is-success" : status.tone === "warning" ? "is-warning" : "is-neutral")}>{status.label}</span></header>
            <p>{status.detail}</p>
            {item.photo.phase_name || item.photo.phase_id ? <small>Phase: {item.photo.phase_name ?? phases.data.find((phase) => phase.id === item.photo.phase_id)?.name ?? "Linked phase"}</small> : null}
            {measurements.length ? <ul>{measurements.map((value) => <li key={value}>{value}</li>)}</ul> : <small>No linked weight or measurements.</small>}
            {originalMissing ? <div className="fitness-module__asset-state is-error"><ImageOff aria-hidden="true" size={16} /><span>Required original missing. Reconciliation must repair this.</span></div> : thumbnailMissing || regenerating ? <div className="fitness-module__asset-state"><RefreshCw aria-hidden="true" size={16} className={cn(regenerating && "is-spinning")} /><span>{regenerating ? "Thumbnail regeneration queued." : "Thumbnail missing; original remains safe."}</span>{!regenerating ? <button type="button" disabled={!online} onClick={() => void regenerateThumbnail(item.photo.id)}>Regenerate</button> : null}</div> : null}
            {item.local?.state === "error" ? <button type="button" className="button button--secondary" disabled={!online} onClick={() => void retryPhoto(item.photo.id)}>Retry private save</button> : null}
          </div>
          <footer><button type="button" className={cn("button button--secondary", selected && "is-active")} aria-pressed={selected} onClick={() => toggleComparison(item.photo.id)}>{selected ? "Selected" : "Compare"}</button><button type="button" className="button button--secondary" aria-label={`Delete ${poseLabels[item.photo.pose]} photograph from ${formatFitnessDate(item.photo.captured_at)}`} onClick={() => setDeleteId(item.photo.id)}><Trash2 aria-hidden="true" size={16} /> Delete</button></footer>
          {deleteId === item.photo.id ? <div className="fitness-module__delete-confirm" role="alert"><strong>Delete this private photograph?</strong><span>{item.local?.uploadAcknowledged && !item.local.metadataAcknowledged ? "The unreferenced staged private asset must be removed from the server before its local original is discarded." : "The server original and metadata will be removed explicitly. This cannot be undone."}</span><div><button type="button" className="button button--danger" disabled={deleting || (deletionNeedsNetwork && !online)} onClick={() => void deletePhoto(item)}>{deleting ? "Deleting…" : "Delete permanently"}</button><button type="button" className="button button--secondary" onClick={() => setDeleteId(null)}>Keep photograph</button></div>{deletionNeedsNetwork && !online ? <small>Reconnect before deleting so no private server asset is stranded.</small> : null}</div> : null}
        </article>;
      })}</div> : null}
    </FitnessCard>

    {selectedItems.length === 1 ? <div className="fitness-module__notice" role="status">Select one more photograph to compare.</div> : null}
    {selectedItems.length === 2 ? <Comparison before={[...selectedItems].sort((left, right) => left.photo.captured_at.localeCompare(right.photo.captured_at))[0]} after={[...selectedItems].sort((left, right) => left.photo.captured_at.localeCompare(right.photo.captured_at))[1]} online={online} /> : null}
  </section>;
}
