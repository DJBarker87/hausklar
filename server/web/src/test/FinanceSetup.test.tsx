import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { getFinanceStrings } from "../financeStrings";
import type { FinanceAccount, FinanceConnection, FinanceSpace, User } from "../types";
import { AccountView } from "../views/AccountView";
import { FinanceSetupView } from "../views/FinanceSetupView";
import { FinanceView } from "../views/FinanceView";

vi.mock("../api", () => ({
  api: vi.fn(),
  getAuthSessionEpoch: () => 1,
  ApiError: class ApiError extends Error {
    status: number;

    constructor(message: string, status: number) {
      super(message);
      this.status = status;
    }
  },
}));

const apiMock = vi.mocked(api);
const spaces: FinanceSpace[] = [
  { id: "personal-space", kind: "personal", name: "Alex", is_default: true },
  { id: "household-space", kind: "household", name: "Family", is_default: false },
  { id: "partner-private", kind: "personal", name: "Morgan private", is_default: false },
];

function account(overrides: Partial<FinanceAccount> & Pick<FinanceAccount, "id" | "label" | "account_type" | "purpose" | "currency">): FinanceAccount {
  return {
    space_id: "personal-space",
    institution: "Fixture Bank",
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
    data_through_at: "2026-07-31T12:00:00Z",
    balance: null,
    ...overrides,
  };
}

const current = account({ id: "current", label: "Daily current", account_type: "CURRENT", purpose: "OPERATING_CURRENT", currency: "GBP", primary_spending_account: true });
const savings = account({ id: "savings", label: "Rainy day", account_type: "SAVINGS", purpose: "SAVINGS", currency: "GBP" });
const euroCash = account({ id: "euro-cash", label: "Euro cash", account_type: "CASH", purpose: "OPERATING_CURRENT", currency: "EUR", primary_spending_account: true });
const hiddenCash = account({ id: "hidden", label: "Hidden pot", account_type: "SAVINGS", purpose: "SAVINGS", currency: "GBP", include_in_cashflow: false });
const card = account({ id: "card", label: "House card", account_type: "CREDIT_CARD", purpose: "CREDIT_CARD", currency: "GBP", include_in_cashflow: false });
const discovered = account({ id: "discovered", label: "Newly found account", account_type: "CURRENT", purpose: "OPERATING_CURRENT", currency: "GBP" });

const connections: FinanceConnection[] = [
  { id: "natwest", space_id: "personal-space", can_manage: true, provider: "ENABLE_BANKING", institution: "NatWest", status: "CONNECTED", granted_capabilities: ["accounts", "balances", "transactions"], consent_created_at: "2026-07-01T10:00:00Z", consent_expires_at: "2026-10-01T10:00:00Z", last_success_at: "2026-07-31T10:00:00Z", last_error_code: null, data_through_at: "2026-07-31", accounts: [] },
  { id: "expired", space_id: "personal-space", can_manage: true, provider: "ENABLE_BANKING", institution: "Expired Bank", status: "EXPIRED", granted_capabilities: ["accounts"], consent_created_at: null, consent_expires_at: "2026-07-01T10:00:00Z", last_success_at: null, last_error_code: null, data_through_at: null, accounts: [] },
  { id: "partial", space_id: "personal-space", can_manage: true, provider: "ENABLE_BANKING", institution: "Partial Bank", status: "PARTIAL", granted_capabilities: ["accounts", "balances"], consent_created_at: null, consent_expires_at: null, last_success_at: "2026-07-30T10:00:00Z", last_error_code: "BALANCES_PARTIAL", data_through_at: "2026-07-30", accounts: [] },
  { id: "old", space_id: "personal-space", can_manage: true, provider: "ENABLE_BANKING", institution: "Old Bank", status: "DISCONNECTED", granted_capabilities: ["accounts"], consent_created_at: null, consent_expires_at: null, last_success_at: null, last_error_code: null, data_through_at: null, accounts: [] },
];

