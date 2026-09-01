import { AlertCircle, CheckCircle2, ChevronRight, ExternalLink, ReceiptText, RotateCcw } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, ApiError } from "../api";
import { getFinanceAdvancedStrings } from "../financeAdvancedStrings";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceEvidenceDetail,
  FinancePurchaseDecisionQuality,
  FinancePurchaseLineAssessment,
  FinancePurchaseOutcome,
  FinancePurchasePlannedness,
  FinancePurchaseReviewItem,
  FinancePurchaseUtility,
  FinancePurchaseValue,
  FinanceSpace,
} from "../types";
import { cn } from "../components/ui";

type ReviewLoadState = "loading" | "ready" | "error";
type AssessmentLoadState = "idle" | "loading" | "ready" | "error";

type ReviewForm = {
  normalizedItem: string;
  beneficiary: string;
  purpose: string;
  plannedness: FinancePurchasePlannedness | "";
  utility: FinancePurchaseUtility | "";
  decisionQuality: FinancePurchaseDecisionQuality | "";
  value: FinancePurchaseValue | "";
  outcome: FinancePurchaseOutcome | "";
  correctionReason: string;
};

const emptyForm: ReviewForm = {
  normalizedItem: "",
  beneficiary: "",
  purpose: "",
  plannedness: "",
  utility: "",
  decisionQuality: "",
  value: "",
  outcome: "",
  correctionReason: "",
};

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
  }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(`${value}T00:00:00`);
  return Number.isNaN(parsed.valueOf()) ? value : new Intl.DateTimeFormat(
    locale === "de" ? "de-DE" : "en-GB",
    { dateStyle: "medium" },
  ).format(parsed);
}

function formFromAssessment(value: FinancePurchaseLineAssessment | null): ReviewForm {
  if (!value) return emptyForm;
  return {
    normalizedItem: value.normalized_item_name ?? "",
    beneficiary: value.beneficiary ?? "",
    purpose: value.purpose ?? "",
    plannedness: value.plannedness ?? "",
    utility: value.utility ?? "",
    decisionQuality: value.decision_quality ?? "",
    value: value.value_for_money ?? "",
    outcome: value.outcome_state ?? "",
    correctionReason: "",
  };
}

function fallbackReviewItem(detail: FinanceEvidenceDetail, merchant: string): FinancePurchaseReviewItem {
  return {
    line_id: detail.record_id,
    purchase_id: "",
    space_id: detail.space_id,
    purchased_on: detail.occurred_on,
    merchant,
    source_description: detail.source_description,
    amount_minor: detail.amount_minor,
    currency: detail.currency,
    confidence_bps: 10_000,
    uncertain_fields: [],
    evidence_handle: detail.handle,
    deep_link: detail.deep_link,
    source_id: detail.source_evidence_id,
    match_status: "UNMATCHED",
    receipt_file_id: null,
  };
}

