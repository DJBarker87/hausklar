import { Camera, ImagePlus, Minus, Plus } from "lucide-react";
import { useEffect, useId, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";

import { api, isOfflineQueuedResult } from "../api";
import type { FamilyMember } from "../types";
import { cn, Modal } from "./ui";

type Point = { x: number; y: number };
type CropSource = { element: HTMLImageElement; url: string; width: number; height: number };

export function personAvatarSource(avatarURL?: string | null): string | undefined {
  if (!avatarURL) return undefined;
  return avatarURL.startsWith("/") ? `/api${avatarURL}` : avatarURL;
}

export function PersonAvatar({ member, className }: { member: Pick<FamilyMember, "name" | "avatar_url">; className?: string }) {
  const source = personAvatarSource(member.avatar_url);
  const [failedSource, setFailedSource] = useState<string>();
  const initials = member.name.split(/\s+/).map((part) => part[0]).join("").slice(0, 2).toUpperCase();
  return (
    <span className={cn("person-avatar", className)} aria-hidden="true">
      {source && failedSource !== source
        ? <img src={source} alt="" onError={() => setFailedSource(source)} />
        : initials}
    </span>
  );
}

export function constrainCropOffset(
  point: Point,
  zoom: number,
  source: Pick<CropSource, "width" | "height">,
  stageSize: number,
): Point {
  const scale = Math.max(stageSize / source.width, stageSize / source.height) * zoom;
  const maxX = Math.max(0, (source.width * scale - stageSize) / 2);
  const maxY = Math.max(0, (source.height * scale - stageSize) / 2);
  return {
    x: maxX === 0 ? 0 : Math.max(-maxX, Math.min(maxX, point.x)),
    y: maxY === 0 ? 0 : Math.max(-maxY, Math.min(maxY, point.y)),
  };
}

async function loadCropSource(file: File): Promise<CropSource> {
  const url = URL.createObjectURL(file);
  try {
    const element = new Image();
    element.decoding = "async";
    await new Promise<void>((resolve, reject) => {
      element.onload = () => resolve();
      element.onerror = () => reject(new Error("That photo could not be opened in this browser."));
      element.src = url;
    });
    return { element, url, width: element.naturalWidth, height: element.naturalHeight };
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
}

async function renderCrop(source: CropSource, zoom: number, offset: Point, stageSize: number): Promise<Blob> {
  const canvas = document.createElement("canvas");
  canvas.width = 512;
  canvas.height = 512;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("This browser cannot prepare the photo.");
  const scale = Math.max(stageSize / source.width, stageSize / source.height) * zoom;
  const displayedWidth = source.width * scale;
  const displayedHeight = source.height * scale;
  const left = (stageSize - displayedWidth) / 2 + offset.x;
  const top = (stageSize - displayedHeight) / 2 + offset.y;
  const sourceSize = stageSize / scale;
  context.drawImage(
    source.element,
    -left / scale,
    -top / scale,
    sourceSize,
    sourceSize,
    0,
    0,
    512,
    512,
  );
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error("The crop could not be saved.")), "image/jpeg", 0.88);
  });
}

