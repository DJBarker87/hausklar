import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { MealsView } from "../views/MealsView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

describe("MealsView shopping controls", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.history.replaceState({}, "", "/");
    apiMock.mockImplementation(async (path) => {
      if (path === "/meals/shopping") return [
        { id: "milk", name: "Milk", checked: false },
        { id: "bread", name: "Bread", checked: true },
        { id: "eggs", name: "Eggs", checked: true },
      ] as never;
      if (path === "/meals/recommendations?date=2026-07-13&limit=8") return null as never;
      return [] as never;
    });
  });

  it("opens and highlights the exact shopping item linked from an assistant result", async () => {
    const originalScroll = Element.prototype.scrollIntoView;
    const scrollIntoView = vi.fn();
    Object.defineProperty(Element.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView });
    window.history.replaceState({}, "", "/?shopping=milk");

    try {
      render(<MealsView revision={0} initialTab="meals" onDataChanged={vi.fn()} notify={vi.fn()} />);
      const row = (await screen.findByText("Milk")).closest(".shopping-row");
      await waitFor(() => expect(row).toHaveClass("is-highlighted"));
      expect(new URL(window.location.href).searchParams.has("shopping")).toBe(false);
      await waitFor(() => expect(scrollIntoView).toHaveBeenCalled());
    } finally {
      if (originalScroll) Object.defineProperty(Element.prototype, "scrollIntoView", { configurable: true, value: originalScroll });
      else Reflect.deleteProperty(Element.prototype, "scrollIntoView");
    }
  });

  it("removes one item and clears completed items sequentially", async () => {
    const notify = vi.fn();
    render(<MealsView revision={0} initialTab="tesco" onDataChanged={vi.fn()} notify={notify} />);

    fireEvent.click(await screen.findByRole("button", { name: "Remove Milk" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/meals/shopping/milk", { method: "DELETE" }));
    expect(screen.queryByText("Milk")).not.toBeInTheDocument();

    fireEvent.click(screen.getByText("In trolley (2)"));
    fireEvent.click(screen.getByRole("button", { name: "Clear completed" }));
    const confirmation = screen.getByRole("dialog", { name: "Clear completed items?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Clear completed" }));

    await waitFor(() => {
      const deletes = apiMock.mock.calls.filter(([, init]) => init?.method === "DELETE").map(([path]) => path);
      expect(deletes).toEqual(["/meals/shopping/milk", "/meals/shopping/bread", "/meals/shopping/eggs"]);
    });
    expect(notify).toHaveBeenCalledWith("2 completed items cleared.");
  });

  it("does not request Finance suggestions when Finance is unavailable", async () => {
    render(<MealsView revision={0} initialTab="tesco" financeEnabled={false} onDataChanged={vi.fn()} notify={vi.fn()} />);

    await screen.findByText("Milk");
    expect(apiMock.mock.calls.some(([path]) => path === "/finance/spaces")).toBe(false);
    expect(screen.queryByRole("heading", { name: "Worth a quick swap?" })).not.toBeInTheDocument();
  });

  it("previews and confirms a Tesco portability file without collecting a login", async () => {
    const notify = vi.fn();
    let summaryReads = 0;
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/meals/shopping") return [{ id: "milk", name: "Milk", checked: false }] as never;
      if (path === "/grocery/tesco-history/summary") {
        summaryReads += 1;
        return {
          shop_count: summaryReads > 1 ? 12 : 0,
          line_count: summaryReads > 1 ? 148 : 0,
          first_purchased_at: summaryReads > 1 ? "2025-08-01T12:00:00Z" : null,
          last_purchased_at: summaryReads > 1 ? "2026-08-01T12:00:00Z" : null,
          usuals: [],
          price_rise_count: 0,
          receipt_monitoring: false,
        } as never;
      }
      if (path === "/grocery/tesco-history/preview" && init?.method === "POST") return {
        sha256: "report-sha",
        order_count: 12,
        line_count: 148,
        first_purchased_at: "2025-08-01T12:00:00Z",
        last_purchased_at: "2026-08-01T12:00:00Z",
        sample_items: ["Milk", "Bananas"],
        already_imported: false,
        can_confirm: true,
      } as never;
      if (path === "/grocery/tesco-history/import" && init?.method === "POST") return {
        imported_orders: 12,
        skipped_orders: 0,
        imported_lines: 148,
      } as never;
      if (String(path).startsWith("/meals/recommendations")) return null as never;
      return [] as never;
    });

    render(<MealsView revision={0} initialTab="tesco" financeEnabled={false} onDataChanged={vi.fn()} notify={notify} />);
    const dialog = await screen.findByRole("dialog", { name: "Tesco history" });
    expect(within(dialog).getByText("HausKlar stores shops, not your Tesco login.")).toBeInTheDocument();
    expect(within(dialog).getByRole("link", { name: "Get Tesco file" })).toHaveAttribute("href", "https://www.tesco.com/account/data-portability/en-GB/");

    const file = new File([JSON.stringify({ orders: [] })], "tesco.json", { type: "application/json" });
    fireEvent.change(within(dialog).getByLabelText("Choose Tesco history file"), { target: { files: [file] } });
    expect(await within(dialog).findByRole("region", { name: "Tesco import review" })).toHaveTextContent("12 shops");
    fireEvent.click(within(dialog).getByRole("button", { name: "Import history" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/grocery/tesco-history/import",
      expect.objectContaining({ method: "POST", body: expect.any(FormData) }),
      true,
      false,
    ));
    const importCall = apiMock.mock.calls.find(([path]) => path === "/grocery/tesco-history/import");
    expect((importCall?.[1]?.body as FormData).get("expected_sha256")).toBe("report-sha");
    expect(notify).toHaveBeenCalledWith("12 Tesco shops added.");
    expect(await within(dialog).findByText("12", { selector: "strong" })).toBeInTheDocument();
  });

  it("shows evidence-based household alternatives and never edits the shopping list", async () => {
    const notify = vi.fn();
    const changed = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/meals/shopping") return [
        { id: "milk", name: "Milk", checked: false },
      ] as never;
      if (path === "/finance/spaces") return [
        { id: "household", kind: "household", name: "Household", is_default: true },
      ] as never;
      if (path === "/finance/opportunities?space_id=household") return [{
        id: "finding-1",
        space_id: "household",
        finding_type: "PRICE_DRIFT",
        title: "Compare Milk with Aldi British Milk",
        observation: "Dated comparison",
        evidence_refs: ["retailer-result:result-1"],
        baseline: { comparison_id: "comparison-1" },
        saving_low_minor: 400,
        saving_high_minor: 600,
        currency: "GBP",
        confidence_bps: 8_500,
        effort: 1,
        overlap_group: "product:item-milk:2026-05-01:2026-07-31",
        status: "OPEN",
        data_through_date: "2026-07-31",
        updated_at: "2026-08-01T12:00:00Z",
      }] as never;
      if (path.startsWith("/finance/items/item-milk/product-price-history")) return {
        normalized_item_id: "item-milk",
        normalized_item_name: "Milk",
        data_through: "2026-07-31",
        observations: [{
          id: "price-1",
          normalized_item_id: "item-milk",
          normalized_item_name: "Milk",
          source_kind: "PURCHASE_LINE",
          source_line_id: "line-1",
          retailer_name: "Tesco",
          product_name: "British semi-skimmed milk",
          pack_quantity: "1",
          pack_unit: "2l",
          comparable_quantity: "2000",
          unit_basis: "ml",
          price_minor: 140,
          currency: "GBP",
          observed_on: "2026-07-31",
          confidence_bps: 9_000,
          evidence_refs: ["purchase-line:line-1"],
        }],
      } as never;
      if (path.startsWith("/finance/items/item-milk/retailer-research-results")) return [{
        id: "result-1",
        request_id: "request-1",
        match_kind: "REALISTIC_SUBSTITUTE",
        retailer_name: "Aldi",
        product_name: "British semi-skimmed milk",
        brand_variant: null,
        pack_quantity: "1",
        pack_unit: "2l",
        comparable_quantity: "2000",
        unit_basis: "ml",
        price_minor: 100,
        currency: "GBP",
        observed_on: "2026-08-01",
        delivery_low_minor: 0,
        delivery_high_minor: 0,
        travel_low_minor: 0,
        travel_high_minor: 0,
        likely_waste_low_bps: 0,
        likely_waste_high_bps: 0,
        inconvenience_note: "One extra stop if Aldi is not already on the route.",
        confidence_bps: 8_500,
        source_label: "Reviewed retailer result",
      }] as never;
      if (path === "/finance/product-comparisons/comparison-1/accept" && init?.method === "POST") return {} as never;
      if (path.startsWith("/meals/recommendations")) return null as never;
      return [] as never;
    });

    const { rerender } = render(<MealsView key="choice-0" revision={0} initialTab="tesco" financeEnabled onDataChanged={changed} notify={notify} />);

    const savings = await screen.findByRole("heading", { name: "Worth a quick swap?" });
    const card = savings.closest(".finance-product-alternative") as HTMLElement;
    expect(within(card).getByText("£0.07 / 100ml")).toBeInTheDocument();
    expect(within(card).getByText("£0.05 / 100ml")).toBeInTheDocument();
    expect(within(card).getByText("Comparable substitute", { exact: false })).toBeInTheDocument();
    expect(within(card).getByText(/One extra stop/)).toBeInTheDocument();
    expect(within(card).getByText("Save £4.00–£6.00 over May 2026–Jul 2026")).toBeInTheDocument();
    expect(within(card).getByRole("button", { name: "Keep usual" })).toBeInTheDocument();
    expect(within(card).getByRole("button", { name: "Not suitable" })).toBeInTheDocument();

    fireEvent.click(within(card).getByRole("button", { name: "Keep usual" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/opportunities/finding-1/disposition",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ status: "SNOOZED" }) }),
      true,
      false,
    ));
    expect(notify).toHaveBeenCalledWith("Kept the usual choice for now. Your shopping list was not changed.");

    rerender(<MealsView key="choice-1" revision={1} initialTab="tesco" financeEnabled onDataChanged={changed} notify={notify} />);
    const secondCard = (await screen.findByRole("heading", { name: "Worth a quick swap?" })).closest(".finance-product-alternative") as HTMLElement;
    fireEvent.click(within(secondCard).getByRole("button", { name: "Not suitable" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/opportunities/finding-1/disposition",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ status: "DISMISSED" }) }),
      true,
      false,
    ));
    expect(notify).toHaveBeenCalledWith("Marked as not suitable. Your shopping list was not changed.");

    rerender(<MealsView key="choice-2" revision={2} initialTab="tesco" financeEnabled onDataChanged={changed} notify={notify} />);
    const thirdCard = (await screen.findByRole("heading", { name: "Worth a quick swap?" })).closest(".finance-product-alternative") as HTMLElement;
    fireEvent.click(within(thirdCard).getByRole("button", { name: "Try next shop" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/finance/product-comparisons/comparison-1/accept",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    expect(apiMock.mock.calls.some(([path, init]) => path === "/meals/shopping" && init?.method !== undefined)).toBe(false);
    expect(screen.getByText("Milk")).toBeInTheDocument();
    expect(notify).toHaveBeenCalledWith("Saved as a Household Finance preference. Your shopping list was not changed.");
    expect(changed).toHaveBeenCalledTimes(3);
  });

  it("gracefully hides savings when Household Finance cannot be read", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/meals/shopping") return [{ id: "milk", name: "Milk", checked: false }] as never;
      if (path === "/finance/spaces") throw new Error("Forbidden");
      if (path.startsWith("/meals/recommendations")) return null as never;
      return [] as never;
    });

    render(<MealsView revision={0} initialTab="tesco" financeEnabled onDataChanged={vi.fn()} notify={vi.fn()} />);

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/finance/spaces", expect.anything(), true, false));
    await waitFor(() => expect(screen.queryByText(/Checking reviewed Household Finance/)).not.toBeInTheDocument());
    expect(screen.queryByRole("heading", { name: "Worth a quick swap?" })).not.toBeInTheDocument();
  });
});

