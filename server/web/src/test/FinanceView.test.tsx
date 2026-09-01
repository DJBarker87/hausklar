import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api, ApiError } from "../api";
import type {
  FinanceAccount,
  FinanceAIConsent,
  FinanceCoachAnswer,
  FinanceCommitment,
  FinanceGoal,
  FinanceLedgerSummary,
  FinanceOverview,
  FinancePurchaseDetail,
  FinancePurchaseException,
  FinancePurchaseSummary,
  FinanceReserve,
  FinanceSpace,
  FinanceTransaction,
} from "../types";
import { FinanceView, type FinanceScope, type FinanceSection } from "../views/FinanceView";

vi.mock("../api", () => ({
  api: vi.fn(),
  invalidateFinanceRequestCache: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;

    constructor(message: string, status: number) {
      super(message);
      this.name = "ApiError";
      this.status = status;
    }
  },
}));

const apiMock = vi.mocked(api);
const recentTimestamp = new Date().toISOString();
const spaces: FinanceSpace[] = [
  { id: "personal-real-id", kind: "personal", name: "Alex", is_default: true },
  { id: "household-real-id", kind: "household", name: "Family", is_default: false },
  { id: "partner-private-id", kind: "personal", name: "Jordan", is_default: false },
];

const consentDisclosure = "When you explicitly ask, authorised Finance facts may be sent. Credentials are never sent. OpenAI requests use store:false. Chat transcripts are not stored by HausKlar, and background processing is disabled.";
const financeConsents: FinanceAIConsent[] = [
  {
    space_id: "personal-real-id",
    space_kind: "personal",
    consented: false,
    consent_version: "finance-ai-v1/openai/coach-model",
    consented_at: null,
    provider: "openai",
    model: "coach-model",
    store: false,
    background_processing: false,
    disclosure: consentDisclosure,
  },
  {
    space_id: "household-real-id",
    space_kind: "household",
    consented: false,
    consent_version: "finance-ai-v1/openai/coach-model",
    consented_at: null,
    provider: "openai",
    model: "coach-model",
    store: false,
    background_processing: false,
    disclosure: consentDisclosure,
  },
];

const checkedCoachAnswer: FinanceCoachAnswer = {
  kind: "answer",
  headline: "Your spending stayed within the plan",
  answer: "Household costs were lower than the previous checked period.",
  answer_mode: "ESTIMATE",
  data_through: "2026-08-01T08:00:00Z",
  claims: [
    { text: "Nursery and groceries were checked against posted transactions.", evidence_ids: ["evidence-1"] },
  ],
  estimates: [
    {
      text: "Likely remaining flexible spend",
      assumptions: ["No new card transactions after the data-through time"],
      low_minor: 12_000,
      high_minor: 15_000,
      currency: "GBP",
    },
  ],
  suggested_actions: ["Check the latest card transactions before a large purchase."],
  analysis_view_id: null,
  questions: [],
};

const personalAccounts: FinanceAccount[] = [
  {
    id: "current-account",
    space_id: "personal-real-id",
    label: "Daily current",
    institution: "Fixture Bank",
    account_type: "CURRENT",
    purpose: "OPERATING_CURRENT",
    currency: "GBP",
    last_four: "4321",
    include_in_cashflow: true,
    include_in_net_worth: true,
    primary_spending_account: true,
    minimum_balance_minor: 0,
    card_paid_in_full: false,
    card_settlement_account_id: null,
    card_statement_close_day: null,
    card_repayment_day: null,
    fresh_through_date: "2026-07-31",
    data_through_at: recentTimestamp,
    balance: {
      booked_minor: 123_456,
      available_minor: 120_000,
      credit_limit_minor: null,
      provider_at: recentTimestamp,
      observed_at: recentTimestamp,
    },
  },
  {
    id: "euro-account",
    space_id: "personal-real-id",
    label: "Euro cash",
    institution: null,
    account_type: "CASH",
    purpose: "OPERATING_CURRENT",
    currency: "EUR",
    last_four: null,
    include_in_cashflow: true,
    include_in_net_worth: true,
    primary_spending_account: false,
    minimum_balance_minor: 0,
    card_paid_in_full: false,
    card_settlement_account_id: null,
    card_statement_close_day: null,
    card_repayment_day: null,
    fresh_through_date: "2026-07-31",
    data_through_at: recentTimestamp,
    balance: {
      booked_minor: 9_876,
      available_minor: null,
      credit_limit_minor: null,
      provider_at: recentTimestamp,
      observed_at: recentTimestamp,
    },
  },
];

const personalSummary: FinanceLedgerSummary = {
  space_id: "personal-real-id",
  data_through_at: recentTimestamp,
  currencies: [
    {
      currency: "GBP",
      account_movement_minor: -2_100,
      income_minor: 150_000,
      gross_spending_minor: 152_100,
      refunds_minor: 499,
      reimbursements_minor: 0,
      fees_minor: 125,
      net_household_cost_minor: 151_601,
    },
    {
      currency: "EUR",
      account_movement_minor: -1_234,
      income_minor: 0,
      gross_spending_minor: 1_234,
      refunds_minor: 0,
      reimbursements_minor: 0,
      fees_minor: 0,
      net_household_cost_minor: 1_234,
    },
  ],
};

const personalOverview: FinanceOverview = {
  scope: "mine",
  month_start: "2026-08-01",
  through_date: "2026-08-10",
  currency: "GBP",
  account_count: 3,
  income_minor: 400_000,
  spending_minor: 82_500,
  spending_by_category: [
    { category_key: "mortgage", name: "Mortgage", spending_type: "FIXED", spent_minor: 30_000, share_bps: 3_636 },
    { category_key: "groceries", name: "Quinn", spending_type: "FLEXIBLE", spent_minor: 42_500, share_bps: 5_152 },
    { category_key: "days-out", name: "Days out", spending_type: "DISCRETIONARY", spent_minor: 10_000, share_bps: 1_212 },
  ],
  budget_buckets: [
    { category_key: "groceries", name: "Quinn", budget_minor: 60_000, spent_minor: 42_500, remaining_minor: 17_500 },
    { category_key: "days-out", name: "Days out", budget_minor: 20_000, spent_minor: 10_000, remaining_minor: 10_000 },
  ],
  current_available_minor: 317_500,
  next_paycheck_date: "2026-08-28",
  next_paycheck_minor: 400_000,
  left_until_payday_minor: 275_000,
  commitments_before_payday_minor: 42_500,
  commitments_before_payday_count: 1,
  upcoming_commitments: [
    { name: "Council tax", due_date: "2026-08-20", amount_minor: 42_500 },
  ],
  savings_balance_minor: 900_000,
  savings_change_minor: 25_000,
  savings_series: [
    { date: "2026-07-01", balance_minor: 875_000 },
    { date: "2026-08-10", balance_minor: 900_000 },
  ],
};

const householdOverview: FinanceOverview = {
  ...personalOverview,
  scope: "household",
  account_count: 4,
  spending_minor: 112_500,
  current_available_minor: 507_500,
  left_until_payday_minor: 465_000,
};

const personalTransactions: FinanceTransaction[] = [
  {
    id: "transaction-gbp",
    space_id: "personal-real-id",
    account_id: "current-account",
    canonical_date: "2026-07-31",
    amount_minor: -2_599,
    currency: "GBP",
    state: "POSTED",
    transaction_kind: "CASEY",
    source_kind: "PROVIDER",
    description: "TESCO STORES 0123",
    merchant_text: "Tesco",
    merchant_id: null,
    primary_category_id: null,
    primary_category_name: "Quinn",
    primary_spending_type: "FLEXIBLE",
    superseded_by_id: null,
    data_through_at: recentTimestamp,
  },
  {
    id: "transaction-eur",
    space_id: "personal-real-id",
    account_id: "euro-account",
    canonical_date: "2026-07-30",
    amount_minor: -1_234,
    currency: "EUR",
    state: "PENDING",
    transaction_kind: "CASEY",
    source_kind: "CSV",
    description: "DB BAHN",
    merchant_text: "Deutsche Bahn",
    merchant_id: null,
    primary_category_id: null,
    primary_category_name: "Travel",
    primary_spending_type: "DISCRETIONARY",
    superseded_by_id: null,
    data_through_at: recentTimestamp,
  },
];

