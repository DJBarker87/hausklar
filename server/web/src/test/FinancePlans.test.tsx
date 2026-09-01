import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { todayInTimeZone } from "../financeDate";
import type { FinanceAccount, FinanceGoal, FinancePlan, FinancePlanEffortLevel, FinancePurchaseProposal, FinanceSpace } from "../types";
import { FinancePlansView } from "../views/FinancePlansView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const space: FinanceSpace = { id: "private", kind: "personal", name: "Alex", is_default: true };
const householdSpace: FinanceSpace = { id: "household", kind: "household", name: "Household", is_default: false };
const account: FinanceAccount = {
  id: "current",
  space_id: "private",
  institution: "Fixture Bank",
  label: "Daily current",
  account_type: "CURRENT",
  purpose: "OPERATING_CURRENT",
  currency: "GBP",
  last_four: null,
  include_in_cashflow: true,
  include_in_net_worth: true,
  primary_spending_account: true,
  minimum_balance_minor: 0,
  card_paid_in_full: false,
  card_settlement_account_id: null,
  card_statement_close_day: null,
  card_repayment_day: null,
  fresh_through_date: "2026-08-01",
  data_through_at: "2026-08-01T18:00:00Z",
  balance: { booked_minor: 120_000, available_minor: 120_000, credit_limit_minor: null, provider_at: "2026-08-01T18:00:00Z", observed_at: "2026-08-01T18:00:00Z" },
};

const houseGoal: FinanceGoal = {
  id: "house-goal",
  space_id: "private",
  name: "House deposit",
  target_minor: 100_000_00,
  deadline: "2030-08-02",
  currently_allocated_minor: 15_000_00,
  remaining_minor: 85_000_00,
  currency: "GBP",
  priority: "IMPORTANT",
  allowed_funding_sources: [],
  emergency_buffer_minor: 300_000,
  feasibility: "UNASSESSED",
  shortfall_minor: null,
  status: "ACTIVE",
  notes: null,
  created_at: "2026-08-02T10:00:00Z",
  updated_at: "2026-08-02T10:00:00Z",
};

function tierPlan(effort: FinancePlanEffortLevel, overrides: Partial<FinancePlan> = {}): FinancePlan {
  const values = {
    EASY: { strategy: "MINIMAL_DISRUPTION" as const, monthly: 100_000, projected: 63_000_00, shortfall: 37_000_00, finish: "2033-09-02", confidence: 8_000 },
    MEDIUM: { strategy: "RESILIENT" as const, monthly: 180_000, projected: 95_000_00, shortfall: 5_000_00, finish: "2030-11-02", confidence: 8_400 },
    HARD: { strategy: "AGGRESSIVE" as const, monthly: 230_000, projected: 100_000_00, shortfall: 0, finish: "2030-06-02", confidence: 7_800 },
  }[effort];
  return {
    id: `plan-${effort.toLowerCase()}`,
    proposal_group_id: "group-1",
    space_id: "private",
    version: 1,
    strategy: values.strategy,
    effort_level: effort,
    answer_basis: "BOUNDED",
    confidence_bps: values.confidence,
    required_monthly_minor: 250_000,
    planned_monthly_saving_minor: values.monthly,
    projected_amount_at_target_minor: values.projected,
    goal_shortfall_at_target_minor: values.shortfall,
    forecast_coverage_end: "2026-07-25",
    assumptions: ["Income and protected family costs stay broadly similar."],
    currency: "GBP",
    goal_id: "house-goal",
    source_plan_id: null,
    recovery_mode: null,
    target_date: "2030-08-02",
    supported_goal_date: values.finish,
    monthly_change_minor: values.monthly,
    household_buffer_minor: 300_000,
    required_reduction_minor: values.monthly,
    achieved_reduction_minor: values.monthly,
    shortfall_minor: values.shortfall,
    feasible: false,
    protected_category_count: 4,
    status: "PROPOSED",
    rationale: effort === "MEDIUM" ? "This makes strong progress without cutting protected family spending." : `${effort} changes based on current spending.`,
    categories: [{ category_id: `change-${effort}`, name: effort === "EASY" ? "Subscriptions" : effort === "MEDIUM" ? "Eating out and subscriptions" : "Shopping, eating out and subscriptions", baseline_minor: 80_000, floor_minor: 20_000, protected: false, weight: 1, reduction_minor: effort === "EASY" ? 20_000 : effort === "MEDIUM" ? 45_000 : 70_000, budget_minor: 60_000 }],
    activated_at: null,
    created_at: "2026-08-02T10:00:00Z",
    ...overrides,
  };
}

