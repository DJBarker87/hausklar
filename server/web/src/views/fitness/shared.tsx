import { Check, LoaderCircle } from "lucide-react";
import {
  type FormEvent,
  type ReactNode,
  useCallback,
  useEffect,
  useState,
} from "react";

import { ApiError, api } from "../../api";
import { ErrorState, SkeletonList, cn } from "../../components/ui";
import {
  asFitnessArray,
  type FitnessEntityType,
  type FitnessProgressCharts,
} from "../../fitness/contract";
import {
  cacheFitnessProgressCharts,
  cacheFitnessRecords,
  cachedFitnessProgressCharts,
  cachedFitnessRecords,
  saveFitnessRecord,
  saveFitnessRecords,
  type SaveFitnessRecordInput,
  type SaveFitnessRecordOptions,
} from "../../fitness/offlineStore";

export type FitnessResource<T> = {
  data: T;
  loading: boolean;
  error: string | null;
  reload: () => void;
  fromCache: boolean;
};

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError || error instanceof Error) return error.message;
  return "Fitness data could not be loaded.";
}

export function localDateValue(date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export function localDateTimeValue(date = new Date()): string {
  return `${localDateValue(date)}T${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

export function utcFromLocalInput(value: string): string {
  return new Date(value).toISOString();
}

export function localTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

export function formatFitnessDate(value?: string | null): string {
  if (!value) return "Not set";
  const date = value.length === 10 ? new Date(`${value}T12:00:00`) : new Date(value);
  if (Number.isNaN(date.valueOf())) return value;
  return new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" }).format(date);
}

export function formatFitnessDateTime(value?: string | null): string {
  if (!value) return "Not set";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return value;
  return new Intl.DateTimeFormat(undefined, {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export function useFitnessCollection<T extends { id: string; revision?: number }>(
  path: string,
  entityType: FitnessEntityType,
  revision: number,
): FitnessResource<T[]> {
  const [data, setData] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [fromCache, setFromCache] = useState(false);
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    void (async () => {
      try {
        if (!navigator.onLine) throw new TypeError("Offline");
        const response = await api<T[] | { items?: T[]; results?: T[] }>(
          path,
          { signal: controller.signal },
          true,
          false,
        );
        const records = asFitnessArray(response);
        if (!cancelled) {
          setData(records);
          setFromCache(false);
        }
        void cacheFitnessRecords(entityType, records)
          .then(() => cachedFitnessRecords<T>(entityType))
          .then((withOptimisticRecords) => {
            if (!cancelled && (withOptimisticRecords.length || records.length === 0)) {
              setData(withOptimisticRecords);
            }
          })
          .catch(() => undefined);
      } catch (requestError) {
        if (controller.signal.aborted) return;
        const cached = await cachedFitnessRecords<T>(entityType).catch(() => []);
        if (!cancelled) {
          setData(cached);
          setFromCache(cached.length > 0);
          if (cached.length === 0 && navigator.onLine) setError(errorMessage(requestError));
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; controller.abort(); };
  }, [entityType, nonce, path, revision]);

  return { data, loading, error, reload, fromCache };
}

export function useFitnessEndpoint<T>(
  path: string,
  emptyValue: T,
  revision: number,
): FitnessResource<T> {
  const [data, setData] = useState<T>(emptyValue);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    if (!navigator.onLine) {
      setLoading(false);
      return () => { cancelled = true; controller.abort(); };
    }
    void api<T>(path, { signal: controller.signal }, true, false)
      .then((response) => { if (!cancelled) setData(response); })
      .catch((requestError) => { if (!cancelled) setError(errorMessage(requestError)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; controller.abort(); };
  }, [nonce, path, revision]);
  return { data, loading, error, reload, fromCache: false };
}

export function useFitnessProgressCharts(
  emptyValue: FitnessProgressCharts,
  revision: number,
): FitnessResource<FitnessProgressCharts> {
  const [data, setData] = useState(emptyValue);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [fromCache, setFromCache] = useState(false);
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    setLoading(true);
    setError(null);
    void (async () => {
      try {
        if (!navigator.onLine) throw new TypeError("Offline");
        const response = await api<FitnessProgressCharts>(
          "/fitness/progress/charts",
          { signal: controller.signal },
          true,
          false,
        );
        if (!cancelled) {
          setData(response);
          setFromCache(false);
        }
        void cacheFitnessProgressCharts(response).catch(() => undefined);
      } catch (requestError) {
        if (controller.signal.aborted) return;
        const cached = await cachedFitnessProgressCharts().catch(() => null);
        if (!cancelled) {
          if (cached) {
            setData(cached);
            setFromCache(true);
          } else if (navigator.onLine) {
            setError(errorMessage(requestError));
          }
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; controller.abort(); };
  }, [nonce, revision]);

  return { data, loading, error, reload, fromCache };
}

export function useFitnessCachedRecords<T extends { id: string }>(
  entityType: FitnessEntityType,
  revision: number,
): FitnessResource<T[]> {
  const [data, setData] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((value) => value + 1), []);
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    void cachedFitnessRecords<T>(entityType)
      .then((records) => { if (!cancelled) setData(records); })
      .catch((requestError) => { if (!cancelled) setError(errorMessage(requestError)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [entityType, nonce, revision]);
  return { data, loading, error, reload, fromCache: true };
}

export function useFitnessSave(onDataChanged: () => void) {
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const save = useCallback(async <T extends Record<string, unknown>>(
    entityType: FitnessEntityType,
    payload: T,
    options?: SaveFitnessRecordOptions,
  ) => {
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    try {
      const record = await saveFitnessRecord(entityType, payload, options);
      setSaved(true);
      onDataChanged();
      return record;
    } catch (error) {
      setSaveError(errorMessage(error));
      throw error;
    } finally {
      setSaving(false);
    }
  }, [onDataChanged]);

  return { save, saving, saveError, saved, clearSaveError: () => setSaveError(null) };
}

export function useFitnessBatchSave(onDataChanged: () => void) {
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const save = useCallback(async (inputs: SaveFitnessRecordInput[]) => {
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    try {
      const records = await saveFitnessRecords(inputs);
      setSaved(true);
      onDataChanged();
      return records;
    } catch (error) {
      setSaveError(errorMessage(error));
      throw error;
    } finally {
      setSaving(false);
    }
  }, [onDataChanged]);
  return { save, saving, saveError, saved };
}

export function FitnessPageHeading({
  title,
  detail,
  actions,
}: {
  title: string;
  detail: string;
  actions?: ReactNode;
}) {
  return (
    <header className="fitness-module__page-heading">
      <div><h2>{title}</h2><p>{detail}</p></div>
      {actions ? <div className="fitness-module__page-actions">{actions}</div> : null}
    </header>
  );
}

export function FitnessCard({
  title,
  detail,
  children,
  className,
}: {
  title?: string;
  detail?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("fitness-module__card", className)}>
      {title || detail ? <header>{title ? <h3>{title}</h3> : null}{detail ? <p>{detail}</p> : null}</header> : null}
      {children}
    </section>
  );
}

export function FitnessStat({ label, value, detail }: { label: string; value: ReactNode; detail?: string }) {
  return (
    <div className="fitness-module__stat">
      <span>{label}</span>
      <strong>{value}</strong>
      {detail ? <small>{detail}</small> : null}
    </div>
  );
}

export function FitnessFormStatus({
  saving,
  saved,
  error,
}: {
  saving: boolean;
  saved: boolean;
  error: string | null;
}) {
  if (saving) return <span className="fitness-module__form-status" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> Saving on this device…</span>;
  if (error) return <span className="fitness-module__form-status is-error" role="alert">{error}</span>;
  if (saved) return <span className="fitness-module__form-status is-saved" role="status"><Check aria-hidden="true" size={16} /> Saved</span>;
  return null;
}

export function FitnessLoadingOrError({
  loading,
  error,
  retry,
}: {
  loading: boolean;
  error: string | null;
  retry: () => void;
}) {
  if (loading) return <SkeletonList rows={4} />;
  if (error) return <ErrorState message={error} retry={retry} />;
  return null;
}

export function submitForm(handler: () => Promise<void>) {
  return (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    void handler();
  };
}
