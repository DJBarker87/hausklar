import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import App, { readLocation } from "../App";
import { api } from "../api";

const authState = vi.hoisted(() => ({
  user: {
    id: "dom",
    name: "Alex",
    email: "dom@example.invalid",
    role: "admin",
    priority: 5,
    family_id: "family",
  },
}));

vi.mock("../AuthContext", () => ({
  useAuth: () => ({ user: authState.user, loading: false, signOut: vi.fn(), updateUser: vi.fn() }),
}));
vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;

    constructor(message: string, status: number) {
      super(message);
      this.status = status;
    }
  },
  flushOfflineQueue: vi.fn().mockResolvedValue(undefined),
  offlineQueueSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, held: 0 }),
}));
vi.mock("../offlineQueue", () => ({
  heldQueuedMutations: vi.fn().mockResolvedValue([]),
  queuedMutations: vi.fn().mockResolvedValue([]),
  removeQueuedMutation: vi.fn().mockResolvedValue(undefined),
}));

const apiMock = vi.mocked(api);

function overview(scope: "mine" | "household") {
  return {
    scope,
    month_start: "2026-08-01",
    through_date: "2026-08-10",
    currency: "GBP",
    account_count: 2,
    income_minor: 400_000,
    spending_minor: 82_500,
    spending_by_category: [
      { category_key: "groceries", name: "Quinn", spending_type: "FLEXIBLE", spent_minor: 82_500, share_bps: 10_000 },
    ],
    budget_buckets: [],
    current_available_minor: 317_500,
    next_paycheck_date: "2026-08-28",
    next_paycheck_minor: 400_000,
    left_until_payday_minor: 275_000,
    commitments_before_payday_minor: 42_500,
    commitments_before_payday_count: 1,
    upcoming_commitments: [{ name: "Council tax", due_date: "2026-08-20", amount_minor: 42_500 }],
    savings_balance_minor: 900_000,
    savings_change_minor: 25_000,
    savings_series: [
      { date: "2026-07-01", balance_minor: 875_000 },
      { date: "2026-08-10", balance_minor: 900_000 },
    ],
  };
}

