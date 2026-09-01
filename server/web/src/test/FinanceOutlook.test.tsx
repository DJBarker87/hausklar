import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { todayInTimeZone } from "../financeDate";
import { getFinanceStrings } from "../financeStrings";
import type { FinanceAccount, FinanceForecast, FinanceSafeToSpend, FinanceSettings, FinanceSpace } from "../types";
import { FinanceOutlookView } from "../views/FinanceOutlookView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const spaces: FinanceSpace[] = [
  { id: "private", kind: "personal", name: "Alex", is_default: true },
  { id: "shared", kind: "household", name: "Family", is_default: false },
];

function account(overrides: Partial<FinanceAccount> & Pick<FinanceAccount, "id" | "label" | "account_type" | "purpose">): FinanceAccount {
  return {
    space_id: "private",
    institution: "Fixture Bank",
    currency: "GBP",
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
    data_through_at: "2026-07-31T18:00:00Z",
    balance: { booked_minor: 100_000, available_minor: 98_000, credit_limit_minor: null, provider_at: "2026-07-31T18:00:00Z", observed_at: "2026-07-31T18:00:00Z" },
    ...overrides,
  };
}

const current = account({ id: "current", label: "Daily current", account_type: "CURRENT", purpose: "OPERATING_CURRENT", primary_spending_account: true, minimum_balance_minor: 10_000 });
const savings = account({ id: "savings", label: "Rainy day", account_type: "SAVINGS", purpose: "SAVINGS", balance: { booked_minor: 40_000, available_minor: 40_000, credit_limit_minor: null, provider_at: "2026-07-31T18:00:00Z", observed_at: "2026-07-31T18:00:00Z" } });
const card = account({ id: "card", label: "House card", account_type: "CREDIT_CARD", purpose: "CREDIT_CARD", card_paid_in_full: true, card_settlement_account_id: "current", card_statement_close_day: 18, card_repayment_day: 27, balance: { booked_minor: -12_000, available_minor: null, credit_limit_minor: 100_000, provider_at: "2026-07-31T18:00:00Z", observed_at: "2026-07-31T18:00:00Z" } });
const incompleteCard = account({ id: "incomplete-card", label: "Incomplete card", account_type: "CREDIT_CARD", purpose: "CREDIT_CARD", balance: { booked_minor: -2_000, available_minor: null, credit_limit_minor: 20_000, provider_at: "2026-07-31T18:00:00Z", observed_at: "2026-07-31T18:00:00Z" } });
const sharedAccount = account({ id: "shared-current", label: "Household current", account_type: "CURRENT", purpose: "OPERATING_CURRENT", space_id: "shared" });

function addDays(value: string, days: number) {
  const parsed = new Date(`${value}T12:00:00Z`);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString().slice(0, 10);
}

