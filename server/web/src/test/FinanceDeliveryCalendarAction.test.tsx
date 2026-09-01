import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";

import { api } from "../api";
import { FinanceDeliveryCalendarAction } from "../components/FinanceDeliveryCalendarAction";
import type { FinanceSpace } from "../types";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

it("shows a trusted delivery suggestion from an ordinary order record but waits for Add", async () => {
  const spaces: FinanceSpace[] = [
    { id: "personal-1", kind: "personal", name: "Alex", is_default: true },
  ];
  apiMock.mockImplementation(async (path, init) => {
    if (path === "/finance/calendar-items?source_id=email-1") return [];
    if (path === "/finance/projection-preferences") {
      return { show_money: false, show_deliveries: true } as never;
    }
    if (path === "/finance/calendar-items/prefill?source_id=email-1") {
      return {
        item_kind: "PARCEL_DELIVERY",
        starts_at: "2026-08-15",
        ends_at: null,
        all_day: true,
      } as never;
    }
    if (path === "/finance/calendar-items" && init?.method === "POST") {
      return {
        id: "calendar-item-1",
        space_id: "personal-1",
        item_kind: "PARCEL_DELIVERY",
        source_id: "email-1",
        starts_at: "2026-08-15",
        ends_at: null,
        all_day: true,
        status: "ACTIVE",
        created_at: "2026-08-01T12:00:00Z",
        updated_at: "2026-08-01T12:00:00Z",
      } as never;
    }
    throw new Error(`Unexpected API request: ${path}`);
  });

  render(
    <FinanceDeliveryCalendarAction
      sourceID="email-1"
      sourceSpaceID="personal-1"
      sourceKind="html"
      description="Your order update"
      spaces={spaces}
      locale="en"
    />,
  );

  expect(await screen.findByRole("heading", { name: "Parcel delivery" })).toBeInTheDocument();
  expect(screen.getByLabelText("Date")).toHaveValue("2026-08-15");
  expect(screen.getByText("Suggested from the order. Check it before adding it.")).toBeInTheDocument();
  expect(apiMock.mock.calls.some(([path, init]) => path === "/finance/calendar-items" && init?.method === "POST")).toBe(false);

  fireEvent.click(screen.getByRole("button", { name: "Add to Calendar" }));
  expect(await screen.findByText("Delivery added to Calendar.")).toBeInTheDocument();
  await waitFor(() => {
    expect(apiMock.mock.calls.some(([path, init]) => path === "/finance/calendar-items" && init?.method === "POST")).toBe(true);
  });
});