describe("Finance query routing and navigation", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.localStorage.clear();
    apiMock.mockImplementation(async (path) => {
      if (path === "/family/members") return [];
      if (path === "/finance/spaces") return [
        { id: "personal-dom", kind: "personal", name: "Alex", is_default: true },
        { id: "household", kind: "household", name: "Household", is_default: false },
      ];
      if (path === "/finance/overview?scope=mine") return overview("mine");
      if (path === "/finance/overview?scope=household") return overview("household");
      if (path.startsWith("/finance/accounts?space_id=")) return [];
      if (path.startsWith("/finance/summary?space_id=")) {
        const spaceID = new URL(path, "https://hausklar.test").searchParams.get("space_id");
        return { space_id: spaceID, data_through_at: null, currencies: [] };
      }
      if (path.startsWith("/finance/transactions?space_id=")) return [];
      if (path.startsWith("/finance/commitments?space_id=")) return [];
      if (path.startsWith("/finance/reserves?space_id=")) return [];
      if (path.startsWith("/finance/goals?space_id=")) return [];
      if (path === "/finance/settings") return { household_timezone: "Europe/London" };
      if (path.startsWith("/finance/plans?space_id=")) return [];
      if (path.startsWith("/finance/payday-actions?space_id=")) return [];
      if (path.startsWith("/finance/habits?space_id=")) return [];
      if (path.startsWith("/finance/proposals?space_id=")) return [];
      if (path.startsWith("/finance/purchases/inbox?space_id=")) return [];
      if (path.startsWith("/finance/purchases?space_id=")) return [];
      if (path.startsWith("/renewals")) return [];
      throw new Error(`Unexpected API request: ${path}`);
    });
    window.history.replaceState({}, "", "/?view=finance&section=overview&scope=household");
    window.scrollTo = vi.fn();
  });

  it("parses Finance sections and scope from the existing query-param route", () => {
    window.history.replaceState({}, "", "/?view=finance&section=purchases&scope=household");
    expect(readLocation()).toMatchObject({
      view: "finance",
      finance: "more",
      financeScope: "household",
    });
  });

  it("uses Overview when a Finance link has no section", () => {
    window.history.replaceState({}, "", "/?view=finance");

    expect(readLocation()).toMatchObject({ view: "finance", finance: "overview" });
  });

  it("maps old Finance links into the new everyday and advanced areas", () => {
    const cases: Array<[string, string]> = [
      ["commitments", "goals"],
      ["transactions", "activity"],
      ["purchase-inbox", "more"],
      ["opportunities", "explore"],
      ["agent", "coach"],
      ["accounts", "setup"],
    ];
    for (const [oldSection, currentSection] of cases) {
      window.history.replaceState({}, "", `/?view=finance&section=${oldSection}&action=kept`);
      expect(readLocation().finance).toBe(currentSection);
      expect(new URL(window.location.href).searchParams.get("action")).toBe("kept");
    }
  });

  it("routes legacy receipt focus to More while transaction focus stays in Activity", () => {
    for (const parameter of ["purchase=purchase-1", "line=line-1", "evidence=evidence-1"]) {
      window.history.replaceState({}, "", `/?view=finance&section=activity&${parameter}`);
      expect(readLocation().finance).toBe("more");
    }
    window.history.replaceState({}, "", "/?view=finance&section=activity&transaction=transaction-1");
    expect(readLocation().finance).toBe("activity");
  });

  it("keeps Renewals in its canonical Lists home", async () => {
    window.history.replaceState({}, "", "/?view=lists&section=renewals");
    expect(readLocation()).toMatchObject({
      view: "lists",
      lists: "renewals",
    });

    render(<App />);

    await waitFor(() => {
      const query = new URLSearchParams(window.location.search);
      expect(query.get("view")).toBe("lists");
      expect(query.get("section")).toBe("renewals");
      expect(query.has("scope")).toBe(false);
    });
  });

  it("keeps the quiet More area inside Finance", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=more&scope=household");
    expect(readLocation()).toMatchObject({ view: "finance", finance: "more", financeScope: "household" });

    render(<App />);

    expect(await screen.findByRole("heading", { name: "More Finance tools" })).toBeInTheDocument();
    await waitFor(() => {
      const query = new URLSearchParams(window.location.search);
      expect(query.get("view")).toBe("finance");
      expect(query.get("section")).toBe("more");
      expect(query.get("scope")).toBe("household");
    });
  });

  it("preserves legacy renewal deep links with a narrow redirect to Lists", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=more&scope=household&renewal=renewal-1");
    expect(readLocation()).toMatchObject({ view: "lists", lists: "renewals" });

    render(<App />);

    await waitFor(() => {
      const query = new URLSearchParams(window.location.search);
      expect(query.get("view")).toBe("lists");
      expect(query.get("section")).toBe("renewals");
      expect(query.get("renewal")).toBe("renewal-1");
      expect(query.has("scope")).toBe(false);
    });
  });

  it("keeps Fitness in the five mobile destinations and puts House and Finance in the header overflow", async () => {
    window.localStorage.setItem("hausklar:fitness-workspace:family:dom", JSON.stringify({ enabled: true, pinned: true }));
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Spending this month" }, { timeout: 5_000 }))
      .toBeInTheDocument();
    await waitFor(() => expect(window.location.search).toContain("section=overview"));
    expect(window.location.search).toContain("scope=household");
    const navigation = screen.getAllByRole("navigation", { name: "Main navigation" });
    expect(within(navigation[0]).getAllByRole("button")).toHaveLength(5);
    expect(within(navigation[1]).getAllByRole("button")).toHaveLength(5);
    expect(within(navigation[1]).getByRole("button", { name: "Fitness" })).toBeInTheDocument();
    expect(within(navigation[1]).queryByRole("button", { name: "Finance" })).not.toBeInTheDocument();
    expect(within(navigation[1]).queryByRole("button", { name: "House" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "More navigation and appearance" }));
    const dialog = screen.getByRole("dialog", { name: "More HausKlar" });
    expect(within(dialog).queryByRole("button", { name: /Fitness/ })).not.toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: /House/ })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: /Finance/ })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "System" })).toHaveAttribute("aria-pressed", "true");
    expect(within(dialog).getByRole("button", { name: "Light" })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "Dark" })).toBeInTheDocument();
  });

  it("updates the URL when the user switches section and scope", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=purchases&scope=household&evidence=old-source&line=old-line&purchase=old-purchase&transaction=old-transaction&commitment=old-commitment");
    render(<App />);
    expect(await screen.findByRole("heading", { name: "More Finance tools" }))
      .toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /AnalysisBuild your own analysis/ }));
    await waitFor(() => expect(window.location.search).toContain("section=explore"));
    for (const parameter of ["evidence", "line", "purchase", "transaction", "commitment"]) {
      expect(new URLSearchParams(window.location.search).has(parameter)).toBe(false);
    }
    const withStaleTransaction = new URL(window.location.href);
    withStaleTransaction.searchParams.set("transaction", "stale-after-section");
    window.history.replaceState({}, "", withStaleTransaction);
    fireEvent.click(screen.getByRole("button", { name: "My finances" }));
    await waitFor(() => expect(window.location.search).not.toContain("scope=household"));
    expect(new URLSearchParams(window.location.search).has("transaction")).toBe(false);
  });

  it("returns to Overview whenever Finance is entered from the secondary workspace navigation", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=more&scope=household");
    render(<App />);
    expect(await screen.findByRole("heading", { name: "More Finance tools" })).toBeInTheDocument();

    const desktopWorkspaces = screen.getByRole("navigation", { name: "House and personal workspaces" });
    fireEvent.click(within(desktopWorkspaces).getByRole("button", { name: "Finance" }));

    expect(await screen.findByRole("heading", { name: "Spending this month", level: 2 })).toBeInTheDocument();
    await waitFor(() => expect(new URLSearchParams(window.location.search).get("section")).toBe("overview"));
  });

  it("opens Settings Money in My finances even when Household was last used", async () => {
    window.localStorage.setItem("hausklar:finance:family:dom:scope", "household");
    render(<App />);

    const householdScope = await screen.findByRole("button", { name: "Household" });
    expect(householdScope).toHaveAttribute("aria-pressed", "true");

    const desktopNavigation = screen.getAllByRole("navigation", { name: "Main navigation" })[0];
    fireEvent.click(within(desktopNavigation).getByRole("button", { name: "Today" }));
    fireEvent.click(screen.getAllByRole("button", { name: "Settings and profile" })[0]);

    const settings = await screen.findByRole("dialog", { name: "Settings & profile" });
    fireEvent.click(await within(settings).findByRole("button", { name: /Personal workspaces/ }));
    fireEvent.click(await within(settings).findByRole("button", { name: /Money/ }));

    const myScope = await screen.findByRole("button", { name: "My finances" });
    await waitFor(() => expect(myScope).toHaveAttribute("aria-pressed", "true"));
    expect(screen.getByRole("button", { name: "Household" })).toHaveAttribute("aria-pressed", "false");
    expect(window.localStorage.getItem("hausklar:finance:family:dom:scope")).toBe("mine");
    await waitFor(() => {
      const query = new URLSearchParams(window.location.search);
      expect(query.get("view")).toBe("finance");
      expect(query.get("section")).toBe("overview");
      expect(query.has("scope")).toBe(false);
    });
    expect(apiMock.mock.calls.some(([path]) => path === "/finance/overview?scope=mine")).toBe(true);
  });

  it("opens Finance for every family account without an entitlement field", async () => {
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Spending this month" })).toBeInTheDocument();
    const workspaces = screen.getByRole("navigation", { name: "House and personal workspaces" });
    expect(within(workspaces).getByRole("button", { name: "Finance" })).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/finance/spaces")).toBe(true);
  });
});
