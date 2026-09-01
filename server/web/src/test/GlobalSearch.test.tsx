import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { GlobalSearch } from "../components/GlobalSearch";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

describe("GlobalSearch", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockResolvedValue({
      query: "sports day",
      has_more: false,
      results: [
        {
          id: "event-1",
          kind: "event",
          title: "Sports day",
          subtitle: "Calendar · School field",
          date: "2026-08-12",
          image_url: null,
          child_id: null,
          path: "?view=calendar&event=event-1&event_date=2026-08-12",
        },
      ],
    } as never);
  });

  it("searches as the family types and opens the exact result", async () => {
    const openResult = vi.fn();
    render(<GlobalSearch open onOpenChange={vi.fn()} onOpenResult={openResult} />);

    fireEvent.change(screen.getByRole("searchbox", { name: "Search HausKlar" }), {
      target: { value: "sports day" },
    });

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/search?q=sports%20day&limit=40"));
    const result = await screen.findByRole("button", { name: /Sports day/ });
    expect(result).toHaveTextContent("School field");
    expect(result).toHaveTextContent("12 Aug 2026");
    fireEvent.click(result);
    expect(openResult).toHaveBeenCalledWith("?view=calendar&event=event-1&event_date=2026-08-12");
  });

  it("does not send one-letter searches", async () => {
    render(<GlobalSearch open onOpenChange={vi.fn()} onOpenResult={vi.fn()} />);
    fireEvent.change(screen.getByRole("searchbox", { name: "Search HausKlar" }), { target: { value: "s" } });
    await new Promise((resolve) => window.setTimeout(resolve, 300));
    expect(apiMock).not.toHaveBeenCalled();
    expect(screen.getByText("Type at least two letters. Search never changes anything.")).toBeInTheDocument();
  });

  it("retries the same query without mutating the family's search text", async () => {
    apiMock
      .mockRejectedValueOnce(new Error("Network unavailable"))
      .mockResolvedValueOnce({ query: "passport", has_more: false, results: [] } as never);
    render(<GlobalSearch open onOpenChange={vi.fn()} onOpenResult={vi.fn()} />);

    const searchbox = screen.getByRole("searchbox", { name: "Search HausKlar" });
    fireEvent.change(searchbox, { target: { value: "passport" } });
    fireEvent.click(await screen.findByRole("button", { name: "Try again" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledTimes(2));
    expect(apiMock).toHaveBeenNthCalledWith(1, "/search?q=passport&limit=40");
    expect(apiMock).toHaveBeenNthCalledWith(2, "/search?q=passport&limit=40");
    expect(searchbox).toHaveValue("passport");
  });
});