const failedDerivedRefreshes: NonNullable<FinanceConnection["derived_refreshes"]> = [
  { hook: "PURCHASE_REMATCH", status: "SUCCEEDED", last_attempt_at: "2026-08-01T12:00:00Z", last_success_at: "2026-08-01T12:00:00Z", last_error_code: null },
  { hook: "FORECAST", status: "FAILED", last_attempt_at: "2026-08-01T12:00:00Z", last_success_at: "2026-07-31T12:00:00Z", last_error_code: "FORECAST_REFRESH_FAILED" },
];

const reminderPreferences = {
  event_reminders_enabled: true, event_minutes_before: 30, task_reminders_enabled: true,
  morning_summary_enabled: true, morning_summary_time: "07:00",
  evening_summary_enabled: true, evening_summary_time: "19:00",
  quiet_start: "21:00", quiet_end: "07:00", privacy_mode: true,
};

describe("Finance setup user actions", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.history.replaceState({}, "", "/");
  });

  it("keeps household setup explicitly shared and generates only the selected household overview", async () => {
    const householdSpace = spaces[1];
    const householdAccount = { ...current, id: "household-current", space_id: householdSpace.id, label: "Household current" };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/connections?space_id=household-space") return [] as never;
      if (path === "/finance/accounts?space_id=household-space") return [householdAccount] as never;
      if (path === "/finance/email-addresses") return {
        configured: true,
        gmail_instructions: "Forward selected receipts.",
        outlook_instructions: "Forward selected receipts.",
        addresses: [
          { id: "private-email", space_id: "personal-space", alias_kind: "PERSONAL", address: "demo-person-25@example.invalid", enabled: true, last_received_at: null, last_parsed_at: null, last_test_sent_at: null, created_at: "2026-08-01T00:00:00Z" },
          { id: "household-email", space_id: "household-space", alias_kind: "HOUSEHOLD", address: "demo-person-22@example.invalid", enabled: true, last_received_at: null, last_parsed_at: null, last_test_sent_at: null, created_at: "2026-08-01T00:00:00Z" },
        ],
      } as never;
      if (path === "/finance/email-addresses/household-email/health") return { alias: { id: "household-email" }, health: [], enrollments: [], open_exception_count: 0 } as never;
      if (path === "/finance/report-preferences?space_id=household-space") return null as never;
      if (path === "/finance/reports?space_id=household-space&report_kind=DAILY&limit=1") return [] as never;
      if (path === "/finance/reports/DAILY/refresh?space_id=household-space" && init?.method === "POST") return { id: "household-report", space_id: "household-space" } as never;
      return undefined as never;
    });

    render(<FinanceSetupView spaces={[householdSpace]} locale="en" copy={getFinanceStrings("en")} />);

    expect(await screen.findByRole("heading", { name: "Your first household overview" })).toBeInTheDocument();
    expect(screen.getByText(/Anything connected or imported here is visible to both adults/)).toBeInTheDocument();
    expect(screen.queryByText(/Neither adult's private data is copied or added here automatically/)).not.toBeInTheDocument();
    expect(await screen.findByText("Your household overview is ready.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/reports/DAILY/refresh?space_id=household-space",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    );
    expect(screen.queryByText("Private Finance file")).not.toBeInTheDocument();
    fireEvent.click(screen.getByText("Optional: forwarding and notifications"));
    expect(screen.getByRole("heading", { name: "Forward household receipts" })).toBeInTheDocument();
    expect(screen.getByText("demo-person-22@example.invalid")).toBeInTheDocument();
    expect(screen.queryByText("demo-person-25@example.invalid")).not.toBeInTheDocument();
  });

  it("handles bank setup, account rules and statement review without an offline queue", async () => {
    let refreshed = false;
    const redirect = vi.fn();
    const onSectionChange = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/spaces") return spaces as never;
      if (path === "/finance/connections?space_id=personal-space") return connections.map((item) => item.id === "natwest" && refreshed ? { ...item, last_success_at: "2026-08-01T12:00:00Z", derived_refreshes: failedDerivedRefreshes } : item) as never;
      if (path === "/finance/connections?space_id=household-space") return [] as never;
      if (path === "/finance/accounts?space_id=personal-space") return [current, savings, euroCash, hiddenCash, card, ...(refreshed ? [discovered] : [])] as never;
      if (path === "/finance/accounts?space_id=household-space") return [] as never;
      if (path === "/finance/connections/natwest/sync" && init?.method === "POST") {
        refreshed = true;
        return { connection_id: "natwest", status: "CONNECTED", accounts_seen: 6, balances_created: 1, source_created: 1, canonical_created: 1, duplicates: 0, pending_superseded: 0, partial_issue_codes: [], derived_refreshes: failedDerivedRefreshes } as never;
      }
      if (path === "/finance/connections/natwest" && init?.method === "DELETE") return { id: "natwest", status: "DISCONNECTED" } as never;
      if (path === "/finance/connections/truelayer/start" && init?.method === "POST") return { redirect_url: "https://auth.truelayer.com/?session=abc" } as never;
      if (path.startsWith("/finance/accounts/") && init?.method === "PATCH") {
        const source = [current, savings, euroCash, hiddenCash, card].find((item) => path.includes(`/finance/accounts/${item.id}?`));
        return { ...source, ...JSON.parse(String(init.body)) } as never;
      }
      if (path === "/finance/imports/preview" && init?.method === "POST") return {
        batch_id: "preview-1", source_kind: "CSV", space_id: "personal-space", account_id: "current", currency: "GBP",
        total_rows: 4, importable_rows: 2, invalid_rows: 1, duplicate_rows: 1, can_confirm: true,
        date_from: "2026-07-20", date_to: "2026-07-31", issue_count: 1, issues_truncated: false,
        issues: [{ row_number: 3, code: "INVALID_AMOUNT", message: "Check this amount", severity: "WARNING" }],
        sample_rows: [{ row_number: 2, booking_date: "2026-07-20", value_date: null, amount_minor: -1250, currency: "GBP", description: "Quinn", source_transaction_id: null }],
        repair: { relationship: "OVERLAP", imported_start: "2026-07-20", imported_end: "2026-07-31", existing_start: "2026-07-01", existing_end: "2026-07-25", gap_start: null, gap_end: null, overlap_start: "2026-07-20", overlap_end: "2026-07-25" },
      } as never;
      if (path === "/finance/imports/confirm" && init?.method === "POST") return { source_created: 2, canonical_created: 2, duplicates: 1, pending_superseded: 0, transaction_ids: ["t1", "t2"], relation_suggestion_ids: [] } as never;
      if (path === "/finance/reports?space_id=personal-space&report_kind=DAILY&limit=1") return [] as never;
      if (path === "/finance/reports/DAILY/refresh?space_id=personal-space" && init?.method === "POST") return { id: "first-report", space_id: "personal-space" } as never;
      if (path === "/calendar/sources" || path === "/family/members") return [] as never;
      if (path === "/calendar/feed") return { configured: false } as never;
      if (path === "/reminders/preferences") return reminderPreferences as never;
      if (path === "/reminders/push") return { configured: false, subscribed: false } as never;
      if (path === "/reminders/preview") return [] as never;
      if (path === "/auth/ai-consent") return { consented: false, version: "v1", consented_at: null, provider: "OpenAI", disclosure: "Only when requested.", background_processing: false } as never;
      return undefined as never;
    });

    window.history.replaceState({}, "", "/?view=finance&section=setup&bank=connected&connection=internal-id");
    render(
      <FinanceView
        hasFamilyAccount
        online
        section="setup"
        scope="mine"
        onSectionChange={onSectionChange}
        onScopeChange={vi.fn()}
        onBankRedirect={redirect}
        locale="en"
      />,
    );

    expect(await screen.findByText("Bank connected. Your accounts are ready.")).toBeInTheDocument();
    await waitFor(() => {
      expect(window.location.search).not.toContain("bank=");
      expect(window.location.search).not.toContain("connection=");
    });
    expect(screen.queryByText("internal-id")).not.toBeInTheDocument();
    expect((await screen.findAllByText("Connected")).length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("Sign in again")).toBeInTheDocument();
    expect(screen.getByText("Disconnected")).toBeInTheDocument();
    const expiredLegacyCard = screen.getByRole("heading", { name: "Expired Bank" }).closest("article")!;
    expect(within(expiredLegacyCard).getByText(getFinanceStrings("en").olderConnectionDetail)).toBeInTheDocument();
    expect(within(expiredLegacyCard).queryByRole("button", { name: "Sign in again" })).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("partner-private"))).toBe(false);
    expect(screen.queryByRole("list", { name: "Setup steps" })).not.toBeInTheDocument();
    const connectHeading = screen.getByRole("heading", { name: "Connect a bank" });
    const privacyHeading = screen.getByRole("heading", { name: "Account ownership" });
    const overviewHeading = screen.getByRole("heading", { name: "Your first overview" });
    expect(connectHeading.compareDocumentPosition(privacyHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(privacyHeading.compareDocumentPosition(overviewHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(await screen.findByText("Your overview is ready.")).toBeInTheDocument();
    expect(screen.queryByLabelText("Bank")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add manual account" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Import a statement" })).toBeVisible();
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("enable-banking/institutions"))).toBe(false);
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/reports/DAILY/refresh?space_id=personal-space",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    );
    expect(screen.getByText("Optional: forwarding and notifications").closest("details")).not.toHaveAttribute("open");

    fireEvent.click(within(screen.getByRole("heading", { name: "NatWest" }).closest("article")!).getByRole("button", { name: "Refresh" }));
    expect(await screen.findByText("Newly found account")).toBeInTheDocument();
    expect(await screen.findByText("Bank data refreshed.")).toBeInTheDocument();
    expect(screen.queryByText(/stale|catching up/i)).not.toBeInTheDocument();
    expect(apiMock.mock.calls.filter(([path]) => path === "/finance/accounts?space_id=personal-space")).toHaveLength(2);

    const refreshedNatWest = screen.getByRole("heading", { name: "NatWest" }).closest("article")!;
    fireEvent.click(within(refreshedNatWest).getByRole("button", { name: "Disconnect" }));
    expect(screen.getByText(/Existing accounts, balances and transaction history stay/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Disconnect bank" }));
    await waitFor(() => expect(within(refreshedNatWest).getByText("Disconnected")).toBeInTheDocument());
    expect(screen.getByText("Newly found account")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Add another bank" }));
    await waitFor(() => expect(redirect).toHaveBeenCalledWith("https://auth.truelayer.com/?session=abc"));
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/connections/truelayer/start",
      { method: "POST", body: JSON.stringify({ space_id: "personal-space" }) },
      true,
      false,
    );

    fireEvent.click(within(screen.getByRole("heading", { name: "House card" }).closest("article")!).getByRole("button", { name: "Edit account" }));
    const cardDialog = screen.getByRole("dialog", { name: "Edit account" });
    const purposeOptions = within(within(cardDialog).getByLabelText("Purpose")).getAllByRole("option").map((option) => option.textContent);
    expect(purposeOptions).toEqual(["Credit card", "Ignore in Finance"]);
    fireEvent.click(within(cardDialog).getByLabelText(/^Paid in full each month/));
    const payingAccount = within(cardDialog).getByLabelText("Account that pays this card");
    expect(within(payingAccount).queryByRole("option", { name: "Hidden pot" })).not.toBeInTheDocument();
    fireEvent.change(payingAccount, { target: { value: "current" } });
    fireEvent.change(within(cardDialog).getByLabelText("Statement closes on day"), { target: { value: "18" } });
    fireEvent.change(within(cardDialog).getByLabelText("Payment leaves on day"), { target: { value: "27" } });
    fireEvent.click(within(cardDialog).getByRole("button", { name: "Save account" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/accounts/card?space_id=personal-space",
      expect.objectContaining({ body: expect.stringContaining('"card_settlement_account_id":"current"') }),
      true,
      false,
    ));
    expect(await screen.findByText("Paid in full each month")).toBeInTheDocument();

    fireEvent.click(within(screen.getByRole("heading", { name: "Rainy day" }).closest("article")!).getByRole("button", { name: "Edit account" }));
    const savingsDialog = screen.getByRole("dialog", { name: "Edit account" });
    fireEvent.click(within(savingsDialog).getByLabelText(/^Default direct-spend account/));
    fireEvent.click(within(savingsDialog).getByRole("button", { name: "Save account" }));
    await waitFor(() => expect(within(screen.getByRole("heading", { name: "Rainy day" }).closest("article")!).getByText("Default direct-spend account")).toBeInTheDocument());
    expect(within(screen.getByRole("heading", { name: "Daily current" }).closest("article")!).queryByText("Default direct-spend account")).not.toBeInTheDocument();
    expect(within(screen.getByRole("heading", { name: "Euro cash" }).closest("article")!).getByText("Default direct-spend account")).toBeInTheDocument();

    fireEvent.click(within(screen.getByRole("heading", { name: "Rainy day" }).closest("article")!).getByRole("button", { name: "Edit account" }));
    const cashflowDialog = screen.getByRole("dialog", { name: "Edit account" });
    fireEvent.click(within(cashflowDialog).getByLabelText(/^Everyday cash plan/));
    expect(within(cashflowDialog).queryByLabelText(/^Default direct-spend account/)).not.toBeInTheDocument();
    fireEvent.click(within(cashflowDialog).getByRole("button", { name: "Save account" }));
    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/finance/accounts/savings?space_id=personal-space" && init?.method === "PATCH" && String(init.body).includes('"include_in_cashflow":false'));
      expect(call?.[1]?.body).toContain('"primary_spending_account":false');
    });

    fireEvent.click(screen.getByRole("button", { name: "Import a statement" }));
    const importDialog = screen.getByRole("dialog", { name: "Import CSV or OFX statement" });
    fireEvent.change(within(importDialog).getByLabelText("Statement file"), { target: { files: [new File(["Date,Amount,Description\n20/07/2026,-12.50,Quinn"], "statement.csv", { type: "text/csv" })] } });
    fireEvent.change(within(importDialog).getByLabelText("Currency"), { target: { value: "GBP" } });
    fireEvent.change(within(importDialog).getByLabelText("Account"), { target: { value: "current" } });
    fireEvent.click(within(importDialog).getByLabelText("Spending is positive"));
    fireEvent.click(within(importDialog).getByRole("button", { name: "Preview statement" }));
    expect(await within(importDialog).findByText(/overlaps existing history/)).toBeInTheDocument();
    const previewCall = apiMock.mock.calls.find(([path]) => path === "/finance/imports/preview");
    expect(previewCall?.[1]?.body).toBeInstanceOf(FormData);
    expect((previewCall?.[1]?.body as FormData).get("sign_convention")).toBe("DEBIT_POSITIVE");
    fireEvent.click(within(importDialog).getByRole("button", { name: "Confirm import" }));
    expect(await within(importDialog).findByText("Statement imported")).toBeInTheDocument();
    const confirmCall = apiMock.mock.calls.find(([path]) => path === "/finance/imports/confirm");
    expect((confirmCall?.[1]?.body as FormData).get("preview_batch_id")).toBe("preview-1");

    const financeCalls = apiMock.mock.calls.filter(([path]) => String(path).startsWith("/finance/"));
    expect(financeCalls.every((call) => call[3] === false)).toBe(true);

    cleanup();
    apiMock.mockClear();
    const admin: User = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family", must_change_password: false };
    render(<AccountView user={admin} onUserUpdated={vi.fn()} onSignOut={vi.fn()} />);
    expect(apiMock).not.toHaveBeenCalled();
    expect(screen.queryByText("Finance access")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/finance/members"))).toBe(false);
  });

  it.each([
    "http://auth.truelayer.com/session",
    "https://auth.truelayer.com.attacker.example/session",
    "https://auth.truelayer.com:443/session",
    "https://auth.truelayer.com:444/session",
  ])("refuses an unsafe bank sign-in address: %s", async (redirectURL) => {
    const redirect = vi.fn();
    const copy = getFinanceStrings("en");
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/connections?space_id=personal-space") return [] as never;
      if (path === "/finance/accounts?space_id=personal-space") return [current] as never;
      if (path === "/finance/email-addresses") return { configured: false, gmail_instructions: "", outlook_instructions: "", addresses: [] } as never;
      if (path === "/finance/report-preferences?space_id=personal-space") return null as never;
      if (path === "/finance/reports?space_id=personal-space&report_kind=DAILY&limit=1") return [{ id: "existing-report" }] as never;
      if (path === "/finance/connections/truelayer/start" && init?.method === "POST") return { redirect_url: redirectURL } as never;
      return undefined as never;
    });

    render(<FinanceSetupView spaces={[spaces[0]]} locale="en" copy={copy} onBankRedirect={redirect} />);

    await screen.findByRole("heading", { name: "Connect a bank" });
    fireEvent.click(screen.getByRole("button", { name: "Choose a bank" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(copy.bankActionError);
    expect(redirect).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "Daily current" })).toBeInTheDocument();
  });

  it("reauthorises an existing TrueLayer connection instead of creating duplicate accounts", async () => {
    const redirect = vi.fn();
    const copy = getFinanceStrings("en");
    const disconnected: FinanceConnection = {
      ...connections[3],
      provider: "TRUELAYER",
      institution: "NatWest",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/connections?space_id=personal-space") return [disconnected] as never;
      if (path === "/finance/accounts?space_id=personal-space") return [current] as never;
      if (path === "/finance/email-addresses") return { configured: false, gmail_instructions: "", outlook_instructions: "", addresses: [] } as never;
      if (path === "/finance/report-preferences?space_id=personal-space") return null as never;
      if (path === "/finance/reports?space_id=personal-space&report_kind=DAILY&limit=1") return [{ id: "existing-report" }] as never;
      if (path === "/finance/connections/truelayer/start" && init?.method === "POST") return { redirect_url: "https://auth.truelayer.com/?session=reauthorise" } as never;
      return undefined as never;
    });

    render(<FinanceSetupView spaces={[spaces[0]]} locale="en" copy={copy} onBankRedirect={redirect} />);

    const card = (await screen.findByRole("heading", { name: "NatWest" })).closest("article")!;
    fireEvent.click(screen.getByRole("button", { name: "Sign in again" }));

    expect(within(card).getByRole("button", { name: "Opening bank list…" })).toHaveAttribute("aria-busy", "true");
    await waitFor(() => expect(redirect).toHaveBeenCalledWith("https://auth.truelayer.com/?session=reauthorise"));
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/connections/truelayer/start",
      {
        method: "POST",
        body: JSON.stringify({ space_id: "personal-space", connection_id: "old" }),
      },
      true,
      false,
    );
  });

  it("keeps another adult's household bank history read-only without taking over add bank", async () => {
    const redirect = vi.fn();
    const copy = getFinanceStrings("en");
    const householdConnection: FinanceConnection = {
      ...connections[3],
      id: "other-adult-bank",
      space_id: "household-space",
      can_manage: false,
      provider: "TRUELAYER",
      institution: "Family Bank",
      status: "EXPIRED",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/finance/connections?space_id=household-space") return [householdConnection] as never;
      if (path === "/finance/accounts?space_id=household-space") return [] as never;
      if (path === "/finance/email-addresses") return { configured: false, gmail_instructions: "", outlook_instructions: "", addresses: [] } as never;
      if (path === "/finance/report-preferences?space_id=household-space") return null as never;
      if (path === "/finance/connections/truelayer/start" && init?.method === "POST") return { redirect_url: "https://auth.truelayer.com/?session=new-bank" } as never;
      return undefined as never;
    });

    render(<FinanceSetupView spaces={[spaces[1]]} locale="en" copy={copy} onBankRedirect={redirect} />);

    const card = (await screen.findByRole("heading", { name: "Family Bank" })).closest("article")!;
    expect(within(card).getByText(copy.connectionHistoryOnly)).toBeInTheDocument();
    expect(within(card).getByText(copy.otherAdultConnectionDetail)).toBeInTheDocument();
    expect(within(card).queryByRole("button")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Add another bank" }));

    await waitFor(() => expect(redirect).toHaveBeenCalledWith("https://auth.truelayer.com/?session=new-bank"));
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/connections/truelayer/start",
      { method: "POST", body: JSON.stringify({ space_id: "household-space" }) },
      true,
      false,
    );
  });
});
