import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FinanceHistoryPage } from "../types";
import { FinanceDataControlsView } from "../views/FinanceDataControlsView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

function page(
  scope: "mine" | "household",
  offset: number,
  items: FinanceHistoryPage["items"],
  hasMore = false,
): FinanceHistoryPage {
  return { scope, offset, limit: 50, has_more: hasMore, items };
}

describe("Finance data controls", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/finance/history?scope=mine&offset=0&limit=50") return page("mine", 0, [{
        id: "history-personal",
        record_type: "transactions",
        record_id: "transaction-1",
        changed_at: "2026-08-02T09:30:00Z",
        changed_by_name: "Alex",
        changed_by_current_user: true,
        previous_values: { description: "Old description", amount_minor: -1299, status: "POSTED" },
      }], true) as never;
      if (path === "/finance/history?scope=mine&offset=50&limit=50") return page("mine", 50, [{
        id: "history-household",
        record_type: "goals",
        record_id: "goal-1",
        changed_at: "2026-08-01T08:00:00Z",
        changed_by_name: "Morgan",
        changed_by_current_user: false,
        previous_values: { name: "Synthetic public demo record 16" },
      }]) as never;
      if (path === "/finance/history?scope=household&offset=0&limit=50") return page("household", 0, [{
        id: "history-household-only",
        record_type: "commitments",
        record_id: "commitment-1",
        changed_at: "2026-08-03T07:00:00Z",
        changed_by_name: "Morgan",
        changed_by_current_user: false,
        previous_values: { name: "Nursery" },
      }]) as never;
      throw new Error(`Unexpected API request: ${path}`);
    });
  });

  it("exports the authorised records and pages through readable history", async () => {
    const view = render(<FinanceDataControlsView scope="mine" locale="en" />);

    expect(screen.getByRole("link", { name: "Export Finance data" }))
      .toHaveAttribute("href", "/api/finance/export");
    expect(await screen.findByText("Transaction")).toBeInTheDocument();
    expect(screen.getByText(/never another adult's private records/i)).toBeInTheDocument();
    fireEvent.click(screen.getByText("Previous values"));
    expect(screen.getByText("Status")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Load more" }));
    expect(await screen.findByText("Goal")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/finance/history?scope=mine&offset=50&limit=50",
      undefined,
      true,
      false,
    );

    view.rerender(<FinanceDataControlsView scope="household" locale="en" />);
    expect(await screen.findByText("Commitment")).toBeInTheDocument();
    expect(screen.getByText(/history shows Household changes only/i)).toBeInTheDocument();
    expect(screen.getByText(/export also includes your private Finance records/i)).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/history?scope=household&offset=0&limit=50",
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
      true,
      false,
    ));
  });
});
