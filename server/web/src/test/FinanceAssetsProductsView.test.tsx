import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FinanceAccount, FinanceSpace } from "../types";
import { FinanceAssetsProductsView } from "../views/FinanceAssetsProductsView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const space: FinanceSpace = { id: "private", kind: "personal", name: "Alex", is_default: true };
const account = {
  id: "current",
  space_id: "private",
  currency: "GBP",
} as FinanceAccount;

describe("FinanceAssetsProductsView retailer prices", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=finance&section=assets&item=oats");
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/finance/settings") return {
        default_currency: "GBP",
        household_timezone: "Europe/London",
      } as never;
      if (path.startsWith("/finance/assets/summary?")) return {
        space_id: "private",
        currency: "GBP",
        total_net_worth_minor: 0,
        known_net_worth_minor: 0,
        layers: [],
      } as never;
      if (path.startsWith("/finance/assets/sources?")) return [] as never;
      if (path.startsWith("/finance/items/oats/product-price-history?")) return {
        normalized_item_id: "oats",
        normalized_item_name: "Porridge oats",
        observations: [],
      } as never;
      if (path.startsWith("/finance/items/oats/retailer-research-results?")) return [] as never;
      throw new Error(`Unexpected API request: ${path}`);
    });
  });

  it("does not offer an automatic lookup until a real service exists", async () => {
    render(<FinanceAssetsProductsView spaces={[space]} accounts={[account]} locale="en" />);

    expect(await screen.findByRole("heading", { name: "Retailer prices" })).toBeInTheDocument();
    expect(screen.getByText(/Automatic price checks are not available yet/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Request price research/i })).not.toBeInTheDocument();
  });
});
