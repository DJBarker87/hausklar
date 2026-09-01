import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, expect, it, vi } from "vitest";

import { api } from "../api";
import { FinanceNetWorthPanel } from "../components/FinanceNetWorthPanel";
import type { FinanceAccount, FinanceNetWorthHistory } from "../types";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

const account: FinanceAccount = {
  id: "current",
  space_id: "household",
  label: "Household current",
  institution: "Family Bank",
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
  fresh_through_date: "2026-08-01",
  data_through_at: "2026-08-01T08:00:00Z",
  balance: { booked_minor: 125_000, available_minor: 125_000, credit_limit_minor: null, provider_at: null, observed_at: "2026-08-01T08:00:00Z" },
};

const emptyLayers = (updates: Partial<Record<FinanceNetWorthHistory["points"][number]["layers"][number]["layer"], number>>) => [
  "OPERATING_CASH", "PROTECTED_RESERVE", "GOAL_CASH", "ACCESSIBLE_SAVINGS",
  "BROKERAGE_INVESTMENT", "PENSION_LOCKED", "STABLE_CRYPTO", "VOLATILE_CRYPTO",
  "PROPERTY", "OTHER_ASSET", "LIABILITY",
].map((layer) => ({ layer, amount_minor: updates[layer as keyof typeof updates] ?? 0 })) as FinanceNetWorthHistory["points"][number]["layers"];

const history: FinanceNetWorthHistory = {
  space_id: "household",
  currency: "GBP",
  current_total_minor: 12_000_000,
  change_minor: 1_000_000,
  period_contributions_minor: 400_000,
  period_withdrawals_minor: 50_000,
  period_market_movement_minor: 250_000,
  points: [
    { as_of_date: "2026-01-01", total_minor: 11_000_000, unknown_component_count: 0, layers: emptyLayers({ OPERATING_CASH: 1_000_000, PROTECTED_RESERVE: 100_000, BROKERAGE_INVESTMENT: 4_000_000, PROPERTY: 6_000_000 }), contributions_minor: 0, withdrawals_minor: 0, market_movement_minor: null },
    { as_of_date: "2026-02-01", total_minor: 11_100_000, unknown_component_count: 0, layers: emptyLayers({ OPERATING_CASH: 1_000_000, PROTECTED_RESERVE: 100_000, BROKERAGE_INVESTMENT: 4_100_000, PROPERTY: 6_000_000 }), contributions_minor: 0, withdrawals_minor: 0, market_movement_minor: 100_000 },
    { as_of_date: "2026-08-01", total_minor: 12_000_000, unknown_component_count: 2, layers: emptyLayers({ OPERATING_CASH: 1_000_000, PROTECTED_RESERVE: 100_000, BROKERAGE_INVESTMENT: 5_000_000, PROPERTY: 6_000_000 }), contributions_minor: 400_000, withdrawals_minor: 50_000, market_movement_minor: 250_000 },
  ],
  holdings: [
    { key: "holding:hl:index", source_id: "hl", source_label: "HL ISA", name: "Global index fund", layer: "BROKERAGE_INVESTMENT", value_minor: 5_000_000, currency: "GBP", as_of_at: "2026-08-01T23:59:59Z", quantity: "125", quantity_unit: "units", instrument_id_kind: "ISIN", instrument_id: "GB00INDEX001", quote_symbol: "INDEX.LON", unit_price_minor: 40_000, price_source: "Daily close", using_last_known_price: false },
    { key: "manual:home", source_id: null, source_label: "Reviewed value", name: "Family home", layer: "PROPERTY", value_minor: 6_000_000, currency: "GBP", as_of_at: "2026-07-20T12:00:00Z", quantity: null, quantity_unit: null, instrument_id_kind: null, instrument_id: null, quote_symbol: null, unit_price_minor: null, price_source: "Reviewed value", using_last_known_price: true },
  ],
  price_observed_at: "2026-08-01T23:59:59Z",
  price_sources: ["Daily close"],
  using_last_known_prices: false,
};

beforeEach(() => apiMock.mockReset());