export function FinancePurchaseReviewView({
  spaces,
  locale,
  focusLineID = null,
  onFocusConsumed,
}: {
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  focusLineID?: string | null;
  onFocusConsumed?: () => void;
}) {
  const copy = getFinanceAdvancedStrings(locale).purchaseReview;
  const text = (english: string, german: string) => locale === "de" ? german : english;
  const [loadState, setLoadState] = useState<ReviewLoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [items, setItems] = useState<FinancePurchaseReviewItem[]>([]);
  const [selected, setSelected] = useState<FinancePurchaseReviewItem | null>(null);
  const [assessmentState, setAssessmentState] = useState<AssessmentLoadState>("idle");
  const [form, setForm] = useState<ReviewForm>(emptyForm);
  const [initialForm, setInitialForm] = useState<ReviewForm>(emptyForm);
  const [assessmentFound, setAssessmentFound] = useState(false);
  const [normalizedItemID, setNormalizedItemID] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState("");
  const [saveError, setSaveError] = useState("");
  const [search, setSearch] = useState("");
  const [visibleCount, setVisibleCount] = useState(10);
  const itemInputRef = useRef<HTMLInputElement>(null);
  const panelRef = useRef<HTMLElement>(null);
  const consumedFocusLineID = useRef<string | null>(null);
  const allowedSpaceIDs = useMemo(() => new Set(spaces.map((space) => space.id)), [spaces]);
  const selectionKey = spaces.map((space) => space.id).join(":");

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setLoadState("loading");
    setNotice("");
    setSaveError("");
    Promise.all(spaces.map((space) => api<FinancePurchaseReviewItem[]>(
      `/finance/purchases/review/high-impact?space_id=${encodeURIComponent(space.id)}&minimum_impact_minor=10000&limit=50`,
      { signal: controller.signal },
      true,
      false,
    )))
      .then(async (results) => {
        if (!active) return;
        const loaded = results.flat()
          .filter((item) => allowedSpaceIDs.has(item.space_id))
          .sort((left, right) => Math.abs(right.amount_minor) - Math.abs(left.amount_minor));
        let focus = focusLineID ? loaded.find((item) => item.line_id === focusLineID) ?? null : null;
        if (!focus && focusLineID) {
          try {
            const detail = await api<FinanceEvidenceDetail>(
              `/finance/analysis/evidence/purchase-line/${encodeURIComponent(focusLineID)}`,
              { signal: controller.signal },
              true,
              false,
            );
            if (active && allowedSpaceIDs.has(detail.space_id)) {
              focus = fallbackReviewItem(detail, copy.sourceText);
            }
          } catch (error) {
            if (isAbortError(error)) return;
          }
        }
        if (!active) return;
        setItems(loaded);
        setSelected(focus ?? loaded[0] ?? null);
        setLoadState("ready");
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setLoadState("error");
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectionKey, retryKey, focusLineID]);

  useEffect(() => {
    if (!focusLineID || selected?.line_id !== focusLineID || consumedFocusLineID.current === focusLineID) return;
    consumedFocusLineID.current = focusLineID;
    window.requestAnimationFrame(() => {
      panelRef.current?.scrollIntoView({ block: "start" });
      panelRef.current?.focus();
      onFocusConsumed?.();
    });
  }, [focusLineID, selected?.line_id, onFocusConsumed]);

  useEffect(() => {
    if (!selected) {
      setAssessmentState("idle");
      setForm(emptyForm);
      setInitialForm(emptyForm);
      setAssessmentFound(false);
      setNormalizedItemID(null);
      return;
    }
    const controller = new AbortController();
    let active = true;
    setAssessmentState("loading");
    setNotice("");
    setSaveError("");
    api<FinancePurchaseLineAssessment>(
      `/finance/purchase-lines/${encodeURIComponent(selected.line_id)}/assessment`,
      { signal: controller.signal },
      true,
      false,
    )
      .then((assessment) => {
        if (!active) return;
        if (assessment.line_id !== selected.line_id || assessment.space_id !== selected.space_id) {
          setAssessmentState("error");
          return;
        }
        setForm(formFromAssessment(assessment));
        setInitialForm(formFromAssessment(assessment));
        setAssessmentFound(true);
        setNormalizedItemID(assessment.normalized_item_id);
        setAssessmentState("ready");
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        if (error instanceof ApiError && error.status === 404) {
          setForm(emptyForm);
          setInitialForm(emptyForm);
          setAssessmentFound(false);
          setNormalizedItemID(null);
          setAssessmentState("ready");
        } else {
          setAssessmentState("error");
        }
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selected?.line_id]);

  function chooseItem(item: FinancePurchaseReviewItem) {
    setSelected(item);
    const url = new URL(window.location.href);
    url.searchParams.set("line", item.line_id);
    window.history.replaceState({}, "", url);
  }

  function finishItem(lineID: string) {
    const remaining = items.filter((item) => item.line_id !== lineID);
    setItems(remaining);
    setSelected(remaining[0] ?? null);
    const url = new URL(window.location.href);
    if (remaining[0]) url.searchParams.set("line", remaining[0].line_id);
    else url.searchParams.delete("line");
    window.history.replaceState({}, "", url);
  }

  const fieldIsUncertain = (field: string) => selected?.uncertain_fields.includes(field) ?? false;

  async function confirmReview(disposition: "CORRECT" | "NOT_RELEVANT") {
    if (!selected || saving || assessmentState !== "ready") return;
    setSaving(true);
    setSaveError("");
    setNotice("");
    try {
      const updated = await api<FinancePurchaseLineAssessment>(
        `/finance/purchase-lines/${encodeURIComponent(selected.line_id)}/assessment/confirm`,
        { method: "POST", body: JSON.stringify({ reviewed: true, disposition }) },
        true,
        false,
      );
      if (updated.line_id !== selected.line_id || updated.space_id !== selected.space_id) throw new Error(copy.saveError);
      setForm(formFromAssessment(updated));
      setInitialForm(formFromAssessment(updated));
      setAssessmentFound(true);
      finishItem(selected.line_id);
      setNotice(disposition === "NOT_RELEVANT" ? text("Marked not relevant.", "Als nicht relevant markiert.") : text("Checked and saved.", "Geprüft und gespeichert."));
    } catch {
      setSaveError(copy.saveError);
    } finally {
      setSaving(false);
    }
  }

  async function saveReview(event: FormEvent) {
    event.preventDefault();
    if (!selected || saving || assessmentState !== "ready") return;
    const classification = { ...form, correctionReason: "" };
    const initialClassification = { ...initialForm, correctionReason: "" };
    const meaningful = Object.values(classification).some((value) => value.trim().length > 0);
    const changed = JSON.stringify(classification) !== JSON.stringify(initialClassification);
    if (!meaningful || !changed) return;
    setSaving(true);
    setSaveError("");
    setNotice("");
    try {
      const updated = await api<FinancePurchaseLineAssessment>(
        `/finance/purchase-lines/${encodeURIComponent(selected.line_id)}/assessment`,
        {
          method: "PUT",
          body: JSON.stringify({
            normalized_item_name: form.normalizedItem.trim() || null,
            beneficiary: form.beneficiary.trim() || null,
            purpose: form.purpose.trim() || null,
            plannedness: form.plannedness || null,
            utility: form.utility || null,
            decision_quality: form.decisionQuality || null,
            value_for_money: form.value || null,
            outcome_state: form.outcome || null,
            correction_reason: form.correctionReason.trim() || null,
          }),
        },
        true,
        false,
      );
      if (updated.line_id !== selected.line_id || updated.space_id !== selected.space_id) throw new Error(copy.saveError);
      setForm(formFromAssessment(updated));
      setInitialForm(formFromAssessment(updated));
      setAssessmentFound(true);
      setNormalizedItemID(updated.normalized_item_id);
      if (updated.review_status === "CONFIRMED") {
        finishItem(selected.line_id);
        setNotice(copy.saved);
      } else {
        setSelected((current) => current ? { ...current, confidence_bps: updated.confidence_bps } : current);
        setNotice(copy.partialSaved);
      }
    } catch {
      setSaveError(copy.saveError);
    } finally {
      setSaving(false);
    }
  }

  const classification = { ...form, correctionReason: "" };
  const initialClassification = { ...initialForm, correctionReason: "" };
  const hasMeaningfulClassification = Object.values(classification).some((value) => value.trim().length > 0);
  const hasClassificationChange = JSON.stringify(classification) !== JSON.stringify(initialClassification);
  const reviewCanSave = assessmentState === "ready" && hasMeaningfulClassification && hasClassificationChange;
  const filteredItems = items.filter((item) => `${item.merchant} ${item.source_description}`.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase()));
  const visibleItems = filteredItems.slice(0, visibleCount);

  return (
    <section ref={panelRef} className="finance-review-panel" aria-labelledby="finance-review-title" tabIndex={-1}>
      <header>
        <div>
          <span className="finance-status-label"><ReceiptText aria-hidden="true" size={15} /> {copy.chooseLine}</span>
          <h2 id="finance-review-title">{copy.title}</h2>
          <p>{copy.detail}</p>
        </div>
      </header>

      {loadState === "loading" ? (
        <div className="finance-review-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>
      ) : loadState === "error" ? (
        <div className="finance-review-state is-error" role="alert">
          <AlertCircle aria-hidden="true" size={22} />
          <div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div>
          <button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}><RotateCcw aria-hidden="true" size={16} /> {copy.retry}</button>
        </div>
      ) : !selected ? (
        <div className="finance-review-state"><CheckCircle2 aria-hidden="true" size={24} /><div><strong>{copy.emptyTitle}</strong><p>{copy.emptyDetail}</p></div></div>
      ) : (
        <div className="finance-review-layout">
          {items.length > 1 ? (
            <nav className="finance-review-list" aria-label={copy.chooseLine}>
              <label className="field finance-review-search"><span>{text("Find a purchase", "Einkauf suchen")}</span><input type="search" value={search} onChange={(event) => { setSearch(event.target.value); setVisibleCount(10); }} /></label>
              {visibleItems.map((item) => (
                <button type="button" key={item.line_id} className={cn(item.line_id === selected.line_id && "is-active")} aria-current={item.line_id === selected.line_id ? "true" : undefined} onClick={() => chooseItem(item)}>
                  <span><strong>{item.merchant}</strong><small>{formatDate(item.purchased_on, locale)}</small></span>
                  <span>{formatCurrency(item.amount_minor, item.currency, locale)} <ChevronRight aria-hidden="true" size={17} /></span>
                </button>
              ))}
              {visibleCount < filteredItems.length ? <button type="button" className="button button--secondary" onClick={() => setVisibleCount((count) => count + 10)}>{text("Load 10 more", "10 weitere laden")}</button> : null}
            </nav>
          ) : null}

          <article className="finance-review-card">
            <header>
              <div><strong>{selected.merchant}</strong><time dateTime={selected.purchased_on}>{formatDate(selected.purchased_on, locale)}</time></div>
              <strong>{formatCurrency(selected.amount_minor, selected.currency, locale)}</strong>
            </header>
            <div className="finance-review-source"><span>{copy.sourceText}</span><blockquote>{selected.source_description}</blockquote></div>
            <dl className="finance-review-meta">
              <div><dt>{copy.impact}</dt><dd>{formatCurrency(selected.amount_minor, selected.currency, locale)}</dd></div>
              <div><dt>{copy.confidence}</dt><dd>{Math.round(selected.confidence_bps / 100)}%</dd></div>
              <div><dt>{copy.uncertain}</dt><dd>{selected.uncertain_fields.length ? selected.uncertain_fields.map((field) => copy.fieldNames[field as keyof typeof copy.fieldNames] ?? field).join(", ") : copy.notSet}</dd></div>
            </dl>

            <div className="finance-review-remedies" aria-label={text("What this purchase needs", "Was dieser Einkauf braucht")}>
              {selected.purchase_id && selected.match_status !== "MATCHED" ? <a className="button button--secondary" href={`/?view=finance&section=more&purchase=${encodeURIComponent(selected.purchase_id)}`}>{text("Match payment", "Zahlung zuordnen")}</a> : null}
              {selected.receipt_file_id ? <a className="button button--secondary" href={`/api/finance/purchases/evidence/${encodeURIComponent(selected.source_id)}/files/${encodeURIComponent(selected.receipt_file_id)}`} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={16} /> {text("Open receipt", "Beleg öffnen")}</a> : null}
              {fieldIsUncertain("normalized_item") ? <button type="button" className="button button--secondary" onClick={() => itemInputRef.current?.focus()}>{text("Describe items", "Artikel beschreiben")}</button> : null}
              <button type="button" className="button button--secondary" disabled={saving} onClick={() => void confirmReview("NOT_RELEVANT")}>{text("Not relevant", "Nicht relevant")}</button>
            </div>

            {assessmentState === "loading" ? (
              <div className="finance-review-form-skeleton" aria-busy="true" aria-label={copy.loading}><div /><div /><div /></div>
            ) : assessmentState === "error" ? (
              <div className="finance-review-state is-error" role="alert"><AlertCircle aria-hidden="true" size={20} /><p>{copy.loadAssessmentError}</p></div>
            ) : (
              <form className="finance-review-form" onSubmit={(event) => void saveReview(event)} aria-busy={saving}>
                <div className="finance-review-quick-actions">
                  <strong>{text("Quick check", "Schnell prüfen")}</strong>
                  <p>{text("Only the details HausKlar is unsure about are shown.", "Es werden nur Details angezeigt, bei denen HausKlar unsicher ist.")}</p>
                  <button type="button" className="button button--primary" disabled={saving} onClick={() => void confirmReview("CORRECT")}>{text("Looks right", "Sieht richtig aus")}</button>
                </div>
                <div className="finance-review-text-fields">
                  {fieldIsUncertain("normalized_item") ? <div className="field"><label htmlFor="finance-review-item">{copy.normalizedItem}</label><input ref={itemInputRef} id="finance-review-item" value={form.normalizedItem} maxLength={200} autoComplete="off" onChange={(event) => setForm((current) => ({ ...current, normalizedItem: event.target.value }))} /><div className="finance-review-chips"><button type="button" onClick={() => setForm((current) => ({ ...current, normalizedItem: selected.source_description }))}>{text("Use receipt wording", "Belegtext verwenden")}</button></div></div> : null}
                  {fieldIsUncertain("beneficiary") ? <div className="field"><label htmlFor="finance-review-beneficiary">{copy.beneficiary}</label><input id="finance-review-beneficiary" value={form.beneficiary} maxLength={120} autoComplete="off" onChange={(event) => setForm((current) => ({ ...current, beneficiary: event.target.value }))} /><div className="finance-review-chips"><button type="button" onClick={() => setForm((current) => ({ ...current, beneficiary: text("Family", "Familie") }))}>{text("Family", "Familie")}</button><button type="button" onClick={() => setForm((current) => ({ ...current, beneficiary: text("Me", "Ich") }))}>{text("Me", "Ich")}</button></div></div> : null}
                  {fieldIsUncertain("purpose") ? <div className="field"><label htmlFor="finance-review-purpose">{copy.purpose}</label><input id="finance-review-purpose" value={form.purpose} maxLength={200} autoComplete="off" onChange={(event) => setForm((current) => ({ ...current, purpose: event.target.value }))} /><div className="finance-review-chips"><button type="button" onClick={() => setForm((current) => ({ ...current, purpose: text("Quinn", "Lebensmittel") }))}>{text("Quinn", "Lebensmittel")}</button><button type="button" onClick={() => setForm((current) => ({ ...current, purpose: text("Home", "Zuhause") }))}>{text("Home", "Zuhause")}</button><button type="button" onClick={() => setForm((current) => ({ ...current, purpose: text("Children", "Kinder") }))}>{text("Children", "Kinder")}</button></div></div> : null}
                </div>
                <div className="finance-review-select-fields">
                  {fieldIsUncertain("plannedness") ? <div className="field"><label htmlFor="finance-review-plannedness">{copy.plannedness}</label><select id="finance-review-plannedness" value={form.plannedness} onChange={(event) => setForm((current) => ({ ...current, plannedness: event.target.value as ReviewForm["plannedness"] }))}><option value="">{copy.notSet}</option>{Object.entries(copy.plannednessValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div> : null}
                  {fieldIsUncertain("utility") ? <div className="field"><label htmlFor="finance-review-utility">{copy.utility}</label><select id="finance-review-utility" value={form.utility} onChange={(event) => setForm((current) => ({ ...current, utility: event.target.value as ReviewForm["utility"] }))}><option value="">{copy.notSet}</option>{Object.entries(copy.utilityValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div> : null}
                  {fieldIsUncertain("decision_quality") ? <div className="field"><label htmlFor="finance-review-decision">{copy.decisionQuality}</label><select id="finance-review-decision" value={form.decisionQuality} onChange={(event) => setForm((current) => ({ ...current, decisionQuality: event.target.value as ReviewForm["decisionQuality"] }))}><option value="">{copy.notSet}</option>{Object.entries(copy.decisionValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div> : null}
                  {fieldIsUncertain("value_for_money") ? <div className="field"><label htmlFor="finance-review-value">{copy.value}</label><select id="finance-review-value" value={form.value} onChange={(event) => setForm((current) => ({ ...current, value: event.target.value as ReviewForm["value"] }))}><option value="">{copy.notSet}</option>{Object.entries(copy.valueValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div> : null}
                  {fieldIsUncertain("outcome_state") ? <div className="field"><label htmlFor="finance-review-outcome">{copy.outcome}</label><select id="finance-review-outcome" value={form.outcome} onChange={(event) => setForm((current) => ({ ...current, outcome: event.target.value as ReviewForm["outcome"] }))}><option value="">{copy.notSet}</option>{Object.entries(copy.outcomeValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div> : null}
                </div>
                {hasClassificationChange ? <div className="field"><label htmlFor="finance-review-reason">{copy.correctionReason}</label><textarea id="finance-review-reason" rows={2} maxLength={500} value={form.correctionReason} onChange={(event) => setForm((current) => ({ ...current, correctionReason: event.target.value }))} /></div> : null}
                {form.outcome === "returned" ? <p className="finance-review-return-state">{text("Return sent; refund not yet seen. This will clear when the refund is matched.", "Rücksendung erfolgt; Erstattung noch nicht gesehen. Dies verschwindet, sobald die Erstattung zugeordnet ist.")}</p> : null}
                {saveError ? <p className="form-error" role="alert">{saveError}</p> : null}
                {!reviewCanSave ? <p className="finance-review-validation">{assessmentFound ? text("If it is already correct, choose Looks right.", "Wenn alles stimmt, wähle „Sieht richtig aus“.") : copy.validationNew}</p> : null}
                {normalizedItemID ? <a className="button button--secondary" href={`/?view=finance&section=assets&space=${encodeURIComponent(selected.space_id)}&item=${encodeURIComponent(normalizedItemID)}`}>{copy.priceHistory}</a> : null}
                {notice ? <p className="finance-review-success" role="status"><CheckCircle2 aria-hidden="true" size={17} /> {notice}</p> : null}
                <button type="submit" className="button button--primary" disabled={saving || !reviewCanSave}>{saving ? copy.saving : copy.save}</button>
              </form>
            )}
          </article>
        </div>
      )}
    </section>
  );
}
