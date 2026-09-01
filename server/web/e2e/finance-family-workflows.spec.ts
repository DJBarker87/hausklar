import { expect, test, type Page, type Route } from "@playwright/test";

const user = {
  id: "dom",
  name: "Alex",
  email: "demo-person-39@example.invalid",
  role: "admin",
  priority: 5,
  family_id: "family",
  must_change_password: false,
};

const spaces = [
  { id: "personal-space", kind: "personal", name: "Alex", is_default: true },
  { id: "household-space", kind: "household", name: "Household", is_default: false },
  // A faulty or older server response must not make a partner's private space
  // selectable or cause the browser to request anything from it.
  { id: "partner-private", kind: "personal", name: "Morgan private", is_default: false },
];

function account(id: string, spaceID: string, label: string) {
  return {
    id,
    space_id: spaceID,
    label,
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
    fresh_through_date: "2026-08-02",
    data_through_at: "2026-08-02T12:00:00Z",
    balance: {
      booked_minor: 125_000,
      available_minor: 120_000,
      credit_limit_minor: null,
      provider_at: "2026-08-02T12:00:00Z",
      observed_at: "2026-08-02T12:00:00Z",
    },
  };
}

const accountsBySpace = {
  "personal-space": [account("personal-current", "personal-space", "Alex private current")],
  "household-space": [account("household-current", "household-space", "Household current")],
  "partner-private": [account("partner-current", "partner-private", "Morgan secret account")],
};

function transaction(id: string, spaceID: string, accountID: string, merchant: string, amountMinor: number) {
  return {
    id,
    space_id: spaceID,
    account_id: accountID,
    canonical_date: "2026-08-02",
    amount_minor: amountMinor,
    currency: "GBP",
    state: "POSTED",
    transaction_kind: "CASEY",
    source_kind: "PROVIDER",
    description: merchant.toUpperCase(),
    merchant_text: merchant,
    merchant_id: null,
    primary_category_id: null,
    superseded_by_id: null,
    data_through_at: "2026-08-02T12:00:00Z",
  };
}

const transactionsBySpace = {
  "personal-space": [transaction("personal-transaction", "personal-space", "personal-current", "Alex private grocer", -2_500)],
  "household-space": [transaction("household-transaction", "household-space", "household-current", "Household Grocer", -4_580)],
  "partner-private": [transaction("partner-transaction", "partner-private", "partner-current", "Morgan private purchase", -9_999)],
};

function purchase(id: string, spaceID: string, merchant: string, totalMinor: number) {
  return {
    id,
    space_id: spaceID,
    merchant,
    item_descriptions: ["Apples", "Nappies"],
    order_reference: "ORDER-1",
    purchased_on: "2026-08-02",
    currency: "GBP",
    lines_subtotal_minor: totalMinor,
    shipping_minor: 0,
    vat_included_minor: 0,
    order_discount_minor: 0,
    final_total_minor: totalMinor,
    refunded_minor: 0,
    behavioural_net_minor: totalMinor,
    status: "fulfilled",
    source_kind: "tesco_order",
    match_status: "MATCHED",
    unmatched_purchase_minor: 0,
    unmatched_refund_minor: 0,
    cashflow_source: "canonical_transactions",
    purchase_total_added_to_cashflow: false,
    supersedes_purchase_id: null,
    superseded_by_id: null,
    created_at: "2026-08-02T12:00:00Z",
  };
}

const personalPurchase = purchase("personal-purchase", "personal-space", "Alex private order", 2_500);
const householdPurchase = purchase("household-purchase", "household-space", "Household Grocer", 4_580);
const partnerPurchase = purchase("partner-purchase", "partner-private", "Morgan private order", 9_999);
const purchasesBySpace = {
  "personal-space": [personalPurchase],
  "household-space": [householdPurchase],
  "partner-private": [partnerPurchase],
};