function mockPlanningLoad(plans: FinancePlan[]) {
  apiMock.mockImplementation(async (path, init) => {
    if (!path) return undefined as never;
    if (path === "/finance/settings") return { household_timezone: "Europe/London" } as never;
    const planList = path.match(/^\/finance\/plans\?space_id=([^&]+)&include_inactive=true$/);
    if (planList) return plans.filter((plan) => plan.space_id === decodeURIComponent(planList[1])) as never;
    if (/^\/finance\/payday-actions\?space_id=[^&]+&include_resolved=true$/.test(path)) return [] as never;
    if (/^\/finance\/habits\?space_id=[^&]+&include_inactive=true$/.test(path)) return [] as never;
    if (/^\/finance\/proposals\?space_id=[^&]+&include_resolved=true$/.test(path)) return [] as never;
    const match = path.match(/^\/finance\/plans\/(.+)\/activate$/);
    if (match && init?.method === "POST") {
      const selected = plans.find((plan) => plan.id === match[1]);
      if (!selected) throw new Error("Unknown plan");
      return { ...selected, status: "ACTIVE", activated_at: "2026-08-02T10:05:00Z" } as never;
    }
    throw new Error(`Unexpected API call: ${path}`);
  });
}

describe("Finance planning", () => {
  beforeEach(() => apiMock.mockReset());

  it("loads plan choices while household date settings are still arriving", async () => {
    let resolveSettings: (value: { household_timezone: string }) => void = () => undefined;
    apiMock.mockImplementation((path) => {
      if (!path) return undefined as never;
      if (path === "/finance/settings") {
        return new Promise((resolve) => { resolveSettings = resolve; }) as never;
      }
      if (path === "/finance/plans?space_id=private&include_inactive=true") {
        return Promise.resolve([tierPlan("MEDIUM")]) as never;
      }
      if (/^\/finance\/(?:payday-actions|habits|proposals)\?space_id=private/.test(path)) {
        return Promise.resolve([]) as never;
      }
      throw new Error(`Unexpected API call: ${path}`);
    });

    render(<FinancePlansView
      spaces={[space]}
      accounts={[account]}
      goals={[houseGoal]}
      monthlySummary={{ period_start: "2026-08-01", period_end: "2026-08-02", data_through: null, currencies: [] }}
      locale="en"
    />);

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/plans?space_id=private&include_inactive=true",
      expect.anything(),
      true,
      false,
    ));
    resolveSettings({ household_timezone: "Europe/London" });
    expect(await screen.findByRole("heading", { name: "House deposit" })).toBeInTheDocument();
  });

  it("shows three selectable saving tiers and keeps giving an answer when detailed spending is older", async () => {
    const plans = [tierPlan("EASY"), tierPlan("MEDIUM"), tierPlan("HARD")];
    mockPlanningLoad(plans);

    render(<FinancePlansView
      spaces={[space]}
      accounts={[account]}
      goals={[houseGoal]}
      monthlySummary={{
        period_start: "2026-08-01",
        period_end: "2026-08-02",
        data_through: "2026-08-01",
        currencies: [{ currency: "GBP", income_minor: 420_000, spending_minor: 372_000, saved_minor: 48_000 }],
      }}
      locale="en"
    />);

    expect(await screen.findByRole("heading", { name: "House deposit" })).toBeInTheDocument();
    const goalCard = screen.getByRole("heading", { name: "House deposit" }).closest<HTMLElement>("article");
    expect(goalCard).not.toBeNull();
    expect(within(goalCard!).getByText("£15,000.00")).toBeInTheDocument();
    expect(goalCard).toHaveTextContent("£15,000.00 of £100,000.00 saved");
    expect(within(goalCard!).getByText("2 Aug 2030")).toBeInTheDocument();
    expect(screen.getAllByText("£2,500.00").length).toBeGreaterThan(0);
    expect(screen.getByRole("heading", { name: "This month" })).toBeInTheDocument();
    expect(screen.getByText("£4,200.00")).toBeInTheDocument();
    expect(screen.getByText("£3,720.00")).toBeInTheDocument();
    expect(screen.getByText("£480.00")).toBeInTheDocument();

    const tierList = document.querySelector(".finance-tier-choice-grid");
    expect(tierList).not.toBeNull();
    const cards = Array.from((tierList as HTMLElement).querySelectorAll<HTMLElement>(":scope > .finance-tier-card"));
    expect(cards).toHaveLength(3);
    expect(within(cards[0]).getByRole("heading", { name: "Easy" })).toBeInTheDocument();
    expect(within(cards[1]).getByRole("heading", { name: "Medium" })).toBeInTheDocument();
    expect(within(cards[2]).getByRole("heading", { name: "Hard" })).toBeInTheDocument();
    expect(within(cards[1]).getByText("£1,800.00")).toBeInTheDocument();
    expect(within(cards[1]).getByText("Short by £5,000.00")).toBeInTheDocument();
    expect(within(cards[1]).getByText("2 Nov 2030")).toBeInTheDocument();
    expect(within(cards[1]).getByText("Eating out and subscriptions")).toBeInTheDocument();
    expect(within(tierList as HTMLElement).queryByText(/84% sure/)).not.toBeInTheDocument();
    expect(screen.getByText("Based on spending through 25 Jul 2026 · about 84% sure.")).toBeInTheDocument();

    expect(screen.queryByText(/won't reach|not enough data|cannot assess|outside the saved outlook/i)).not.toBeInTheDocument();
    const chooseButtons = within(tierList as HTMLElement).getAllByRole("button", { name: "Choose this plan" });
    expect(chooseButtons).toHaveLength(3);
    chooseButtons.forEach((button) => {
      expect(button.tagName).toBe("BUTTON");
      expect(button).toHaveAttribute("type", "button");
      expect(button).toBeEnabled();
    });

    fireEvent.click(within(cards[1]).getByRole("button", { name: "Choose this plan" }));
    expect(screen.getByText("Use this as your long-term saving plan?")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Yes, use this plan" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/plans/plan-medium/activate",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    expect(await screen.findByText("Plan chosen.")).toBeInTheDocument();
  });

  it("recalculates the exact monthly target when an older active plan saved it as zero", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-08-02T12:00:00Z"));
    try {
      const legacyPlan = tierPlan("MEDIUM", { status: "ACTIVE", required_monthly_minor: 0 });
      mockPlanningLoad([legacyPlan]);

      render(<FinancePlansView
        spaces={[space]}
        accounts={[account]}
        goals={[houseGoal]}
        monthlySummary={{ period_start: "2026-08-01", period_end: "2026-08-02", data_through: null, currencies: [] }}
        locale="en"
      />);

      const goalHeading = await screen.findByRole("heading", { name: "House deposit" });
      const goalCard = goalHeading.closest<HTMLElement>("article");
      expect(goalCard).not.toBeNull();
      const targetRow = within(goalCard!).getByText("Required each month").closest("div");
      expect(targetRow).toHaveTextContent("£1,734.70");
      expect(targetRow).not.toHaveTextContent("£0.00");
    } finally {
      vi.useRealTimers();
    }
  });

  it("builds This month from a calendar-month query and never folds older or partner-space spending into it", async () => {
    const analysisBodies: Array<Record<string, unknown>> = [];
    const householdAccount: FinanceAccount = { ...account, id: "house-current", space_id: householdSpace.id };
    apiMock.mockImplementation(async (path, init) => {
      if (!path) return undefined as never;
      if (path === "/finance/settings") return { household_timezone: "Europe/London" } as never;
      if (/^\/finance\/(?:plans|payday-actions|habits|proposals)\?space_id=/.test(path)) return [] as never;
      if (path === "/finance/analysis" && init?.method === "POST") {
        const body = JSON.parse(String(init.body)) as Record<string, unknown>;
        analysisBodies.push(body);
        const amount = body.space_id === householdSpace.id
          ? 9_999_00
          : body.measure === "INCOME" ? 420_000 : 372_000;
        return {
          basis: "TRANSACTIONS",
          currency: body.currency,
          total: { numerator: amount, denominator: 1 },
          groups: [],
          comparison_groups: [],
          comparison_total: null,
          comparison_start_date: null,
          comparison_end_date: null,
          data_through: todayInTimeZone("Europe/London"),
          itemisation_coverage: null,
          evidence: [],
          saved_view: null,
        } as never;
      }
      throw new Error(`Unexpected API call: ${path}`);
    });

    render(<FinancePlansView
      spaces={[space, householdSpace]}
      accounts={[account, householdAccount]}
      goals={[houseGoal]}
      monthlySpaceIDs={[space.id]}
      locale="en"
    />);

    expect(await screen.findByText("£4,200.00")).toBeInTheDocument();
    expect(screen.getByText("£3,720.00")).toBeInTheDocument();
    expect(screen.getByText("£480.00")).toBeInTheDocument();
    expect(screen.queryByText("£9,999.00")).not.toBeInTheDocument();

    const today = todayInTimeZone("Europe/London");
    expect(analysisBodies).toHaveLength(2);
    expect(analysisBodies).toEqual(expect.arrayContaining([
      expect.objectContaining({ space_id: "private", measure: "INCOME", start_date: `${today.slice(0, 7)}-01`, end_date: today }),
      expect.objectContaining({ space_id: "private", measure: "SPEND", start_date: `${today.slice(0, 7)}-01`, end_date: today }),
    ]));
    expect(analysisBodies.some((body) => body.space_id === householdSpace.id)).toBe(false);
  });

  it("refreshes all three choices when another goal has claimed money since this proposal was made", async () => {
    const stalePlans = [tierPlan("EASY"), tierPlan("MEDIUM"), tierPlan("HARD")];
    const refreshedPlans = [
      tierPlan("EASY", { id: "fresh-easy", proposal_group_id: "fresh-group", version: 2, planned_monthly_saving_minor: 90_000 }),
      tierPlan("MEDIUM", { id: "fresh-medium", proposal_group_id: "fresh-group", version: 2, planned_monthly_saving_minor: 170_000 }),
      tierPlan("HARD", { id: "fresh-hard", proposal_group_id: "fresh-group", version: 2, planned_monthly_saving_minor: 220_000 }),
    ];
    apiMock.mockImplementation(async (path, init) => {
      if (!path) return undefined as never;
      if (path === "/finance/settings") return { household_timezone: "Europe/London" } as never;
      if (path === "/finance/plans?space_id=private&include_inactive=true") return stalePlans as never;
      if (/^\/finance\/(?:payday-actions|habits|proposals)\?space_id=private/.test(path)) return [] as never;
      if (path === "/finance/plans/plan-medium/activate" && init?.method === "POST") {
        throw Object.assign(new Error("Plan allocations changed"), { status: 409 });
      }
      if (path === "/finance/plans/generate?space_id=private" && init?.method === "POST") return {
        proposal_group_id: "fresh-group",
        version: 2,
        recommendation_strategy: "RESILIENT",
        recommendation_effort_level: "MEDIUM",
        plans: refreshedPlans,
      } as never;
      throw new Error(`Unexpected API call: ${path}`);
    });

    render(<FinancePlansView
      spaces={[space]}
      accounts={[account]}
      goals={[houseGoal]}
      monthlySummary={{ period_start: "2026-08-01", period_end: "2026-08-02", data_through: null, currencies: [] }}
      locale="en"
    />);

    await screen.findByRole("heading", { name: "House deposit" });
    const tierList = document.querySelector<HTMLElement>(".finance-tier-choice-grid");
    expect(tierList).not.toBeNull();
    const staleCards = Array.from(tierList!.querySelectorAll<HTMLElement>(":scope > .finance-tier-card"));
    fireEvent.click(within(staleCards[1]).getByRole("button", { name: "Choose this plan" }));
    fireEvent.click(screen.getByRole("button", { name: "Yes, use this plan" }));

    expect(await screen.findByText("Another savings plan changed, so these amounts have been updated. Choose the plan you want.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/plans/generate?space_id=private",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ goal_id: houseGoal.id, source_plan_id: null, recovery_mode: null }),
      }),
      true,
      false,
    );
    const refreshedCards = Array.from(tierList!.querySelectorAll<HTMLElement>(":scope > .finance-tier-card"));
    expect(within(refreshedCards[0]).getByText("£900.00")).toBeInTheDocument();
    expect(within(refreshedCards[1]).getByText("£1,700.00")).toBeInTheDocument();
    expect(within(refreshedCards[2]).getByText("£2,200.00")).toBeInTheDocument();
    expect(screen.queryByText(/could not be activated/i)).not.toBeInTheDocument();
  });

  it("keeps several goals on different timescales separate and totals chosen allocations by currency", async () => {
    const holidayGoal: FinanceGoal = {
      ...houseGoal,
      id: "holiday-goal",
      space_id: householdSpace.id,
      name: "Synthetic public demo record 16",
      target_minor: 1_200_000,
      currently_allocated_minor: 200_000,
      remaining_minor: 1_000_000,
      deadline: "2027-06-01",
    };
    const emergencyGoal: FinanceGoal = {
      ...houseGoal,
      id: "emergency-goal",
      name: "Emergency fund",
      target_minor: 900_000,
      currently_allocated_minor: 100_000,
      remaining_minor: 800_000,
      deadline: "2028-02-15",
      currency: "EUR",
    };
    const houseActive = tierPlan("MEDIUM", {
      id: "house-medium-active",
      status: "ACTIVE",
      activated_at: "2026-08-02T10:10:00Z",
    });
    const holidayActive = tierPlan("EASY", {
      id: "holiday-easy-active",
      proposal_group_id: "holiday-group",
      space_id: householdSpace.id,
      goal_id: holidayGoal.id,
      status: "ACTIVE",
      activated_at: "2026-08-02T10:11:00Z",
      required_monthly_minor: 100_000,
      planned_monthly_saving_minor: 40_000,
      monthly_change_minor: 40_000,
      projected_amount_at_target_minor: 680_000,
      goal_shortfall_at_target_minor: 520_000,
      shortfall_minor: 520_000,
      target_date: holidayGoal.deadline,
      supported_goal_date: "2028-09-01",
    });
    const emergencyActive = tierPlan("HARD", {
      id: "emergency-hard-active",
      proposal_group_id: "emergency-group",
      goal_id: emergencyGoal.id,
      status: "ACTIVE",
      activated_at: "2026-08-02T10:12:00Z",
      currency: "EUR",
      required_monthly_minor: 45_000,
      planned_monthly_saving_minor: 30_000,
      monthly_change_minor: 30_000,
      projected_amount_at_target_minor: 650_000,
      goal_shortfall_at_target_minor: 250_000,
      shortfall_minor: 250_000,
      target_date: emergencyGoal.deadline,
      supported_goal_date: "2028-11-15",
    });
    const harderHousePlan = tierPlan("HARD", {
      id: "house-hard-proposed",
      proposal_group_id: "house-group-2",
      version: 2,
      planned_monthly_saving_minor: 230_000,
      monthly_change_minor: 230_000,
    });
    const plans = [harderHousePlan, houseActive, holidayActive, emergencyActive];
    mockPlanningLoad(plans);

    render(<FinancePlansView spaces={[space, householdSpace]} accounts={[account]} goals={[houseGoal, holidayGoal, emergencyGoal]} monthlySpaceIDs={[space.id]} locale="en" />);

    const houseCard = (await screen.findByRole("heading", { name: "House deposit" })).closest<HTMLElement>("article")!;
    const holidayCard = screen.getByRole("heading", { name: "Synthetic public demo record 16" }).closest<HTMLElement>("article")!;
    const emergencyCard = screen.getByRole("heading", { name: "Emergency fund" }).closest<HTMLElement>("article")!;
    expect(within(houseCard).getByText("2 Aug 2030")).toBeInTheDocument();
    expect(within(holidayCard).getByText("1 Jun 2027")).toBeInTheDocument();
    expect(within(holidayCard).getByText("Household")).toBeInTheDocument();
    expect(within(emergencyCard).getByText("15 Feb 2028")).toBeInTheDocument();
    expect(within(houseCard).getByText("Medium · £1,800.00 a month")).toBeInTheDocument();
    expect(within(holidayCard).getByText("Easy · £400.00 a month")).toBeInTheDocument();
    expect(within(emergencyCard).getByText("Hard · €300.00 a month")).toBeInTheDocument();

    const allocations = screen.getByRole("heading", { name: "Your separate allocations" }).closest<HTMLElement>("article")!;
    expect(within(allocations).getByText("£2,200.00 a month")).toBeInTheDocument();
    expect(within(allocations).getByText("€300.00 a month")).toBeInTheDocument();
    expect(screen.getByText(/same money is never shown as funding two goals/i)).toBeInTheDocument();

    fireEvent.click(within(houseCard).getByRole("button", { name: "Review plan" }));
    fireEvent.click(screen.getByRole("button", { name: "Choose this plan" }));
    fireEvent.click(screen.getByRole("button", { name: "Yes, use this plan" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/plans/house-hard-proposed/activate",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    expect(within(houseCard).getByText("Hard · £2,300.00 a month")).toBeInTheDocument();
    expect(within(holidayCard).getByText("Easy · £400.00 a month")).toBeInTheDocument();
    expect(within(emergencyCard).getByText("Hard · €300.00 a month")).toBeInTheDocument();
    expect(within(allocations).getByText("£2,700.00 a month")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/plans?space_id=household&include_inactive=true",
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
      true,
      false,
    );
  });

  it("shows field-level goal errors and focuses the first invalid field", async () => {
    mockPlanningLoad([]);
    render(<FinancePlansView spaces={[space]} accounts={[account]} goals={[]} locale="en" />);

    fireEvent.click(await screen.findByRole("button", { name: "Set a savings goal" }));
    const save = screen.getByRole("button", { name: "Save goal" });
    fireEvent.click(save);

    const name = screen.getByLabelText("What are you saving for?");
    const target = screen.getByLabelText("Target amount");
    const deadline = screen.getByLabelText("Target date");
    const allocated = screen.getByLabelText("Already set aside (optional)");
    expect(name).toHaveFocus();
    expect(name).toHaveAttribute("aria-invalid", "true");
    expect(target).toHaveAttribute("aria-invalid", "true");
    expect(deadline).toHaveAttribute("aria-invalid", "true");
    expect(allocated).not.toHaveAttribute("aria-invalid");
    expect(name).toHaveAccessibleDescription("Name the goal so everyone knows what this money is for.");
    expect(target).toHaveAccessibleDescription("Enter a target greater than zero, with no more than two decimal places.");
    expect(deadline).toHaveAccessibleDescription("Choose today or a later date.");
  });

  it("keeps advanced planning collapsed and checks a purchase from only what, cost and date", async () => {
    let createdProposal: FinancePurchaseProposal | null = null;
    apiMock.mockImplementation(async (path, init) => {
      if (!path) return undefined as never;
      if (path === "/finance/settings") return { household_timezone: "Europe/London" } as never;
      if (path === "/finance/plans?space_id=private&include_inactive=true") return [] as never;
      if (path === "/finance/payday-actions?space_id=private&include_resolved=true") return [] as never;
      if (path === "/finance/habits?space_id=private&include_inactive=true") return [] as never;
      if (path === "/finance/proposals?space_id=private&include_resolved=true") return [] as never;
      if (path === "/finance/proposals?space_id=private" && init?.method === "POST") {
        const body = JSON.parse(String(init.body));
        createdProposal = {
          id: "proposal-1",
          space_id: "private",
          source_kind: "TEXT",
          name: body.name,
          amount_low_minor: body.amount_low_minor,
          amount_high_minor: body.amount_high_minor,
          desired_date: body.desired_date,
          recurrence: "ONE_OFF",
          payment_account_id: body.payment_account_id,
          purpose: body.purpose,
          beneficiary: body.beneficiary,
          lines: [],
          cheaper_alternative_minor: body.cheaper_alternative_minor,
          later_date: body.later_date,
          uncertainties: [],
          currency: "GBP",
          status: "CONFIRMED",
          approved_scenario: null,
          created_at: "2026-08-02T10:00:00Z",
          updated_at: "2026-08-02T10:00:00Z",
        };
        return createdProposal as never;
      }
      if (path === "/finance/forecasts?space_id=private" && init?.method === "POST") return { id: "forecast-1" } as never;
      if (path === "/finance/proposals/proposal-1/evaluate" && init?.method === "POST") return {
        id: "evaluation-1",
        proposal_id: "proposal-1",
        forecast_id: "forecast-1",
        verdict: "YES",
        rationale: "This fits without using protected money.",
        scenarios: [{ scenario: "BUY_NOW", status: "FEASIBLE", passed: true, minimum_household_free_minor: 55_000, assumptions: ["Uses usual spending since the latest bank records."] }],
        historical_context: { confidence_bps: 8000 },
        evidence_refs: [],
        data_through_at: "2026-08-01T18:00:00Z",
        created_at: "2026-08-02T10:00:00Z",
      } as never;
      throw new Error(`Unexpected API call: ${path}`);
    });

    render(<FinancePlansView spaces={[space]} accounts={[account]} goals={[]} locale="en" />);

    expect(await screen.findByRole("heading", { name: "Your savings goals" })).toBeInTheDocument();
    expect(screen.queryByLabelText("Finances")).not.toBeInTheDocument();
    expect(screen.getByText("Savings goal and three plans").closest("details")).not.toHaveAttribute("open");
    expect(screen.getByText("Payday actions and habit details").closest("details")).not.toHaveAttribute("open");

    const submit = screen.getByRole("button", { name: "Save and compare choices" });
    const form = submit.closest("form");
    expect(form).not.toBeNull();
    const compactFields = form!.querySelector(".finance-proposal-form-grid.is-compact");
    expect(compactFields?.querySelectorAll("input")).toHaveLength(3);
    const optional = within(form!).getByText("Optional purchase details").closest("details");
    expect(optional).not.toHaveAttribute("open");
    expect(form!.querySelector("#finance-proposal-cheaper")).toBeNull();
    expect(form!.querySelector("input[type='checkbox']")).toBeNull();

    fireEvent.change(within(form!).getByLabelText("What are you considering?"), { target: { value: "Family bike" } });
    const amountField = within(form!).getByLabelText("Expected amount (GBP)");
    expect(amountField).toHaveAttribute("inputmode", "decimal");
    expect(amountField).toHaveAttribute("placeholder", "e.g. 250.00");
    fireEvent.change(amountField, { target: { value: "450.00" } });
    fireEvent.click(submit);

    const verdict = await screen.findByText("Fits now");
    const evaluationCard = verdict.closest<HTMLElement>("article.finance-proposal-evaluation");
    expect(evaluationCard).not.toBeNull();
    const rationale = within(evaluationCard!).getByText("This fits without using protected money.");
    const basis = evaluationCard!.querySelector<HTMLElement>(".finance-purchase-basis-note");
    expect(basis).toHaveTextContent("Based on spending through 1 Aug 2026 · Uses usual spending since the latest bank records. · about 80% sure");
    expect(rationale.compareDocumentPosition(basis!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(within(evaluationCard!).queryByText("Data through")).not.toBeInTheDocument();
    expect(within(evaluationCard!).queryByText("Assumptions")).not.toBeInTheDocument();
    expect(document.querySelector(".finance-purchase-evaluation-context")).toBeNull();
    expect(createdProposal).not.toBeNull();
    const createCall = apiMock.mock.calls.find(([path, init]) => path === "/finance/proposals?space_id=private" && init?.method === "POST");
    const body = JSON.parse(String(createCall?.[1]?.body));
    expect(body).toMatchObject({
      reviewed: true,
      name: "Family bike",
      amount_low_minor: 45_000,
      amount_high_minor: 45_000,
      payment_account_id: "current",
      purpose: null,
      beneficiary: null,
      later_date: null,
      cheaper_alternative_minor: null,
    });
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/proposals/proposal-1/evaluate",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
  });
});
