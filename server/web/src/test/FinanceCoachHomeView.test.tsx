import { render, screen, within } from "@testing-library/react";
import { expect, it, vi } from "vitest";

import { api } from "../api";
import type { FinanceCoachingReport, FinanceSpace } from "../types";
import { FinanceCoachHomeView } from "../views/FinanceCoachHomeView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const currentTime = new Date().toISOString();

function report(
  spaceID: string,
  primaryAction: Record<string, unknown> | null,
): FinanceCoachingReport {
  return {
    id: `report-${spaceID}`,
    space_id: spaceID,
    member_user_id: "dom",
    report_kind: "DAILY",
    local_date: currentTime.slice(0, 10),
    household_timezone: "Europe/London",
    locale: "en",
    currency: "GBP",
    input_digest: `digest-${spaceID}`,
    data_through_at: currentTime,
    itemised_coverage_bps: 10_000,
    trajectory_status: "ON_PLAN",
    expected_durable_saving_minor: 0,
    primary_action: primaryAction,
    optional_observation: null,
    summary: {},
    explanation: "The saved figures are on plan.",
    created_at: currentTime,
  };
}

it("uses only the Finance space selected by the parent", async () => {
  const spaces: FinanceSpace[] = [
    { id: "personal-1", kind: "personal", name: "Alex", is_default: true },
    { id: "household-1", kind: "household", name: "Household", is_default: false },
  ];
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1") {
      return [report("personal-1", null)] as never;
    }
    if (path === "/finance/reports?space_id=household-1&report_kind=DAILY&limit=1") {
      return [
        report("household-1", {
          kind: "PAYDAY_TRANSFER",
          record_id: "payday-action-1",
          amount_minor: 5000,
          currency: "GBP",
        }),
      ] as never;
    }
    if (path === "/finance/reports?space_id=household-1&report_kind=WEEKLY&limit=1") {
      return [];
    }
    if (path.startsWith("/finance/report-preferences?")) {
      const spaceID = new URL(path, "https://hausklar.test").searchParams.get("space_id");
      return { space_id: spaceID, show_more_by_default: false } as never;
    }
    if (
      path.startsWith("/finance/habits?")
      || path.startsWith("/finance/opportunities?")
      || path.startsWith("/finance/purchases/inbox?")
    ) {
      return [];
    }
    throw new Error(`Unexpected API request: ${path}`);
  });

  const view = render(<FinanceCoachHomeView spaces={[spaces[0]]} scope="mine" commitments={[]} goals={[]} locale="en" />);

  expect(await screen.findByText("No action is needed this month.")).toBeInTheDocument();
  expect(screen.queryByRole("combobox", { name: "Finances" })).not.toBeInTheDocument();
  expect(apiMock.mock.calls.some(([path]) => String(path).includes("household-1"))).toBe(false);

  view.rerender(<FinanceCoachHomeView spaces={[spaces[1]]} scope="household" commitments={[]} goals={[]} locale="en" />);
  expect(await screen.findByRole("heading", { name: "Move the money you planned" })).toBeInTheDocument();
});

it("leads with the three decisions a busy adult needs", async () => {
  apiMock.mockReset();
  const selected: FinanceSpace = { id: "personal-1", kind: "personal", name: "Alex", is_default: true };
  const decisionReport = {
    ...report("personal-1", {
      kind: "PURCHASE_REVIEW",
      record_id: "purchase-1",
      title: "Review the supermarket receipt",
    }),
    summary: {
      safe_to_spend: { amount_minor: 12_345, currency: "GBP" },
      next_protected_commitment: {
        name: "Nursery",
        due_date: "2026-08-12",
        amount_minor: 32_000,
        currency: "GBP",
      },
    },
  } satisfies FinanceCoachingReport;
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1") return [decisionReport] as never;
    if (path === "/finance/report-preferences?space_id=personal-1") return { space_id: "personal-1", show_more_by_default: false } as never;
    if (
      path.startsWith("/finance/habits?")
      || path.startsWith("/finance/opportunities?")
      || path.startsWith("/finance/purchases/inbox?")
    ) return [] as never;
    if (path === "/finance/analysis") return { basis: "TRANSACTIONS", currency: "GBP", groups: [] } as never;
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceCoachHomeView spaces={[selected]} scope="mine" commitments={[]} goals={[]} locale="en" />);

  const summary = await screen.findByRole("region", { name: "Money now" });
  expect(within(summary).getByText("Needs attention")).toBeInTheDocument();
  expect(within(summary).getByText("Check the planned purchase")).toBeInTheDocument();
  expect(within(summary).getByText("Available after commitments")).toBeInTheDocument();
  expect(within(summary).getByText("£123.45")).toBeInTheDocument();
  expect(within(summary).getByText("Next bill")).toBeInTheDocument();
  expect(within(summary).getByText("Nursery")).toBeInTheDocument();
  expect(within(summary).getByText(/£320\.00/)).toBeInTheDocument();
});

