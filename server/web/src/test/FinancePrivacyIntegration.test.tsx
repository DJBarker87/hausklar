import { fireEvent, render, screen, waitFor } from "@testing-library/react";
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
  flushOfflineQueue: vi.fn().mockResolvedValue(undefined),
  offlineQueueSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, held: 0 }),
}));
vi.mock("../offlineQueue", () => ({
  heldQueuedMutations: vi.fn().mockResolvedValue([]),
  queuedMutations: vi.fn().mockResolvedValue([]),
  removeQueuedMutation: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("../views/FinanceView", () => ({
  FinanceView: () => <h1>Private Finance workspace</h1>,
}));
vi.mock("../views/RenewalsView", () => ({
  RenewalsView: () => <h1>Household renewals</h1>,
}));

const apiMock = vi.mocked(api);

describe("Finance privacy integrations", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/family/members") return [] as never;
      return [] as never;
    });
    window.history.replaceState({}, "", "/?view=finance&section=coach");
    window.scrollTo = vi.fn();
  });

  it("removes both global Add/Bismarck launchers throughout Finance", async () => {
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Private Finance workspace" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add or ask Bismarck" })).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Quick actions" })).not.toBeInTheDocument();
  });

  it("keeps the Renewals route in shared Lists without loading private Finance data", async () => {
    window.history.replaceState({}, "", "/?view=lists&section=renewals");

    expect(readLocation()).toMatchObject({ view: "lists", lists: "renewals" });
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Household renewals" })).toBeInTheDocument();
    const location = new URL(window.location.href);
    expect(location.searchParams.get("view")).toBe("lists");
    expect(location.searchParams.get("section")).toBe("renewals");
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/finance/"))).toBe(false);
  });

  it("shows Renewals in the Lists hub for family accounts", async () => {
    window.history.replaceState({}, "", "/?view=lists");
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Lists" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Renewals/ }));
    expect(await screen.findByRole("heading", { name: "Household renewals" })).toBeInTheDocument();
    await waitFor(() => expect(window.location.search).toContain("section=renewals"));
  });
});
