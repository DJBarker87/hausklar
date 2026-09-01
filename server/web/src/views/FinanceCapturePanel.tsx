import { AlertCircle, BarChart3, CheckCircle2, FilePenLine, Send, ShieldCheck, Upload } from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";

import { api, ApiError, isOfflineQueuedResult } from "../api";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceAccount,
  FinanceCaptureConfirmResponse,
  FinanceCaptureDraft,
  FinanceCaptureInterpretResponse,
  FinanceCaptureTurn,
  FinanceCoachAnswer,
  FinancePurchaseEvidenceUploadResponse,
  FinanceSpace,
} from "../types";

export type FinanceCaptureContext = {
  screen: "coach" | "transactions" | "purchase" | "purchases" | "explore" | "plan" | "habits";
  selected_transaction_id: string | null;
  selected_purchase_id: string | null;
  selected_purchase_line_id: string | null;
  selected_account_id: string | null;
};

const defaultContext: FinanceCaptureContext = {
  screen: "coach",
  selected_transaction_id: null,
  selected_purchase_id: null,
  selected_purchase_line_id: null,
  selected_account_id: null,
};

const labels = {
  en: {
    title: "Ask or capture a Finance update",
    detail: "Ask a question, or describe a correction, cash spend, commitment, goal, habit or planned purchase. HausKlar shows a review card before changing anything.",
    finances: "Finances",
    text: "Question or statement",
    placeholder: "For example: I spent £18 cash at the market, or remember that school trips are protected.",
    interpret: "Check this",
    checking: "Checking…",
    noStorage: "This text and the short conversation are processed transiently by the server and are not retained. Only a card you confirm is saved.",
    clarify: "One more detail is needed",
    answer: "Answer from saved Finance records",
    review: "Review before saving",
    expires: "Card expires",
    target: "Saved record this belongs to",
    posting: "How to record this",
    account: "Account",
    choose: "Choose…",
    noTarget: "None of these — save as a standalone purchase",
    purchaseOnly: "Save purchase only (cash tender; no cashflow entry)",
    requiredTargetMissing: "No matching saved record was found. Open the relevant transaction or purchase item and try again.",
    noPostingAccount: "No eligible operating account in this currency is available. Add or update an account in Setup before saving this planned purchase.",
    openSetup: "Open Finance setup",
    confirm: "Confirm this card",
    confirming: "Saving…",
    confirmed: "Finance update saved.",
    error: "This Finance text could not be checked. Your text is still here.",
    confirmError: "This review card could not be saved. Check its fields and choices.",
    uncertainties: "Check these uncertainties",
    total: "Total",
    assigned: "Assigned to lines",
    remainder: "Unassigned remainder",
    balanced: "The total reconciles.",
    unbalanced: "Lines and remainder must equal the total.",
    lines: "Items or splits",
    addLine: "Add line",
    removeLine: "Remove line",
    category: "Saved category",
    none: "Not set",
    examples: "Try an example",
    openEvidence: "Open record",
    openAnalysis: "Open saved analysis",
    draftTitles: {
      FACT: "Review this Finance fact",
      PREFERENCE: "Review this preference",
      TRANSACTION_CORRECTION: "Review this payment correction",
      PURCHASE_DETAILS: "Review these purchase details",
      ITEM_OUTCOME: "Review this item outcome",
      CASH_SPEND: "Review this cash spend",
      COMMITMENT: "Review this commitment",
      GOAL: "Review this goal",
      HABIT: "Review this habit",
      PURCHASE_PLAN: "Review this planned purchase",
    },
    exampleStatements: [
      "I spent £18 cash at the market today.",
      "Synthetic public demo record 18s are protected spending.",
      "Remind me to wait before optional purchases over £40.",
    ],
  },
  de: {
    title: "Finanzfrage oder Änderung erfassen",
    detail: "Stelle eine Frage oder beschreibe eine Korrektur, Barausgabe, Verpflichtung, ein Ziel, eine Gewohnheit oder einen geplanten Einkauf. HausKlar zeigt vor jeder Änderung eine Prüfkarte.",
    finances: "Finanzen",
    text: "Frage oder Aussage",
    placeholder: "Zum Beispiel: Ich habe 18 € bar auf dem Markt ausgegeben, oder Schulausflüge sind geschützt.",
    interpret: "Prüfen",
    checking: "Wird geprüft…",
    noStorage: "Dieser Text und das kurze Gespräch werden vorübergehend auf dem Server verarbeitet und nicht aufbewahrt. Nur eine bestätigte Karte wird gespeichert.",
    clarify: "Eine weitere Angabe wird benötigt",
    answer: "Antwort aus gespeicherten Finanzdaten",
    review: "Vor dem Speichern prüfen",
    expires: "Karte läuft ab",
    target: "Zugehöriger gespeicherter Eintrag",
    posting: "So wird dies erfasst",
    account: "Konto",
    choose: "Auswählen…",
    noTarget: "Keiner davon — als eigenständigen Einkauf speichern",
    purchaseOnly: "Nur den Einkauf speichern (Barzahlung; kein Umsatz im Geldfluss)",
    requiredTargetMissing: "Kein passender gespeicherter Eintrag wurde gefunden. Öffne den betreffenden Umsatz oder Einkaufsartikel und versuche es erneut.",
    noPostingAccount: "Für diese Währung ist kein geeignetes laufendes Konto verfügbar. Füge vor dem Speichern dieses geplanten Einkaufs ein Konto in der Einrichtung hinzu oder passe es dort an.",
    openSetup: "Finanzeinrichtung öffnen",
    confirm: "Diese Karte bestätigen",
    confirming: "Wird gespeichert…",
    confirmed: "Finanzänderung gespeichert.",
    error: "Dieser Finanztext konnte nicht geprüft werden. Dein Text bleibt erhalten.",
    confirmError: "Diese Prüfkarte konnte nicht gespeichert werden. Prüfe Felder und Auswahl.",
    uncertainties: "Diese Unsicherheiten prüfen",
    total: "Gesamt",
    assigned: "Auf Zeilen verteilt",
    remainder: "Nicht zugeordneter Rest",
    balanced: "Die Summe stimmt.",
    unbalanced: "Zeilen und Rest müssen der Gesamtsumme entsprechen.",
    lines: "Artikel oder Aufteilungen",
    addLine: "Zeile hinzufügen",
    removeLine: "Zeile entfernen",
    category: "Gespeicherte Kategorie",
    none: "Nicht festgelegt",
    examples: "Beispiel verwenden",
    openEvidence: "Eintrag öffnen",
    openAnalysis: "Gespeicherte Auswertung öffnen",
    draftTitles: {
      FACT: "Diese Finanzangabe prüfen",
      PREFERENCE: "Diese Präferenz prüfen",
      TRANSACTION_CORRECTION: "Diese Zahlungskorrektur prüfen",
      PURCHASE_DETAILS: "Diese Einkaufsdetails prüfen",
      ITEM_OUTCOME: "Dieses Artikelergebnis prüfen",
      CASH_SPEND: "Diese Barausgabe prüfen",
      COMMITMENT: "Diese Verpflichtung prüfen",
      GOAL: "Dieses Ziel prüfen",
      HABIT: "Diese Gewohnheit prüfen",
      PURCHASE_PLAN: "Diesen geplanten Einkauf prüfen",
    },
    exampleStatements: [
      "Ich habe heute 18 € bar auf dem Markt ausgegeben.",
      "Schulausflüge sind geschützte Ausgaben.",
      "Erinnere mich vor optionalen Einkäufen über 40 € ans Warten.",
    ],
  },
} as const;

