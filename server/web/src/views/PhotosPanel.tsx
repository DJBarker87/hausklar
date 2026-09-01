import {
  BookOpen,
  Camera,
  Download,
  Heart,
  ImagePlus,
  Loader2,
  MapPin,
  Pencil,
  Share2,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, isOfflineQueuedResult } from "../api";
import { ConfirmDialog, EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { Child } from "../types";

import "./photos-panel.css";

export type ChildPhoto = {
  id: string;
  child_id: string;
  child_name?: string | null;
  caption?: string | null;
  taken_on: string;
  location?: string | null;
  story?: string | null;
  favourite: boolean;
  include_in_yearbook: boolean;
  yearbook_position?: number | null;
  original_available: boolean;
  created_at: string;
  updated_at: string;
  image_url: string;
  original_image_url?: string | null;
};

type CaptureItem = {
  id: string;
  file: File;
  preview: string;
  takenOn: string;
};

type MomentDraft = {
  childId: string;
  caption: string;
  oneDate: string;
  location: string;
  story: string;
  includeInYearbook: boolean;
};

type EditDraft = Omit<MomentDraft, "oneDate"> & { takenOn: string };

const PAGE_SIZE = 40;
const BATCH_SIZE = 5;
const MAX_PILE = 30;
const CAPTURE_CHILD_KEY = "hausklar.photos.capture-child";

function localDateValue(date = new Date()): string {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

function photoDateLabel(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMMM yyyy");
}

function monthKey(value: string): string {
  return /^\d{4}-\d{2}/.test(value) ? value.slice(0, 7) : value;
}

function monthLabel(value: string): string {
  const parsed = parseISO(`${value}-01`);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "MMMM yyyy");
}

function imageURL(path: string, size?: "thumb"): string {
  if (!size) return `/api${path}`;
  return `/api${path}${path.includes("?") ? "&" : "?"}size=${size}`;
}

function photoAlt(photo: ChildPhoto): string {
  return photo.caption?.trim()
    || `Photo of ${photo.child_name ?? "a child"} from ${photoDateLabel(photo.taken_on)}`;
}

function sortPhotos(items: ChildPhoto[]): ChildPhoto[] {
  return [...items].sort((first, second) => {
    if (first.favourite !== second.favourite) return first.favourite ? -1 : 1;
    if (first.taken_on !== second.taken_on) return first.taken_on < second.taken_on ? 1 : -1;
    return first.created_at < second.created_at ? 1 : -1;
  });
}

function mergePhoto(items: ChildPhoto[], photo: ChildPhoto): ChildPhoto[] {
  return sortPhotos([photo, ...items.filter((item) => item.id !== photo.id)]);
}

function extensionFor(mediaType: string): string {
  return ({
    "image/png": "png",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/webp": "webp",
  } as Record<string, string>)[mediaType.toLowerCase()] ?? "jpg";
}

function filenameFor(photo: ChildPhoto, mediaType: string): string {
  const base = (photo.caption || `${photo.child_name ?? "Family"} ${photo.taken_on}`)
    .replace(/[\\/:*?"<>|]+/g, "-")
    .trim() || "Family photo";
  return `${base}.${extensionFor(mediaType)}`;
}

async function captureDate(file: File): Promise<string> {
  if (file.type !== "image/jpeg") return localDateValue(new Date(file.lastModified || Date.now()));
  try {
    const bytes = new Uint8Array(await file.slice(0, 256 * 1024).arrayBuffer());
    let header = "";
    for (const byte of bytes) header += String.fromCharCode(byte);
    const exif = header.indexOf("Exif\u0000\u0000");
    const match = (exif >= 0 ? header.slice(exif) : header)
      .match(/((?:19|20)\d{2}):(0[1-9]|1[0-2]):(0[1-9]|[12]\d|3[01]) /);
    if (match) return match[1].replaceAll(":", "-");
  } catch {
    // File modification time is still a useful local fallback.
  }
  return localDateValue(new Date(file.lastModified || Date.now()));
}

function PhotoImage({ photo, full = false }: { photo: ChildPhoto; full?: boolean }) {
  const [failed, setFailed] = useState(false);
  if (failed) {
    return <div className="photos-panel__fallback" role="img" aria-label={`${photoAlt(photo)} unavailable`}><Camera aria-hidden="true" /></div>;
  }
  return (
    <img
      src={imageURL(photo.image_url, full ? undefined : "thumb")}
      alt={photoAlt(photo)}
      loading={full ? "eager" : "lazy"}
      onError={() => setFailed(true)}
    />
  );
}

export function PhotosPanel({
  children,
  selectedChild,
  revision,
  initialPhotoId,
  onDataChanged,
}: {
  children: Child[];
  selectedChild: string;
  revision: number;
  initialPhotoId?: string | null;
  onDataChanged: () => void;
}) {
  const [photos, setPhotos] = useState<ChildPhoto[]>([]);
  const [favouritesOnly, setFavouritesOnly] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [nextOffset, setNextOffset] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const requestSequence = useRef(0);

  const [captureOpen, setCaptureOpen] = useState(false);
  const [captureItems, setCaptureItems] = useState<CaptureItem[]>([]);
  const captureItemsRef = useRef<CaptureItem[]>([]);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [captureProgress, setCaptureProgress] = useState<{ done: number; total: number } | null>(null);
  const [draft, setDraft] = useState<MomentDraft>({ childId: "", caption: "", oneDate: "", location: "", story: "", includeInYearbook: true });

  const [viewer, setViewer] = useState<ChildPhoto | null>(null);
  const [editOpen, setEditOpen] = useState(false);
  const [editDraft, setEditDraft] = useState<EditDraft | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<ChildPhoto | null>(null);
  const [undoPhoto, setUndoPhoto] = useState<ChildPhoto | null>(null);

  const childNames = useMemo(() => new Map(children.map((child) => [child.id, child.name])), [children]);
  const timeline = useMemo(() => {
    const groups = new Map<string, ChildPhoto[]>();
    for (const photo of photos) {
      const key = monthKey(photo.taken_on);
      groups.set(key, [...(groups.get(key) ?? []), photo]);
    }
    return [...groups.entries()].sort(([first], [second]) => first < second ? 1 : -1);
  }, [photos]);

  const loadPage = useCallback(async (offset: number, reset: boolean) => {
    const sequence = ++requestSequence.current;
    if (reset) {
      setLoading(true);
      setError(null);
    } else setLoadingMore(true);
    const query = new URLSearchParams({ offset: String(offset), limit: String(PAGE_SIZE) });
    if (selectedChild !== "all") query.set("child_id", selectedChild);
    if (favouritesOnly) query.set("favourites_only", "true");
    try {
      const fetched = await api<ChildPhoto[]>(`/child-photos/?${query.toString()}`);
      if (sequence !== requestSequence.current) return;
      setPhotos((current) => reset
        ? sortPhotos(fetched)
        : sortPhotos([...current, ...fetched.filter((photo) => !current.some((known) => known.id === photo.id))]));
      setNextOffset(offset + fetched.length);
      setHasMore(fetched.length === PAGE_SIZE);
    } catch (requestError) {
      if (sequence !== requestSequence.current) return;
      const message = requestError instanceof Error ? requestError.message : "The family photos could not be opened.";
      if (reset) setError(message);
      else setActionError("More photos could not be loaded. Try again when the connection settles.");
    } finally {
      if (sequence === requestSequence.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [favouritesOnly, selectedChild]);

  useEffect(() => {
    void loadPage(0, true);
  }, [loadPage, revision]);

  useEffect(() => {
    captureItemsRef.current = captureItems;
  }, [captureItems]);

  useEffect(() => () => {
    for (const item of captureItemsRef.current) if (item.preview) URL.revokeObjectURL(item.preview);
  }, []);

  function visible(photo: ChildPhoto): boolean {
    return (selectedChild === "all" || photo.child_id === selectedChild)
      && (!favouritesOnly || photo.favourite);
  }

  function applyPhoto(photo: ChildPhoto): void {
    setPhotos((current) => visible(photo) ? mergePhoto(current, photo) : current.filter((item) => item.id !== photo.id));
    setViewer((current) => current?.id === photo.id ? photo : current);
  }

  useEffect(() => {
    if (!initialPhotoId) return;
    let cancelled = false;
    void api<ChildPhoto>(`/child-photos/${initialPhotoId}`)
      .then((photo) => {
        if (cancelled) return;
        setPhotos((current) => visible(photo) ? mergePhoto(current, photo) : current);
        setViewer(photo);
        const url = new URL(window.location.href);
        url.searchParams.delete("photo");
        window.history.replaceState({}, "", url);
      })
      .catch((requestError) => {
        if (!cancelled) setActionError(requestError instanceof Error ? requestError.message : "That photo could not be opened.");
      });
    return () => { cancelled = true; };
  // The search destination is consumed once when this panel mounts.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialPhotoId]);

  function openCapture(): void {
    let remembered = "";
    try { remembered = window.sessionStorage.getItem(CAPTURE_CHILD_KEY) ?? ""; } catch { /* privacy mode */ }
    const childId = selectedChild !== "all"
      ? selectedChild
      : children.some((child) => child.id === remembered) ? remembered : children[0]?.id ?? "";
    setDraft({ childId, caption: "", oneDate: "", location: "", story: "", includeInYearbook: true });
    setCaptureItems([]);
    setDetailsOpen(false);
    setCaptureProgress(null);
    setActionError(null);
    setCaptureOpen(true);
  }

  function closeCapture(): void {
    if (working === "capture") return;
    setCaptureOpen(false);
    setCaptureItems((current) => {
      for (const item of current) if (item.preview) URL.revokeObjectURL(item.preview);
      return [];
    });
  }

  async function addCaptureFiles(files: FileList | null): Promise<void> {
    if (!files?.length) return;
    const remaining = Math.max(0, MAX_PILE - captureItems.length);
    const chosen = Array.from(files).slice(0, remaining);
    if (files.length > remaining) setActionError(`A moment can contain up to ${MAX_PILE} photos.`);
    const additions = await Promise.all(chosen.map(async (file) => ({
      id: crypto.randomUUID(),
      file,
      preview: typeof URL.createObjectURL === "function" ? URL.createObjectURL(file) : "",
      takenOn: await captureDate(file),
    })));
    setCaptureItems((current) => [...current, ...additions]);
  }

  function removeCaptureItem(id: string): void {
    setCaptureItems((current) => {
      const removed = current.find((item) => item.id === id);
      if (removed?.preview) URL.revokeObjectURL(removed.preview);
      return current.filter((item) => item.id !== id);
    });
  }

  async function saveCapture(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (!draft.childId || !captureItems.length) return;
    setWorking("capture");
    setActionError(null);
    setCaptureProgress({ done: 0, total: captureItems.length });
    let processed = 0;
    let queued = 0;
    let failure: unknown = null;
    for (let start = 0; start < captureItems.length; start += BATCH_SIZE) {
      const chunk = captureItems.slice(start, start + BATCH_SIZE);
      const form = new FormData();
      form.set("child_id", draft.childId);
      if (draft.caption.trim()) form.set("caption", draft.caption.trim());
      if (draft.location.trim()) form.set("location", draft.location.trim());
      if (draft.story.trim()) form.set("story", draft.story.trim());
      form.set("include_in_yearbook", String(draft.includeInYearbook));
      for (const item of chunk) {
        form.append("files", item.file, item.file.name);
        form.append("taken_on", draft.oneDate || item.takenOn);
        form.append("client_id", item.id);
      }
      try {
        const response = await api<{ photos: ChildPhoto[] }>("/child-photos/", { method: "POST", body: form, timeoutMs: 120_000 });
        if (isOfflineQueuedResult(response)) queued += chunk.length;
        else for (const photo of response.photos) if (visible(photo)) setPhotos((current) => mergePhoto(current, photo));
        processed += chunk.length;
        setCaptureProgress({ done: processed, total: captureItems.length });
      } catch (requestError) {
        failure = requestError;
        break;
      }
    }
    if (processed) {
      try { window.sessionStorage.setItem(CAPTURE_CHILD_KEY, draft.childId); } catch { /* privacy mode */ }
      onDataChanged();
      setCaptureItems((current) => {
        for (const item of current.slice(0, processed)) if (item.preview) URL.revokeObjectURL(item.preview);
        return current.slice(processed);
      });
    }
    if (failure) {
      const detail = failure instanceof Error ? failure.message : "The remaining photos could not be saved.";
      setActionError(processed ? `${processed} saved. The rest are still here to retry. ${detail}` : detail);
    } else {
      setCaptureOpen(false);
      setNotice(queued
        ? `${queued} ${queued === 1 ? "photo is" : "photos are"} saved offline and waiting to sync.`
        : `${processed} ${processed === 1 ? "photo" : "photos"} added to this moment.`);
    }
    setCaptureProgress(null);
    setWorking(null);
  }

  function openViewer(photo: ChildPhoto): void {
    setViewer(photo);
    setEditOpen(false);
    setEditDraft({
      childId: photo.child_id,
      caption: photo.caption ?? "",
      takenOn: photo.taken_on,
      location: photo.location ?? "",
      story: photo.story ?? "",
      includeInYearbook: photo.include_in_yearbook,
    });
    setActionError(null);
  }

  async function patchPhoto(photo: ChildPhoto, changes: Record<string, unknown>, key: string): Promise<ChildPhoto | null> {
    setWorking(key);
    setActionError(null);
    try {
      const updated = await api<ChildPhoto>(`/child-photos/${photo.id}`, { method: "PATCH", body: JSON.stringify(changes) });
      applyPhoto(updated);
      onDataChanged();
      return updated;
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The photo could not be updated.");
      return null;
    } finally {
      setWorking(null);
    }
  }

  async function saveEdits(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (!viewer || !editDraft) return;
    const updated = await patchPhoto(viewer, {
      child_id: editDraft.childId,
      caption: editDraft.caption.trim() || null,
      taken_on: editDraft.takenOn,
      location: editDraft.location.trim() || null,
      story: editDraft.story.trim() || null,
      include_in_yearbook: editDraft.includeInYearbook,
    }, "edit");
    if (updated) setEditOpen(false);
  }

  async function removePhoto(photo: ChildPhoto): Promise<void> {
    setWorking("delete");
    try {
      await api(`/child-photos/${photo.id}`, { method: "DELETE" });
      setPhotos((current) => current.filter((item) => item.id !== photo.id));
      setViewer(null);
      setDeleteTarget(null);
      setUndoPhoto(photo);
      setNotice(`Removed ${photo.caption || `photo from ${photoDateLabel(photo.taken_on)}`}`);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The photo could not be removed.");
    } finally {
      setWorking(null);
    }
  }

  async function restorePhoto(): Promise<void> {
    if (!undoPhoto) return;
    setWorking("undo");
    try {
      const restored = await api<ChildPhoto>(`/child-photos/${undoPhoto.id}/restore`, { method: "POST" });
      if (visible(restored)) setPhotos((current) => mergePhoto(current, restored));
      setUndoPhoto(null);
      setNotice("Photo restored.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The photo could not be restored.");
    } finally {
      setWorking(null);
    }
  }

  async function sharePhoto(photo: ChildPhoto): Promise<void> {
    setWorking("share");
    setActionError(null);
    const source = imageURL(photo.original_image_url || photo.image_url);
    try {
      const response = await fetch(source, { credentials: "same-origin" });
      if (!response.ok) throw new Error("The photo file could not be opened.");
      const blob = await response.blob();
      const file = new File([blob], filenameFor(photo, blob.type), { type: blob.type || "image/jpeg" });
      if (navigator.share && (!navigator.canShare || navigator.canShare({ files: [file] }))) {
        await navigator.share({ files: [file], title: photo.caption || "Family photo" });
      } else {
        const url = URL.createObjectURL(blob);
        const anchor = document.createElement("a");
        anchor.href = url;
        anchor.download = file.name;
        document.body.append(anchor);
        anchor.click();
        anchor.remove();
        URL.revokeObjectURL(url);
      }
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The photo could not be shared.");
    } finally {
      setWorking(null);
    }
  }

  if (loading) return <SkeletonList rows={7} />;
  if (error && !photos.length) return <ErrorState message={error} retry={() => void loadPage(0, true)} />;

  return (
    <div className="photos-panel">
      <div className="photos-panel__heading">
        <div><p className="page-eyebrow">People & moments</p><h2>Family photos</h2><span>The originals stay safe. The gallery stays simple.</span></div>
        <button type="button" className="button button--primary" disabled={!children.length} onClick={openCapture}><ImagePlus aria-hidden="true" size={18} /> Add a moment</button>
      </div>

      <div className="photos-panel__filters">
        <button type="button" className={cn("photos-panel__filter", !favouritesOnly && "is-active")} aria-pressed={!favouritesOnly} onClick={() => setFavouritesOnly(false)}>All moments</button>
        <button type="button" className={cn("photos-panel__filter", favouritesOnly && "is-active")} aria-pressed={favouritesOnly} onClick={() => setFavouritesOnly(true)}><Heart aria-hidden="true" size={15} fill={favouritesOnly ? "currentColor" : "none"} /> Favourites</button>
      </div>

      {actionError ? <div className="partial-notice inline-recovery" role="alert"><span>{actionError}</span><button type="button" className="button button--secondary button--compact" onClick={() => setActionError(null)}>Dismiss</button></div> : null}
      {notice ? <div className="photos-panel__notice" role="status"><span>{notice}</span>{undoPhoto ? <button type="button" disabled={working === "undo"} onClick={() => void restorePhoto()}><Undo2 aria-hidden="true" size={16} /> {working === "undo" ? "Restoring…" : "Undo"}</button> : null}<button type="button" aria-label="Dismiss notice" onClick={() => { setNotice(null); setUndoPhoto(null); }}><X aria-hidden="true" size={15} /></button></div> : null}

      {timeline.map(([month, items]) => (
        <section className="photos-panel__month" key={month}>
          <h3>{monthLabel(month)} <span>{items.length}</span></h3>
          <div className="photos-panel__grid">
            {items.map((photo) => (
              <button type="button" className="photos-panel__card" aria-label={`Open ${photoAlt(photo)}`} onClick={() => openViewer(photo)} key={photo.id}>
                <PhotoImage photo={photo} />
                <span className="photos-panel__card-shade" />
                {photo.favourite ? <Heart className="photos-panel__heart" aria-label="Favourite" size={17} fill="currentColor" /> : null}
                {selectedChild === "all" ? <span className="photos-panel__person">{photo.child_name ?? childNames.get(photo.child_id) ?? "Child"}</span> : null}
                <span className="photos-panel__caption"><strong>{photo.caption || photoDateLabel(photo.taken_on)}</strong>{photo.caption ? <small>{photoDateLabel(photo.taken_on)}</small> : null}</span>
              </button>
            ))}
          </div>
        </section>
      ))}

      {!photos.length ? <EmptyState title={favouritesOnly ? "No favourite moments yet" : "No family photos yet"} detail={favouritesOnly ? "Tap the heart on a photo you never want to lose in the crowd." : "Add the birthdays, first steps and ordinary afternoons that make up family life."} action={favouritesOnly ? () => setFavouritesOnly(false) : openCapture} actionLabel={favouritesOnly ? "Show every moment" : "Add a moment"} /> : null}
      {hasMore ? <button type="button" className="button button--secondary photos-panel__more" disabled={loadingMore} onClick={() => void loadPage(nextOffset, false)}>{loadingMore ? <Loader2 className="spin" aria-hidden="true" size={17} /> : null}{loadingMore ? "Loading…" : "Load more photos"}</button> : null}

      <Modal open={captureOpen} onOpenChange={(open) => { if (!open) closeCapture(); }} title="Add a moment" description="Choose the person first; the camera dates are kept automatically." size="wide">
        <form className="photos-panel__capture" onSubmit={saveCapture}>
          <div className="photos-panel__capture-lead">
            <div className="field"><label htmlFor="photo-capture-child">Who is this about?</label><select id="photo-capture-child" value={draft.childId} onChange={(event) => setDraft((current) => ({ ...current, childId: event.target.value }))} required>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
            <label className="photos-panel__drop"><ImagePlus aria-hidden="true" size={26} /><strong>{captureItems.length ? "Add more photos" : "Choose photos"}</strong><span>Up to {MAX_PILE} from one moment</span><input type="file" accept="image/*" multiple aria-label="Choose photos for this moment" onChange={(event) => { void addCaptureFiles(event.target.files); event.target.value = ""; }} /></label>
          </div>
          {captureItems.length ? <div className="photos-panel__pile">{captureItems.map((item) => <div key={item.id}>{item.preview ? <img src={item.preview} alt="" /> : <Camera aria-hidden="true" />}<span>{photoDateLabel(draft.oneDate || item.takenOn)}</span><button type="button" aria-label={`Remove ${item.file.name}`} onClick={() => removeCaptureItem(item.id)}><X aria-hidden="true" size={14} /></button></div>)}</div> : null}
          <div className="field"><label htmlFor="photo-capture-caption">What was the moment?</label><input id="photo-capture-caption" maxLength={2_000} value={draft.caption} onChange={(event) => setDraft((current) => ({ ...current, caption: event.target.value }))} placeholder="First day of school, Sunday in the garden…" /></div>
          <button type="button" className="photos-panel__details-toggle" aria-expanded={detailsOpen} onClick={() => setDetailsOpen((open) => !open)}>{detailsOpen ? "Hide details" : "Add place, story or one shared date"}</button>
          {detailsOpen ? <div className="photos-panel__details">
            <div className="photos-panel__field-pair"><div className="field"><label htmlFor="photo-capture-date">One date for every photo (optional)</label><input id="photo-capture-date" type="date" max={localDateValue()} value={draft.oneDate} onChange={(event) => setDraft((current) => ({ ...current, oneDate: event.target.value }))} /><small>Leave blank to keep each original camera date.</small></div><div className="field"><label htmlFor="photo-capture-location">Place</label><input id="photo-capture-location" maxLength={300} value={draft.location} onChange={(event) => setDraft((current) => ({ ...current, location: event.target.value }))} placeholder="Walberswick, Granny's house…" /></div></div>
            <div className="field"><label htmlFor="photo-capture-story">The story worth remembering</label><textarea id="photo-capture-story" rows={3} maxLength={2_000} value={draft.story} onChange={(event) => setDraft((current) => ({ ...current, story: event.target.value }))} /></div>
            <label className="photos-panel__check"><input type="checkbox" checked={draft.includeInYearbook} onChange={(event) => setDraft((current) => ({ ...current, includeInYearbook: event.target.checked }))} /><span><strong>Available for Yearbook</strong><small>You will choose the final pages later.</small></span></label>
          </div> : null}
          {captureProgress ? <div className="photos-panel__progress" role="status"><Loader2 className="spin" aria-hidden="true" /><span>Saving originals and gallery copies — {captureProgress.done} of {captureProgress.total}</span><progress max={captureProgress.total} value={captureProgress.done} /></div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "capture"} onClick={closeCapture}>Cancel</button><button type="submit" className="button button--primary" disabled={!draft.childId || !captureItems.length || working === "capture"}>{working === "capture" ? "Saving safely…" : `Save ${captureItems.length || ""} ${captureItems.length === 1 ? "photo" : "photos"}`}</button></div>
        </form>
      </Modal>

      <Modal open={Boolean(viewer)} onOpenChange={(open) => { if (!open) setViewer(null); }} title={viewer?.caption || (viewer ? photoDateLabel(viewer.taken_on) : "Photo")} description={viewer ? `${viewer.child_name ?? childNames.get(viewer.child_id) ?? "Child"} · ${photoDateLabel(viewer.taken_on)}` : undefined} size="wide">
        {viewer ? <div className="photos-panel__viewer">
          <div className="photos-panel__viewer-image"><PhotoImage photo={viewer} full />{viewer.original_available ? <span>Original preserved</span> : <span>Gallery copy only</span>}</div>
          <div className="photos-panel__viewer-content">
            <div className="photos-panel__quick-actions">
              <button type="button" className={cn("button button--secondary button--compact", viewer.favourite && "is-active")} disabled={Boolean(working)} onClick={() => void patchPhoto(viewer, { favourite: !viewer.favourite }, "favourite")}><Heart aria-hidden="true" size={16} fill={viewer.favourite ? "currentColor" : "none"} /> {viewer.favourite ? "Favourite" : "Add favourite"}</button>
              <button type="button" className={cn("button button--secondary button--compact", viewer.include_in_yearbook && "is-active")} disabled={Boolean(working)} onClick={() => void patchPhoto(viewer, { include_in_yearbook: !viewer.include_in_yearbook }, "yearbook")}><BookOpen aria-hidden="true" size={16} /> {viewer.include_in_yearbook ? "In Yearbook" : "Add to Yearbook"}</button>
            </div>
            {viewer.location ? <p className="photos-panel__place"><MapPin aria-hidden="true" size={17} />{viewer.location}</p> : null}
            {viewer.story ? <p className="photos-panel__story">{viewer.story}</p> : null}
            <div className="photos-panel__viewer-actions">
              <button type="button" className="button button--secondary" disabled={working === "share"} onClick={() => void sharePhoto(viewer)}><Share2 aria-hidden="true" size={17} />{working === "share" ? "Preparing…" : "Share"}</button>
              {viewer.original_image_url ? <a className="button button--secondary" href={imageURL(viewer.original_image_url)} download><Download aria-hidden="true" size={17} />Original</a> : null}
              <button type="button" className="button button--secondary" onClick={() => setEditOpen(true)}><Pencil aria-hidden="true" size={17} />Edit</button>
              <button type="button" className="button button--danger" onClick={() => setDeleteTarget(viewer)}><Trash2 aria-hidden="true" size={17} />Remove</button>
            </div>
          </div>
        </div> : null}
      </Modal>

      <Modal open={editOpen && Boolean(viewer)} onOpenChange={setEditOpen} title="Edit this moment">
        {viewer && editDraft ? <form className="form-stack" onSubmit={saveEdits}>
          <div className="field"><label htmlFor="photo-edit-child">Person</label><select id="photo-edit-child" value={editDraft.childId} onChange={(event) => setEditDraft((current) => current ? { ...current, childId: event.target.value } : current)}>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
          <div className="field"><label htmlFor="photo-edit-caption">Moment</label><input id="photo-edit-caption" maxLength={2_000} value={editDraft.caption} onChange={(event) => setEditDraft((current) => current ? { ...current, caption: event.target.value } : current)} /></div>
          <div className="photos-panel__field-pair"><div className="field"><label htmlFor="photo-edit-date">Date taken</label><input id="photo-edit-date" type="date" max={localDateValue()} value={editDraft.takenOn} onChange={(event) => setEditDraft((current) => current ? { ...current, takenOn: event.target.value } : current)} /></div><div className="field"><label htmlFor="photo-edit-place">Place</label><input id="photo-edit-place" maxLength={300} value={editDraft.location} onChange={(event) => setEditDraft((current) => current ? { ...current, location: event.target.value } : current)} /></div></div>
          <div className="field"><label htmlFor="photo-edit-story">Story</label><textarea id="photo-edit-story" rows={4} maxLength={2_000} value={editDraft.story} onChange={(event) => setEditDraft((current) => current ? { ...current, story: event.target.value } : current)} /></div>
          <label className="photos-panel__check"><input type="checkbox" checked={editDraft.includeInYearbook} onChange={(event) => setEditDraft((current) => current ? { ...current, includeInYearbook: event.target.checked } : current)} /><span><strong>Available for Yearbook</strong></span></label>
          <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setEditOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "edit"}>{working === "edit" ? "Saving…" : "Save changes"}</button></div>
        </form> : null}
      </Modal>

      <ConfirmDialog open={Boolean(deleteTarget)} onOpenChange={(open) => { if (!open) setDeleteTarget(null); }} title="Remove this photo?" description="It will disappear from the gallery now, but Undo can restore the preserved files." confirmLabel="Remove photo" destructive busy={working === "delete"} onConfirm={() => { if (deleteTarget) void removePhoto(deleteTarget); }} />
    </div>
  );
}
