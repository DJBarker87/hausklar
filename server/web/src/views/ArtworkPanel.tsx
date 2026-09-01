import {
  BookOpen,
  Camera,
  Check,
  ChevronDown,
  Download,
  Heart,
  Image as ImageIcon,
  Loader2,
  Palette,
  Pencil,
  Plus,
  Printer,
  RotateCcw,
  RotateCw,
  Share2,
  Sparkles,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, isOfflineQueuedResult } from "../api";
import { ConfirmDialog, EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { Child } from "../types";

import "./artwork-panel.css";

export type Artwork = {
  id: string;
  child_id: string;
  child_name?: string | null;
  title?: string | null;
  approx_date: string;
  date_precision: "year" | "month" | "day";
  age_label?: string | null;
  notes?: string | null;
  medium?: string | null;
  story?: string | null;
  child_quote?: string | null;
  school_year?: string | null;
  favourite: boolean;
  include_in_yearbook: boolean;
  yearbook_position?: number | null;
  original_available: boolean;
  rotation_degrees: number;
  enhanced: boolean;
  created_at: string;
  updated_at?: string | null;
  image_url: string;
  original_image_url?: string | null;
};

type SelectedPhoto = { id: string; file: File; preview: string };
type CaptureDraft = {
  childId: string;
  year: string;
  month: string;
  day: string;
  title: string;
  notes: string;
  medium: string;
  story: string;
  childQuote: string;
  schoolYear: string;
  includeInYearbook: boolean;
};
type EditDraft = Omit<CaptureDraft, "includeInYearbook"> & {
  favourite: boolean;
  includeInYearbook: boolean;
};

const PAGE_SIZE = 40;
const CAPTURE_MEMORY_KEY = "hausklar.artwork.capture";
const MONTHS = Array.from({ length: 12 }, (_, index) => ({
  value: String(index + 1).padStart(2, "0"),
  label: format(new Date(2026, index, 1), "MMMM"),
}));

function localDateValue(date = new Date()): string {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

function splitApproxDate(value: string): Pick<CaptureDraft, "year" | "month" | "day"> {
  const [year = String(new Date().getFullYear()), month = "", day = ""] = value.split("-");
  return { year, month, day };
}

function approxDate(draft: Pick<CaptureDraft, "year" | "month" | "day">): string {
  if (!draft.month) return draft.year;
  if (!draft.day) return `${draft.year}-${draft.month}`;
  return `${draft.year}-${draft.month}-${draft.day}`;
}

function artworkDateLabel(artwork: Artwork): string {
  if (artwork.date_precision === "year") return artwork.approx_date;
  if (artwork.date_precision === "month") {
    return format(parseISO(`${artwork.approx_date}-01`), "MMMM yyyy");
  }
  return format(parseISO(artwork.approx_date), "d MMMM yyyy");
}

function apiImageURL(path: string, size?: "thumb"): string {
  const suffix = size ? `${path.includes("?") ? "&" : "?"}size=${size}` : "";
  return `/api${path}${suffix}`;
}

function sortArtworks(items: Artwork[]): Artwork[] {
  return [...items].sort((first, second) => {
    if (first.favourite !== second.favourite) return first.favourite ? -1 : 1;
    if (first.approx_date !== second.approx_date) return first.approx_date < second.approx_date ? 1 : -1;
    return first.created_at < second.created_at ? 1 : -1;
  });
}

function mergeArtwork(items: Artwork[], artwork: Artwork): Artwork[] {
  return sortArtworks([artwork, ...items.filter((item) => item.id !== artwork.id)]);
}

function filenameFor(artwork: Artwork, mediaType = "image/jpeg"): string {
  const base = (artwork.title || `${artwork.child_name ?? "Child"} artwork`)
    .replace(/[\\/:*?"<>|]+/g, "-")
    .trim() || "Artwork";
  const extension = ({
    "image/png": "png",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/webp": "webp",
  } as Record<string, string>)[mediaType.toLowerCase()] ?? "jpg";
  return `${base}.${extension}`;
}

function readCaptureMemory(): { childId?: string; approxDate?: string } {
  try {
    const stored = window.sessionStorage.getItem(CAPTURE_MEMORY_KEY);
    if (!stored) return {};
    const parsed = JSON.parse(stored) as { childId?: unknown; approxDate?: unknown };
    return {
      childId: typeof parsed.childId === "string" ? parsed.childId : undefined,
      approxDate: typeof parsed.approxDate === "string" ? parsed.approxDate : undefined,
    };
  } catch {
    return {};
  }
}

function rememberCapture(childId: string, date: string): void {
  try {
    window.sessionStorage.setItem(CAPTURE_MEMORY_KEY, JSON.stringify({ childId, approxDate: date }));
  } catch {
    // A remembered convenience must never prevent capture in privacy mode.
  }
}

function artworkMatches(artwork: Artwork, selectedChild: string, favouritesOnly: boolean): boolean {
  return (selectedChild === "all" || artwork.child_id === selectedChild)
    && (!favouritesOnly || artwork.favourite);
}

function ArtworkImage({ artwork, size = "full", className }: { artwork: Artwork; size?: "thumb" | "full"; className?: string }) {
  const [failed, setFailed] = useState(false);
  const title = artwork.title || `Artwork by ${artwork.child_name ?? "a child"}`;
  if (failed) {
    return <div className={cn("artwork-panel__image-fallback", className)} role="img" aria-label={`${title} image unavailable`}><Palette aria-hidden="true" /></div>;
  }
  return (
    <img
      className={className}
      src={apiImageURL(artwork.image_url, size === "thumb" ? "thumb" : undefined)}
      alt={title}
      loading={size === "thumb" ? "lazy" : "eager"}
      onError={() => setFailed(true)}
    />
  );
}

function DetailFields({
  draft,
  onChange,
  prefix,
  editing = false,
}: {
  draft: CaptureDraft | EditDraft;
  onChange: (draft: CaptureDraft | EditDraft) => void;
  prefix: string;
  editing?: boolean;
}) {
  return (
    <div className="artwork-panel__detail-fields">
      <div className="field">
        <label htmlFor={`${prefix}-title`}>Title (optional)</label>
        <input id={`${prefix}-title`} maxLength={200} placeholder="Our house, a rocket, Granny…" value={draft.title} onChange={(event) => onChange({ ...draft, title: event.target.value })} />
      </div>
      <div className="artwork-panel__form-pair">
        <div className="field">
          <label htmlFor={`${prefix}-medium`}>Medium</label>
          <input id={`${prefix}-medium`} maxLength={120} placeholder="Paint, collage, pencil…" value={draft.medium} onChange={(event) => onChange({ ...draft, medium: event.target.value })} />
        </div>
        <div className="field">
          <label htmlFor={`${prefix}-school-year`}>School year</label>
          <input id={`${prefix}-school-year`} maxLength={40} placeholder="Reception" value={draft.schoolYear} onChange={(event) => onChange({ ...draft, schoolYear: event.target.value })} />
        </div>
      </div>
      <div className="field">
        <label htmlFor={`${prefix}-story`}>The story behind it</label>
        <textarea id={`${prefix}-story`} rows={3} maxLength={2_000} placeholder="What was happening when they made it?" value={draft.story} onChange={(event) => onChange({ ...draft, story: event.target.value })} />
      </div>
      <div className="field">
        <label htmlFor={`${prefix}-quote`}>What they said about it</label>
        <textarea id={`${prefix}-quote`} rows={2} maxLength={500} placeholder="Their words, while they are still fresh" value={draft.childQuote} onChange={(event) => onChange({ ...draft, childQuote: event.target.value })} />
      </div>
      <div className="field">
        <label htmlFor={`${prefix}-notes`}>Other notes</label>
        <textarea id={`${prefix}-notes`} rows={2} maxLength={2_000} value={draft.notes} onChange={(event) => onChange({ ...draft, notes: event.target.value })} />
      </div>
      <label className="artwork-panel__check">
        <input type="checkbox" aria-label="Include in Yearbook" checked={draft.includeInYearbook} onChange={(event) => onChange({ ...draft, includeInYearbook: event.target.checked })} />
        <span><strong>Include in Yearbook</strong><small>Keep this piece available for the annual book.</small></span>
      </label>
      {editing && "favourite" in draft ? (
        <label className="artwork-panel__check">
          <input type="checkbox" aria-label="Favourite" checked={draft.favourite} onChange={(event) => onChange({ ...draft, favourite: event.target.checked })} />
          <span><strong>Favourite</strong><small>Pin it towards the front of the gallery.</small></span>
        </label>
      ) : null}
    </div>
  );
}

function RoughDateFields({
  draft,
  onChange,
  prefix,
}: {
  draft: Pick<CaptureDraft, "year" | "month" | "day">;
  onChange: (values: Pick<CaptureDraft, "year" | "month" | "day">) => void;
  prefix: string;
}) {
  const year = Number(draft.year);
  const month = Number(draft.month);
  const days = draft.month && Number.isFinite(year) && Number.isFinite(month)
    ? new Date(year, month, 0).getDate()
    : 31;
  const currentYear = new Date().getFullYear();
  const years = Array.from({ length: 22 }, (_, index) => String(currentYear + 1 - index));
  return (
    <fieldset className="artwork-panel__rough-date">
      <legend>When was it made? <span>Roughly is fine</span></legend>
      <div className="artwork-panel__date-grid">
        <div className="field">
          <label htmlFor={`${prefix}-year`}>Year</label>
          <select id={`${prefix}-year`} value={draft.year} onChange={(event) => {
            const nextYear = event.target.value;
            const nextDays = draft.month ? new Date(Number(nextYear), Number(draft.month), 0).getDate() : 31;
            onChange({ ...draft, year: nextYear, day: Number(draft.day) > nextDays ? "" : draft.day });
          }}>{years.map((value) => <option value={value} key={value}>{value}</option>)}</select>
        </div>
        <div className="field">
          <label htmlFor={`${prefix}-month`}>Month</label>
          <select id={`${prefix}-month`} value={draft.month} onChange={(event) => onChange({ ...draft, month: event.target.value, day: "" })}>
            <option value="">Any time that year</option>
            {MONTHS.map((item) => <option value={item.value} key={item.value}>{item.label}</option>)}
          </select>
        </div>
        {draft.month ? <div className="field">
          <label htmlFor={`${prefix}-day`}>Day</label>
          <select id={`${prefix}-day`} value={draft.day} onChange={(event) => onChange({ ...draft, day: event.target.value })}>
            <option value="">Any time that month</option>
            {Array.from({ length: days }, (_, index) => String(index + 1).padStart(2, "0")).map((value) => <option value={value} key={value}>{Number(value)}</option>)}
          </select>
        </div> : null}
      </div>
    </fieldset>
  );
}

export function ArtworkPanel({
  children,
  selectedChild,
  revision,
  initialArtworkId,
  onDataChanged,
}: {
  children: Child[];
  selectedChild: string;
  revision: number;
  initialArtworkId?: string | null;
  onDataChanged: () => void;
}) {
  const [artworks, setArtworks] = useState<Artwork[]>([]);
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
  const [captureFiles, setCaptureFiles] = useState<SelectedPhoto[]>([]);
  const [captureDetailsOpen, setCaptureDetailsOpen] = useState(false);
  const [captureProgress, setCaptureProgress] = useState<{ saved: number; total: number } | null>(null);
  const captureFilesRef = useRef<SelectedPhoto[]>([]);
  const [captureDraft, setCaptureDraft] = useState<CaptureDraft>(() => {
    const date = splitApproxDate(localDateValue());
    return { childId: "", ...date, title: "", notes: "", medium: "", story: "", childQuote: "", schoolYear: "", includeInYearbook: false };
  });

  const [viewer, setViewer] = useState<Artwork | null>(null);
  const [editTarget, setEditTarget] = useState<Artwork | null>(null);
  const [editDraft, setEditDraft] = useState<EditDraft | null>(null);
  const [adjustTarget, setAdjustTarget] = useState<Artwork | null>(null);
  const [adjustment, setAdjustment] = useState({ rotation: 0, enhanced: false });
  const [deleteTarget, setDeleteTarget] = useState<Artwork | null>(null);
  const [undoArtwork, setUndoArtwork] = useState<Artwork | null>(null);

  const selectedChildName = useMemo(
    () => children.find((child) => child.id === selectedChild)?.name,
    [children, selectedChild],
  );

  const loadPage = useCallback(async (reset: boolean) => {
    const sequence = ++requestSequence.current;
    if (reset) {
      setLoading(true);
      setError(null);
    } else {
      setLoadingMore(true);
    }
    const offset = reset ? 0 : nextOffset;
    const query = new URLSearchParams({ offset: String(offset), limit: String(PAGE_SIZE) });
    if (selectedChild !== "all") query.set("child_id", selectedChild);
    if (favouritesOnly) query.set("favourites_only", "true");
    try {
      const fetched = await api<Artwork[]>(`/artworks/?${query.toString()}`);
      if (sequence !== requestSequence.current) return;
      setArtworks((current) => reset
        ? sortArtworks(fetched)
        : sortArtworks([...current, ...fetched.filter((item) => !current.some((known) => known.id === item.id))]));
      setNextOffset(offset + fetched.length);
      setHasMore(fetched.length === PAGE_SIZE);
      setError(null);
    } catch (requestError) {
      if (sequence !== requestSequence.current) return;
      const message = requestError instanceof Error ? requestError.message : "The artwork gallery could not be opened.";
      if (reset && artworks.length === 0) setError(message);
      else setActionError("More artwork could not be loaded. Try again when the connection settles.");
    } finally {
      if (sequence === requestSequence.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [artworks.length, favouritesOnly, nextOffset, selectedChild]);

  useEffect(() => {
    void loadPage(true);
    // The callback intentionally reloads when the route filter or shared data revision changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedChild, favouritesOnly, revision]);

  useEffect(() => {
    captureFilesRef.current = captureFiles;
  }, [captureFiles]);

  useEffect(() => () => {
    for (const item of captureFilesRef.current) if (item.preview) URL.revokeObjectURL(item.preview);
  }, []);

  function visibleAfterUpdate(artwork: Artwork): boolean {
    return artworkMatches(artwork, selectedChild, favouritesOnly);
  }

  function applyUpdatedArtwork(updated: Artwork): void {
    setArtworks((current) => {
      const existed = current.some((item) => item.id === updated.id);
      const visible = visibleAfterUpdate(updated);
      if (existed && !visible) {
        setNextOffset((offset) => Math.max(0, offset - 1));
        return current.filter((item) => item.id !== updated.id);
      }
      if (!existed && visible) setNextOffset((offset) => offset + 1);
      return visible ? mergeArtwork(current, updated) : current;
    });
    setViewer((current) => current?.id === updated.id ? updated : current);
  }

  useEffect(() => {
    if (!initialArtworkId) return;
    let cancelled = false;
    void api<Artwork>(`/artworks/${initialArtworkId}`)
      .then((artwork) => {
        if (cancelled) return;
        setArtworks((current) => artworkMatches(artwork, selectedChild, favouritesOnly) ? mergeArtwork(current, artwork) : current);
        setViewer(artwork);
        const url = new URL(window.location.href);
        url.searchParams.delete("artwork");
        window.history.replaceState({}, "", url);
      })
      .catch((requestError) => {
        if (!cancelled) setActionError(requestError instanceof Error ? requestError.message : "That artwork could not be opened.");
      });
    return () => { cancelled = true; };
  }, [favouritesOnly, initialArtworkId, selectedChild]);

  function openCapture() {
    const memory = readCaptureMemory();
    const rememberedChild = children.some((child) => child.id === memory.childId) ? memory.childId! : "";
    const childId = selectedChild !== "all" ? selectedChild : rememberedChild || children[0]?.id || "";
    const rememberedDate = /^\d{4}(-\d{2})?(-\d{2})?$/.test(memory.approxDate ?? "")
      ? memory.approxDate!
      : localDateValue();
    setCaptureDraft({
      childId,
      ...splitApproxDate(rememberedDate),
      title: "",
      notes: "",
      medium: "",
      story: "",
      childQuote: "",
      schoolYear: "",
      includeInYearbook: false,
    });
    setCaptureFiles([]);
    setCaptureDetailsOpen(false);
    setCaptureProgress(null);
    setActionError(null);
    setCaptureOpen(true);
  }

  function closeCapture() {
    if (working === "capture") return;
    setCaptureOpen(false);
    setCaptureFiles((current) => {
      for (const item of current) if (item.preview) URL.revokeObjectURL(item.preview);
      return [];
    });
    setCaptureProgress(null);
  }

  function selectCaptureFiles(files: FileList | null) {
    if (!files?.length) return;
    const remainingCapacity = Math.max(0, 30 - captureFilesRef.current.length);
    const incoming = Array.from(files);
    const accepted = incoming.slice(0, remainingCapacity);
    const selected = accepted.map((file) => ({
      id: crypto.randomUUID(),
      file,
      preview: typeof URL.createObjectURL === "function" ? URL.createObjectURL(file) : "",
    }));
    if (incoming.length > remainingCapacity) {
      setActionError(remainingCapacity
        ? `Added ${remainingCapacity}. A pile can contain up to 30 pieces.`
        : "This pile already contains 30 pieces. Remove one before adding another.");
    }
    else setActionError(null);
    captureFilesRef.current = [...captureFilesRef.current, ...selected];
    setCaptureFiles(captureFilesRef.current);
  }

  function removeCaptureFile(id: string) {
    setCaptureFiles((current) => {
      const removed = current.find((item) => item.id === id);
      if (removed?.preview) URL.revokeObjectURL(removed.preview);
      return current.filter((item) => item.id !== id);
    });
  }

  async function saveCapture(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!captureDraft.childId || !captureFiles.length) return;
    setWorking("capture");
    setActionError(null);
    const date = approxDate(captureDraft);
    const pending = [...captureFiles];
    let saved = 0;
    let queued = 0;
    let failure: unknown = null;
    setCaptureProgress({ saved: 0, total: pending.length });
    for (const [index, selected] of pending.entries()) {
      const form = new FormData();
      form.set("file", selected.file, selected.file.name);
      form.set("child_id", captureDraft.childId);
      form.set("approx_date", date);
      form.set("client_id", selected.id);
      const title = captureDraft.title.trim();
      if (title) form.set("title", pending.length === 1 ? title : `${title} ${index + 1}`);
      const fields: Array<[string, string]> = [
        ["notes", captureDraft.notes],
        ["medium", captureDraft.medium],
        ["story", captureDraft.story],
        ["child_quote", captureDraft.childQuote],
        ["school_year", captureDraft.schoolYear],
      ];
      for (const [key, value] of fields) if (value.trim()) form.set(key, value.trim());
      form.set("include_in_yearbook", String(captureDraft.includeInYearbook));
      try {
        const created = await api<Artwork>("/artworks/", { method: "POST", body: form, timeoutMs: 60_000 });
        if (isOfflineQueuedResult(created)) {
          queued += 1;
        } else if (visibleAfterUpdate(created)) {
          setArtworks((current) => mergeArtwork(current, created));
          setNextOffset((offset) => offset + 1);
        }
        saved += 1;
        setCaptureProgress({ saved, total: pending.length });
      } catch (requestError) {
        failure = requestError;
        break;
      }
    }
    if (saved > 0) {
      rememberCapture(captureDraft.childId, date);
      onDataChanged();
      setCaptureFiles((current) => {
        const completed = current.slice(0, saved);
        for (const item of completed) if (item.preview) URL.revokeObjectURL(item.preview);
        return current.slice(saved);
      });
    }
    if (failure) {
      const detail = failure instanceof Error ? failure.message : "One photo could not be saved.";
      setActionError(saved ? `${saved} saved; the next piece still needs attention. ${detail}` : detail);
    } else {
      setCaptureOpen(false);
      setCaptureFiles([]);
      setNotice(queued
        ? `${queued === pending.length ? "The pile is" : `${queued} pieces are`} ready to upload when the connection returns.`
        : `${saved} ${saved === 1 ? "piece" : "pieces"} added to the family gallery.`);
    }
    setCaptureProgress(null);
    setWorking(null);
  }

  async function patchArtwork(artwork: Artwork, payload: Record<string, unknown>, key: string): Promise<Artwork | null> {
    setWorking(key);
    setActionError(null);
    try {
      const updated = await api<Artwork>(`/artworks/${artwork.id}`, {
        method: "PATCH",
        body: JSON.stringify(payload),
      });
      applyUpdatedArtwork(updated);
      onDataChanged();
      return updated;
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The artwork could not be updated.");
      return null;
    } finally {
      setWorking(null);
    }
  }

  async function toggleFavourite(artwork: Artwork) {
    const updated = await patchArtwork(artwork, { favourite: !artwork.favourite }, `favourite-${artwork.id}`);
    if (updated) setNotice(updated.favourite ? "Added to favourites." : "Removed from favourites.");
  }

  async function toggleYearbook(artwork: Artwork) {
    const updated = await patchArtwork(artwork, { include_in_yearbook: !artwork.include_in_yearbook }, `yearbook-${artwork.id}`);
    if (updated) setNotice(updated.include_in_yearbook ? "Included in the Yearbook." : "Kept in the gallery but left out of the Yearbook.");
  }

  function openEdit(artwork: Artwork) {
    setViewer(null);
    setEditTarget(artwork);
    setEditDraft({
      childId: artwork.child_id,
      ...splitApproxDate(artwork.approx_date),
      title: artwork.title ?? "",
      notes: artwork.notes ?? "",
      medium: artwork.medium ?? "",
      story: artwork.story ?? "",
      childQuote: artwork.child_quote ?? "",
      schoolYear: artwork.school_year ?? "",
      favourite: artwork.favourite,
      includeInYearbook: artwork.include_in_yearbook,
    });
    setActionError(null);
  }

  async function saveEdit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editTarget || !editDraft) return;
    const updated = await patchArtwork(editTarget, {
      child_id: editDraft.childId,
      approx_date: approxDate(editDraft),
      title: editDraft.title.trim() || null,
      notes: editDraft.notes.trim() || null,
      medium: editDraft.medium.trim() || null,
      story: editDraft.story.trim() || null,
      child_quote: editDraft.childQuote.trim() || null,
      school_year: editDraft.schoolYear.trim() || null,
      favourite: editDraft.favourite,
      include_in_yearbook: editDraft.includeInYearbook,
    }, `edit-${editTarget.id}`);
    if (updated) {
      setEditTarget(null);
      setEditDraft(null);
      setViewer(updated);
      setNotice("Artwork details updated.");
    }
  }

  function openAdjustments(artwork: Artwork) {
    setViewer(null);
    setAdjustTarget(artwork);
    setAdjustment({ rotation: artwork.rotation_degrees ?? 0, enhanced: artwork.enhanced });
    setActionError(null);
  }

  async function saveAdjustments() {
    if (!adjustTarget) return;
    setWorking(`adjust-${adjustTarget.id}`);
    setActionError(null);
    try {
      const updated = await api<Artwork>(`/artworks/${adjustTarget.id}/appearance`, {
        method: "PUT",
        body: JSON.stringify({ rotation_degrees: adjustment.rotation, enhanced: adjustment.enhanced }),
        timeoutMs: 60_000,
      });
      applyUpdatedArtwork(updated);
      setAdjustTarget(null);
      setViewer(updated);
      setNotice("Photo adjustments applied. The original is still safe.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The photo could not be adjusted.");
    } finally {
      setWorking(null);
    }
  }

  async function deleteArtwork() {
    if (!deleteTarget) return;
    const removed = deleteTarget;
    setWorking(`delete-${removed.id}`);
    setActionError(null);
    try {
      await api(`/artworks/${removed.id}`, { method: "DELETE" });
      setArtworks((current) => current.filter((item) => item.id !== removed.id));
      setNextOffset((offset) => Math.max(0, offset - 1));
      setViewer(null);
      setDeleteTarget(null);
      setUndoArtwork(removed);
      setNotice(null);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The artwork could not be removed.");
      setDeleteTarget(null);
    } finally {
      setWorking(null);
    }
  }

  async function restoreArtwork() {
    if (!undoArtwork) return;
    const removed = undoArtwork;
    setWorking(`restore-${removed.id}`);
    setActionError(null);
    try {
      const restored = await api<Artwork>(`/artworks/${removed.id}/restore`, { method: "POST" });
      if (visibleAfterUpdate(restored)) {
        setArtworks((current) => mergeArtwork(current, restored));
        setNextOffset((offset) => offset + 1);
      }
      setUndoArtwork(null);
      setNotice("Artwork restored.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The artwork could not be restored.");
    } finally {
      setWorking(null);
    }
  }

  async function shareArtwork(artwork: Artwork) {
    setWorking(`share-${artwork.id}`);
    setActionError(null);
    const path = artwork.original_image_url || artwork.image_url;
    try {
      const response = await fetch(apiImageURL(path), { credentials: "same-origin" });
      if (!response.ok) throw new Error("The image could not be prepared for sharing.");
      const blob = await response.blob();
      const file = new File([blob], filenameFor(artwork, blob.type), { type: blob.type || "image/jpeg" });
      const shareData: ShareData = { title: artwork.title || "Artwork", files: [file] };
      if (navigator.share && (!navigator.canShare || navigator.canShare(shareData))) {
        await navigator.share(shareData);
        setNotice("Artwork shared.");
      } else {
        const downloadURL = typeof URL.createObjectURL === "function" ? URL.createObjectURL(blob) : apiImageURL(path);
        const link = document.createElement("a");
        link.href = downloadURL;
        link.download = filenameFor(artwork, blob.type);
        document.body.append(link);
        link.click();
        link.remove();
        if (downloadURL.startsWith("blob:")) window.setTimeout(() => URL.revokeObjectURL(downloadURL), 1_000);
        setNotice("Artwork downloaded, ready to share.");
      }
    } catch (requestError) {
      if (requestError instanceof DOMException && requestError.name === "AbortError") return;
      setActionError(requestError instanceof Error ? requestError.message : "The artwork could not be shared.");
    } finally {
      setWorking(null);
    }
  }

  return (
    <section className="artwork-panel" aria-labelledby="artwork-panel-heading">
      <header className="artwork-panel__hero">
        <div className="artwork-panel__hero-copy">
          <span className="artwork-panel__hero-icon"><Palette aria-hidden="true" size={28} /></span>
          <div>
            <p className="page-eyebrow">Creations</p>
            <h2 id="artwork-panel-heading">Artwork</h2>
            <p>{selectedChildName ? `${selectedChildName}'s gallery` : "Small masterpieces, kept properly"}</p>
          </div>
        </div>
        <button type="button" className="button button--primary" disabled={!children.length} onClick={openCapture}><Camera aria-hidden="true" size={18} /> Add artwork</button>
      </header>

      <div className="artwork-panel__toolbar">
        <div className="artwork-panel__filter" role="group" aria-label="Artwork filter">
          <button type="button" className={cn(!favouritesOnly && "is-active")} aria-pressed={!favouritesOnly} onClick={() => setFavouritesOnly(false)}>All artwork</button>
          <button type="button" className={cn(favouritesOnly && "is-active")} aria-pressed={favouritesOnly} onClick={() => setFavouritesOnly(true)}><Heart aria-hidden="true" size={16} /> Favourites</button>
        </div>
        {!loading && artworks.length ? <span>{artworks.length}{hasMore ? "+" : ""} {artworks.length === 1 ? "piece" : "pieces"}</span> : null}
      </div>

      {actionError ? <div className="artwork-panel__message is-error" role="alert"><span>{actionError}</span><button type="button" aria-label="Dismiss error" onClick={() => setActionError(null)}><X aria-hidden="true" size={17} /></button></div> : null}
      {notice ? <div className="artwork-panel__message is-success" role="status"><Check aria-hidden="true" size={18} /><span>{notice}</span><button type="button" aria-label="Dismiss message" onClick={() => setNotice(null)}><X aria-hidden="true" size={17} /></button></div> : null}

      {loading && !artworks.length ? <SkeletonList rows={6} /> : null}
      {error && !artworks.length ? <ErrorState message={error} retry={() => void loadPage(true)} /> : null}
      {!loading && !error && !artworks.length ? (
        <EmptyState
          title={favouritesOnly ? "No favourites yet" : "No artwork yet"}
          detail={favouritesOnly ? "Tap the heart on a treasured piece to keep it here." : "Photograph a drawing now; the story and details can come later."}
          action={favouritesOnly ? () => setFavouritesOnly(false) : openCapture}
          actionLabel={favouritesOnly ? "Show all artwork" : "Add artwork"}
        />
      ) : null}

      {artworks.length ? (
        <div className="artwork-panel__grid" aria-label="Artwork gallery">
          {artworks.map((artwork) => (
            <button type="button" className="artwork-panel__card" onClick={() => { setViewer(artwork); setActionError(null); }} key={artwork.id}>
              <span className="artwork-panel__card-image">
                <ArtworkImage artwork={artwork} size="thumb" />
                {artwork.favourite ? <span className="artwork-panel__favourite" aria-label="Favourite"><Heart aria-hidden="true" size={15} fill="currentColor" /></span> : null}
                {!artwork.include_in_yearbook ? <span className="artwork-panel__yearbook-state">Gallery only</span> : null}
              </span>
              <span className="artwork-panel__card-copy">
                <strong>{artwork.title || artworkDateLabel(artwork)}</strong>
                <small>{[artwork.child_name, artwork.age_label].filter(Boolean).join(" · ") || artworkDateLabel(artwork)}</small>
              </span>
            </button>
          ))}
        </div>
      ) : null}

      {hasMore && artworks.length ? (
        <div className="artwork-panel__load-more">
          <button type="button" className="button button--secondary" disabled={loadingMore} onClick={() => void loadPage(false)}>
            {loadingMore ? <Loader2 className="spin" aria-hidden="true" size={18} /> : <ImageIcon aria-hidden="true" size={18} />}
            {loadingMore ? "Loading…" : "Load more artwork"}
          </button>
        </div>
      ) : null}

      <Modal open={captureOpen} onOpenChange={(open) => open ? setCaptureOpen(true) : closeCapture()} title="Add artwork" description="Choose a whole pile. Every piece keeps the same child and rough date." size="wide">
        <form className="artwork-panel__form" onSubmit={saveCapture}>
          <div className="artwork-panel__capture-zone">
            <input id="artwork-capture-files" type="file" accept="image/jpeg,image/png,image/heic,image/heif,image/webp" multiple disabled={captureFiles.length >= 30} onChange={(event) => { selectCaptureFiles(event.target.files); event.target.value = ""; }} />
            <label htmlFor="artwork-capture-files"><Camera aria-hidden="true" size={23} /><span><strong>{captureFiles.length >= 30 ? "Pile full" : captureFiles.length ? "Add more photos" : "Photograph or choose a pile"}</strong><small>{captureFiles.length ? `${30 - captureFiles.length} ${30 - captureFiles.length === 1 ? "space" : "spaces"} left` : "Up to 30 pieces at once"}</small></span></label>
          </div>
          {captureFiles.length ? (
            <div className="artwork-panel__capture-list" aria-label="Selected artwork photos">
              {captureFiles.map((selected, index) => (
                <div className="artwork-panel__capture-photo" key={selected.id}>
                  {selected.preview ? <img src={selected.preview} alt="" /> : <ImageIcon aria-hidden="true" />}
                  <span><strong>Piece {index + 1}</strong><small>{selected.file.name}</small></span>
                  <button type="button" aria-label={`Remove photo ${index + 1}`} onClick={() => removeCaptureFile(selected.id)}><X aria-hidden="true" size={17} /></button>
                </div>
              ))}
            </div>
          ) : null}
          <div className="field">
            <label htmlFor="artwork-capture-child">Whose masterpiece?</label>
            <select id="artwork-capture-child" value={captureDraft.childId} onChange={(event) => setCaptureDraft((current) => ({ ...current, childId: event.target.value }))} required>
              <option value="" disabled>Choose a child</option>
              {children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}
            </select>
          </div>
          <RoughDateFields draft={captureDraft} prefix="artwork-capture" onChange={(values) => setCaptureDraft((current) => ({ ...current, ...values }))} />
          <button type="button" className="artwork-panel__details-toggle" aria-expanded={captureDetailsOpen} onClick={() => setCaptureDetailsOpen((open) => !open)}>
            <span><strong>More details</strong><small>Optional — you can always add these later</small></span>
            <ChevronDown aria-hidden="true" size={19} />
          </button>
          {captureDetailsOpen ? <DetailFields draft={captureDraft} prefix="artwork-capture" onChange={(draft) => setCaptureDraft(draft as CaptureDraft)} /> : null}
          {actionError ? <p className="artwork-panel__form-error" role="alert">{actionError}</p> : null}
          {captureProgress ? <div className="artwork-panel__progress" role="status"><Loader2 className="spin" aria-hidden="true" size={18} /><span>Saving {captureProgress.saved} of {captureProgress.total}…</span></div> : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={working === "capture"} onClick={closeCapture}>Cancel</button>
            <button type="submit" className="button button--primary" disabled={working === "capture" || !captureDraft.childId || !captureFiles.length}>{working === "capture" ? "Saving pile…" : `Save ${captureFiles.length || ""} ${captureFiles.length === 1 ? "piece" : "pieces"}`}</button>
          </div>
        </form>
      </Modal>

      <Modal open={Boolean(viewer)} onOpenChange={(open) => !open && setViewer(null)} title={viewer?.title || "Artwork"} description={viewer ? [viewer.child_name, artworkDateLabel(viewer), viewer.age_label].filter(Boolean).join(" · ") : undefined} size="wide">
        {viewer ? (
          <article className="artwork-panel__viewer artwork-viewer-print">
            <div className="artwork-panel__viewer-image"><ArtworkImage artwork={viewer} /></div>
            <div className="artwork-panel__viewer-actions" aria-label="Artwork actions">
              <button type="button" className={cn("artwork-panel__action", viewer.favourite && "is-active")} disabled={Boolean(working)} onClick={() => void toggleFavourite(viewer)}><Heart aria-hidden="true" size={18} fill={viewer.favourite ? "currentColor" : "none"} /><span>{viewer.favourite ? "Remove favourite" : "Favourite"}</span></button>
              <button type="button" className={cn("artwork-panel__action", viewer.include_in_yearbook && "is-active")} disabled={Boolean(working)} onClick={() => void toggleYearbook(viewer)}><BookOpen aria-hidden="true" size={18} /><span>{viewer.include_in_yearbook ? "In Yearbook" : "Add to Yearbook"}</span></button>
              <button type="button" className="artwork-panel__action" disabled={Boolean(working)} onClick={() => void shareArtwork(viewer)}>{working === `share-${viewer.id}` ? <Loader2 className="spin" aria-hidden="true" size={18} /> : <Share2 aria-hidden="true" size={18} />}<span>Share</span></button>
              <button type="button" className="artwork-panel__action" disabled={Boolean(working)} onClick={() => window.print()}><Printer aria-hidden="true" size={18} /><span>Print</span></button>
            </div>
            <div className="artwork-panel__viewer-copy">
              {viewer.title ? <h3>{viewer.title}</h3> : null}
              <p className="artwork-panel__meta">{[viewer.child_name, artworkDateLabel(viewer), viewer.age_label].filter(Boolean).join(" · ")}</p>
              {viewer.notes ? <p>{viewer.notes}</p> : null}
              {(viewer.medium || viewer.school_year) ? <div className="artwork-panel__facts">{viewer.medium ? <span><Palette aria-hidden="true" size={16} />{viewer.medium}</span> : null}{viewer.school_year ? <span><BookOpen aria-hidden="true" size={16} />{viewer.school_year}</span> : null}</div> : null}
              {viewer.story ? <section><h4>The story</h4><p>{viewer.story}</p></section> : null}
              {viewer.child_quote ? <blockquote>“{viewer.child_quote}”</blockquote> : null}
              <p className="artwork-panel__original-note">The original photo is kept untouched, even after adjustments.</p>
            </div>
            {actionError ? <p className="artwork-panel__form-error" role="alert">{actionError}</p> : null}
            <div className="dialog-actions artwork-panel__viewer-footer">
              {viewer.original_available && viewer.original_image_url ? <a className="button button--secondary" href={apiImageURL(viewer.original_image_url)} target="_blank" rel="noreferrer"><Download aria-hidden="true" size={17} /> Original</a> : null}
              <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => openAdjustments(viewer)}><Sparkles aria-hidden="true" size={17} /> Adjust photo</button>
              <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => openEdit(viewer)}><Pencil aria-hidden="true" size={17} /> Edit details</button>
              <button type="button" className="button button--danger" disabled={Boolean(working)} onClick={() => setDeleteTarget(viewer)}><Trash2 aria-hidden="true" size={17} /> Remove</button>
            </div>
          </article>
        ) : null}
      </Modal>

      <Modal open={Boolean(editTarget && editDraft)} onOpenChange={(open) => { if (!open && !working?.startsWith("edit-")) { setEditTarget(null); setEditDraft(null); } }} title="Edit artwork" description="Correct the record without losing the original photo." size="wide">
        {editTarget && editDraft ? (
          <form className="artwork-panel__form" onSubmit={saveEdit}>
            <div className="field"><label htmlFor="artwork-edit-child">Child</label><select id="artwork-edit-child" value={editDraft.childId} onChange={(event) => setEditDraft((current) => current ? { ...current, childId: event.target.value } : current)} required>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
            <RoughDateFields draft={editDraft} prefix="artwork-edit" onChange={(values) => setEditDraft((current) => current ? { ...current, ...values } : current)} />
            <DetailFields draft={editDraft} prefix="artwork-edit" editing onChange={(draft) => setEditDraft(draft as EditDraft)} />
            {actionError ? <p className="artwork-panel__form-error" role="alert">{actionError}</p> : null}
            <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === `edit-${editTarget.id}`} onClick={() => { setEditTarget(null); setEditDraft(null); }}>Cancel</button><button type="submit" className="button button--primary" disabled={working === `edit-${editTarget.id}`}>{working === `edit-${editTarget.id}` ? "Saving…" : "Save changes"}</button></div>
          </form>
        ) : null}
      </Modal>

      <Modal open={Boolean(adjustTarget)} onOpenChange={(open) => { if (!open && !working?.startsWith("adjust-")) setAdjustTarget(null); }} title="Adjust photo" description="The original stays untouched." size="default">
        {adjustTarget ? (
          <div className="artwork-panel__adjust">
            <div className="artwork-panel__adjust-preview"><ArtworkImage artwork={adjustTarget} /></div>
            <div className="artwork-panel__turn-buttons" role="group" aria-label="Rotate photo">
              <button type="button" className="button button--secondary" onClick={() => setAdjustment((current) => ({ ...current, rotation: (current.rotation + 270) % 360 }))}><RotateCcw aria-hidden="true" size={18} /> Turn left</button>
              <span>{adjustment.rotation}°</span>
              <button type="button" className="button button--secondary" onClick={() => setAdjustment((current) => ({ ...current, rotation: (current.rotation + 90) % 360 }))}><RotateCw aria-hidden="true" size={18} /> Turn right</button>
            </div>
            <label className="artwork-panel__check"><input type="checkbox" aria-label="Improve paper and lighting" checked={adjustment.enhanced} onChange={(event) => setAdjustment((current) => ({ ...current, enhanced: event.target.checked }))} /><span><strong>Improve paper and lighting</strong><small>Gently brightens the paper and evens out uneven light.</small></span></label>
            <button type="button" className="artwork-panel__reset" onClick={() => setAdjustment({ rotation: 0, enhanced: false })}>Reset to original</button>
            {actionError ? <p className="artwork-panel__form-error" role="alert">{actionError}</p> : null}
            <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === `adjust-${adjustTarget.id}`} onClick={() => setAdjustTarget(null)}>Cancel</button><button type="button" className="button button--primary" disabled={working === `adjust-${adjustTarget.id}`} onClick={() => void saveAdjustments()}>{working === `adjust-${adjustTarget.id}` ? "Applying…" : "Apply"}</button></div>
          </div>
        ) : null}
      </Modal>

      <ConfirmDialog
        open={Boolean(deleteTarget)}
        onOpenChange={(open) => !open && setDeleteTarget(null)}
        title="Remove this artwork?"
        description={`It will leave ${deleteTarget?.child_name ?? "the child's"} gallery. You can undo this afterwards.`}
        confirmLabel="Remove artwork"
        destructive
        busy={Boolean(deleteTarget && working === `delete-${deleteTarget.id}`)}
        onConfirm={() => void deleteArtwork()}
      />

      {undoArtwork ? (
        <div className="artwork-panel__undo" role="status">
          <span>Removed {undoArtwork.title || "artwork"}</span>
          <button type="button" disabled={working === `restore-${undoArtwork.id}`} onClick={() => void restoreArtwork()}><Undo2 aria-hidden="true" size={17} />{working === `restore-${undoArtwork.id}` ? "Restoring…" : "Undo"}</button>
          <button type="button" aria-label="Dismiss undo" onClick={() => setUndoArtwork(null)}><X aria-hidden="true" size={17} /></button>
        </div>
      ) : null}
    </section>
  );
}