const householdPurchaseDetail = {
  ...householdPurchase,
  evidence: {
    id: "household-evidence",
    space_id: "household-space",
    external_source_id: "fixture-household-order",
    source_kind: "tesco_order",
    corrects_source_id: null,
    parser_version: "fixture-v1",
    extraction_status: "PARSED",
    confidence_bps: 9_900,
    raw_payload: {},
    issues: [],
    storage_area: "finance-evidence",
    storage_key: null,
    received_at: "2026-08-02T12:00:00Z",
    parsed_at: "2026-08-02T12:01:00Z",
    created_at: "2026-08-02T12:00:00Z",
    files: [{ id: "household-receipt", storage_status: "STORED" }],
  },
  lines: [{
    id: "apples",
    line_ref: "line-1",
    position: 1,
    line_kind: "product",
    raw_description: "Braeburn apples",
    quantity_decimal: "2",
    unit_description: "bags",
    unit_price_minor: 2_290,
    line_gross_minor: 4_580,
    line_discount_minor: 0,
    line_net_minor: 4_580,
    evidence_status: "observed_structured",
    source_refs: [],
    seller: null,
    product_reference: null,
    replaces_description: null,
  }],
  tenders: [{
    id: "household-tender",
    tender_ref: "tender-1",
    tender_kind: "card",
    amount_minor: 4_580,
    provider_transaction_id: "provider-1",
    card_suffix: "4321",
    source_refs: [],
  }],
  refunds: [],
  payment_allocations: [{
    id: "household-allocation",
    allocation_ref: "allocation-1",
    transaction_id: "household-transaction",
    line_id: null,
    tender_kind: "card",
    allocated_minor: 4_580,
    transaction_amount_minor: -4_580,
    transaction_date: "2026-08-02",
    match_method: "AUTO_EXACT",
    status: "CONFIRMED",
  }],
};

const reportPreference = {
  id: "preference-1",
  space_id: "personal-space",
  locale: "en",
  daily_time: "07:00:00",
  enabled: true,
  notification_channel: "IN_APP",
  notification_mode: "ACTION_ONLY",
  show_more_by_default: false,
  quiet_hours_start: null,
  quiet_hours_end: null,
  underfunded_commitment_threshold_minor: 5_000,
  goal_movement_threshold_minor: 5_000,
  missed_payday_alerts: true,
  selected_return_deadline_alerts: true,
  ordinary_purchase_alerts: false,
  group_related_alerts: true,
  tone: "BALANCED",
  default_spend_account_id: "personal-current",
  extra_cash_buffer_minor: 0,
  writing_mode: "LOCAL",
  allow_dated_estimates: true,
  created_at: "2026-08-01T08:00:00Z",
  updated_at: "2026-08-01T08:00:00Z",
};

const consents = spaces.slice(0, 2).map((space) => ({
  space_id: space.id,
  space_kind: space.kind,
  consented: false,
  consent_version: "finance-ai-v1/openai/fixture-model",
  consented_at: null,
  provider: "openai",
  model: "fixture-model",
  store: false,
  background_processing: false,
  disclosure: "Only information you explicitly send is used.",
}));

const natWestConnection = {
  id: "natwest",
  space_id: "personal-space",
  can_manage: true,
  provider: "TRUELAYER",
  institution: "NatWest",
  status: "CONNECTED",
  granted_capabilities: ["accounts", "balances", "transactions"],
  consent_created_at: "2026-08-01T10:00:00Z",
  consent_expires_at: "2026-11-01T10:00:00Z",
  last_success_at: "2026-08-02T10:00:00Z",
  last_error_code: null,
  data_through_at: "2026-08-02",
  accounts: [],
};

type FinanceMockOptions = {
  onRequest?: (method: string, path: string, url: URL) => void;
};

async function json(route: Route, body: unknown, status = 200) {
  await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
}

