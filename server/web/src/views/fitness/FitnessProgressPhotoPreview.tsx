import { ImageOff, WifiOff } from "lucide-react";
import { useEffect, useState } from "react";

import { cn } from "../../components/ui";
import type { FitnessProgressPhoto, FitnessProgressPhotoPose } from "../../fitness/contract";
import { fitnessProgressPhotoLocalBlob, type FitnessPendingProgressPhoto } from "../../fitness/offlineStore";

export type FitnessProgressPhotoItem = {
  photo: FitnessProgressPhoto;
  local: FitnessPendingProgressPhoto | null;
};

export const fitnessProgressPhotoPoseLabels: Record<FitnessProgressPhotoPose, string> = {
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

function usePhotoSource(item: FitnessProgressPhotoItem, online: boolean): string | null {
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
  if (!online || item.photo.thumbnail_state !== "ready") return null;
  return `/api/fitness/progress-photos/${encodeURIComponent(item.photo.id)}/thumbnail`;
}

export function FitnessProgressPhotoPreview({ item, online, alt, className }: {
  item: FitnessProgressPhotoItem;
  online: boolean;
  alt: string;
  className?: string;
}) {
  const source = usePhotoSource(item, online);
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [source]);
  if (!source || failed) {
    return <div className={cn("fitness-measurements__photo-unavailable", className)} role="img" aria-label={alt}>
      {online ? <ImageOff aria-hidden="true" size={24} /> : <WifiOff aria-hidden="true" size={24} />}
      <strong>{online ? "Preview unavailable" : "Photo stored elsewhere"}</strong>
      <span>{online ? "The private thumbnail could not be loaded." : "Reconnect unless the original is saved on this device."}</span>
    </div>;
  }
  return <img className={className} src={source} width="640" height="800" alt={alt} loading="lazy" onError={() => setFailed(true)} />;
}