export function PersonAvatarEditor({
  member,
  open,
  onOpenChange,
  onSaved,
}: {
  member: FamilyMember;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: (member: FamilyMember) => void;
}) {
  const inputId = useId();
  const stageRef = useRef<HTMLButtonElement | null>(null);
  const dragRef = useRef<{ pointerId: number; start: Point; origin: Point } | undefined>(undefined);
  const [source, setSource] = useState<CropSource>();
  const [stageSize, setStageSize] = useState(300);
  const [zoom, setZoom] = useState(1);
  const [offset, setOffset] = useState<Point>({ x: 0, y: 0 });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  useEffect(() => () => { if (source) URL.revokeObjectURL(source.url); }, [source]);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const update = () => setStageSize(stage.getBoundingClientRect().width || 300);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(stage);
    return () => observer.disconnect();
  }, [source]);

  useEffect(() => {
    if (!open) {
      setSource(undefined);
      setZoom(1);
      setOffset({ x: 0, y: 0 });
      setError(undefined);
    }
  }, [open]);

  async function chooseFile(file?: File) {
    if (!file) return;
    setError(undefined);
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
      setError("Choose a JPEG, PNG, or WebP photo.");
      return;
    }
    if (file.size > 20 * 1024 * 1024) {
      setError("Choose a photo smaller than 20 MB.");
      return;
    }
    try {
      const next = await loadCropSource(file);
      setSource((current) => {
        if (current) URL.revokeObjectURL(current.url);
        return next;
      });
      setZoom(1);
      setOffset({ x: 0, y: 0 });
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "That photo could not be opened.");
    }
  }

  function changeZoom(value: number) {
    if (!source) return;
    setZoom(value);
    setOffset((current) => constrainCropOffset(current, value, source, stageSize));
  }

  function startDrag(event: PointerEvent<HTMLButtonElement>) {
    if (!source) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    dragRef.current = { pointerId: event.pointerId, start: { x: event.clientX, y: event.clientY }, origin: offset };
  }

  function moveDrag(event: PointerEvent<HTMLButtonElement>) {
    if (!source || dragRef.current?.pointerId !== event.pointerId) return;
    const next = {
      x: dragRef.current.origin.x + event.clientX - dragRef.current.start.x,
      y: dragRef.current.origin.y + event.clientY - dragRef.current.start.y,
    };
    setOffset(constrainCropOffset(next, zoom, source, stageSize));
  }

  function endDrag(event: PointerEvent<HTMLButtonElement>) {
    if (dragRef.current?.pointerId === event.pointerId) dragRef.current = undefined;
  }

  function moveWithKeyboard(event: KeyboardEvent<HTMLButtonElement>) {
    if (!source || !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    const step = event.shiftKey ? 12 : 4;
    const delta = {
      x: event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0,
      y: event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0,
    };
    setOffset((current) => constrainCropOffset({ x: current.x + delta.x, y: current.y + delta.y }, zoom, source, stageSize));
  }

  async function save() {
    if (!source) return;
    setBusy(true);
    setError(undefined);
    try {
      const crop = await renderCrop(source, zoom, offset, stageSize);
      const form = new FormData();
      form.append("file", crop, "avatar.jpg");
      const updated = await api<FamilyMember>(`/family/members/${member.id}/avatar`, {
        method: "PUT",
        body: form,
        timeoutMs: 45_000,
      });
      if (!isOfflineQueuedResult(updated)) onSaved(updated);
      onOpenChange(false);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "The profile photo could not be saved.");
    } finally {
      setBusy(false);
    }
  }

  const scale = source ? Math.max(stageSize / source.width, stageSize / source.height) * zoom : 1;
  return (
    <Modal
      open={open}
      onOpenChange={(next) => { if (!busy) onOpenChange(next); }}
      title={`Photo for ${member.name}`}
      description="Choose a photo, then move and zoom it until the circle looks right. Nothing changes until you save."
    >
      <div className="avatar-editor">
        {source ? (
          <>
            <button
              ref={stageRef}
              type="button"
              className="avatar-crop-stage"
              aria-label={`Reposition ${member.name}'s photo`}
              aria-describedby={`${inputId}-crop-help`}
              onPointerDown={startDrag}
              onPointerMove={moveDrag}
              onPointerUp={endDrag}
              onPointerCancel={endDrag}
              onKeyDown={moveWithKeyboard}
            >
              <img
                src={source.url}
                alt=""
                draggable="false"
                style={{
                  width: source.width * scale,
                  height: source.height * scale,
                  transform: `translate(calc(-50% + ${offset.x}px), calc(-50% + ${offset.y}px))`,
                }}
              />
            </button>
            <p className="field-help" id={`${inputId}-crop-help`}>Drag the photo or use the arrow keys to reposition it.</p>
            <div className="avatar-zoom-control">
              <Minus aria-hidden="true" size={18} />
              <label htmlFor={`${inputId}-zoom`}>Zoom</label>
              <input
                id={`${inputId}-zoom`}
                type="range"
                min="1"
                max="3"
                step="0.01"
                value={zoom}
                onChange={(event) => changeZoom(Number(event.target.value))}
              />
              <Plus aria-hidden="true" size={18} />
            </div>
          </>
        ) : (
          <div className="avatar-editor-empty">
            <PersonAvatar member={member} className="avatar-editor-current" />
            <p>{member.avatar_url ? "Choose a new photo to replace this one." : "Add a face or favourite photo for this person."}</p>
          </div>
        )}
        <input
          className="visually-hidden"
          id={inputId}
          type="file"
          accept="image/jpeg,image/png,image/webp"
          onChange={(event) => { void chooseFile(event.target.files?.[0]); event.target.value = ""; }}
        />
        <label className="button button--secondary avatar-file-label" htmlFor={inputId}>
          {source ? <Camera aria-hidden="true" size={18} /> : <ImagePlus aria-hidden="true" size={18} />}
          {source ? "Choose another photo" : "Choose a photo"}
        </label>
        {error ? <div className="form-error" role="alert">{error}</div> : null}
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" disabled={busy} onClick={() => onOpenChange(false)}>Cancel</button>
          <button type="button" className="button button--primary" disabled={!source || busy} aria-busy={busy} onClick={() => void save()}>
            {busy ? "Saving…" : "Save photo"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
