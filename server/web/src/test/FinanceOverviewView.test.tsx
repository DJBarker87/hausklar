import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import type { FinanceOverview } from "../types";
import { FinanceOverviewView } from "../views/FinanceOverviewView";

const sparseOverview: FinanceOverview = {
  scope: "mine",
  month_start: "2026-08-01",
  through_date: "2026-08-10",
  currency: "GBP",
  account_count: 0,
  income_minor: 0,
  spending_minor: 0,
  spending_by_category: [],
  budget_buckets: [],
  current_available_minor: null,
  next_paycheck_date: null,
  next_paycheck_minor: null,
  left_until_payday_minor: null,
  commitments_before_payday_minor: 0,
  commitments_before_payday_count: 0,
  upcoming_commitments: [
    { name: "Annual insurance", due_date: "2026-09-02", amount_minor: 12_500 },
  ],
  savings_balance_minor: null,
  savings_change_minor: null,
  savings_series: [],
};

describe("FinanceOverviewView", () => {
  it("uses honest sparse states and does not describe generic commitments as before payday", () => {
    const openGoals = vi.fn();
    render(<FinanceOverviewView overview={sparseOverview} locale="en" onOpenGoals={openGoals} />);

    expect(screen.getByText("No spending recorded this month yet.")).toBeInTheDocument();
    expect(screen.getByText("No confirmed payday yet")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Upcoming commitments" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Still due before then" })).not.toBeInTheDocument();
    expect(screen.getByText("Annual insurance")).toBeInTheDocument();
    expect(screen.getByText("Connect savings accounts or goals to see their progress here.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Set up budgets" }));
    expect(openGoals).toHaveBeenCalledOnce();
  });
});