const uncertaintyTranslations: Record<string, string> = {
  "Check the spending date": "Ausgabedatum prüfen",
  "Select the matching payment and check the categories": "Passende Zahlung auswählen und Kategorien prüfen",
  "Select the matching payment and check the purchase date": "Passende Zahlung auswählen und Einkaufsdatum prüfen",
  "Check the exact due day": "Genauen Fälligkeitstag prüfen",
  "Amount is approximate": "Der Betrag ist ungefähr",
  "Check the exact deadline day": "Genauen Zieltermin prüfen",
  "Select the payment account and check the exact purchase date": "Zahlungskonto auswählen und genaues Einkaufsdatum prüfen",
  "Select the matching purchase item": "Passenden Einkaufsartikel auswählen",
  "Check when this starts": "Beginn prüfen",
  "Check that this should be saved as a Finance fact": "Prüfen, ob dies als Finanzangabe gespeichert werden soll",
  "Choose a saved category or leave the line uncategorised": "Gespeicherte Kategorie wählen oder die Zeile ohne Kategorie lassen",
};

const enumLabels: Record<string, { en: string; de: string }> = {
  PROTECTED: { en: "Protected", de: "Geschützt" },
  VALUED: { en: "Valued", de: "Geschätzt" },
  REGRETTED: { en: "Regretted", de: "Bereut" },
  NEGOTIABLE: { en: "Negotiable", de: "Verhandelbar" },
  NEUTRAL: { en: "Neutral", de: "Neutral" },
  IMPORTANT: { en: "Important", de: "Wichtig" },
  OPTIONAL: { en: "Optional", de: "Optional" },
  EXACT: { en: "Exact", de: "Genau" },
  FORECAST: { en: "Forecast", de: "Prognose" },
  ONE_OFF: { en: "One-off", de: "Einmalig" },
  MONTHLY: { en: "Monthly", de: "Monatlich" },
  ANNUAL: { en: "Annual", de: "Jährlich" },
  TERMLY: { en: "Each school term", de: "Je Schultrimester" },
  CUSTOM: { en: "Custom", de: "Benutzerdefiniert" },
  PRIMARY: { en: "Main habit", de: "Hauptgewohnheit" },
  SECONDARY: { en: "Supporting habit", de: "Unterstützende Gewohnheit" },
  valued: { en: "Valued", de: "Geschätzt" },
  neutral: { en: "Neutral", de: "Neutral" },
  regretted: { en: "Regretted", de: "Bereut" },
  returned: { en: "Returned", de: "Zurückgegeben" },
  unused: { en: "Unused", de: "Ungenutzt" },
  unknown: { en: "Unknown", de: "Unbekannt" },
  essential: { en: "Essential", de: "Notwendig" },
  useful: { en: "Useful", de: "Nützlich" },
  optional: { en: "Optional", de: "Optional" },
  unclear: { en: "Unclear", de: "Unklar" },
  AUTOMATIC: { en: "Paid automatically", de: "Automatisch bezahlt" },
  MANUAL: { en: "I need to pay it", de: "Ich muss es bezahlen" },
  RENEWAL: { en: "Review or renew it", de: "Prüfen oder verlängern" },
};