const householdTransactions: FinanceTransaction[] = [
  {
    id: "transaction-household",
    space_id: "household-real-id",
    account_id: "household-account",
    canonical_date: "2026-08-01",
    amount_minor: -5_000,
    currency: "GBP",
    state: "POSTED",
    transaction_kind: "CASEY",
    source_kind: "PROVIDER",
    description: "SHARED GROCER",
    merchant_text: "Shared Grocer",
    merchant_id: null,
    primary_category_id: null,
    primary_category_name: "Quinn",
    primary_spending_type: "FLEXIBLE",
    superseded_by_id: null,
    data_through_at: recentTimestamp,
  },
];

const householdAccounts: FinanceAccount[] = [
  {
    ...personalAccounts[0],
    id: "household-account",
    space_id: "household-real-id",
    label: "Shared current",
    balance: { ...personalAccounts[0].balance!, booked_minor: 77_700 },
  },
];
const householdSummary: FinanceLedgerSummary = {
  space_id: "household-real-id",
  data_through_at: recentTimestamp,
  currencies: [{ ...personalSummary.currencies[0], account_movement_minor: -7_700 }],
};

const personalCommitments: FinanceCommitment[] = [
  {
    id: "school-fees",
    space_id: "personal-real-id",
    name: "School fees",
    amount_mode: "EXACT",
    exact_minor: 12_500,
    expected_minor: null,
    low_minor: null,
    high_minor: null,
    currency: "GBP",
    recurrence: "ONE_OFF",
    reviewed_dates: ["2026-08-15"],
    next_due_date: "2026-08-15",
    priority: "IMPORTANT",
    funding_account_id: null,
    already_reserved_minor: 2_500,
    required_minor: 12_500,
    remaining_minor: 10_000,
    funding_status: "PARTLY_FUNDED",
    status: "ACTIVE",
    notes: null,
    created_at: recentTimestamp,
    updated_at: recentTimestamp,
  },
];

const personalReserves: FinanceReserve[] = [
  {
    id: "car-repairs",
    space_id: "personal-real-id",
    name: "Car repairs",
    allocated_minor: 20_000,
    target_minor: 50_000,
    remaining_minor: 30_000,
    funding_status: "PARTLY_FUNDED",
    currency: "GBP",
    linked_account_id: null,
    status: "ACTIVE",
    created_at: recentTimestamp,
    updated_at: recentTimestamp,
  },
];

const personalGoals: FinanceGoal[] = [
  {
    id: "family-holiday",
    space_id: "personal-real-id",
    name: "Family holiday",
    target_minor: 100_000,
    deadline: "2026-12-20",
    currently_allocated_minor: 20_000,
    remaining_minor: 80_000,
    currency: "GBP",
    priority: "IMPORTANT",
    allowed_funding_sources: [],
    emergency_buffer_minor: 0,
    feasibility: "UNASSESSED",
    shortfall_minor: null,
    status: "ACTIVE",
    notes: null,
    created_at: recentTimestamp,
    updated_at: recentTimestamp,
  },
];

const personalPurchases: FinancePurchaseSummary[] = [
  {
    id: "tesco-purchase",
    space_id: "personal-real-id",
    merchant: "Tesco",
    item_descriptions: ["Braeburn apples", "Nappies"],
    order_reference: "TES-410",
    purchased_on: "2026-07-31",
    currency: "GBP",
    lines_subtotal_minor: 4_500,
    shipping_minor: 350,
    vat_included_minor: 700,
    order_discount_minor: 270,
    final_total_minor: 4_580,
    refunded_minor: 500,
    behavioural_net_minor: 4_080,
    status: "partly_refunded",
    source_kind: "tesco_order",
    match_status: "MATCHED",
    unmatched_purchase_minor: 0,
    unmatched_refund_minor: 0,
    cashflow_source: "canonical_transactions",
    purchase_total_added_to_cashflow: false,
    supersedes_purchase_id: null,
    superseded_by_id: null,
    created_at: "2026-07-31T12:00:00Z",
  },
  {
    id: "amazon-purchase",
    space_id: "personal-real-id",
    merchant: "Amazon",
    item_descriptions: ["Book"],
    order_reference: null,
    purchased_on: "2026-07-30",
    currency: "GBP",
    lines_subtotal_minor: 2_000,
    shipping_minor: 0,
    vat_included_minor: 333,
    order_discount_minor: 0,
    final_total_minor: 2_000,
    refunded_minor: 0,
    behavioural_net_minor: 2_000,
    status: "fulfilled",
    source_kind: "amazon_email",
    match_status: "PARTIAL",
    unmatched_purchase_minor: 500,
    unmatched_refund_minor: 0,
    cashflow_source: "canonical_transactions",
    purchase_total_added_to_cashflow: false,
    supersedes_purchase_id: null,
    superseded_by_id: null,
    created_at: "2026-07-30T12:00:00Z",
  },
];

const householdPurchases: FinancePurchaseSummary[] = [
  {
    ...personalPurchases[0],
    id: "market-purchase",
    space_id: "household-real-id",
    merchant: "Family Market",
    order_reference: "FM-10",
    purchased_on: "2026-08-01",
    final_total_minor: 7_000,
    refunded_minor: 0,
    behavioural_net_minor: 7_000,
    match_status: "UNMATCHED",
    unmatched_purchase_minor: 7_000,
    created_at: "2026-08-01T12:00:00Z",
  },
];

const purchaseExceptions: FinancePurchaseException[] = [
  {
    id: "unsupported-exception",
    space_id: "personal-real-id",
    source_id: "source-unsupported",
    purchase_id: null,
    exception_kind: "UNSUPPORTED_SOURCE",
    title: "Forwarded shop message",
    detail: "This sender format cannot be read yet.",
    amount_minor: null,
    currency: null,
    status: "OPEN",
    priority: 8,
    created_at: "2026-08-01T09:00:00Z",
  },
];

const householdPurchaseExceptions: FinancePurchaseException[] = [
  {
    id: "quarantined-exception",
    space_id: "household-real-id",
    source_id: "source-quarantined",
    purchase_id: null,
    exception_kind: "QUARANTINED_EVIDENCE",
    title: "Receipt needs inspection",
    detail: "The total could not be verified.",
    amount_minor: 7_000,
    currency: "GBP",
    status: "OPEN",
    priority: 10,
    created_at: "2026-08-01T10:00:00Z",
  },
];

const tescoPurchaseDetail: FinancePurchaseDetail = {
  ...personalPurchases[0],
  evidence: {
    id: "tesco-evidence",
    space_id: "personal-real-id",
    external_source_id: "tesco-source",
    source_kind: "tesco_order",
    corrects_source_id: null,
    parser_version: "1",
    extraction_status: "PARSED",
    confidence_bps: 9_900,
    raw_payload: { private: "never render this" },
    issues: [],
    storage_area: "finance-evidence",
    storage_key: null,
    received_at: "2026-07-31T12:00:00Z",
    parsed_at: "2026-07-31T12:01:00Z",
    created_at: "2026-07-31T12:00:00Z",
  },
  lines: [
    {
      id: "line-apples",
      line_ref: "line-1",
      position: 1,
      line_kind: "product",
      raw_description: "Braeburn apples",
      quantity_decimal: "2.5",
      unit_description: "kg",
      unit_price_minor: 1_200,
      line_gross_minor: 3_000,
      line_discount_minor: 200,
      line_net_minor: 2_800,
      evidence_status: "observed_structured",
      source_refs: [],
      seller: null,
      product_reference: null,
      replaces_description: null,
    },
    {
      id: "line-nappies",
      line_ref: "line-2",
      position: 2,
      line_kind: "product",
      raw_description: "Nappies",
      quantity_decimal: "1",
      unit_description: "pack",
      unit_price_minor: 1_700,
      line_gross_minor: 1_700,
      line_discount_minor: 70,
      line_net_minor: 1_630,
      evidence_status: "observed_structured",
      source_refs: [],
      seller: null,
      product_reference: null,
      replaces_description: null,
    },
  ],
  tenders: [
    {
      id: "tesco-tender",
      tender_ref: "tender-1",
      tender_kind: "card",
      amount_minor: 4_580,
      provider_transaction_id: "provider-789",
      card_suffix: "4321",
      source_refs: [],
    },
  ],
  refunds: [
    {
      id: "tesco-refund",
      refund_ref: "refund-1",
      line_id: "line-nappies",
      line_ref: "line-2",
      amount_minor: 500,
      quantity_decimal: "1",
      source_refs: [],
    },
  ],
  payment_allocations: [
    {
      id: "tesco-allocation",
      allocation_ref: "allocation-1",
      transaction_id: "transaction-gbp",
      line_id: null,
      tender_kind: "card",
      allocated_minor: 4_580,
      transaction_amount_minor: -4_580,
      transaction_date: "2026-07-31",
      match_method: "AUTO_EXACT",
      status: "CONFIRMED",
    },
  ],
};

