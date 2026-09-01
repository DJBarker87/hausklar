import { BrainCircuit, LoaderCircle, ShieldCheck } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { api } from "../api";
import type { AIConsentStatus } from "../types";

export function useAIConsent(active = true) {
  const [status, setStatus] = useState<AIConsentStatus | null>(null);
  const [loading, setLoading] = useState(active);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!active) return;
    setLoading(true);
    setError(null);
    try {
      setStatus(await api<AIConsentStatus>("/auth/ai-consent"));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "AI privacy settings could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [active]);

  useEffect(() => { void reload(); }, [reload]);

  const grant = useCallback(async () => {
    if (!status || busy) return false;
    setBusy(true);
    setError(null);
    try {
      setStatus(await api<AIConsentStatus>("/auth/ai-consent", {
        method: "PUT",
        body: JSON.stringify({ accepted: true, version: status.version }),
      }));
      return true;
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Permission could not be saved.");
      return false;
    } finally {
      setBusy(false);
    }
  }, [busy, status]);

  const revoke = useCallback(async () => {
    if (busy) return false;
    setBusy(true);
    setError(null);
    try {
      setStatus(await api<AIConsentStatus>("/auth/ai-consent", { method: "DELETE" }));
      return true;
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Permission could not be withdrawn.");
      return false;
    } finally {
      setBusy(false);
    }
  }, [busy]);

  return { status, loading, busy, error, grant, revoke, reload };
}

export function AIConsentPrompt({
  status,
  busy,
  error,
  title = "Allow Bismarck to use OpenAI?",
  summary,
  assurances,
  onAllow,
  onDecline,
}: {
  status: AIConsentStatus;
  busy: boolean;
  error?: string | null;
  title?: string;
  summary?: string;
  assurances?: string[];
  onAllow: () => void;
  onDecline?: () => void;
}) {
  const visibleAssurances = assurances ?? [
    "Only runs when you deliberately choose an AI feature",
    "No unattended or nightly AI processing",
    "Withdraw permission at any time in Settings",
  ];
  return (
    <section className="ai-consent-card" aria-labelledby="ai-consent-heading">
      <div className="ai-consent-icon"><BrainCircuit aria-hidden="true" size={24} /></div>
      <div className="ai-consent-copy">
        <p className="page-eyebrow">Your choice</p>
        <h2 id="ai-consent-heading">{title}</h2>
        <p>{summary ?? status.disclosure}</p>
        <ul>
          {visibleAssurances.map((assurance) => <li key={assurance}><ShieldCheck aria-hidden="true" size={16} />{assurance}</li>)}
        </ul>
        {summary ? <details className="ai-consent-scope"><summary>What may be included</summary><p>{status.disclosure}</p></details> : null}
        <p className="ai-consent-legal"><a href="/privacy-policy" target="_blank" rel="noreferrer">Read the privacy policy</a></p>
        {error ? <div className="form-error" role="alert">{error}</div> : null}
        <div className="ai-consent-actions">
          {onDecline ? <button type="button" className="button button--secondary" disabled={busy} onClick={onDecline}>Not now</button> : null}
          <button type="button" className="button button--primary" disabled={busy} aria-busy={busy} onClick={onAllow}>
            {busy ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
            {busy ? "Saving…" : "Allow and continue"}
          </button>
        </div>
      </div>
    </section>
  );
}