const enumChoices: Record<string, string[]> = {
  value_kind: ["PROTECTED", "VALUED", "REGRETTED", "NEGOTIABLE", "NEUTRAL"],
  outcome_state: ["valued", "neutral", "regretted", "returned", "unused", "unknown"],
  amount_mode: ["EXACT", "FORECAST"],
  recurrence: ["ONE_OFF", "MONTHLY", "ANNUAL", "TERMLY", "CUSTOM"],
  priority: ["PROTECTED", "IMPORTANT", "OPTIONAL"],
  slot: ["PRIMARY", "SECONDARY"],
  utility: ["essential", "useful", "optional", "unclear"],
  payment_handling: ["AUTOMATIC", "MANUAL", "RENEWAL"],
};

const scalarKeys: Record<string, string[]> = {
  FACT: ["statement"],
  PREFERENCE: ["statement", "value_kind"],
  TRANSACTION_CORRECTION: ["payment_amount_minor", "transaction_date", "currency"],
  PURCHASE_DETAILS: ["merchant", "payment_amount_minor", "purchased_on", "currency"],
  ITEM_OUTCOME: ["outcome_state", "correction_reason"],
  CASH_SPEND: ["merchant", "spent_on", "total_minor", "currency"],
  COMMITMENT: ["name", "amount_mode", "exact_minor", "expected_minor", "currency", "recurrence", "reviewed_date", "priority"],
  GOAL: ["name", "target_minor", "deadline", "currency", "priority"],
  HABIT: ["slot", "name", "trigger", "minimum_line_minor", "start_date", "review_date", "fallback"],
  PURCHASE_PLAN: ["name", "amount_low_minor", "amount_high_minor", "desired_date", "currency", "recurrence", "purpose", "beneficiary"],
};

function humanField(key: string, locale: FinanceLocale) {
  const known: Record<string, [string, string]> = {
    statement: ["Statement", "Aussage"], merchant: ["Merchant", "Händler"], name: ["Name", "Name"], payment_amount_minor: ["Payment amount", "Zahlungsbetrag"], total_minor: ["Total", "Gesamt"], exact_minor: ["Exact amount", "Genauer Betrag"], expected_minor: ["Expected amount", "Erwarteter Betrag"], target_minor: ["Target amount", "Zielbetrag"], amount_low_minor: ["Amount from", "Betrag von"], amount_high_minor: ["Amount to", "Betrag bis"], minimum_line_minor: ["Minimum item amount", "Mindestbetrag pro Artikel"], transaction_date: ["Transaction date", "Umsatzdatum"], purchased_on: ["Purchase date", "Kaufdatum"], spent_on: ["Spend date", "Ausgabedatum"], reviewed_date: ["Due date", "Fälligkeitsdatum"], deadline: ["Deadline", "Frist"], desired_date: ["Wanted date", "Gewünschtes Datum"], start_date: ["Start date", "Startdatum"], review_date: ["Review date", "Prüfdatum"], currency: ["Currency", "Währung"], purpose: ["Purpose", "Zweck"], beneficiary: ["Who it is for", "Für wen"], normalized_item: ["Normalised item", "Normalisierter Artikel"], trigger: ["Trigger", "Auslöser"], fallback: ["Fallback", "Ausweichlösung"], correction_reason: ["Reason for correction", "Grund der Korrektur"], amount_mode: ["Amount type", "Betragsart"], recurrence: ["Repeats", "Wiederholung"], priority: ["Priority", "Priorität"], slot: ["Habit position", "Position der Gewohnheit"], value_kind: ["Value", "Bedeutung"], outcome_state: ["Outcome", "Ergebnis"], purposes: ["Purposes", "Zwecke"], utilities: ["Usefulness", "Nutzen"], utility: ["Usefulness", "Nutzen"],
  };
  return known[key]?.[locale === "de" ? 1 : 0] ?? key.replaceAll("_", " ");
}

function minorInput(value: number) {
  const sign = value < 0 ? "-" : "";
  const absolute = Math.abs(value);
  return `${sign}${Math.floor(absolute / 100)}.${String(absolute % 100).padStart(2, "0")}`;
}

function parseMinor(value: string) {
  const match = /^(-?)(0|[1-9]\d*)(?:[.,](\d{1,2}))?$/.exec(value.trim());
  if (!match) return null;
  const sign = match[1] === "-" ? -1n : 1n;
  const minor = sign * (BigInt(match[2]) * 100n + BigInt((match[3] ?? "").padEnd(2, "0") || "0"));
  if (minor > BigInt(Number.MAX_SAFE_INTEGER) || minor < BigInt(Number.MIN_SAFE_INTEGER)) return null;
  return Number(minor);
}

function money(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "currency", currency }).format(minor / 100);
}

function evidenceHref(evidenceID: string, household: boolean) {
  const [kind, id] = evidenceID.split(":", 2);
  const scope = household ? "&scope=household" : "";
  if (kind === "transaction" && id) return `/?view=finance&section=activity${scope}&transaction=${encodeURIComponent(id)}`;
  if (kind === "purchase-line" && id) return `/?view=finance&section=more${scope}&line=${encodeURIComponent(id)}`;
  return null;
}

