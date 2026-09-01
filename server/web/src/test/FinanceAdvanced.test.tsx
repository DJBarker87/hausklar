import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { expect, it, vi } from "vitest";

import { api, ApiError } from "../api";
import { todayInTimeZone } from "../financeDate";
import type {
  FinanceAccount,
  FinanceAnalysisRequest,
  FinanceAnalysisResponse,
  FinanceEvidenceDetail,
  FinanceMaterialQuestion,
  FinancePatternScan,
  FinancePurchaseLineAssessment,
  FinancePurchaseReviewItem,
  FinanceSavedAnalysisView,
  FinanceSettings,
  FinanceSpace,
  FinanceTransaction,
} from "../types";
import { FinanceAnalysisView } from "../views/FinanceAnalysisView";
import { FinanceMaterialQuestionsView } from "../views/FinanceMaterialQuestionsView";
import { FinancePurchaseReviewView } from "../views/FinancePurchaseReviewView";

vi.mock("../api", async (loadOriginal) => {
  const original = await loadOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const spaces: FinanceSpace[] = [{ id: "private", kind: "personal", name: "Alex", is_default: true }];
const householdToday = todayInTimeZone("Europe/London");

function dateShift(days: number) {
  const value = new Date(`${householdToday}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function emptyNetWorth(currency: string) {
  return {
    space_id: "private",
    currency,
    current_total_minor: 0,
    change_minor: 0,
    period_contributions_minor: 0,
    period_withdrawals_minor: 0,
    period_market_movement_minor: 0,
    points: [
      { as_of_date: dateShift(-364), total_minor: 0, unknown_component_count: 0, layers: [], contributions_minor: 0, withdrawals_minor: 0, market_movement_minor: null },
      { as_of_date: dateShift(0), total_minor: 0, unknown_component_count: 0, layers: [], contributions_minor: 0, withdrawals_minor: 0, market_movement_minor: 0 },
    ],
    holdings: [],
    price_observed_at: null,
    price_sources: [],
    using_last_known_prices: false,
  };
}

const financeSettings: FinanceSettings = {
  id: "settings-1",
  household_timezone: "Europe/London",
  default_currency: "GBP",
  personal_space_id: "private",
  household_space_id: "shared",
  created_at: `${householdToday}T00:00:00Z`,
  updated_at: `${householdToday}T00:00:00Z`,
};

function account(): FinanceAccount {
  return {
    id: "current",
    space_id: "private",
    label: "Daily current",
    institution: "Fixture Bank",
    account_type: "CURRENT",
    purpose: "OPERATING_CURRENT",
    currency: "GBP",
    last_four: "1234",
    include_in_cashflow: true,
    include_in_net_worth: true,
    primary_spending_account: true,
    minimum_balance_minor: 0,
    card_paid_in_full: false,
    card_settlement_account_id: null,
    card_statement_close_day: null,
    card_repayment_day: null,
    fresh_through_date: dateShift(-1),
    data_through_at: `${dateShift(-1)}T08:00:00Z`,
    balance: { booked_minor: 100_000, available_minor: 100_000, credit_limit_minor: null, provider_at: null, observed_at: `${dateShift(-1)}T08:00:00Z` },
  };
}

function assessment(review_status: FinancePurchaseLineAssessment["review_status"], overrides: Partial<FinancePurchaseLineAssessment> = {}): FinancePurchaseLineAssessment {
  return {
    id: "assessment-1",
    line_id: "line-1",
    purchase_id: "purchase-1",
    space_id: "private",
    source_description: "PHONE STAND BLACK — RETAILER ORIGINAL",
    normalized_item_id: "item-1",
    normalized_item_name: "Phone stand",
    beneficiary: null,
    purpose: null,
    plannedness: null,
    utility: null,
    decision_quality: null,
    value_for_money: null,
    outcome_state: null,
    classification_source: "USER",
    confidence_bps: review_status === "CONFIRMED" ? 10_000 : 6_000,
    review_status,
    feedback_recorded: 1,
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

it("opens Insights with automatic, selected-space summaries before the custom builder", async () => {
  apiMock.mockReset();
  window.history.replaceState({}, "", "/?view=finance&section=explore");
  const categoryResponse: FinanceAnalysisResponse = {
    basis: "TRANSACTIONS",
    currency: "GBP",
    total: { numerator: 400_000, denominator: 1 },
    groups: [
      { key: "Quinn", value: { numerator: 300_000, denominator: 1 }, record_count: 10, evidence_handles: [] },
      { key: "(unknown)", value: { numerator: 100_000, denominator: 1 }, record_count: 3, evidence_handles: [] },
    ],
    comparison_groups: [
      { key: "Quinn", value: { numerator: 200_000, denominator: 1 }, record_count: 8, evidence_handles: [] },
      { key: "(unknown)", value: { numerator: 50_000, denominator: 1 }, record_count: 2, evidence_handles: [] },
    ],
    comparison_total: { numerator: 250_000, denominator: 1 },
    comparison_start_date: dateShift(-179),
    comparison_end_date: dateShift(-90),
    data_through: dateShift(0),
    itemisation_coverage: null,
    evidence: [],
    saved_view: null,
  };
  const utilityResponse: FinanceAnalysisResponse = {
    ...categoryResponse,
    basis: "PURCHASE_LINES",
    total: { numerator: 700_000, denominator: 1 },
    groups: [
      { key: "essential", value: { numerator: 400_000, denominator: 1 }, record_count: 12, evidence_handles: [] },
      { key: "optional", value: { numerator: 200_000, denominator: 1 }, record_count: 6, evidence_handles: [] },
      { key: "unclear", value: { numerator: 100_000, denominator: 1 }, record_count: 4, evidence_handles: [] },
    ],
    comparison_groups: [],
    comparison_total: null,
    comparison_start_date: null,
    comparison_end_date: null,
    itemisation_coverage: { eligible_minor: 1_000_000, itemised_minor: 700_000, coverage_bps: 7_000 },
  };
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/settings") return financeSettings as never;
    if (path === "/finance/analysis/views?space_id=private") return [] as never;
    if (String(path).startsWith("/finance/opportunities?space_id=private")) return [] as never;
    if (String(path).startsWith("/finance/habits?space_id=private")) return [] as never;
    if (String(path).startsWith("/finance/reports?space_id=private")) return [] as never;
    if (String(path).startsWith("/finance/assets/net-worth-history?")) {
      const currency = new URL(String(path), "https://hausklar.test").searchParams.get("currency") ?? "GBP";
      return emptyNetWorth(currency) as never;
    }
    if (path === "/finance/analysis") {
      const request = JSON.parse(String(init?.body)) as FinanceAnalysisRequest;
      return (request.basis === "TRANSACTIONS" ? categoryResponse : utilityResponse) as never;
    }
    throw new Error(`Unexpected API request: ${path}`);
  });
  const transaction: FinanceTransaction = {
    id: "tx-overview", space_id: "private", account_id: "current", amount_minor: -20_00, currency: "GBP",
    description: "Quinn", merchant_text: "Quinn", canonical_date: dateShift(0), state: "POSTED",
    transaction_kind: "CASEY", source_kind: "bank", merchant_id: null, primary_category_id: null, primary_category_name: "Uncategorised", primary_spending_type: "UNCATEGORISED",
    superseded_by_id: null, data_through_at: `${dateShift(0)}T08:00:00Z`,
  };
  const availableSpaces: FinanceSpace[] = [
    ...spaces,
    { id: "shared", kind: "household", name: "Household", is_default: false },
  ];

  const usdAccount = { ...account(), id: "usd-current", currency: "USD" };
  render(<FinanceAnalysisView accounts={[account(), usdAccount]} transactions={[transaction]} spaces={availableSpaces} scope="mine" locale="en" onAskAbout={vi.fn()} />);

  expect(await screen.findByRole("heading", { name: "At a glance" })).toBeInTheDocument();
  expect(screen.getByText("Private records plus deliberately shared Household records.")).toBeInTheDocument();
  expect(screen.queryByText(/plans and spending money remain separate/i)).not.toBeInTheDocument();
  const topChange = screen.getByText("Top change").closest("article");
  expect(topChange).not.toBeNull();
  expect(within(topChange!).getByText("Quinn")).toBeInTheDocument();
  expect(within(topChange!).getByText(/\+£1,000\.00/)).toBeInTheDocument();
  const utility = screen.getByText("Essential vs flexible").closest("article");
  expect(utility).not.toBeNull();
  expect(within(utility!).getByText("£4,000.00")).toBeInTheDocument();
  expect(within(utility!).getByText("£2,000.00")).toBeInTheDocument();
  expect(screen.getByText("70%", { selector: "strong" })).toBeInTheDocument();
  expect(screen.getByText("Build a custom view").closest("details")).not.toHaveAttribute("open");
  expect(document.querySelector("#finance-analysis-space")).toBeNull();

  const analysisCalls = apiMock.mock.calls.filter(([path]) => path === "/finance/analysis");
  expect(analysisCalls).toHaveLength(2);
  expect(analysisCalls.map(([, init]) => JSON.parse(String(init?.body)))).toEqual(expect.arrayContaining([
    expect.objectContaining({ space_id: "private", basis: "TRANSACTIONS", grouping: "CATEGORY" }),
    expect.objectContaining({ space_id: "private", basis: "PURCHASE_LINES", grouping: "UTILITY" }),
  ]));
  expect(apiMock.mock.calls.some(([path]) => String(path).includes("shared"))).toBe(false);
  fireEvent.change(screen.getByLabelText("Currency"), { target: { value: "USD" } });
  await waitFor(() => expect(apiMock.mock.calls.some(([path]) => {
    const value = String(path);
    return value.startsWith("/finance/assets/net-worth-history?") && value.includes("currency=USD");
  })).toBe(true));
});

it("treats an empty Insights space as a calm next-data state rather than an error", async () => {
  apiMock.mockReset();
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/settings") return financeSettings as never;
    if (path === "/finance/analysis/views?space_id=private") return [] as never;
    if (String(path).startsWith("/finance/opportunities?space_id=private")) return [] as never;
    if (String(path).startsWith("/finance/habits?space_id=private")) return [] as never;
    if (String(path).startsWith("/finance/reports?space_id=private")) return [] as never;
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceAnalysisView accounts={[]} transactions={[]} spaces={spaces} scope="mine" locale="en" onAskAbout={vi.fn()} />);

  const title = await screen.findByText("Best view from the money recorded so far");
  const state = title.closest(".finance-analysis-state");
  expect(state).not.toBeNull();
  expect(state).not.toHaveClass("is-error");
  expect(within(state as HTMLElement).queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
  expect(within(state as HTMLElement).getByText(/No clear change or savings win/)).toBeInTheDocument();
  expect(screen.getByText("Build a custom view").closest("details")).not.toHaveAttribute("open");
  expect(apiMock.mock.calls.some(([path]) => path === "/finance/analysis")).toBe(false);
});

it("reviews material purchase lines, opens saved analysis evidence, and resolves only explicit material questions", async () => {
  const reviewItem: FinancePurchaseReviewItem = {
    line_id: "line-1",
    purchase_id: "purchase-1",
    space_id: "private",
    purchased_on: dateShift(-4),
    merchant: "Amazon",
    source_description: "PHONE STAND BLACK — RETAILER ORIGINAL",
    amount_minor: 20_00,
    currency: "GBP",
    confidence_bps: 4_000,
    uncertain_fields: ["normalized_item", "beneficiary", "purpose", "utility", "outcome_state"],
    evidence_handle: "purchase-line:line-1",
    deep_link: "/?view=finance&section=purchases&line=line-1",
    source_id: "source-1",
    match_status: "UNMATCHED",
    receipt_file_id: null,
  };
  let reviewSaves = 0;
  apiMock.mockImplementation(async (path, init) => {
    if (String(path).startsWith("/finance/purchases/review/high-impact")) return [reviewItem] as never;
    if (path === "/finance/purchase-lines/line-1/assessment" && !init?.method) throw new ApiError("missing", 404);
    if (path === "/finance/purchase-lines/line-1/assessment" && init?.method === "PUT") {
      reviewSaves += 1;
      return (reviewSaves === 1
        ? assessment("NEEDS_REVIEW")
        : assessment("CONFIRMED", { beneficiary: "Household", utility: "optional", outcome_state: "regretted" })) as never;
    }
    return undefined as never;
  });
  window.history.replaceState({}, "", "/?view=finance&section=purchases&line=line-1");
  render(<FinancePurchaseReviewView spaces={spaces} locale="en" />);

  expect(await screen.findByText("PHONE STAND BLACK — RETAILER ORIGINAL")).toBeInTheDocument();
  const saveReview = screen.getByRole("button", { name: "Save review" });
  expect(saveReview).toBeDisabled();
  fireEvent.change(screen.getByLabelText("Usual item or service name"), { target: { value: "Phone stand" } });
  await waitFor(() => expect(saveReview).toBeEnabled());
  fireEvent.click(saveReview);
  expect(await screen.findByText(/partial review was saved/i)).toBeInTheDocument();
  expect(screen.getByText("PHONE STAND BLACK — RETAILER ORIGINAL")).toBeInTheDocument();
  expect(saveReview).toBeDisabled();
  fireEvent.change(screen.getByLabelText("Who or what it was for"), { target: { value: "Household" } });
  fireEvent.change(screen.getByLabelText("Household usefulness"), { target: { value: "optional" } });
  fireEvent.change(screen.getByLabelText("What happened afterwards"), { target: { value: "regretted" } });
  fireEvent.click(saveReview);
  await waitFor(() => expect(reviewSaves).toBe(2));
  const reviewBodies = apiMock.mock.calls.filter(([path, init]) => path === "/finance/purchase-lines/line-1/assessment" && init?.method === "PUT").map(([, init]) => JSON.parse(String(init?.body)));
  expect(reviewBodies[0]).toMatchObject({ normalized_item_name: "Phone stand" });
  expect(reviewBodies[0]).not.toHaveProperty("source_description");
  expect(reviewBodies[1]).toMatchObject({ beneficiary: "Household", utility: "optional", outcome_state: "regretted" });

  cleanup();
  apiMock.mockReset();
  const analysisRequest: FinanceAnalysisRequest = {
    space_id: "private",
    basis: "PURCHASE_LINES",
    start_date: dateShift(-30),
    end_date: dateShift(0),
    currency: "GBP",
    grouping: "PLANNEDNESS",
    measure: "SPEND",
    comparison: "PREVIOUS_PERIOD",
    pending_policy: "EXCLUDE",
    refund_policy: "NET",
    transfer_policy: "EXCLUDE",
    filters: {
      account_ids: [], merchants: [], categories: [], transaction_types: [], line_kinds: [],
      normalized_items: ["Phone stand"], purposes: [], beneficiaries: [], plannedness: ["planned"],
      utilities: [], decision_qualities: [], value_for_money: [], outcomes: [], itemisation: [],
    },
    save_as: null,
  };
  const savedView: FinanceSavedAnalysisView = {
    id: "saved-1",
    space_id: "private",
    name: "Geplante Einkäufe",
    request: analysisRequest,
    deep_link: "/?view=finance&section=explore&analysis=saved-1",
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  const analysisResponse: FinanceAnalysisResponse = {
    basis: "PURCHASE_LINES",
    currency: "GBP",
    total: { numerator: 20_00, denominator: 1 },
    groups: [{ key: "planned", value: { numerator: 20_00, denominator: 1 }, record_count: 2, evidence_handles: ["purchase-line:line-1"] }],
    comparison_groups: [{ key: "planned", value: { numerator: 15_00, denominator: 1 }, record_count: 1, evidence_handles: ["purchase-line:line-2"] }],
    comparison_total: { numerator: 15_00, denominator: 1 },
    comparison_start_date: dateShift(-61),
    comparison_end_date: dateShift(-31),
    data_through: dateShift(0),
    itemisation_coverage: { eligible_minor: 40_00, itemised_minor: 30_00, coverage_bps: 7_500 },
    evidence: [
      { handle: "purchase-line:line-1", kind: "purchase-line", record_id: "line-1", deep_link: "/?view=finance&section=purchases&line=line-1" },
      { handle: "purchase-line:line-2", kind: "purchase-line", record_id: "line-2", deep_link: "/?view=finance&section=purchases&line=line-2" },
    ],
    saved_view: null,
  };
  const evidenceDetail: FinanceEvidenceDetail = {
    handle: "purchase-line:line-1",
    kind: "purchase-line",
    record_id: "line-1",
    space_id: "private",
    deep_link: "/?view=finance&section=purchases&line=line-1",
    source_evidence_id: "source-1",
    source_description: "PHONE STAND BLACK — RETAILER ORIGINAL",
    amount_minor: 20_00,
    currency: "GBP",
    occurred_on: dateShift(-4),
  };
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/settings") return financeSettings as never;
    if (String(path).startsWith("/finance/analysis/views")) return [savedView] as never;
    if (path === "/finance/analysis") {
      const requested = JSON.parse(String(init?.body)) as FinanceAnalysisRequest;
      if (requested.grouping === "CATEGORY") {
        return { ...analysisResponse, basis: "TRANSACTIONS", groups: [], comparison_groups: [], evidence: [], itemisation_coverage: null } as never;
      }
      if (requested.grouping === "UTILITY") {
        return { ...analysisResponse, groups: [], comparison_groups: [], evidence: [] } as never;
      }
      return analysisResponse as never;
    }
    if (String(path).startsWith("/finance/opportunities?") || String(path).startsWith("/finance/habits?") || String(path).startsWith("/finance/reports?")) return [] as never;
    if (String(path).startsWith("/finance/assets/net-worth-history?")) return emptyNetWorth("GBP") as never;
    if (path === "/finance/analysis/evidence/purchase-line/line-1") return evidenceDetail as never;
    if (String(path).startsWith("/finance/calendar-items?")) return [] as never;
    if (String(path).startsWith("/finance/calendar-items/prefill?")) return null as never;
    if (path === "/finance/projection-preferences") return { show_finance_events: false, event_visibility: "PRIVATE" } as never;
    return undefined as never;
  });
  window.history.replaceState({}, "", "/?view=finance&section=explore&analysis=saved-1");
  const askAbout = vi.fn();
  const transaction: FinanceTransaction = {
    id: "tx-1", space_id: "private", account_id: "current", amount_minor: -20_00, currency: "GBP",
    description: "Amazon", merchant_text: "Amazon", canonical_date: dateShift(0), state: "POSTED",
    transaction_kind: "CASEY", source_kind: "bank", merchant_id: null, primary_category_id: null, primary_category_name: "Uncategorised", primary_spending_type: "UNCATEGORISED",
    superseded_by_id: null, data_through_at: `${dateShift(0)}T08:00:00Z`,
  };
  render(<FinanceAnalysisView accounts={[account()]} transactions={[transaction]} spaces={spaces} scope="mine" locale="de" onAskAbout={askAbout} />);

  const coverageLabel = (await screen.findAllByText("Einkäufe mit Artikeldetails"))
    .find((element) => element.tagName === "SPAN");
  const coverage = coverageLabel?.closest("article") ?? null;
  expect(coverage).not.toBeNull();
  expect(within(coverage!).getByText((content, element) => element?.tagName === "STRONG" && content.includes("75"))).toBeInTheDocument();
  expect(screen.getAllByText("Geplant").length).toBeGreaterThan(0);
  expect(screen.queryByText("planned")).not.toBeInTheDocument();
  const plannedRow = screen.getByRole("row", { name: /Geplant/ });
  expect(within(plannedRow).getByText("2")).toBeInTheDocument();
  expect(within(plannedRow).getByText("1")).toBeInTheDocument();
  const analysisCall = apiMock.mock.calls.find(([path, init]) => path === "/finance/analysis"
    && (JSON.parse(String(init?.body)) as FinanceAnalysisRequest).grouping === "PLANNEDNESS");
  expect(JSON.parse(String(analysisCall?.[1]?.body))).toEqual({ ...analysisRequest, scope: "mine" });
  expect(analysisCall?.[3]).toBe(false);
  fireEvent.click(within(plannedRow).getByRole("button", { name: "Einträge anzeigen" }));
  fireEvent.click(screen.getByRole("button", { name: /Artikel aus Belegen 1/ }));
  expect(await screen.findByText("PHONE STAND BLACK — RETAILER ORIGINAL")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: "Diesen Eintrag öffnen" })).toHaveAttribute("href", "/?view=finance&section=purchases&line=line-1");
  fireEvent.click(screen.getByRole("button", { name: "Hierzu fragen" }));
  expect(askAbout).toHaveBeenCalledTimes(1);
  const questionWithContext = String(askAbout.mock.calls[0][0]);
  expect(questionWithContext).toContain("Auswertungskontext");
  expect(questionWithContext).toContain("Übliche Artikelnamen: Phone stand");
  expect(questionWithContext).not.toContain("normalized_items");
  expect(questionWithContext).not.toContain("PLANNEDNESS");

  cleanup();
  apiMock.mockReset();
  const salaryQuestion: FinanceMaterialQuestion = {
    id: "salary-question", space_id: "private", question_kind: "SALARY", prompt: "Is this monthly payment your salary?", evidence_refs: ["tx-1"], action_kind: "CONFIRM_RECURRING", action_target_id: "salary-series", next_action_method: "POST", next_action_route: "/not-for-the-browser", priority_minor: 300_000, currency: "GBP", status: "OPEN", answer_text: null, resolved_at: null, updated_at: new Date().toISOString(),
  };
  const nurseryQuestion: FinanceMaterialQuestion = {
    ...salaryQuestion, id: "nursery-question", question_kind: "NURSERY", prompt: "What are the reviewed nursery dates?", action_kind: "SAVE_NURSERY_PLAN", action_target_id: null, priority_minor: 120_000,
  };
  const cardQuestion: FinanceMaterialQuestion = {
    ...salaryQuestion, id: "card-question", question_kind: "MISSING_CARD", prompt: "A card repayment has no card account.", action_kind: "ADD_CREDIT_CARD", action_target_id: null, priority_minor: 90_000,
  };
  const purchaseQuestion: FinanceMaterialQuestion = {
    ...salaryQuestion, id: "purchase-question", question_kind: "LARGE_UNITEMISED_PURCHASE", prompt: "This large purchase needs item details.", action_kind: "ITEMISE_PURCHASE", action_target_id: "source-1", priority_minor: 80_000,
  };
  const scan: FinancePatternScan = {
    space_id: "private",
    data_through_date: dateShift(0),
    questions: [salaryQuestion, nurseryQuestion, cardQuestion, purchaseQuestion],
    recurring_series: [{
      id: "salary-series", space_id: "private", detection_key: "salary", name: "Monthly salary", series_type: "SALARY", interval_kind: "MONTHLY", expected_minor: 300_000, low_minor: 295_000, high_minor: 305_000, currency: "GBP", next_expected_date: dateShift(20), working_day_adjustment: "PREVIOUS", evidence_refs: ["tx-1"], confidence_bps: 9_000, status: "CANDIDATE", confirmed_at: null, updated_at: new Date().toISOString(),
    }],
  };
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/settings") return financeSettings as never;
    if (String(path).startsWith("/finance/patterns/scan")) return scan as never;
    const questionID = String(path).split("/")[3];
    if (String(path).endsWith("/correct")) return { ...[salaryQuestion, nurseryQuestion].find((item) => item.id === questionID)!, status: "CORRECTED" } as never;
    if (String(path).endsWith("/dismiss") && init?.method === "POST") return { ...cardQuestion, status: "DISMISSED" } as never;
    return undefined as never;
  });
  const openSetup = vi.fn();
  const openPurchases = vi.fn();
  render(<FinanceMaterialQuestionsView spaces={spaces} accounts={[account()]} locale="en" onOpenSetup={openSetup} onOpenPurchases={openPurchases} />);

  fireEvent.click(await screen.findByRole("button", { name: "Change details" }));
  expect(await screen.findByDisplayValue("Monthly salary")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Confirm salary details" }));
  await screen.findByText("What are the reviewed nursery dates?");
  const salaryCall = apiMock.mock.calls.find(([path]) => path === "/finance/questions/salary-question/correct");
  expect(JSON.parse(String(salaryCall?.[1]?.body))).toMatchObject({ recurring: { series_type: "SALARY", expected_minor: 300_000, next_expected_date: dateShift(20) } });
  fireEvent.click(screen.getByRole("button", { name: "Add amount and dates" }));
  fireEvent.change(screen.getByLabelText("Expected nursery amount"), { target: { value: "1200.00" } });
  fireEvent.change(screen.getByLabelText("Reviewed due dates 1"), { target: { value: dateShift(45) } });
  fireEvent.click(screen.getByRole("button", { name: "Save nursery dates" }));
  await screen.findByText("A card repayment has no card account.");
  const nurseryCall = apiMock.mock.calls.find(([path]) => path === "/finance/questions/nursery-question/correct");
  expect(JSON.parse(String(nurseryCall?.[1]?.body))).toEqual({ nursery_expected_minor: 120_000, nursery_due_dates: [dateShift(45)] });
  fireEvent.click(screen.getByRole("button", { name: "Add card" }));
  expect(openSetup).toHaveBeenCalledOnce();
  expect(screen.getByText("A card repayment has no card account.")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Not now" }));
  await screen.findByText("This large purchase needs item details.");
  fireEvent.click(screen.getByRole("button", { name: "Review purchase" }));
  expect(openPurchases).toHaveBeenCalledWith("source-1");
  expect(apiMock.mock.calls.filter(([path]) => String(path).startsWith("/finance/patterns/scan"))).toHaveLength(1);
  expect(apiMock.mock.calls.every(([, , , queueOffline]) => queueOffline === undefined || queueOffline === false)).toBe(true);
});