const amazonPurchaseDetail: FinancePurchaseDetail = {
  ...tescoPurchaseDetail,
  ...personalPurchases[1],
  evidence: {
    ...tescoPurchaseDetail.evidence,
    id: "amazon-evidence",
    external_source_id: "amazon-source",
    source_kind: "amazon_email",
  },
  lines: [],
  tenders: [],
  refunds: [],
  payment_allocations: [],
};

function mockFinanceReads({
  returnedSpaces = spaces,
  accounts = personalAccounts,
  summary = personalSummary,
  transactions = personalTransactions,
  sharedAccounts = householdAccounts,
  sharedSummary = householdSummary,
  sharedTransactions = householdTransactions,
  commitments = personalCommitments,
  reserves = personalReserves,
  goals = personalGoals,
  sharedCommitments = [],
  sharedReserves = [],
  sharedGoals = [],
  purchases = personalPurchases,
  sharedPurchases = householdPurchases,
  exceptions = purchaseExceptions,
  sharedExceptions = householdPurchaseExceptions,
  purchaseDetails = {
    "tesco-purchase": tescoPurchaseDetail,
    "amazon-purchase": amazonPurchaseDetail,
  },
  consents = financeConsents,
  onWrite,
  onConsentWrite,
  onCoachAsk,
  onPurchaseMatch,
  olderTransactions = [],
  olderPurchases = [],
  overview = personalOverview,
  sharedOverview = householdOverview,
}: {
  returnedSpaces?: FinanceSpace[];
  accounts?: FinanceAccount[];
  summary?: FinanceLedgerSummary;
  transactions?: FinanceTransaction[];
  sharedAccounts?: FinanceAccount[];
  sharedSummary?: FinanceLedgerSummary;
  sharedTransactions?: FinanceTransaction[];
  commitments?: FinanceCommitment[];
  reserves?: FinanceReserve[];
  goals?: FinanceGoal[];
  sharedCommitments?: FinanceCommitment[];
  sharedReserves?: FinanceReserve[];
  sharedGoals?: FinanceGoal[];
  purchases?: FinancePurchaseSummary[];
  sharedPurchases?: FinancePurchaseSummary[];
  exceptions?: FinancePurchaseException[];
  sharedExceptions?: FinancePurchaseException[];
  purchaseDetails?: Record<string, FinancePurchaseDetail>;
  consents?: FinanceAIConsent[];
  onWrite?: (path: string, body: unknown) => unknown | Promise<unknown>;
  onConsentWrite?: (path: string, method: string, body: unknown) => unknown | Promise<unknown>;
  onCoachAsk?: (body: unknown) => FinanceCoachAnswer | Promise<FinanceCoachAnswer>;
  onPurchaseMatch?: (purchaseID: string, body: unknown) => FinancePurchaseDetail | Promise<FinancePurchaseDetail>;
  olderTransactions?: FinanceTransaction[];
  olderPurchases?: FinancePurchaseSummary[];
  overview?: FinanceOverview;
  sharedOverview?: FinanceOverview;
} = {}) {
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/ai-consent" && (!init?.method || init.method === "GET")) {
      return consents;
    }
    if (path.startsWith("/finance/ai-consent") && ["PUT", "DELETE"].includes(init?.method ?? "")) {
      const body = typeof init?.body === "string" ? JSON.parse(init.body) : init?.body;
      if (onConsentWrite) return onConsentWrite(path, init?.method ?? "", body);
      const spaceID = init?.method === "PUT"
        ? (body as { space_id: string }).space_id
        : new URL(path, "https://hausklar.test").searchParams.get("space_id");
      const consent = consents.find((item) => item.space_id === spaceID);
      if (!consent) throw new Error(`Unexpected consent space: ${spaceID}`);
      return {
        ...consent,
        consented: init?.method === "PUT",
        consented_at: init?.method === "PUT" ? recentTimestamp : null,
      };
    }
    if (path === "/finance/coach/ask" && init?.method === "POST") {
      if (!onCoachAsk) throw new Error("Unexpected Finance Coach request");
      const body = typeof init.body === "string" ? JSON.parse(init.body) : init.body;
      return onCoachAsk(body);
    }
    if (path === "/finance/settings") return { id: "settings-1", household_timezone: "Europe/London", default_currency: "GBP", personal_space_id: "personal-real-id", household_space_id: "household-real-id", created_at: recentTimestamp, updated_at: recentTimestamp };
    if (path.startsWith("/finance/analysis/views?space_id=")) return [];
    if (path === "/finance/analysis" && init?.method === "POST") {
      const request = JSON.parse(String(init.body)) as { basis: "TRANSACTIONS" | "PURCHASE_LINES"; currency: string };
      return {
        basis: request.basis,
        currency: request.currency,
        total: { numerator: 0, denominator: 1 },
        groups: [],
        comparison_groups: [],
        comparison_total: null,
        comparison_start_date: null,
        comparison_end_date: null,
        data_through: null,
        itemisation_coverage: null,
        evidence: [],
        saved_view: null,
      };
    }
    if (path === "/finance/shares") return [];
    if (path.startsWith("/finance/reports?")) return [];
    if (path.startsWith("/finance/report-preferences?")) {
      const spaceID = new URL(path, "https://hausklar.test").searchParams.get("space_id") ?? "";
      return { space_id: spaceID, show_more_by_default: false, updated_at: recentTimestamp };
    }
    if (path.startsWith("/finance/habits?")) return [];
    if (path.startsWith("/finance/opportunities?")) return [];
    if (path.startsWith("/finance/plans?")) return [];
    if (path.startsWith("/finance/payday-actions?")) return [];
    if (path.startsWith("/finance/proposals?")) return [];
    if (path.includes("/finance/purchases/inbox?") && path.includes("limit=3")) return [];
    if (path.startsWith("/finance/purchases/review/high-impact?")) return [];
    if (path.startsWith("/finance/patterns/scan?") && init?.method === "POST") {
      const spaceID = new URL(path, "https://hausklar.test").searchParams.get("space_id") ?? "";
      return { space_id: spaceID, data_through_date: null, recurring_series: [], questions: [] };
    }
    if (path.startsWith("/finance/purchases/") && path.endsWith("/match") && init?.method === "POST") {
      const purchaseID = decodeURIComponent(path.slice("/finance/purchases/".length, -"/match".length));
      const body = typeof init.body === "string" ? JSON.parse(init.body) : init.body;
      if (onPurchaseMatch) return onPurchaseMatch(purchaseID, body);
      const detail = purchaseDetails[purchaseID];
      if (!detail) throw new Error(`Unexpected purchase match: ${purchaseID}`);
      return { ...detail, match_status: "MATCHED", unmatched_purchase_minor: 0, unmatched_refund_minor: 0 };
    }
    if (path.startsWith("/finance/purchases/") && !path.includes("?") && !path.endsWith("/match")) {
      const purchaseID = decodeURIComponent(path.slice("/finance/purchases/".length));
      const detail = purchaseDetails[purchaseID];
      if (!detail) throw new Error(`Unexpected purchase detail: ${purchaseID}`);
      return detail;
    }
    if (["POST", "PATCH", "DELETE"].includes(init?.method ?? "") && onWrite) {
      return onWrite(path, typeof init?.body === "string" ? JSON.parse(init.body) : init?.body);
    }
    if (path === "/finance/spaces") return returnedSpaces;
    if (path === "/finance/overview?scope=mine") return overview;
    if (path === "/finance/overview?scope=household") return sharedOverview;
    if (path === "/finance/accounts?space_id=personal-real-id") return accounts;
    if (path === "/finance/summary?space_id=personal-real-id") return summary;
    if (path === "/finance/transactions?space_id=personal-real-id&limit=12") {
      return transactions;
    }
    if (path === "/finance/transactions?space_id=personal-real-id&offset=0&limit=200") {
      return transactions;
    }
    if (path === "/finance/transactions?space_id=personal-real-id&offset=200&limit=200") {
      return olderTransactions;
    }
    if (path === "/finance/commitments?space_id=personal-real-id") return commitments;
    if (path === "/finance/reserves?space_id=personal-real-id") return reserves;
    if (path === "/finance/goals?space_id=personal-real-id") return goals;
    if (path === "/finance/accounts?space_id=household-real-id" || path === "/finance/accounts?space_id=household-real-id&exclude_own_shared_copies=true") return sharedAccounts;
    if (path === "/finance/summary?space_id=household-real-id" || path === "/finance/summary?space_id=household-real-id&exclude_own_shared_copies=true") return sharedSummary;
    if (path === "/finance/transactions?space_id=household-real-id&limit=12" || path === "/finance/transactions?space_id=household-real-id&limit=12&exclude_own_shared_copies=true") {
      return sharedTransactions;
    }
    if (path === "/finance/transactions?space_id=household-real-id&offset=0&limit=200" || path === "/finance/transactions?space_id=household-real-id&offset=0&limit=200&exclude_own_shared_copies=true") {
      return sharedTransactions;
    }
    if (path === "/finance/commitments?space_id=household-real-id" || path === "/finance/commitments?space_id=household-real-id&exclude_own_shared_copies=true") return sharedCommitments;
    if (path === "/finance/reserves?space_id=household-real-id" || path === "/finance/reserves?space_id=household-real-id&exclude_own_shared_copies=true") return sharedReserves;
    if (path === "/finance/goals?space_id=household-real-id" || path === "/finance/goals?space_id=household-real-id&exclude_own_shared_copies=true") return sharedGoals;
    if (path === "/finance/purchases?space_id=personal-real-id&offset=0&limit=50") return purchases;
    if (path === "/finance/purchases?space_id=personal-real-id&offset=50&limit=50") return olderPurchases;
    if (path === "/finance/purchases/inbox?space_id=personal-real-id&offset=0&limit=50") return exceptions;
    if (path === "/finance/purchases?space_id=household-real-id&offset=0&limit=50&exclude_own_shared_copies=true") return sharedPurchases;
    if (path === "/finance/purchases/inbox?space_id=household-real-id&offset=0&limit=50&exclude_own_shared_copies=true") return sharedExceptions;
    throw new Error(`Unexpected API request: ${path}`);
  });
}