function CaptureAnswer({ answer, locale, household }: { answer: FinanceCoachAnswer; locale: FinanceLocale; household: boolean }) {
  const copy = labels[locale];
  return <article className="finance-capture-answer"><span>{copy.answer}</span><h4>{answer.headline}</h4><p>{answer.answer}</p>{answer.claims.length ? <ul>{answer.claims.map((claim, claimIndex) => <li key={`${claimIndex}-${claim.text}`}><span>{claim.text}</span>{claim.evidence_ids.length ? <div className="finance-evidence-links">{claim.evidence_ids.map((evidenceID, evidenceIndex) => { const href = evidenceHref(evidenceID, household); const kind = evidenceID.split(":", 1)[0]; const label = kind === "transaction" ? (locale === "de" ? `Bankeintrag ${evidenceIndex + 1}` : `Bank entry ${evidenceIndex + 1}`) : kind === "purchase-line" ? (locale === "de" ? `Belegartikel ${evidenceIndex + 1}` : `Receipt item ${evidenceIndex + 1}`) : (locale === "de" ? `Gespeicherter Eintrag ${evidenceIndex + 1}` : `Saved record ${evidenceIndex + 1}`); return href ? <a href={href} key={evidenceID}><span>{label}</span><span>{copy.openEvidence}</span></a> : <span key={evidenceID}>{label}</span>; })}</div> : null}</li>)}</ul> : null}{answer.analysis_view_id ? <a className="button button--secondary" href={`/?view=finance&section=explore${household ? "&scope=household" : ""}&analysis=${encodeURIComponent(answer.analysis_view_id)}`}><BarChart3 aria-hidden="true" size={16} /> {copy.openAnalysis}</a> : null}</article>;
}

