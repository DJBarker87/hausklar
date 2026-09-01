import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { PhotoSearch } from "../components/PhotoSearch";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

describe("PhotoSearch", () => {
  beforeEach(() => {
    apiMock.mockReset();
  });

  it("shows a grid of results for a query", async () => {
    apiMock.mockResolvedValue({
      query: "beach",
      results: [
        { asset_id: "p1", taken_at: "2024-06-01T10:00:00Z", thumbnail_url: "/photos/p1/thumbnail?size=preview" },
        { asset_id: "p2", taken_at: null, thumbnail_url: "/photos/p2/thumbnail?size=preview" },
      ],
    } as never);

    render(<PhotoSearch open onOpenChange={vi.fn()} />);
    fireEvent.change(screen.getByRole("searchbox"), { target: { value: "beach" } });
    fireEvent.click(screen.getByRole("button", { name: "Search" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/photos/search?q=beach&limit=30"));
    const images = await screen.findAllByRole("img");
    expect(images).toHaveLength(2);
    expect(images[0]).toHaveAttribute("src", "/api/photos/p1/thumbnail?size=preview");
  });

  it("shows a gentle empty state when nothing matches", async () => {
    apiMock.mockResolvedValue({ query: "unicorn", results: [] } as never);

    render(<PhotoSearch open onOpenChange={vi.fn()} />);
    fireEvent.change(screen.getByRole("searchbox"), { target: { value: "unicorn" } });
    fireEvent.click(screen.getByRole("button", { name: "Search" }));

    expect(await screen.findByText("No photos found")).toBeInTheDocument();
  });
});