it("shows low-confidence categories as a ranked list with uncategorised spend explicit", async () => {
  apiMock.mockReset();
  const selected: FinanceSpace = { id: "personal-1", kind: "personal", name: "Alex", is_default: true };
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1") {
      return [report("personal-1", null)] as never;
    }
    if (path === "/finance/report-preferences?space_id=personal-1") {
      return { space_id: "personal-1", show_more_by_default: false } as never;
    }
    if (
      path.startsWith("/finance/habits?")
      || path.startsWith("/finance/opportunities?")
      || path.startsWith("/finance/purchases/inbox?")
    ) return [] as never;
    if (path === "/finance/analysis") {
      return {
        basis: "TRANSACTIONS",
        currency: "GBP",
        groups: [
          { key: "(unknown)", value: { numerator: 9_600, denominator: 1 }, record_count: 12, evidence_handles: [] },
          { key: "Quinn", value: { numerator: 400, denominator: 1 }, record_count: 1, evidence_handles: [] },
        ],
      } as never;
    }
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceCoachHomeView spaces={[selected]} scope={selected.kind === "household" ? "household" : "mine"} commitments={[]} goals={[]} locale="en" />);

  const ranking = await screen.findByRole("list", { name: "Spending by category, largest first" });
  expect(within(ranking).getByText("Uncategorised")).toBeInTheDocument();
  expect(screen.getByText("4%", { selector: "strong" })).toBeInTheDocument();
  expect(screen.queryByRole("img", { name: "Spending by category, last 30 days" })).not.toBeInTheDocument();
});

it("keeps the answer and easy win visible without freshness furniture", async () => {
  apiMock.mockReset();
  const selected: FinanceSpace = { id: "personal-1", kind: "personal", name: "Alex", is_default: true };
  const datedReport = {
    ...report("personal-1", null),
    data_through_at: "2026-01-10T08:00:00Z",
    explanation: "You can keep the current savings transfer and still cover the known bills.",
  };
  apiMock.mockImplementation(async (path) => {
    if (path === "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1") return [datedReport] as never;
    if (path === "/finance/report-preferences?space_id=personal-1") return { space_id: "personal-1", show_more_by_default: false } as never;
    if (path.startsWith("/finance/habits?")) throw new Error("Habit history is temporarily unavailable");
    if (path.startsWith("/finance/purchases/inbox?")) return [] as never;
    if (path === "/finance/opportunities?space_id=personal-1") return [{
      id: "easy-win-1",
      space_id: "personal-1",
      finding_type: "ANNUALISED_SMALL_COST",
      title: "Cancel the unused photo-storage add-on",
      observation: "The add-on has repeated for six months without any saved photos.",
      evidence_refs: ["transaction:add-on"],
      baseline: { annualised_minor: 7_200, payment_count: 6 },
      saving_low_minor: 600,
      saving_high_minor: 600,
      currency: "GBP",
      confidence_bps: 8_000,
      effort: 1,
      overlap_group: null,
      status: "OPEN",
      data_through_date: "2026-01-10",
      updated_at: "2026-01-10T08:00:00Z",
    }] as never;
    if (path === "/finance/analysis") return { basis: "TRANSACTIONS", currency: "GBP", groups: [] } as never;
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceCoachHomeView spaces={[selected]} scope={selected.kind === "household" ? "household" : "mine"} commitments={[]} goals={[]} locale="en" />);

  expect(await screen.findByText("You can keep the current savings transfer and still cover the known bills.")).toBeInTheDocument();
  expect(screen.getByRole("heading", { name: "One easy win" })).toBeInTheDocument();
  expect(screen.getByText("Cancel the unused photo-storage add-on")).toBeInTheDocument();
  expect(screen.queryByText(/Based on spending through|latest saved spending|\d+% sure/i)).not.toBeInTheDocument();
});

it("starts the monthly report, preferences, habits and opportunities together", async () => {
  apiMock.mockReset();
  const selected: FinanceSpace = { id: "personal-1", kind: "personal", name: "Alex", is_default: true };
  let resolveDaily: (value: FinanceCoachingReport[]) => void = () => undefined;
  apiMock.mockImplementation((path) => {
    if (path === "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1") {
      return new Promise<FinanceCoachingReport[]>((resolve) => { resolveDaily = resolve; }) as never;
    }
    if (path === "/finance/report-preferences?space_id=personal-1") {
      return Promise.resolve({ space_id: "personal-1", show_more_by_default: false }) as never;
    }
    if (
      path.startsWith("/finance/habits?")
      || path.startsWith("/finance/opportunities?")
      || path.startsWith("/finance/purchases/inbox?")
    ) return Promise.resolve([]) as never;
    if (path === "/finance/analysis") return Promise.resolve({ basis: "TRANSACTIONS", currency: "GBP", groups: [] }) as never;
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(<FinanceCoachHomeView spaces={[selected]} scope={selected.kind === "household" ? "household" : "mine"} commitments={[]} goals={[]} locale="en" />);

  await vi.waitFor(() => expect(apiMock.mock.calls.map(([path]) => path)).toEqual(expect.arrayContaining([
    "/finance/reports?space_id=personal-1&report_kind=DAILY&limit=1",
    "/finance/report-preferences?space_id=personal-1",
    "/finance/habits?space_id=personal-1",
    "/finance/opportunities?space_id=personal-1",
    "/finance/purchases/inbox?space_id=personal-1&offset=0&limit=3",
  ])));
  resolveDaily([report("personal-1", null)]);
  expect(await screen.findByText("No action is needed this month.")).toBeInTheDocument();
});