describe("Finance outlook", () => {
  beforeEach(() => apiMock.mockReset());

  it("builds the saved path and sends only the chosen route plus explicit missing-spending estimate", async () => {
    const today = new Date();
    const start = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
    const forecast: FinanceForecast = {
      id: "forecast-1",
      space_id: "private",
      input_snapshot_digest: "digest-1",
      engine_version: "finance-forecast-v1",
      household_timezone: "Europe/London",
      currency: "GBP",
      start_date: start,
      end_date: addDays(start, 89),
      household_buffer_minor: 15_000,
      passed: true,
      limiting_event: null,
      minimum_household_free_minor: 50_000,
      minimum_household_free_date: addDays(start, 2),
      data_through_at: `${start}T18:00:00Z`,
      source: "SAVED",
      data_status: "STALE",
      input_notes: ["Balances are only current through 2026-07-31; changes since then are not estimated.", "Linked active reserves are protected on their saved cash accounts."],
      created_at: `${start}T19:00:00Z`,
      events: [
        { event_id: "salary", day: start, account_id: "current", amount_minor: 200_000, currency: "GBP", kind: "income", destination_account_id: null, sequence: 100, provenance: "recurring:salary" },
        { event_id: "bill", day: addDays(start, 1), account_id: "current", amount_minor: -20_000, currency: "GBP", kind: "expense", destination_account_id: null, sequence: 200, provenance: "recurring:bill" },
        { event_id: "commitment", day: addDays(start, 2), account_id: "current", amount_minor: -30_000, currency: "GBP", kind: "commitment", destination_account_id: null, sequence: 300, provenance: "commitment:school" },
        { event_id: "card-repayment", day: addDays(start, 2), account_id: "current", amount_minor: -12_000, currency: "GBP", kind: "transfer", destination_account_id: "card", sequence: 250, provenance: "card-repayment:card" },
      ],
      days: [0, 1, 2].map((offset) => ({
        day: addDays(start, offset),
        household_liquid_minor: 140_000 - offset * 20_000,
        household_free_minor: 75_000 - offset * 12_500,
        constraints_passed_through_day: true,
        accounts: [
          { account_id: "current", balance_minor: 100_000 - offset * 20_000, floor_minor: 25_000, headroom_minor: 75_000 - offset * 20_000 },
          { account_id: "savings", balance_minor: 40_000, floor_minor: 10_000, headroom_minor: 30_000 },
          { account_id: "card", balance_minor: -12_000, floor_minor: -100_000, headroom_minor: 88_000 },
        ],
      })),
    };
    let safeCalls = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/finance/settings") return ({
        id: "settings-1",
        household_timezone: "Europe/London",
        default_currency: "GBP",
        personal_space_id: "private",
        household_space_id: "shared",
        created_at: `${start}T00:00:00Z`,
        updated_at: `${start}T00:00:00Z`,
      } satisfies FinanceSettings) as never;
      if (String(path).startsWith("/finance/forecasts/overview?")) return ({
        ...forecast,
        opening_accounts: forecast.days[0].accounts,
        days: forecast.days.map(({ accounts: _accounts, ...day }) => day),
      }) as never;
      if (path === "/finance/forecasts/forecast-1") return forecast as never;
      if (path === "/finance/safe-to-spend") {
        safeCalls += 1;
        if (safeCalls === 4) throw new Error("temporary request failure");
        const response: FinanceSafeToSpend = safeCalls === 1 ? {
          forecast_id: forecast.id,
          input_snapshot_digest: forecast.input_snapshot_digest,
          status: "OK",
          answer_mode: "ESTIMATED_RANGE",
          currency: "GBP",
          amount_minor: null,
          low_minor: 32_000,
          high_minor: 36_000,
          data_through: start,
          evaluated_through: forecast.end_date,
          limiting_event: { kind: "ACCOUNT_FLOOR", day: addDays(start, 2), event_id: "commitment", account_id: "current", required_minor: 25_000, actual_minor: 24_999, shortfall_minor: 1 },
          refusal_reasons: ["No confirmed repeating income or spending has been saved."],
        } : safeCalls === 2 ? {
          forecast_id: forecast.id,
          input_snapshot_digest: forecast.input_snapshot_digest,
          status: "NO_SAFE_AMOUNT",
          answer_mode: "CURRENT_EXACT",
          currency: "GBP",
          amount_minor: 0,
          low_minor: null,
          high_minor: null,
          data_through: start,
          evaluated_through: forecast.end_date,
          limiting_event: { kind: "ACCOUNT_FLOOR", day: addDays(start, 2), event_id: "commitment", account_id: "current", required_minor: 25_000, actual_minor: 24_999, shortfall_minor: 1 },
          refusal_reasons: [],
        } : {
          forecast_id: forecast.id,
          input_snapshot_digest: forecast.input_snapshot_digest,
          status: "CANNOT_MODEL_CARD_ROUTE",
          answer_mode: "CANNOT_MODEL",
          currency: "GBP",
          amount_minor: null,
          low_minor: null,
          high_minor: null,
          data_through: start,
          evaluated_through: forecast.end_date,
          limiting_event: null,
          refusal_reasons: ["The saved forecast has no confirmed full-repayment route for this card."],
        };
        return response as never;
      }
      return undefined as never;
    });

    const view = render(<FinanceOutlookView accounts={[current, savings, card, incompleteCard, sharedAccount]} spaces={[spaces[0]]} online locale="en" copy={getFinanceStrings("en")} />);
    expect(screen.queryByText("No saved outlook yet")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Finances to use")).not.toBeInTheDocument();

    const lowestCard = (await screen.findByText("Lowest you'll go")).closest("article");
    expect(lowestCard).not.toBeNull();
    expect(within(lowestCard!).getByText("£500.00")).toBeInTheDocument();
    expect(screen.getByText("Nothing urgent. Your current plan stays above the protected amount.")).toBeInTheDocument();
    expect(screen.queryByText("Refresh the bank connection before a larger purchase.")).not.toBeInTheDocument();
    expect(screen.queryByText("Some recent spending may be missing")).not.toBeInTheDocument();
    expect(screen.getAllByText("Money coming in").length).toBeGreaterThan(0);
    expect(screen.getByText("Bill or regular spending")).toBeInTheDocument();
    expect(screen.getByText("Bill")).toBeInTheDocument();
    expect(screen.getByText("Card bill paid")).toBeInTheDocument();
    expect(screen.getByText("Protected savings stay held on their linked accounts.")).toBeInTheDocument();
    const advanced = screen.getByText("How this was worked out").closest("details");
    expect(advanced).not.toHaveAttribute("open");
    fireEvent.click(screen.getByText("How this was worked out"));
    fireEvent.click(await screen.findByText("Day-by-day detail"));
    expect(screen.getByRole("columnheader", { name: "Rainy day" })).toBeInTheDocument();

    const forecastCall = apiMock.mock.calls.find(([path]) => String(path).startsWith("/finance/forecasts/overview?"));
    const forecastBody = JSON.parse(String(forecastCall?.[1]?.body));
    expect(Object.keys(forecastBody).sort()).toEqual(["currency", "end_date", "household_buffer_minor"]);
    expect(forecastBody.end_date).toBe(addDays(todayInTimeZone("Europe/London"), 89));
    expect(forecastCall?.[3]).toBe(false);

    const routeSelect = screen.getByLabelText("How you'd pay");
    expect(routeSelect).toHaveValue("direct:current");
    expect(within(routeSelect).getByRole("option", { name: /Incomplete card.*everyday-account estimate/ })).toBeInTheDocument();
    fireEvent.change(routeSelect, { target: { value: "card:card" } });
    fireEvent.change(screen.getByLabelText("Rough low"), { target: { value: "12.00" } });
    fireEvent.change(screen.getByLabelText("Rough high"), { target: { value: "18.00" } });
    fireEvent.click(screen.getByRole("button", { name: "Check what's safe" }));

    expect(await screen.findByText("Best available range")).toBeInTheDocument();
    expect(screen.getByText("£320.00–£360.00")).toBeInTheDocument();
    expect(screen.getByText(/You'd first run short on/)).toBeInTheDocument();
    expect(screen.queryByText("This payment route cannot be checked yet")).not.toBeInTheDocument();
    expect(screen.getByText("No confirmed repeating pay or spending has been saved.")).toBeInTheDocument();
    expect(screen.queryByText(/Based on spending through|about \d+% sure/i)).not.toBeInTheDocument();

    const safeCall = apiMock.mock.calls.find(([path]) => path === "/finance/safe-to-spend");
    const safeBody = JSON.parse(String(safeCall?.[1]?.body));
    expect(safeBody).toEqual({
      forecast_id: "forecast-1",
      route: "full_repayment_card",
      spend_date: start,
      card_account_id: "card",
      unobserved_spend_low_minor: 1200,
      unobserved_spend_high_minor: 1800,
    });
    expect(safeBody).not.toHaveProperty("card_statement_close_day");
    expect(safeBody).not.toHaveProperty("card_repayment_day");
    expect(safeBody).not.toHaveProperty("card_settlement_account_id");
    expect(safeBody).not.toHaveProperty("balance");
    expect(safeCall?.[3]).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Check what's safe" }));
    const zeroAnswer = (await screen.findByText("Exact, from the latest data")).closest("article");
    expect(zeroAnswer).toHaveClass("is-warning");
    expect(within(zeroAnswer!).getByText("£0.00")).toBeInTheDocument();
    expect(within(zeroAnswer!).getByText(/You'd first run short on/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Check what's safe" }));
    const fallbackAnswer = (await screen.findByText("Best available range")).closest("article");
    expect(fallbackAnswer).not.toBeNull();
    expect(within(fallbackAnswer!).getByText("£315.00–£350.00")).toBeInTheDocument();
    expect(within(fallbackAnswer!).getByText("Card repayment timing isn't included, so this uses the money available in the everyday account.")).toBeInTheDocument();
    expect(within(fallbackAnswer!).queryByText(/about \d+% sure/i)).not.toBeInTheDocument();
    expect(screen.queryByText("This payment route cannot be checked yet")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Check what's safe" }));
    await waitFor(() => expect(apiMock.mock.calls.filter(([path]) => path === "/finance/safe-to-spend")).toHaveLength(4));
    expect(screen.getByText("£315.00–£350.00")).toBeInTheDocument();
    expect(screen.queryByText("That couldn't be checked. Your outlook and entries are unchanged.")).not.toBeInTheDocument();

    view.rerender(<FinanceOutlookView accounts={[current, savings, card, incompleteCard, sharedAccount]} spaces={[spaces[0]]} online={false} locale="en" copy={getFinanceStrings("en")} />);
    expect(screen.queryByText("Showing the last saved outlook.")).not.toBeInTheDocument();
  });
});