function CaptureDraftCard({ draft, accounts, context, locale, household, busy, onConfirm }: { draft: FinanceCaptureDraft; accounts: FinanceAccount[]; context: FinanceCaptureContext; locale: FinanceLocale; household: boolean; busy: boolean; onConfirm: (draft: FinanceCaptureDraft, content: FinanceCaptureDraft["content"], targetID: string | null, accountID: string | null) => void }) {
  const copy = labels[locale];
  const [content, setContent] = useState(() => structuredClone(draft.content));
  const kind = String(content.kind);
  const lineKey: "lines" | "splits" | null = Array.isArray(content.lines) ? "lines" : Array.isArray(content.splits) ? "splits" : null;
  const lines = lineKey ? content[lineKey] as Array<Record<string, unknown>> : [];
  const totalKey = typeof content.payment_amount_minor === "number" ? "payment_amount_minor" : typeof content.total_minor === "number" ? "total_minor" : null;
  const total = totalKey ? content[totalKey] as number : null;
  const assigned = lines.reduce((sum, line) => sum + (typeof line.amount_minor === "number" ? line.amount_minor : 0), 0);
  const remainder = typeof content.unassigned_remainder_minor === "number" ? content.unassigned_remainder_minor : 0;
  const reconciles = total === null || assigned + remainder === total;
  const currency = typeof content.currency === "string" ? content.currency : "";
  const targetRequired = kind === "TRANSACTION_CORRECTION" || kind === "ITEM_OUTCOME";
  const targetOptions = draft.target_options.filter((option) => ["TRANSACTION", "PURCHASE", "PURCHASE_LINE"].includes(option.kind));
  const adultOptions = draft.target_options.filter((option) => option.kind === "ADULT");
  const postingOptions = draft.target_options.filter((option) => option.kind === "ACCOUNT" || kind === "CASH_SPEND" && option.kind === "PURCHASE_ONLY");
  const postingRequired = kind === "CASH_SPEND" || kind === "PURCHASE_PLAN";
  const contextualTargetID = [context.selected_purchase_line_id, context.selected_purchase_id, context.selected_transaction_id].find((id) => id && targetOptions.some((option) => option.id === id)) ?? "";
  const contextualPostingID = context.selected_account_id && postingOptions.some((option) => option.id === context.selected_account_id)
    ? context.selected_account_id
    : kind === "CASH_SPEND" && postingOptions.length === 1 && postingOptions[0].kind === "PURCHASE_ONLY" ? postingOptions[0].id : "";
  const [targetID, setTargetID] = useState(contextualTargetID);
  const [postingID, setPostingID] = useState(contextualPostingID);
  const selectedPosting = postingOptions.find((option) => option.id === postingID) ?? null;
  const currencyOptions = [...new Set([currency, ...accounts.filter((account) => account.space_id === draft.space_id).map((account) => account.currency)].filter(Boolean))];
  const allowedScalarKeys = new Set((scalarKeys[kind] ?? []).filter((key) => kind !== "COMMITMENT" || key !== "exact_minor" && key !== "expected_minor" || content.amount_mode === "EXACT" && key === "exact_minor" || content.amount_mode === "FORECAST" && key === "expected_minor"));
  const scalarEntries = Object.entries(content).filter(([key, value]) => allowedScalarKeys.has(key) && !Array.isArray(value));
  const lineFields = kind === "TRANSACTION_CORRECTION"
    ? ["name", "amount_minor", "category_name"]
    : kind === "PURCHASE_DETAILS" || kind === "CASH_SPEND"
      ? ["name", "amount_minor", "purpose", "beneficiary", "normalized_item", "utility", "outcome_state"]
      : [];
  const responsibleAdultID = typeof content.responsible_user_id === "string" ? content.responsible_user_id : "";
  const commitmentInvalid = kind === "COMMITMENT" && (
    content.payment_handling === "UNSPECIFIED"
    || !content.payment_handling
    || Boolean(content.show_in_tasks) && !responsibleAdultID
  );

  function update(key: string, value: unknown) {
    setContent((current) => ({ ...current, [key]: value }));
  }

  function updateLine(index: number, key: string, value: unknown) {
    if (!lineKey) return;
    const selectedLineKey = lineKey;
    setContent((current) => ({ ...current, [selectedLineKey]: (current[selectedLineKey] as Array<Record<string, unknown>>).map((line, lineIndex) => lineIndex === index ? { ...line, [key]: value } : line) }));
  }

  function addLine() {
    if (!lineKey) return;
    const selectedLineKey = lineKey;
    const empty = kind === "TRANSACTION_CORRECTION"
      ? { name: "", amount_minor: 0, category_name: null }
      : { name: "", amount_minor: 0, category_name: null, purpose: null, beneficiary: null, normalized_item: null, utility: null, outcome_state: null };
    setContent((current) => ({ ...current, [selectedLineKey]: [...(current[selectedLineKey] as unknown[]), empty] }));
  }

  function removeLine(index: number) {
    if (!lineKey) return;
    const selectedLineKey = lineKey;
    setContent((current) => ({ ...current, [selectedLineKey]: (current[selectedLineKey] as unknown[]).filter((_, lineIndex) => lineIndex !== index) }));
  }

  function confirm() {
    const accountID = selectedPosting?.kind === "ACCOUNT" ? selectedPosting.id : null;
    const selectedTargetID = selectedPosting?.kind === "PURCHASE_ONLY" ? selectedPosting.id : targetID || null;
    const reviewedContent = kind === "COMMITMENT" && !household
      ? { ...content, show_in_calendar: false, show_in_tasks: false, responsible_user_id: null }
      : content;
    onConfirm(draft, reviewedContent, selectedTargetID, accountID);
  }

  const translatedUncertainties = (content.uncertainties ?? []).map((uncertainty) => locale === "de" ? uncertaintyTranslations[uncertainty] ?? uncertainty : uncertainty);
  const title = copy.draftTitles[kind as keyof typeof copy.draftTitles] ?? draft.title;
  return <article className="finance-capture-card">
    <header><div><span>{copy.review}</span><h4>{title}</h4></div><small>{copy.expires}: {new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", { dateStyle: "short", timeStyle: "short" }).format(new Date(draft.expires_at))}</small></header>
    {translatedUncertainties.length ? <div className="finance-capture-uncertainties"><strong>{copy.uncertainties}</strong><ul>{translatedUncertainties.map((uncertainty) => <li key={uncertainty}>{uncertainty}</li>)}</ul></div> : null}
    <div className="finance-capture-fields">{scalarEntries.map(([key, value]) => {
      const choices = enumChoices[key]?.filter((choice) => key !== "recurrence" || kind === "COMMITMENT" || choice !== "TERMLY" && choice !== "CUSTOM");
      if (choices) return <div className="field" key={key}><label htmlFor={`${draft.id}-${key}`}>{humanField(key, locale)}</label><select id={`${draft.id}-${key}`} value={String(value ?? "")} onChange={(event) => update(key, event.target.value)}>{choices.map((choice) => <option value={choice} key={choice}>{enumLabels[choice]?.[locale] ?? choice}</option>)}</select></div>;
      if (key === "currency") return <div className="field" key={key}><label htmlFor={`${draft.id}-${key}`}>{humanField(key, locale)}</label><select id={`${draft.id}-${key}`} value={String(value ?? "")} onChange={(event) => update(key, event.target.value)}>{currencyOptions.map((choice) => <option value={choice} key={choice}>{choice}</option>)}</select></div>;
      const isMinor = key.endsWith("_minor");
      const isDate = key.endsWith("_date") || key.endsWith("_on") || key === "deadline";
      return <div className="field" key={key}><label htmlFor={`${draft.id}-${key}`}>{humanField(key, locale)}</label><input id={`${draft.id}-${key}`} type={isDate ? "date" : "text"} inputMode={isMinor ? "decimal" : undefined} autoComplete="off" value={isMinor && typeof value === "number" ? minorInput(value) : String(value ?? "")} onChange={(event) => update(key, isMinor ? parseMinor(event.target.value) ?? value : event.target.value || null)} /></div>;
    })}{Object.entries(content).filter(([key, value]) => ["purposes", "utilities"].includes(key) && Array.isArray(value)).map(([key, value]) => <div className="field" key={key}><label htmlFor={`${draft.id}-${key}`}>{humanField(key, locale)}</label><input id={`${draft.id}-${key}`} autoComplete="off" value={(value as string[]).join(", ")} onChange={(event) => update(key, event.target.value.split(",").map((item) => item.trim()).filter(Boolean))} /></div>)}</div>
    {kind === "COMMITMENT" ? <section className="finance-capture-reminders" aria-labelledby={`${draft.id}-reminders-title`}>
      <div><h5 id={`${draft.id}-reminders-title`}>{locale === "de" ? "Erinnerungen" : "Reminders"}</h5><p>{locale === "de" ? "Lege fest, wie die Zahlung erledigt und wer bei Bedarf erinnert wird." : "Choose how the payment is handled and who needs a reminder."}</p></div>
      <div className="field"><label htmlFor={`${draft.id}-payment-handling`}>{locale === "de" ? "Wie wird es bezahlt?" : "How is it paid?"}</label><select id={`${draft.id}-payment-handling`} value={String(content.payment_handling ?? "UNSPECIFIED")} onChange={(event) => update("payment_handling", event.target.value)}>{content.payment_handling === "UNSPECIFIED" || !content.payment_handling ? <option value="UNSPECIFIED" disabled>{copy.choose}</option> : null}{enumChoices.payment_handling.map((choice) => <option value={choice} key={choice}>{enumLabels[choice][locale]}</option>)}</select></div>
      {household ? <>
        <label className="finance-capture-reminder-choice"><input type="checkbox" checked={Boolean(content.show_in_calendar)} onChange={(event) => update("show_in_calendar", event.target.checked)} /> <span><strong>{locale === "de" ? "Im Familienkalender anzeigen" : "Show in the family Calendar"}</strong><small>{locale === "de" ? "Verwendet das oben geprüfte Fälligkeitsdatum." : "Uses the due date checked above."}</small></span></label>
        <div className="field"><label htmlFor={`${draft.id}-responsible-adult`}>{locale === "de" ? "Verantwortliche Person (optional)" : "Responsible adult (optional)"}</label><select id={`${draft.id}-responsible-adult`} value={responsibleAdultID} onChange={(event) => { const adultID = event.target.value || null; setContent((current) => ({ ...current, responsible_user_id: adultID, show_in_tasks: adultID ? current.show_in_tasks : false })); }}><option value="">{locale === "de" ? "Niemand – keine Aufgabe" : "No one — no task"}</option>{adultOptions.map((adult) => <option key={adult.id} value={adult.id}>{adult.label}</option>)}</select></div>
        <label className="finance-capture-reminder-choice"><input type="checkbox" checked={Boolean(content.show_in_tasks)} disabled={!responsibleAdultID} onChange={(event) => update("show_in_tasks", event.target.checked)} /> <span><strong>{locale === "de" ? "Auch eine Aufgabe erstellen" : "Create a task too"}</strong><small>{responsibleAdultID ? (locale === "de" ? "Die ausgewählte Person erhält die Aufgabe." : "The selected adult will get the task.") : (locale === "de" ? "Wähle zuerst eine verantwortliche Person." : "Choose a responsible adult first.")}</small></span></label>
      </> : <p className="finance-capture-private-note"><ShieldCheck aria-hidden="true" size={16} /> {locale === "de" ? "Private Verpflichtungen bleiben nur in Finanzen und erscheinen nicht im Kalender oder in Aufgaben." : "Personal commitments stay in Finance and do not appear in Calendar or Tasks."}</p>}
    </section> : null}
    {lineKey && lineFields.length ? <section className="finance-capture-lines"><header><h5>{copy.lines}</h5></header>{lines.map((line, index) => <fieldset key={index}>{lineFields.map((key) => {
      if (key === "category_name") return <div className="field" key={key}><label htmlFor={`${draft.id}-line-category-${index}`}>{copy.category}</label><select id={`${draft.id}-line-category-${index}`} value={String(line.category_name ?? "")} onChange={(event) => updateLine(index, "category_name", event.target.value || null)}><option value="">{copy.none}</option>{draft.category_options.map((category) => <option value={category} key={category}>{category}</option>)}</select></div>;
      if (key === "utility" || key === "outcome_state") return <div className="field" key={key}><label htmlFor={`${draft.id}-line-${key}-${index}`}>{humanField(key, locale)}</label><select id={`${draft.id}-line-${key}-${index}`} value={String(line[key] ?? "")} onChange={(event) => updateLine(index, key, event.target.value || null)}><option value="">{copy.none}</option>{(enumChoices[key] ?? []).map((choice) => <option value={choice} key={choice}>{enumLabels[choice]?.[locale] ?? choice}</option>)}</select></div>;
      const isMinor = key === "amount_minor";
      return <div className="field" key={key}><label htmlFor={`${draft.id}-line-${key}-${index}`}>{humanField(isMinor ? "payment_amount_minor" : key, locale)}</label><input id={`${draft.id}-line-${key}-${index}`} inputMode={isMinor ? "decimal" : undefined} value={isMinor ? minorInput(Number(line[key] ?? 0)) : String(line[key] ?? "")} onChange={(event) => { const value = isMinor ? parseMinor(event.target.value) : event.target.value || null; if (value !== null) updateLine(index, key, value); }} /></div>;
    })}<button type="button" className="button button--secondary" disabled={lines.length === 1} onClick={() => removeLine(index)}>{copy.removeLine}</button></fieldset>)}<button type="button" className="button button--secondary" onClick={addLine}>{copy.addLine}</button>{total !== null ? <div className={`finance-capture-reconciliation ${reconciles ? "is-balanced" : "is-unbalanced"}`}><dl><div><dt>{copy.total}</dt><dd>{currency ? money(total, currency, locale) : minorInput(total)}</dd></div><div><dt>{copy.assigned}</dt><dd>{currency ? money(assigned, currency, locale) : minorInput(assigned)}</dd></div><div><dt>{copy.remainder}</dt><dd><input aria-label={copy.remainder} inputMode="decimal" value={minorInput(remainder)} onChange={(event) => { const value = parseMinor(event.target.value); if (value !== null) update("unassigned_remainder_minor", value); }} /></dd></div></dl><strong>{reconciles ? copy.balanced : copy.unbalanced}</strong></div> : null}</section> : null}
    {kind === "PURCHASE_DETAILS" || targetOptions.length ? <div className="field"><label htmlFor={`${draft.id}-target`}>{copy.target}</label><select id={`${draft.id}-target`} value={targetID} onChange={(event) => setTargetID(event.target.value)}><option value="">{kind === "PURCHASE_DETAILS" ? copy.noTarget : copy.choose}</option>{targetOptions.map((option) => <option value={option.id} key={option.id}>{option.label}{option.amount_minor !== null && option.currency ? ` · ${money(option.amount_minor, option.currency, locale)}` : ""}</option>)}</select></div> : null}
    {targetRequired && !targetOptions.length ? <p className="form-error" role="alert">{copy.requiredTargetMissing}</p> : null}
    {postingRequired ? <div className="field"><label htmlFor={`${draft.id}-posting`}>{kind === "CASH_SPEND" ? copy.posting : copy.account}</label><select id={`${draft.id}-posting`} value={postingID} onChange={(event) => setPostingID(event.target.value)}><option value="">{copy.choose}</option>{postingOptions.map((option) => <option value={option.id} key={option.id}>{option.kind === "PURCHASE_ONLY" ? copy.purchaseOnly : option.label}{option.amount_minor !== null && option.currency ? ` · ${money(option.amount_minor, option.currency, locale)}` : ""}</option>)}</select></div> : null}
    {kind === "PURCHASE_PLAN" && !postingOptions.length ? <div className="finance-capture-missing-account"><p className="form-error" role="alert">{copy.noPostingAccount}</p><a className="button button--secondary" href={`/?view=finance&section=setup${household ? "&scope=household" : ""}`}>{copy.openSetup}</a></div> : null}
    <button type="button" className="button button--primary" disabled={busy || !reconciles || targetRequired && !targetID || postingRequired && !postingID || commitmentInvalid} onClick={confirm}>{busy ? copy.confirming : copy.confirm}</button>
  </article>;
}

export function FinanceCapturePanel({ spaces, accounts, locale, conversation, context = defaultContext }: { spaces: FinanceSpace[]; accounts: FinanceAccount[]; locale: FinanceLocale; conversation: FinanceCaptureTurn[]; context?: FinanceCaptureContext }) {
  const copy = labels[locale];
  const [spaceID, setSpaceID] = useState(spaces[0]?.id ?? "");
  const [text, setText] = useState("");
  const [checking, setChecking] = useState(false);
  const [response, setResponse] = useState<FinanceCaptureInterpretResponse | null>(null);
  const [confirmingID, setConfirmingID] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [privateFile, setPrivateFile] = useState<File | null>(null);
  const [privateTitle, setPrivateTitle] = useState("");
  const [uploading, setUploading] = useState(false);
  const allowedIDs = useMemo(() => new Set(spaces.map((space) => space.id)), [spaces]);
  const selectedSpaceID = allowedIDs.has(spaceID) ? spaceID : spaces[0]?.id ?? "";
  const selectedSpace = spaces.find((space) => space.id === selectedSpaceID) ?? null;
  const privateSpace = spaces.find((space) => space.kind === "personal") ?? null;
  const contextKey = `${context.screen}:${context.selected_transaction_id ?? ""}:${context.selected_purchase_id ?? ""}:${context.selected_purchase_line_id ?? ""}:${context.selected_account_id ?? ""}`;
  const idPrefix = `finance-capture-${contextKey.replace(/[^a-z0-9]+/gi, "-")}`;

  useEffect(() => {
    setResponse(null);
    setText("");
    setError("");
    setNotice("");
  }, [contextKey]);

  async function interpret(event: FormEvent) {
    event.preventDefault();
    const statement = text.trim();
    if (!statement || !selectedSpaceID || checking) return;
    setChecking(true);
    setError("");
    setNotice("");
    try {
      const loaded = await api<FinanceCaptureInterpretResponse>("/finance/capture/interpret", { method: "POST", body: JSON.stringify({ space_id: selectedSpaceID, text: statement, conversation: conversation.slice(-8), context }) }, true, false);
      if (loaded.conversation_persisted !== false) throw new Error(copy.error);
      setResponse(loaded);
    } catch {
      setError(copy.error);
    } finally {
      setChecking(false);
    }
  }

  async function confirm(draft: FinanceCaptureDraft, content: FinanceCaptureDraft["content"], targetID: string | null, accountID: string | null) {
    if (confirmingID) return;
    setConfirmingID(draft.id);
    setError("");
    setNotice("");
    try {
      const saved = await api<FinanceCaptureConfirmResponse>(`/finance/capture/${encodeURIComponent(draft.id)}/confirm`, { method: "POST", body: JSON.stringify({ content, selected_target_id: targetID, selected_account_id: accountID }) }, true, false);
      if (saved.status !== "CONFIRMED" || saved.draft_id !== draft.id) throw new Error(copy.confirmError);
      setResponse((current) => current ? { ...current, drafts: current.drafts.filter((item) => item.id !== draft.id) } : current);
      setText("");
      setNotice(copy.confirmed);
    } catch (caught) {
      setError(caught instanceof ApiError && caught.message ? caught.message : copy.confirmError);
    } finally {
      setConfirmingID("");
    }
  }

  async function uploadPrivateEvidence(event: FormEvent) {
    event.preventDefault();
    if (!privateFile || !privateTitle.trim() || !privateSpace || uploading) return;
    setUploading(true);
    setError("");
    setNotice("");
    const form = new FormData();
    form.set("file", privateFile);
    form.set("title", privateTitle.trim());
    try {
      const saved = await api<FinancePurchaseEvidenceUploadResponse>(
        `/finance/purchases/evidence/upload?space_id=${encodeURIComponent(privateSpace.id)}`,
        { method: "POST", body: form },
      );
      if (!isOfflineQueuedResult(saved) && saved.source.space_id !== privateSpace.id) throw new Error(copy.confirmError);
      setPrivateFile(null);
      setPrivateTitle("");
      setNotice(isOfflineQueuedResult(saved)
        ? (locale === "de" ? "Datei offline gespeichert und wartet auf Synchronisierung." : "File saved offline and waiting to sync.")
        : (locale === "de" ? "Datei privat in Finanzen gespeichert. Öffne Aktivität, um sie zuzuordnen oder zu beschreiben." : "File saved to Private Finance. Open Activity to match or describe it."));
    } catch (caught) {
      setError(caught instanceof ApiError && caught.message ? caught.message : (locale === "de" ? "Die private Datei konnte nicht gespeichert werden." : "The private file could not be saved."));
    } finally {
      setUploading(false);
    }
  }

  const answer = response?.answer as FinanceCoachAnswer | null | undefined;
  return <section className="finance-capture-panel" aria-labelledby={`${idPrefix}-title`}>
    <header><div><span className="finance-status-label"><FilePenLine aria-hidden="true" size={15} /> {copy.review}</span><h3 id={`${idPrefix}-title`}>{copy.title}</h3><p>{copy.detail}</p></div></header>
    <form className="finance-capture-input" onSubmit={(event) => void interpret(event)}>
      {spaces.length > 1 ? <div className="field"><label htmlFor={`${idPrefix}-space`}>{copy.finances}</label><select id={`${idPrefix}-space`} value={selectedSpaceID} onChange={(event) => { setSpaceID(event.target.value); setResponse(null); }}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div> : selectedSpace ? <p className="finance-capture-space"><span>{copy.finances}</span><strong>{selectedSpace.name}</strong></p> : null}
      <div className="field"><label htmlFor={`${idPrefix}-text`}>{copy.text}</label><textarea id={`${idPrefix}-text`} rows={3} maxLength={4_000} autoComplete="off" value={text} onChange={(event) => setText(event.target.value)} placeholder={copy.placeholder} /></div>
      {!text && !response ? <div className="finance-capture-examples" aria-label={copy.examples}>{copy.exampleStatements.map((example) => <button type="button" key={example} onClick={() => setText(example)}>{example}</button>)}</div> : null}
      <button type="submit" className="button button--primary" disabled={checking || !text.trim()}><Send aria-hidden="true" size={16} /> {checking ? copy.checking : copy.interpret}</button>
      <small><ShieldCheck aria-hidden="true" size={14} /> {copy.noStorage}</small>
    </form>
    {privateSpace ? <details className="finance-private-upload">
      <summary>{locale === "de" ? "Beleg oder Kontoauszug privat hochladen" : "Upload a receipt or statement privately"}</summary>
      <form onSubmit={(event) => void uploadPrivateEvidence(event)}>
        <p><ShieldCheck aria-hidden="true" size={16} /> {locale === "de" ? "Diese Datei landet nur in deinen privaten Finanzen. Sie erscheint nicht in den gemeinsamen Familien-Dokumenten." : "This file goes only to your Private Finance area. It will not appear in shared family Documents."}</p>
        <div className="field"><label htmlFor={`${idPrefix}-private-title`}>{locale === "de" ? "Titel" : "Title"}</label><input id={`${idPrefix}-private-title`} value={privateTitle} onChange={(event) => setPrivateTitle(event.target.value)} maxLength={300} /></div>
        <div className="field"><label htmlFor={`${idPrefix}-private-file`}>{locale === "de" ? "PDF, Foto oder Textdatei" : "PDF, photo or text file"}</label><input id={`${idPrefix}-private-file`} type="file" accept="application/pdf,image/jpeg,image/png,image/heic,image/heif,image/tiff,text/plain" onChange={(event) => setPrivateFile(event.target.files?.[0] ?? null)} /></div>
        <button type="submit" className="button button--secondary" disabled={!privateFile || !privateTitle.trim() || uploading || !privateSpace}><Upload aria-hidden="true" size={16} /> {uploading ? (locale === "de" ? "Wird gespeichert…" : "Saving…") : (locale === "de" ? "Privat speichern" : "Save privately")}</button>
      </form>
    </details> : null}
    {error ? <p className="form-error" role="alert"><AlertCircle aria-hidden="true" size={16} /> {error}</p> : null}
    {notice ? <p className="form-success" role="status"><CheckCircle2 aria-hidden="true" size={16} /> {notice}</p> : null}
    {response?.mode === "CLARIFY" && response.message ? <div className="finance-capture-clarify"><strong>{copy.clarify}</strong><p>{response.message}</p></div> : null}
    {response?.mode === "ANSWER" && answer ? <CaptureAnswer answer={answer} locale={locale} household={selectedSpace?.kind === "household"} /> : null}
    {response?.drafts.length ? <div className="finance-capture-cards">{response.drafts.map((draft) => <CaptureDraftCard key={draft.id} draft={draft} accounts={accounts} context={context} locale={locale} household={selectedSpace?.kind === "household"} busy={confirmingID === draft.id} onConfirm={(card, content, targetID, accountID) => void confirm(card, content, targetID, accountID)} />)}</div> : null}
  </section>;
}