function renderFinance(overrides: Partial<React.ComponentProps<typeof FinanceView>> = {}) {
  const props: React.ComponentProps<typeof FinanceView> = {
    hasFamilyAccount: true,
    online: true,
    section: "coach",
    scope: "mine",
    onSectionChange: vi.fn(),
    onScopeChange: vi.fn(),
    locale: "en",
    ...overrides,
  };
  return { ...render(<FinanceView {...props} />), props };
}

describe("FinanceView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.localStorage.clear();
    window.history.replaceState({}, "", "/");
  });

  it("asks for a family account before loading family-scoped Finance data", () => {
    renderFinance({ hasFamilyAccount: false });

    expect(screen.getByRole("heading", { name: "Finance needs a family account" }))
      .toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("keeps financial data and planning writes out of offline browser storage", () => {
    renderFinance({ online: false });

    expect(screen.getByRole("heading", { name: "Finance needs a connection" }))
      .toBeInTheDocument();
    expect(screen.getByText(/not stored for offline use/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add a bill" })).not.toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("shows stable loading, setup-empty and recoverable error states", async () => {
    let resolveSpaces: (value: FinanceSpace[]) => void = () => undefined;
    apiMock.mockReturnValueOnce(new Promise((resolve) => { resolveSpaces = resolve; }));
    const initial = renderFinance();

    expect(screen.getByLabelText("Loading your finances"))
      .toHaveAttribute("aria-busy", "true");
    resolveSpaces([]);
    expect(await screen.findByRole("heading", { name: "Finance is ready to set up" }))
      .toBeInTheDocument();
    initial.unmount();

    apiMock.mockReset();
    apiMock.mockRejectedValueOnce(new Error("unavailable")).mockResolvedValueOnce([]);
    renderFinance();
    expect(await screen.findByRole("heading", { name: "Couldn't load Finance" }))
      .toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByRole("heading", { name: "Finance is ready to set up" }))
      .toBeInTheDocument();
  });

  it("opens on a calm real-data Overview without loading transaction or reconciliation detail", async () => {
    mockFinanceReads();
    renderFinance({ section: "overview" });

    expect(await screen.findByRole("heading", { name: "Spending this month" }))
      .toBeInTheDocument();
    expect(screen.getByText("£825.00")).toBeInTheDocument();
    expect(screen.getAllByText("Quinn")).toHaveLength(2);
    expect(screen.getByText("£175.00")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Until next payday" })).toBeInTheDocument();
    expect(screen.getByText("Council tax")).toBeInTheDocument();
    expect(screen.getByText("£2,750.00")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Savings" })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /Savings trend from £8,750.00 to £9,000.00/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "My finances" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Household" })).toHaveAttribute("aria-pressed", "false");
    expect(screen.getByRole("button", { name: "Overview" })).toHaveAttribute("aria-current", "page");
    const financeNavigation = screen.getByRole("navigation", { name: "Finance sections" });
    expect(within(financeNavigation).getAllByRole("button").map((button) => button.textContent)).toEqual([
      "Overview", "Goals", "Activity", "More",
    ]);

    await waitFor(() => expect(apiMock.mock.calls.map(([path]) => path)).toEqual(expect.arrayContaining([
      "/finance/spaces",
      "/finance/overview?scope=mine",
    ])));
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/transactions?"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("partner-private-id"))).toBe(false);
    for (const call of apiMock.mock.calls) expect(call[3]).toBe(false);
  });

  it("keeps the same four calm destinations for every role and puts advanced tools behind More", async () => {
    mockFinanceReads();
    const { props } = renderFinance({ section: "more", simpleDefault: true, preferenceOwner: "family:kat" });

    expect(await screen.findByRole("heading", { name: "More Finance tools" })).toBeInTheDocument();
    const navigation = screen.getByRole("navigation", { name: "Finance sections" });
    expect(within(navigation).getAllByRole("button").map((button) => button.textContent)).toEqual([
      "Overview", "Goals", "Activity", "More",
    ]);
    expect(screen.queryByRole("button", { name: "Simple" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Full" })).not.toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Advanced Finance tools" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /AnalysisBuild your own analysis/ }));
    expect(props.onSectionChange).toHaveBeenCalledWith("explore");
    expect(window.localStorage.getItem("hausklar:finance:family:kat:display-mode")).toBeNull();
    expect(apiMock.mock.calls.map(([path]) => path)).toEqual(["/finance/spaces"]);
  });

  it("classifies every normal spend in Activity and treats confirmed transfers as neutral", async () => {
    const uncategorised: FinanceTransaction = {
      ...personalTransactions[0],
      id: "transaction-unknown",
      description: "CORNER SHOP",
      merchant_text: "Corner shop",
      primary_category_name: "Uncategorised",
      primary_spending_type: "UNCATEGORISED",
    };
    const transfer: FinanceTransaction = {
      ...personalTransactions[0],
      id: "transaction-transfer",
      description: "MOVE TO SAVINGS",
      merchant_text: "Move to savings",
      amount_minor: -50_000,
      primary_category_name: "Uncategorised",
      primary_spending_type: "UNCATEGORISED",
      relations: [{
        id: "relation-transfer",
        from_transaction_id: "transaction-transfer",
        to_transaction_id: "transaction-transfer-other-side",
        relation_type: "INTERNAL_TRANSFER",
        status: "CONFIRMED",
        method: "AUTO",
        confidence_bps: 10_000,
      }],
    };
    const income: FinanceTransaction = {
      ...personalTransactions[0],
      id: "transaction-income",
      description: "SALARY",
      merchant_text: "Salary",
      amount_minor: 400_000,
      primary_category_name: "Uncategorised",
      primary_spending_type: "UNCATEGORISED",
    };
    const splitSpend: FinanceTransaction = {
      ...personalTransactions[0],
      id: "transaction-split",
      description: "DEPARTMENT STORE",
      merchant_text: "Department store",
      amount_minor: -12_345,
      primary_category_name: "Quinn",
      primary_spending_type: "FLEXIBLE",
      splits: [{
        id: "split-groceries",
        transaction_id: "transaction-split",
        amount_minor: -7_345,
        category_id: "category-groceries",
        category_name: "Quinn",
        spending_type: "FLEXIBLE",
        label: "Weekly food",
        created_at: "2026-07-11T10:00:00Z",
      }, {
        id: "split-clothing",
        transaction_id: "transaction-split",
        amount_minor: -5_000,
        category_id: "category-clothing",
        category_name: "Clothing",
        spending_type: "DISCRETIONARY",
        label: null,
        created_at: "2026-07-11T10:00:00Z",
      }],
    };
    mockFinanceReads({ transactions: [personalTransactions[0], uncategorised, transfer, income, splitSpend] });
    renderFinance({ section: "activity", simpleDefault: true, preferenceOwner: "family:kat" });

    expect(await screen.findByRole("heading", { name: "Bank activity" })).toBeInTheDocument();
    const categorisedRow = screen.getByRole("link", { name: /Tesco/ });
    expect(within(categorisedRow).getByText("Quinn")).toBeInTheDocument();
    const uncategorisedRow = screen.getByRole("link", { name: /Corner shop/ });
    expect(within(uncategorisedRow).getByText("Uncategorised")).toHaveClass("is-uncategorised");
    const splitRow = screen.getByRole("link", { name: /Department store/ });
    expect(within(splitRow).getByText("Split · 2 categories")).toBeInTheDocument();
    expect(within(splitRow).queryByText("Quinn")).not.toBeInTheDocument();
    fireEvent.click(splitRow);
    let dialog = await screen.findByRole("dialog", { name: "Department store" });
    expect(within(dialog).getByText("Split · 2 categories")).toBeInTheDocument();
    expect(within(dialog).getByText("Quinn")).toBeInTheDocument();
    expect(within(dialog).getByText("Flexible · Weekly food")).toBeInTheDocument();
    expect(within(dialog).getByText("-£73.45")).toBeInTheDocument();
    expect(within(dialog).getByText("Clothing")).toBeInTheDocument();
    expect(within(dialog).getByText("Discretionary")).toBeInTheDocument();
    expect(within(dialog).getByText("-£50.00")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    const transferRow = screen.getByRole("link", { name: /Move to savings/ });
    expect(within(transferRow).queryByText("Uncategorised")).not.toBeInTheDocument();
    fireEvent.click(transferRow);
    dialog = await screen.findByRole("dialog", { name: "Move to savings" });
    expect(within(dialog).getByText("Transfer")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    const incomeRow = screen.getByRole("link", { name: /Salary/ });
    expect(within(incomeRow).queryByText("Uncategorised")).not.toBeInTheDocument();
    fireEvent.click(incomeRow);
    dialog = await screen.findByRole("dialog", { name: "Salary" });
    expect(within(dialog).getByText("Income")).toBeInTheDocument();
    expect(within(dialog).queryByText("Uncategorised")).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Recent purchases" })).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path.includes("by-transaction"))).toBe(false);
  });

  it("shows only deliberately shared rows in Household Activity", async () => {
    mockFinanceReads();
    renderFinance({ section: "activity", scope: "household" });

    expect(await screen.findByRole("heading", { name: "Bank activity" })).toBeInTheDocument();
    expect(screen.queryByText("Only deliberately shared Household transactions.")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /Shared Grocer/ })).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /Tesco/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /Deutsche Bahn/ })).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path.includes("personal-real-id"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => (
      path === "/finance/transactions?space_id=household-real-id&offset=0&limit=200"
    ))).toBe(true);
  });

  it("does no reconciliation or data-quality work until its quiet More disclosure opens", async () => {
    mockFinanceReads();
    renderFinance({ section: "more" });

    expect(await screen.findByRole("heading", { name: "More Finance tools" })).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases?"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases/review/high-impact?"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/patterns/scan?"))).toBe(false);

    fireEvent.click(screen.getByText("Review receipts and purchases"));
    expect(await screen.findByRole("heading", { name: "Recent purchases" })).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases?"))).toBe(true);
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases/review/high-impact?"))).toBe(false);
    fireEvent.click(screen.getByText("Review purchases"));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => (
      path.startsWith("/finance/purchases/review/high-impact?")
    ))).toBe(true));
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/patterns/scan?"))).toBe(false);

    fireEvent.click(screen.getByText("Check data quality"));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => (
      path.startsWith("/finance/patterns/scan?")
    ))).toBe(true));
  });

  it("opens advanced purchase review work immediately for a More line deep link", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=more&line=line-apples");
    mockFinanceReads();
    renderFinance({ section: "more" });

    expect(await screen.findByRole("heading", { name: "Recent purchases" })).toBeInTheDocument();
    expect(screen.getByText("Review receipts and purchases").closest("details")).toHaveAttribute("open");
    window.history.replaceState({}, "", "/");
  });

  it("remembers the last scope and renders household Overview as aggregates without private rows", async () => {
    window.localStorage.setItem("hausklar:finance:family:dom:scope", "household");
    mockFinanceReads();
    const onScopeChange = vi.fn();
    const restored = renderFinance({ section: "overview", preferenceOwner: "family:dom", onScopeChange });
    await waitFor(() => expect(onScopeChange).toHaveBeenCalledWith("household"));
    restored.unmount();

    window.localStorage.clear();
    apiMock.mockClear();
    mockFinanceReads({ returnedSpaces: spaces.slice(0, 1) });
    renderFinance({ section: "overview", scope: "household", preferenceOwner: "family:dom" });
    expect(await screen.findByRole("heading", { name: "Spending this month" })).toBeInTheDocument();
    expect(screen.getByText("Combined household totals")).toBeInTheDocument();
    expect(screen.getByText("£1,125.00")).toBeInTheDocument();
    expect(screen.queryByText("Combined totals from linked accounts. Private transactions stay private.")).not.toBeInTheDocument();
    expect(screen.queryByText("Tesco")).not.toBeInTheDocument();
    expect(screen.queryByText("Deutsche Bahn")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.map(([path]) => path)).toEqual([
      "/finance/spaces",
      "/finance/overview?scope=household",
    ]);
  });

  it("keeps every visible shared goal in the personal Savings plan overview", async () => {
    const sharedGoals: FinanceGoal[] = [
      {
        ...personalGoals[0],
        id: "shared-house-goal",
        space_id: "household-real-id",
        name: "House deposit",
        deadline: "2030-08-02",
      },
      {
        ...personalGoals[0],
        id: "shared-holiday-goal",
        space_id: "household-real-id",
        name: "Synthetic public demo record 16",
        deadline: "2027-06-01",
      },
    ];
    mockFinanceReads({ sharedGoals });
    renderFinance({ section: "goals" });

    expect(await screen.findByRole("heading", { name: "House deposit" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Synthetic public demo record 16" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "2 shared savings goals" })).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("partner-private-id"))).toBe(false);
  });

  it("refetches the selected accessible space without showing the previous private scope", async () => {
    let resolveHouseholdAccounts: (value: FinanceAccount[]) => void = () => undefined;
    let resolveHouseholdSummary: (value: FinanceLedgerSummary) => void = () => undefined;
    let deferHousehold = false;
    apiMock.mockImplementation((path) => {
      if (path === "/finance/spaces") return Promise.resolve(spaces);
      if (path === "/finance/accounts?space_id=personal-real-id") {
        return Promise.resolve(personalAccounts);
      }
      if (path === "/finance/summary?space_id=personal-real-id") {
        return Promise.resolve(personalSummary);
      }
      if (path === "/finance/transactions?space_id=personal-real-id&limit=12") {
        return Promise.resolve(personalTransactions);
      }
      if (path === "/finance/commitments?space_id=personal-real-id") {
        return Promise.resolve(personalCommitments);
      }
      if (path === "/finance/reserves?space_id=personal-real-id") {
        return Promise.resolve(personalReserves);
      }
      if (path === "/finance/goals?space_id=personal-real-id") {
        return Promise.resolve(personalGoals);
      }
      if (path === "/finance/accounts?space_id=household-real-id" || path === "/finance/accounts?space_id=household-real-id&exclude_own_shared_copies=true") {
        if (!deferHousehold) return Promise.resolve(householdAccounts);
        return new Promise((resolve) => { resolveHouseholdAccounts = resolve; });
      }
      if (path === "/finance/summary?space_id=household-real-id" || path === "/finance/summary?space_id=household-real-id&exclude_own_shared_copies=true") {
        if (!deferHousehold) return Promise.resolve(householdSummary);
        return new Promise((resolve) => { resolveHouseholdSummary = resolve; });
      }
      if (path === "/finance/transactions?space_id=household-real-id&limit=12" || path === "/finance/transactions?space_id=household-real-id&limit=12&exclude_own_shared_copies=true") {
        if (!deferHousehold) return Promise.resolve(householdTransactions);
        return Promise.resolve([]);
      }
      if (path === "/finance/commitments?space_id=household-real-id" || path === "/finance/commitments?space_id=household-real-id&exclude_own_shared_copies=true") return Promise.resolve([]);
      if (path === "/finance/reserves?space_id=household-real-id" || path === "/finance/reserves?space_id=household-real-id&exclude_own_shared_copies=true") return Promise.resolve([]);
      if (path === "/finance/goals?space_id=household-real-id" || path === "/finance/goals?space_id=household-real-id&exclude_own_shared_copies=true") return Promise.resolve([]);
      return Promise.reject(new Error(`Unexpected API request: ${path}`));
    });

    function Harness() {
      const [section, setSection] = useState<FinanceSection>("coach");
      const [scope, setScope] = useState<FinanceScope>("mine");
      return (
        <FinanceView
          hasFamilyAccount
          online
          section={section}
          scope={scope}
          onSectionChange={setSection}
          onScopeChange={setScope}
          locale="en"
        />
      );
    }

    render(<Harness />);
    expect(await screen.findAllByText("£1,234.56")).not.toHaveLength(0);
    deferHousehold = true;
    const callsBeforeScopeChange = apiMock.mock.calls.length;
    fireEvent.click(screen.getByRole("button", { name: "Household" }));

    expect(screen.queryByText("£1,234.56")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Loading financial records")).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path, init, retry, allowOfflineQueue]) => (
      path === "/finance/accounts?space_id=household-real-id"
        && init?.signal instanceof AbortSignal
        && retry === true
        && allowOfflineQueue === false
    ))).toBe(true);
    await waitFor(() => expect(apiMock.mock.calls.length).toBeGreaterThan(callsBeforeScopeChange));
    expect(apiMock.mock.calls.slice(callsBeforeScopeChange).map(([path]) => path)).toEqual(expect.arrayContaining([
      "/finance/accounts?space_id=household-real-id",
      "/finance/summary?space_id=household-real-id",
      "/finance/commitments?space_id=household-real-id",
      "/finance/goals?space_id=household-real-id",
      "/finance/ai-consent",
    ]));
    expect(apiMock.mock.calls.slice(callsBeforeScopeChange).map(([path]) => String(path)).filter((path) => path.includes("personal-real-id"))).toEqual([]);

    resolveHouseholdAccounts(householdAccounts);
    resolveHouseholdSummary(householdSummary);
    expect(await screen.findAllByText("£777.00")).not.toHaveLength(0);
    expect(screen.queryByText("Daily current")).not.toBeInTheDocument();
  });

  it("keeps Insights focused on changes and savings instead of repeating Activity", async () => {
    mockFinanceReads();
    renderFinance({ section: "explore" });

    expect(await screen.findByRole("heading", { name: "Insights" })).toBeInTheDocument();
    expect(await screen.findByRole("heading", { name: "At a glance" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Recent transactions" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Correct this transaction with text" })).not.toBeInTheDocument();
  });

  it("never falls back to personal data when the household space is inaccessible", async () => {
    mockFinanceReads({ returnedSpaces: spaces.slice(0, 1) });
    renderFinance({ scope: "household" });

    expect(await screen.findByRole("heading", { name: "This Finance view isn't available" }))
      .toBeInTheDocument();
    expect(screen.getByText(/Private records remain hidden/i)).toBeInTheDocument();
    expect(apiMock.mock.calls.length).toBe(1);
  });

  it("loads scoped purchases only in More, fetches details on demand and confirms a reviewed match", async () => {
    const matches: Array<{ purchaseID: string; body: unknown }> = [];
    mockFinanceReads({
      onPurchaseMatch: (purchaseID, body) => {
        matches.push({ purchaseID, body });
        return {
          ...amazonPurchaseDetail,
          match_status: "MATCHED",
          unmatched_purchase_minor: 0,
          payment_allocations: [
            {
              id: "amazon-reviewed-allocation",
              allocation_ref: "reviewed-1",
              transaction_id: "transaction-gbp",
              line_id: null,
              tender_kind: "bank",
              allocated_minor: 2_000,
              transaction_amount_minor: -2_599,
              transaction_date: "2026-07-31",
              match_method: "REVIEWED",
              status: "CONFIRMED",
            },
          ],
        };
      },
    });

    function Harness() {
      const [section, setSection] = useState<FinanceSection>("more");
      return (
        <FinanceView
          hasFamilyAccount
          online
          section={section}
          scope="mine"
          onSectionChange={setSection}
          onScopeChange={vi.fn()}
          locale="en"
        />
      );
    }

    render(<Harness />);
    expect(await screen.findByRole("heading", { name: "More Finance tools" })).toBeInTheDocument();
    fireEvent.click(screen.getByText("Review receipts and purchases"));
    expect(await screen.findByRole("heading", { name: "Recent purchases" })).toBeInTheDocument();
    expect(screen.getByText("Can't read this source")).toBeInTheDocument();
    expect(screen.getByText("This sender format cannot be read yet.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toHaveTextContent("Matched");
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toHaveTextContent("£45.80");
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toHaveTextContent("£5.00");
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toHaveTextContent("£40.80");
    expect(screen.getByRole("button", { name: "Open purchase: Amazon" })).toHaveTextContent("Partly matched");

    const purchaseSearch = screen.getByLabelText("Search merchant or item");
    fireEvent.change(purchaseSearch, { target: { value: "Braeburn" } });
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open purchase: Amazon" })).not.toBeInTheDocument();
    fireEvent.change(purchaseSearch, { target: { value: "" } });
    fireEvent.change(screen.getByLabelText("Payment match"), { target: { value: "PARTIAL" } });
    expect(screen.getByRole("button", { name: "Open purchase: Amazon" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open purchase: Tesco" })).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Payment match"), { target: { value: "ALL" } });

    const purchaseReadPaths = apiMock.mock.calls
      .map(([path]) => path)
      .filter((path) => path.startsWith("/finance/purchases?") || path.startsWith("/finance/purchases/inbox?"));
    expect(purchaseReadPaths).toEqual([
      "/finance/purchases?space_id=personal-real-id&offset=0&limit=50",
      "/finance/purchases/inbox?space_id=personal-real-id&offset=0&limit=50",
      "/finance/purchases?space_id=household-real-id&offset=0&limit=50&exclude_own_shared_copies=true",
      "/finance/purchases/inbox?space_id=household-real-id&offset=0&limit=50&exclude_own_shared_copies=true",
    ]);
    expect(apiMock.mock.calls.some(([path]) => path.includes("partner-private-id"))).toBe(false);
    for (const call of apiMock.mock.calls) expect(call[call.length - 1]).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Open purchase: Tesco" }));
    let dialog = await screen.findByRole("dialog", { name: "Tesco" });
    expect(await within(dialog).findAllByText("Braeburn apples")).not.toHaveLength(0);
    expect(within(dialog).getByText("2.5 kg")).toBeInTheDocument();
    expect(within(dialog).getAllByText("Nappies")).not.toHaveLength(0);
    expect(within(dialog).getAllByText("£3.50")).not.toHaveLength(0);
    expect(within(dialog).getAllByText("£7.00")).not.toHaveLength(0);
    expect(within(dialog).getAllByText("£2.70")).not.toHaveLength(0);
    expect(within(dialog).getAllByText("£5.00")).not.toHaveLength(0);
    expect(within(dialog).getByText("Card · £45.80")).toBeInTheDocument();
    expect(within(dialog).queryByText("Provider reference: provider-789")).not.toBeInTheDocument();
    expect(within(dialog).getByText("Exact bank match · Confirmed")).toBeInTheDocument();
    expect(within(dialog).queryByText("never render this")).not.toBeInTheDocument();
    expect(within(dialog).queryByText("Review payment match")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.filter(([path]) => path === "/finance/purchases/tesco-purchase")).toHaveLength(1);

    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    expect(screen.getByRole("button", { name: "Open purchase: Tesco" })).toHaveTextContent("2 items");

    fireEvent.click(screen.getByRole("button", { name: "Open purchase: Amazon" }));
    dialog = await screen.findByRole("dialog", { name: "Amazon" });
    fireEvent.click(await within(dialog).findByText("Review payment match"));
    const transactionChoice = await within(dialog).findByRole("checkbox", { name: "Select transaction: Tesco" });
    expect(within(dialog).queryByText("Deutsche Bahn")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path, , retry, allowOfflineQueue]) => (
      path === "/finance/transactions?space_id=personal-real-id&offset=0&limit=200"
        && retry === true
        && allowOfflineQueue === false
    ))).toBe(true);
    fireEvent.click(transactionChoice);
    expect(within(dialog).getByLabelText("Allocation amount")).toHaveValue("20.00");
    const confirm = within(dialog).getByRole("button", { name: "Confirm exact match" });
    expect(confirm).toBeEnabled();
    fireEvent.click(confirm);
    await waitFor(() => expect(matches).toEqual([{
      purchaseID: "amazon-purchase",
      body: {
        reviewed: true,
        allocations: [{ transaction_id: "transaction-gbp", allocated_minor: 2_000 }],
      },
    }]));
    const matchCall = apiMock.mock.calls.find(([path]) => path === "/finance/purchases/amazon-purchase/match");
    expect(matchCall?.[3]).toBe(false);
    await waitFor(() => expect(within(dialog).getByText("Reviewed match · Confirmed")).toBeInTheDocument());
    expect(within(dialog).queryByText("Review payment match")).not.toBeInTheDocument();
  });

  it("loads older bank activity and purchases from the API", async () => {
    const fullTransactionPage = Array.from({ length: 200 }, (_, index) => ({
      ...personalTransactions[0],
      id: `transaction-page-${index}`,
      description: `Transaction ${index}`,
      merchant_text: `Merchant ${index}`,
    }));
    const fullPurchasePage = Array.from({ length: 50 }, (_, index) => ({
      ...personalPurchases[0],
      id: `purchase-page-${index}`,
      merchant: `Purchase ${index}`,
    }));
    mockFinanceReads({ transactions: fullTransactionPage, purchases: fullPurchasePage });
    const activity = renderFinance({ section: "activity" });

    fireEvent.click(await screen.findByRole("button", { name: "Load more" }));
    await waitFor(() => expect(apiMock.mock.calls.some(([path]) => (
      path === "/finance/transactions?space_id=personal-real-id&offset=200&limit=200"
    ))).toBe(true));
    expect(apiMock.mock.calls.some(([path]) => path.startsWith("/finance/purchases?"))).toBe(false);
    activity.unmount();

    mockFinanceReads({ transactions: fullTransactionPage, purchases: fullPurchasePage });
    renderFinance({ section: "more" });
    fireEvent.click(await screen.findByText("Review receipts and purchases"));
    fireEvent.click(await screen.findByRole("button", { name: "Load more" }));
    await waitFor(() => expect(apiMock.mock.calls.map(([path]) => path).filter((path) => (
      path.startsWith("/finance/purchases?")
    ))).toContain("/finance/purchases?space_id=personal-real-id&offset=50&limit=50"));
  });

  it("creates exact commitments and reserves only in the selected space without float rounding", async () => {
    const writes: Array<{ path: string; body: unknown }> = [];
    const planningWrites = () => writes.filter(({ path }) => path.startsWith("/finance/commitments?") || path.startsWith("/finance/reserves?"));
    mockFinanceReads({
      onWrite: (path, body) => {
        writes.push({ path, body });
        return {};
      },
    });
    renderFinance({ section: "planning" });

    const advancedHeading = await screen.findByRole("heading", { name: "Forecast and commitments" });
    const outlookHeading = await screen.findByRole("heading", { name: "Money outlook" });
    expect(advancedHeading.compareDocumentPosition(outlookHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByRole("button", { name: "Back to More" })).toBeInTheDocument();
    fireEvent.click(await screen.findByText("Commitments, reserves and assumptions"));
    await screen.findByRole("heading", { name: "Plans" });
    fireEvent.click(screen.getByRole("button", { name: "Add a bill" }));
    let dialog = screen.getByRole("dialog", { name: "Add a bill" });
    const commitmentDestination = within(dialog).getByLabelText("Save in") as HTMLSelectElement;
    expect(commitmentDestination).toHaveValue("personal-real-id");
    expect(within(commitmentDestination).getAllByRole("option").map((option) => option.textContent))
      .toEqual(["Alex", "Family"]);

    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Council tax" } });
    fireEvent.change(within(dialog).getByLabelText("Amount"), { target: { value: "10.001" } });
    fireEvent.change(within(dialog).getByLabelText("Already put by"), { target: { value: "0.02" } });
    fireEvent.change(within(dialog).getByLabelText("Due date"), { target: { value: "2026-09-01" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }));
    expect(await within(dialog).findByText(/no more than two decimal places/i)).toBeInTheDocument();
    expect(planningWrites()).toHaveLength(0);

    fireEvent.change(within(dialog).getByLabelText("Amount"), { target: { value: "10.01" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(planningWrites()).toHaveLength(1));
    expect(planningWrites()[0]).toEqual({
      path: "/finance/commitments?space_id=personal-real-id",
      body: expect.objectContaining({
        name: "Council tax",
        amount_mode: "EXACT",
        exact_minor: 1001,
        already_reserved_minor: 2,
        reviewed_dates: ["2026-09-01"],
        currency: "GBP",
      }),
    });
    const commitmentCall = apiMock.mock.calls.find(([path, init]) => (
      path.startsWith("/finance/commitments?") && init?.method === "POST"
    ));
    expect(commitmentCall?.[3]).toBe(false);

    expect(await screen.findByText("Commitment added.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Set money aside" }));
    dialog = screen.getByRole("dialog", { name: "Set money aside" });
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Boiler" } });
    fireEvent.change(within(dialog).getByLabelText("Goal amount"), { target: { value: "500.00" } });
    fireEvent.change(within(dialog).getByLabelText("Set aside"), { target: { value: "125.25" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(planningWrites()).toHaveLength(2));
    expect(planningWrites()[1]).toEqual({
      path: "/finance/reserves?space_id=personal-real-id",
      body: expect.objectContaining({ target_minor: 50_000, allocated_minor: 12_525 }),
    });
  });

  it("opens commitment deep links and supports explicit edit and removal", async () => {
    const writes: Array<{ path: string; method: string; body: unknown }> = [];
    const commitmentWrites = () => writes.filter(({ path }) => path === "/finance/commitments/school-fees");
    window.history.replaceState({}, "", "/?view=finance&section=planning&commitment=school-fees");
    mockFinanceReads({
      onWrite: (path, body) => {
        const call = apiMock.mock.calls.at(-1);
        writes.push({ path, method: call?.[1]?.method ?? "", body });
        return {};
      },
    });
    renderFinance({ section: "planning" });

    let dialog = await screen.findByRole("dialog", { name: "Edit commitment" });
    expect(within(dialog).getByLabelText("Name")).toHaveValue("School fees");
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "School fees updated" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(commitmentWrites()[0]).toEqual({
      path: "/finance/commitments/school-fees",
      method: "PATCH",
      body: expect.objectContaining({
        name: "School fees updated",
        exact_minor: 12_500,
        already_reserved_minor: 2_500,
      }),
    }));
    expect(new URLSearchParams(window.location.search).has("commitment")).toBe(false);

    fireEvent.click(await screen.findByRole("button", { name: "Edit" }));
    dialog = screen.getByRole("dialog", { name: "Edit commitment" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Remove" }));
    const confirm = screen.getByRole("dialog", { name: "Remove commitment?" });
    fireEvent.click(within(confirm).getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(commitmentWrites()[1]).toEqual({
      path: "/finance/commitments/school-fees",
      method: "DELETE",
      body: undefined,
    }));
  });

  it("defaults goals to the household space and surfaces API errors before retry", async () => {
    let attempts = 0;
    const writes: Array<{ path: string; body: unknown }> = [];
    mockFinanceReads({
      onWrite: (path, body) => {
        if (path.startsWith("/finance/goals?")) {
          writes.push({ path, body });
          attempts += 1;
          if (attempts === 1) throw new Error("Goal service unavailable");
        }
        return {};
      },
    });
    renderFinance({ scope: "household", section: "planning" });

    fireEvent.click(await screen.findByText("Commitments, reserves and assumptions"));
    await screen.findByRole("heading", { name: "Plans" });
    fireEvent.click(screen.getByRole("button", { name: "Add a goal" }));
    const dialog = screen.getByRole("dialog", { name: "Add a goal" });
    const destination = within(dialog).getByLabelText("Save in") as HTMLSelectElement;
    expect(destination).toHaveValue("household-real-id");
    expect(within(destination).getAllByRole("option")).toHaveLength(1);
    expect(within(destination).queryByRole("option", { name: "Jordan" })).not.toBeInTheDocument();

    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Kitchen" } });
    fireEvent.change(within(dialog).getByLabelText("Goal amount"), { target: { value: "1000" } });
    fireEvent.change(within(dialog).getByLabelText("Set aside"), { target: { value: "50" } });
    fireEvent.change(within(dialog).getByLabelText("Deadline"), { target: { value: "2027-06-30" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Goal service unavailable");

    fireEvent.click(within(dialog).getByRole("button", { name: "Save" }));
    await waitFor(() => expect(writes).toHaveLength(2));
    expect(writes[1]).toEqual({
      path: "/finance/goals?space_id=household-real-id",
      body: expect.objectContaining({
        target_minor: 100_000,
        currently_allocated_minor: 5_000,
        deadline: "2027-06-30",
      }),
    });
    expect(await screen.findByText("Goal added.")).toBeInTheDocument();
  });

  it("shows the explicit Finance notice and supports consent grant and withdrawal", async () => {
    mockFinanceReads();
    renderFinance();

    await screen.findByRole("button", { name: "Ask Finance Coach" });
    expect(document.getElementById("finance-coach-disclosure")).toHaveAttribute("open");
    expect(await screen.findByRole("heading", { name: "Finance Coach privacy" })).toBeInTheDocument();
    expect(screen.getByText(consentDisclosure)).toBeInTheDocument();
    const question = screen.getByLabelText("Question");
    fireEvent.change(question, { target: { value: "What changed this month?" } });
    expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
    expect(apiMock.mock.calls.some(([path]) => path === "/finance/coach/ask")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Agree for Alex" }));
    await screen.findByRole("button", { name: "Withdraw for Alex" });
    fireEvent.click(screen.getByRole("button", { name: "Agree for Family" }));
    await screen.findByRole("button", { name: "Withdraw for Family" });
    await waitFor(() => expect(screen.getByRole("button", { name: "Send" })).toBeEnabled());

    const consentWrites = apiMock.mock.calls.filter(([path, init]) => (
      path.startsWith("/finance/ai-consent") && ["PUT", "DELETE"].includes(init?.method ?? "")
    ));
    expect(consentWrites).toHaveLength(2);
    expect(JSON.parse(String(consentWrites[0][1]?.body))).toEqual({
      space_id: "personal-real-id",
      accepted: true,
      consent_version: "finance-ai-v1/openai/coach-model",
    });
    expect(JSON.parse(String(consentWrites[1][1]?.body))).toEqual({
      space_id: "household-real-id",
      accepted: true,
      consent_version: "finance-ai-v1/openai/coach-model",
    });
    expect(consentWrites[0][3]).toBe(false);
    expect(consentWrites[1][3]).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Withdraw for Alex" }));
    await waitFor(() => expect(apiMock.mock.calls.some(([path, init, , allowOfflineQueue]) => (
      path === "/finance/ai-consent?space_id=personal-real-id"
        && init?.method === "DELETE"
        && allowOfflineQueue === false
    ))).toBe(true));
    await waitFor(() => expect(screen.getByRole("button", { name: "Send" })).toBeDisabled());
  });

  it("sends only on explicit action and renders the checked answer contract", async () => {
    const questions: unknown[] = [];
    mockFinanceReads({
      consents: financeConsents.map((consent) => ({
        ...consent,
        consented: true,
        consented_at: recentTimestamp,
      })),
      onCoachAsk: (body) => {
        questions.push(body);
        return checkedCoachAnswer;
      },
    });
    renderFinance();

    fireEvent.click(await screen.findByRole("button", { name: "Ask Finance Coach" }));
    const question = await screen.findByLabelText("Question");
    fireEvent.change(question, { target: { value: "  How much room is left?  " } });
    expect(questions).toHaveLength(0);
    const send = screen.getByRole("button", { name: "Send" });
    await waitFor(() => expect(send).toBeEnabled());
    fireEvent.click(send);

    expect(await screen.findByRole("heading", { name: "Your spending stayed within the plan" }))
      .toBeInTheDocument();
    expect(questions).toEqual([{
      question: "How much room is left?",
      scope: "mine",
      space_id: "personal-real-id",
      conversation: [],
    }]);
    expect(screen.getByText("Household costs were lower than the previous checked period."))
      .toBeInTheDocument();
    expect(screen.getAllByText(/based on records through/i).length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText("Nursery and groceries were checked against posted transactions."))
      .toBeInTheDocument();
    expect(screen.getByText("£120.00–£150.00")).toBeInTheDocument();
    expect(screen.getByText("No new card transactions after the data-through time"))
      .toBeInTheDocument();
    expect(screen.getByText("Check the latest card transactions before a large purchase."))
      .toBeInTheDocument();
    const askCall = apiMock.mock.calls.find(([path]) => path === "/finance/coach/ask");
    expect(askCall?.[3]).toBe(false);
  });

  it("keeps normal Finance usable when household consent or the coach service blocks an answer", async () => {
    let attempt = 0;
    const coachBodies: unknown[] = [];
    mockFinanceReads({
      consents: financeConsents.map((consent) => ({
        ...consent,
        consented: true,
        consented_at: recentTimestamp,
      })),
      onCoachAsk: (body) => {
        coachBodies.push(body);
        attempt += 1;
        throw new ApiError(attempt === 1 ? "Consent required" : "Unavailable", attempt === 1 ? 428 : 503);
      },
    });
    renderFinance({ scope: "household" });

    fireEvent.click(await screen.findByRole("button", { name: "Ask Finance Coach" }));
    const question = await screen.findByLabelText("Question");
    expect(screen.queryByRole("button", { name: /for Alex$/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Withdraw for Family" })).toBeInTheDocument();
    fireEvent.change(question, { target: { value: "Can the household afford this?" } });
    const send = screen.getByRole("button", { name: "Send" });
    await waitFor(() => expect(send).toBeEnabled());
    fireEvent.click(send);
    expect(await screen.findByText(/Another adult still needs to agree/i)).toBeInTheDocument();
    expect(coachBodies[0]).toMatchObject({ scope: "household", space_id: "household-real-id" });
    expect(screen.getByText("Shared current")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Goals" })).toBeInTheDocument();

    await waitFor(() => expect(send).toBeEnabled());
    fireEvent.click(send);
    expect(await screen.findByText(/Finance Coach is temporarily unavailable/i)).toBeInTheDocument();
    expect(screen.getByText("Shared current")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Goals" })).toBeInTheDocument();
  });

  it("keeps ordinary older imports quiet and formats German euro amounts", async () => {
    const staleAccounts = personalAccounts.map((account) => ({
      ...account,
      data_through_at: "2020-01-01T00:00:00Z",
    }));
    const staleSharedAccounts = householdAccounts.map((account) => ({
      ...account,
      data_through_at: "2020-01-01T00:00:00Z",
    }));
    mockFinanceReads({
      accounts: staleAccounts,
      summary: { ...personalSummary, data_through_at: "2020-01-01T00:00:00Z" },
      transactions: personalTransactions.map((transaction) => ({
        ...transaction,
        data_through_at: "2020-01-01T00:00:00Z",
      })),
      sharedAccounts: staleSharedAccounts,
      sharedSummary: { ...householdSummary, data_through_at: "2020-01-01T00:00:00Z" },
      sharedTransactions: householdTransactions.map((transaction) => ({
        ...transaction,
        data_through_at: "2020-01-01T00:00:00Z",
      })),
    });
    renderFinance({ locale: "de" });

    expect(await screen.findByRole("heading", { name: "Dieser Monat mit deinem Geld" }))
      .toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Was auf den Konten ist" })).toBeInTheDocument();
    expect(screen.queryByText(/2020/)).not.toBeInTheDocument();
    expect(screen.getAllByText(/98,76\s*€/)).not.toHaveLength(0);
    expect(screen.getByRole("button", { name: "Aktivität" })).toBeInTheDocument();
  });
});
