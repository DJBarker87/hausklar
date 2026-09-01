import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";

import { api } from "../api";
import type { FinanceCaptureInterpretResponse, FinanceSpace } from "../types";
import { FinanceCapturePanel } from "../views/FinanceCapturePanel";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

const apiMock = vi.mocked(api);

it("reviews a cash capture with the explicit purchase-only fallback before saving", async () => {
  const spaces: FinanceSpace[] = [{ id: "personal-1", kind: "personal", name: "Alex", is_default: true }];
  const interpretation: FinanceCaptureInterpretResponse = {
    mode: "REVIEW",
    answer: null,
    message: null,
    conversation_persisted: false,
    drafts: [{
      id: "draft-1",
      space_id: "personal-1",
      title: "Review this cash spend",
      content: {
        kind: "CASH_SPEND",
        merchant: "Market",
        spent_on: "2026-08-01",
        total_minor: 1800,
        currency: "EUR",
        account_hint: null,
        lines: [{ name: "Fruit", amount_minor: 1500, category_name: null, purpose: null, beneficiary: null, normalized_item: "Fruit", utility: "useful", outcome_state: null }],
        unassigned_remainder_minor: 300,
        uncertainties: [],
      },
      target_options: [{ id: "cash-spend:purchase-only", kind: "PURCHASE_ONLY", label: "Save purchase only (cash tender; no cashflow entry)", date: null, amount_minor: null, currency: "EUR" }],
      category_options: ["Quinn"],
      expires_at: "2026-08-01T12:00:00Z",
    }],
  };
  let interpretBody: Record<string, unknown> | null = null;
  let confirmBody: Record<string, unknown> | null = null;
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/capture/interpret") {
      interpretBody = JSON.parse(String(init?.body));
      return interpretation as never;
    }
    if (path === "/finance/capture/draft-1/confirm") {
      confirmBody = JSON.parse(String(init?.body));
      return { draft_id: "draft-1", status: "CONFIRMED", action_kind: "CASH_SPEND_PURCHASE_ONLY", action_id: "purchase-1", result: { posting_mode: "PURCHASE_ONLY", cashflow_posted: false } } as never;
    }
    throw new Error(`Unexpected path ${path}`);
  });

  render(<FinanceCapturePanel spaces={spaces} accounts={[]} locale="en" conversation={[]} context={{ screen: "explore", selected_transaction_id: "transaction-1", selected_purchase_id: null, selected_purchase_line_id: null, selected_account_id: null }} />);
  expect(screen.getByText(/processed transiently by the server/i)).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "I spent £18 cash at the market today." }));
  fireEvent.click(screen.getByRole("button", { name: "Check this" }));

  expect(await screen.findByText("Review this cash spend")).toBeInTheDocument();
  expect(screen.queryByLabelText("Saved category")).not.toBeInTheDocument();
  expect(screen.getByLabelText("How to record this")).toHaveValue("cash-spend:purchase-only");
  expect(screen.getByText("€18.00")).toBeInTheDocument();
  expect(screen.getByText("The total reconciles.")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Confirm this card" }));

  expect(await screen.findByText("Finance update saved.")).toBeInTheDocument();
  await waitFor(() => expect(confirmBody).not.toBeNull());
  expect(interpretBody).toMatchObject({ space_id: "personal-1", context: { screen: "explore", selected_transaction_id: "transaction-1" } });
  expect(confirmBody).toMatchObject({ selected_target_id: "cash-spend:purchase-only", selected_account_id: null });
});