async function mockFinanceApp(page: Page, options: FinanceMockOptions = {}) {
  const unexpected: string[] = [];
  let bankRefreshed = false;

  await page.context().route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace(/^\/api/, "");
    const method = request.method();
    options.onRequest?.(method, path, url);

    if (path === "/auth/web/session") return json(route, user);
    if (path === "/auth/onboarding") return json(route, {
      family_name: "HausKlar",
      people_count: 2,
      adult_count: 2,
      child_count: 0,
      calendar_commitment_count: 1,
      reminders_configured: true,
      selected_modules: [],
      dismissed: false,
      completed: true,
      should_show: false,
      first_success: true,
    });
    if (path === "/fitness/workspace") return json(route, { enabled: false, pinned: false });
    if (path === "/family/members") return json(route, []);
    if (path === "/finance/spaces") return json(route, spaces);

    const spaceID = url.searchParams.get("space_id") as keyof typeof accountsBySpace | null;
    if (path === "/finance/accounts" && spaceID) return json(route, accountsBySpace[spaceID] ?? []);
    if (path === "/finance/summary" && spaceID) return json(route, {
      space_id: spaceID,
      data_through_at: "2026-08-02T12:00:00Z",
      currencies: [],
    });
    if (path === "/finance/transactions" && spaceID) return json(route, transactionsBySpace[spaceID] ?? []);
    if (path === "/finance/purchases" && spaceID) return json(route, purchasesBySpace[spaceID] ?? []);
    if (path === "/finance/purchases/inbox" && spaceID) return json(route, []);
    if (path === "/finance/commitments" || path === "/finance/reserves" || path === "/finance/goals") return json(route, []);

    if (path === "/finance/purchases/by-transaction/household-transaction") return json(route, householdPurchaseDetail);
    if (path === "/finance/purchases/household-purchase") return json(route, householdPurchaseDetail);
    if (path === "/finance/calendar-items") return json(route, []);
    if (path === "/finance/calendar-items/prefill") return json(route, null);
    if (path === "/finance/projection-preferences") return json(route, { show_money: true, show_deliveries: true });
    if (path === "/finance/ai-consent") return json(route, consents);
    if (path === "/finance/shares") return json(route, []);
    if (path === "/finance/history") {
      const scope = url.searchParams.get("scope") === "household" ? "household" : "mine";
      return json(route, {
        scope,
        offset: 0,
        limit: 50,
        has_more: false,
        items: scope === "household" ? [{
          id: "household-history",
          record_type: "goals",
          record_id: "household-goal",
          changed_at: "2026-08-02T09:30:00Z",
          changed_by_name: "Morgan",
          changed_by_current_user: false,
          previous_values: { name: "Synthetic public demo record 16" },
        }] : [{
          id: "personal-history",
          record_type: "transactions",
          record_id: "personal-transaction",
          changed_at: "2026-08-02T09:30:00Z",
          changed_by_name: "Alex",
          changed_by_current_user: true,
          previous_values: { description: "Old description" },
        }],
      });
    }
    if (path === "/finance/report-preferences" && spaceID) return json(route, {
      ...reportPreference,
      id: `preference-${spaceID}`,
      space_id: spaceID,
      default_spend_account_id: spaceID === "personal-space" ? "personal-current" : "household-current",
    });
    if (path === "/reminders/push") return json(route, { configured: false, subscribed: false });
    if (path === "/reminders/preferences") return json(route, { quiet_start: "21:00", quiet_end: "07:00" });

    if (path === "/finance/connections/truelayer/start" && method === "POST") return json(route, {
      redirect_url: "https://auth.truelayer.com/session/test",
    });
    if (path === "/finance/connections" && spaceID) {
      if (spaceID !== "personal-space") return json(route, []);
      return json(route, [{
        ...natWestConnection,
        ...(bankRefreshed ? {
          last_success_at: "2026-08-03T10:00:00Z",
          derived_refreshes: [{
            hook: "FORECAST",
            status: "FAILED",
            last_attempt_at: "2026-08-03T10:00:00Z",
            last_success_at: "2026-08-02T10:00:00Z",
            last_error_code: "FORECAST_REFRESH_FAILED",
          }],
        } : {}),
      }]);
    }
    if (path === "/finance/connections/natwest/sync" && method === "POST") {
      bankRefreshed = true;
      return json(route, {
        connection_id: "natwest",
        status: "CONNECTED",
        accounts_seen: 1,
        balances_created: 1,
        source_created: 1,
        canonical_created: 1,
        duplicates: 0,
        pending_superseded: 0,
        partial_issue_codes: [],
        derived_refreshes: [{
          hook: "FORECAST",
          status: "FAILED",
          last_attempt_at: "2026-08-03T10:00:00Z",
          last_success_at: "2026-08-02T10:00:00Z",
          last_error_code: "FORECAST_REFRESH_FAILED",
        }],
      });
    }
    if (path === "/finance/email-addresses") return json(route, {
      configured: false,
      gmail_instructions: "",
      outlook_instructions: "",
      addresses: [],
    });
    if (path === "/finance/reports") return json(route, [{ id: "existing-report" }]);

    unexpected.push(`${method} ${path}${url.search}`);
    return json(route, { detail: "Unexpected mocked request" }, 501);
  });

  return unexpected;
}