it("shows a simple total, selectable lines and cash flows separately from market movement", async () => {
  apiMock.mockResolvedValue(history as never);
  const ask = vi.fn();
  render(<FinanceNetWorthPanel spaceID="household" currency="GBP" accounts={[account]} locale="en" onAskAbout={ask} />);

  expect(await screen.findByRole("heading", { name: "£120,000" })).toBeInTheDocument();
  expect(screen.getByText("Known net worth")).toBeInTheDocument();
  expect(screen.getByText("+ 2 values not yet priced")).toHaveClass("finance-net-worth-unknown");
  expect(screen.getByText("+£10,000 over the selected period")).toBeInTheDocument();
  const flowSummary = document.querySelector<HTMLElement>(".finance-net-worth-flow-summary")!;
  expect(within(flowSummary).getByText("Contributed").parentElement).toHaveTextContent("£4,000");
  expect(within(flowSummary).getByText("Withdrawn").parentElement).toHaveTextContent("£500");
  expect(within(flowSummary).getByText("Market movement").parentElement).toHaveTextContent("+£2,500");

  const graph = screen.getByRole("img", { name: /Known net worth .* to/ });
  expect(graph.querySelectorAll("path.finance-net-worth-series")).toHaveLength(1);
  expect(graph.querySelector("path.finance-net-worth-series")?.getAttribute("d")).toMatch(/L 116\.6 /);
  fireEvent.click(screen.getByRole("checkbox", { name: "Investments" }));
  expect(graph.querySelectorAll("path.finance-net-worth-series")).toHaveLength(2);

  expect(screen.queryByText("Valuation history")).not.toBeInTheDocument();
  expect(screen.queryByRole("region", { name: /Valuation history/ })).not.toBeInTheDocument();
  expect(screen.queryByText(/Investment prices through/)).not.toBeInTheDocument();
  fireEvent.click(screen.getByText("Full breakdown"));
  const table = screen.getByRole("region", { name: /Holdings and values/ });
  expect(within(table).getByText("Global index fund")).toBeInTheDocument();
  expect(within(table).getByText(/ISIN GB00INDEX001/)).toBeInTheDocument();
  expect(screen.getByText("Part of the cash above; not counted twice")).toBeInTheDocument();
  expect(screen.getByText("Valuation history")).toBeInTheDocument();
  expect(screen.getByRole("region", { name: /Valuation history/ })).toHaveTextContent("1 Aug 2026");
  expect(screen.getByText(/Investment prices through 1 Aug 2026 · Daily close/)).toHaveClass("finance-net-worth-price-note");

  fireEvent.click(screen.getByRole("button", { name: "Ask about this" }));
  expect(ask).toHaveBeenCalledWith(expect.stringContaining("Separate contributions, withdrawals and market movement"));
});

it("still gives the saved account total before a history scope is available", async () => {
  render(<FinanceNetWorthPanel spaceID="" currency="GBP" accounts={[{ ...account, space_id: "" }]} locale="en" onAskAbout={vi.fn()} />);

  await waitFor(() => expect(screen.getByText(/Current account value/)).toBeInTheDocument());
  expect(screen.getAllByText("£1,250").length).toBeGreaterThan(0);
  expect(screen.queryByText(/cannot|unavailable|stale/i)).not.toBeInTheDocument();
  expect(apiMock).not.toHaveBeenCalled();
});

it("mounts a bounded page of valuation rows only when the breakdown is opened", async () => {
  const points = Array.from({ length: 205 }, (_, index) => {
    const asOf = new Date(Date.UTC(2025, 0, index + 1)).toISOString().slice(0, 10);
    return {
      as_of_date: asOf,
      total_minor: 10_000_000 + index,
      unknown_component_count: 0,
      layers: emptyLayers({ BROKERAGE_INVESTMENT: 10_000_000 + index }),
      contributions_minor: 0,
      withdrawals_minor: 0,
      market_movement_minor: index === 0 ? null : 1,
    };
  });
  apiMock.mockResolvedValue({
    ...history,
    points,
    holdings: [],
    current_total_minor: points.at(-1)!.total_minor,
  } as never);

  render(<FinanceNetWorthPanel spaceID="household" currency="GBP" accounts={[account]} locale="en" onAskAbout={vi.fn()} />);
  await screen.findByRole("heading", { name: "£100,002" });
  expect(screen.queryByRole("region", { name: /Valuation history/ })).not.toBeInTheDocument();

  fireEvent.click(screen.getByText("Full breakdown"));
  const table = screen.getByRole("region", { name: /Valuation history/ });
  expect(within(table).getAllByRole("row")).toHaveLength(101);
  expect(screen.getByText("Page 1 of 3")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Previous" })).toBeDisabled();

  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  expect(screen.getByText("Page 2 of 3")).toBeInTheDocument();
  expect(within(table).getAllByRole("row")).toHaveLength(101);

  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  expect(screen.getByText("Page 3 of 3")).toBeInTheDocument();
  expect(within(table).getAllByRole("row")).toHaveLength(6);
  expect(screen.getByRole("button", { name: "Next" })).toBeDisabled();
});

it("reuses a previously loaded range instead of fetching the same graph twice", async () => {
  apiMock.mockResolvedValue(history as never);
  render(<FinanceNetWorthPanel spaceID="household" currency="GBP" accounts={[account]} locale="en" onAskAbout={vi.fn()} />);

  await screen.findByRole("heading", { name: "£120,000" });
  expect(apiMock).toHaveBeenCalledTimes(1);
  fireEvent.click(screen.getByRole("button", { name: "3Y" }));
  await waitFor(() => expect(apiMock).toHaveBeenCalledTimes(2));
  expect(apiMock.mock.calls[1][0]).toContain("days=1095");

  fireEvent.click(screen.getByRole("button", { name: "1Y" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "1Y" })).toHaveAttribute("aria-pressed", "true"));
  expect(apiMock).toHaveBeenCalledTimes(2);
});