describe("MealsView family meal decisions", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.history.replaceState({}, "", "/");
  });

  it("starts with tonight and turns a suggestion into dinner in one choice", async () => {
    const notify = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/meals/") return [{ id: "curry", name: "Chicken curry", prep_minutes: 20, recipe_url: "https://example.com/curry" }] as never;
      if (path.startsWith("/meals/plan?")) return [] as never;
      if (path === "/meals/shopping" || path.startsWith("/grocery/")) return [] as never;
      if (path.startsWith("/meals/recommendations?") && init?.method === undefined) return {
        date: "2026-08-09",
        recommendations: [{ meal_id: "curry", meal_name: "Chicken curry", tags: ["fast"], score: 50, reasons: ["Works well for a late home evening"] }],
      } as never;
      if (path === "/meals/recommendations/curry/decision") return { message: "Chicken curry is dinner tonight." } as never;
      return [] as never;
    });

    render(<MealsView revision={0} initialTab="meals" onDataChanged={vi.fn()} notify={notify} />);

    expect(await screen.findByRole("heading", { name: "Choose dinner" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Use tonight" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/meals/recommendations/curry/decision",
      { method: "POST", body: JSON.stringify({ action: "use_tonight", date: null }) },
    ));
    expect(notify).toHaveBeenCalledWith("Chicken curry is dinner tonight.");
  });

  it("reviews a deduplicated week before adding ingredients to shopping", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/meals/") return [{ id: "curry", name: "Curry" }] as never;
      if (path.startsWith("/meals/plan?")) return [{ id: "plan", meal_id: "curry", date: "2026-08-10", meal_type: "dinner", meal_name: "Curry" }] as never;
      if (path === "/meals/shopping" || path.startsWith("/grocery/") || path.startsWith("/meals/recommendations?")) return [] as never;
      if (path.startsWith("/meals/shopping/plan-diff?") && init?.method === undefined) return {
        start: "2026-08-10",
        end: "2026-08-16",
        items: [
          { key: "spinach", name: "Spinach", quantity: "1 bag", category: "Rileys", meal_plan_ids: ["plan"], planned_meals: ["Curry · 2026-08-10"], already_on_list: false, likely_at_home: false },
          { key: "rice", name: "Rice", quantity: "500g", category: "Cupboard", meal_plan_ids: ["plan"], planned_meals: ["Curry · 2026-08-10"], already_on_list: true, likely_at_home: false },
        ],
      } as never;
      if (path === "/meals/shopping/plan-diff/apply") return { created: [{ id: "spinach", name: "Spinach", checked: false }], skipped: 0 } as never;
      return [] as never;
    });

    render(<MealsView revision={0} initialTab="meals" onDataChanged={vi.fn()} notify={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "This week" }));
    fireEvent.click(screen.getByRole("button", { name: "Check what we need" }));
    const dialog = await screen.findByRole("dialog", { name: "What do we need?" });
    expect(within(dialog).getByText("Already on shopping")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add 1 to shopping" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/meals/shopping/plan-diff/apply",
      expect.objectContaining({ method: "POST", body: expect.stringContaining("spinach") }),
    ));
  });
});