async function waitForFinance(page: Page, heading: string) {
  await expect(page.getByRole("heading", { name: heading, exact: true })).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0, { timeout: 15_000 });
}

async function expectNoDocumentOverflow(page: Page) {
  const width = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(width.document, JSON.stringify(width)).toBeLessThanOrEqual(width.viewport + 1);
  expect(width.body, JSON.stringify(width)).toBeLessThanOrEqual(width.viewport + 1);
}

test("My finances and Household stay separate while receipts remain openable", async ({ page }) => {
  let requestedSpaces: string[] = [];
  const unexpected = await mockFinanceApp(page, {
    onRequest: (_method, path, url) => {
      if (path.startsWith("/finance/")) {
        const spaceID = url.searchParams.get("space_id");
        if (spaceID) requestedSpaces.push(spaceID);
      }
    },
  });

  await page.goto("/?view=finance&section=activity");
  await waitForFinance(page, "Bank activity");
  await expect(page.getByText("Alex private grocer", { exact: true })).toBeVisible();
  await expect(page.getByText("Household Grocer", { exact: true }).first()).toBeVisible();
  await expect(page.getByText(/Plans and spending money stay separate/)).toHaveCount(0);
  await expect(page.getByText(/Morgan private/)).toHaveCount(0);
  expect(requestedSpaces).toContain("personal-space");
  expect(requestedSpaces).toContain("household-space");
  expect(requestedSpaces).not.toContain("partner-private");

  requestedSpaces = [];
  await page.getByRole("button", { name: "Household", exact: true }).click();
  await waitForFinance(page, "Bank activity");
  await expect(page.getByText("Alex private grocer", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Household Grocer", { exact: true }).first()).toBeVisible();
  expect(requestedSpaces).toContain("household-space");
  expect(requestedSpaces).not.toContain("personal-space");
  expect(requestedSpaces).not.toContain("partner-private");

  await page.getByRole("navigation", { name: "Finance sections" }).getByRole("button", { name: "More", exact: true }).click();
  await expect(page.getByRole("heading", { name: "More Finance tools" })).toBeVisible();
  await page.getByText("Review receipts and purchases", { exact: true }).click();
  await expect(page.getByRole("heading", { name: "Recent purchases" })).toBeVisible();
  await page.getByRole("button", { name: "Open purchase: Household Grocer" }).click();
  const purchaseDialog = page.getByRole("dialog", { name: "Household Grocer" });
  await expect(purchaseDialog.getByRole("heading", { name: "Evidence" })).toBeVisible();
  const evidenceLink = purchaseDialog.getByRole("link", { name: "Open original evidence" });
  await expect(evidenceLink).toHaveAttribute(
    "href",
    "/api/finance/purchases/evidence/household-evidence/files/household-receipt",
  );
  await expectNoDocumentOverflow(page);
  expect(unexpected).toEqual([]);
});

test("Finance export control, history, and reconnect work without an offline Finance queue", async ({ page, context }) => {
  const financeWrites: string[] = [];
  const unexpected = await mockFinanceApp(page, {
    onRequest: (method, path) => {
      if (path.startsWith("/finance/") && !["GET", "HEAD", "OPTIONS"].includes(method)) {
        financeWrites.push(`${method} ${path}`);
      }
    },
  });

  await page.goto("/?view=finance&section=settings");
  await waitForFinance(page, "Export and change history");
  await expect(page.getByText(/never another adult's private records/i)).toBeVisible();
  const history = page.locator(".finance-history");
  await expect(history.getByText("Transaction", { exact: true })).toBeVisible();

  const exportLink = page.getByRole("link", { name: "Export Finance data" });
  await expect(exportLink).toHaveAttribute("href", "/api/finance/export");
  await expect(exportLink).toHaveAttribute("download", "");

  await page.getByRole("button", { name: "Household", exact: true }).click();
  await expect(page.getByText(/history shows Household changes only/i)).toBeVisible();
  await expect(history.getByText("Goal", { exact: true })).toBeVisible();
  await expect(history.getByText("Transaction", { exact: true })).toHaveCount(0);

  await context.setOffline(true);
  await expect(page.getByRole("heading", { name: "Finance needs a connection" })).toBeVisible();
  await expect(page.getByText("Financial records are not stored for offline use in this browser. Reconnect to view them.")).toBeVisible();
  expect(financeWrites).toEqual([]);

  await context.setOffline(false);
  await waitForFinance(page, "Export and change history");
  await expect(page.getByText(/history shows Household changes only/i)).toBeVisible();
  await expectNoDocumentOverflow(page);
  expect(financeWrites).toEqual([]);
  expect(unexpected).toEqual([]);
});

test("bank sign-in, callbacks and refresh keep existing Finance information", async ({ page, baseURL }) => {
  const requestedSpaces: string[] = [];
  let connectionLoads = 0;
  const unexpected = await mockFinanceApp(page, {
    onRequest: (method, path, url) => {
      if (path.startsWith("/finance/")) {
        const spaceID = url.searchParams.get("space_id");
        if (spaceID) requestedSpaces.push(spaceID);
      }
      if (method === "GET" && path === "/finance/connections") connectionLoads += 1;
    },
  });
  await page.context().route("https://auth.truelayer.com/**", (route) => route.fulfill({
    status: 200,
    contentType: "text/html",
    body: "<!doctype html><title>Choose a bank</title><h1>Choose a bank</h1>",
  }));
  const appBaseURL = baseURL ?? "http://127.0.0.1:5173";

  await page.goto(new URL("/?view=finance&section=setup", appBaseURL).toString());
  await waitForFinance(page, "Connect a bank");
  await expect(page.getByLabel("Bank", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Add manual account" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Import a statement" })).toBeVisible();
  expect(requestedSpaces).not.toContain("partner-private");

  const loadsBeforeReturn = connectionLoads;
  const startRequest = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return request.method() === "POST" && url.pathname === "/api/finance/connections/truelayer/start";
  });
  await page.getByRole("button", { name: "Add another bank" }).click();
  expect((await startRequest).postDataJSON()).toEqual({ space_id: "personal-space" });
  await expect.poll(() => new URL(page.url()).hostname).toBe("auth.truelayer.com");

  await page.goto(new URL("/?view=finance&section=setup&bank=connected&connection=internal-id", appBaseURL).toString());
  await expect(page.getByText("Bank connected. Your accounts are ready.")).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.has("bank")).toBe(false);
  await expect.poll(() => new URL(page.url()).searchParams.has("connection")).toBe(false);
  await expect(page.getByText("internal-id")).toHaveCount(0);
  await waitForFinance(page, "Connect a bank");
  await expect(page.getByText(/Choose your bank on the next screen/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "NatWest" })).toBeVisible();
  expect(connectionLoads).toBeGreaterThan(loadsBeforeReturn);
  expect(requestedSpaces).not.toContain("partner-private");

  const natWestCard = page.locator(".finance-connection-card").filter({ hasText: "NatWest" });
  await natWestCard.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(page.getByText("Bank data refreshed.")).toBeVisible();
  await expect(page.getByText(/stale|catching up/i)).toHaveCount(0);

  await page.goto(new URL("/?view=finance&section=setup&bank=cancelled", appBaseURL).toString());
  await expect(page.getByText("No bank was connected. Your Finance information is unchanged.")).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.has("bank")).toBe(false);
  await waitForFinance(page, "Connect a bank");
  await expect(page.getByRole("heading", { name: "NatWest" })).toBeVisible();

  await page.goto(new URL("/?view=finance&section=setup&bank=failed", appBaseURL).toString());
  await expect(page.getByText("Couldn't connect the bank. Your Finance information is unchanged.")).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.has("bank")).toBe(false);
  await waitForFinance(page, "Connect a bank");
  await expect(page.getByRole("heading", { name: "NatWest" })).toBeVisible();
  await expectNoDocumentOverflow(page);
  expect(unexpected).toEqual([]);
});
