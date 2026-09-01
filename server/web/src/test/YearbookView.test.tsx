import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { YearbookView } from "../views/YearbookView";

vi.mock("../api", () => ({
  api: vi.fn(),
  // Re-export a usable ApiError so the 429 branch keeps working.
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) {
      super(message);
      this.status = status;
    }
  },
}));

const apiMock = vi.mocked(api);
const YEAR = new Date().getFullYear();

function book(narrative: string | null) {
  return {
    child: { id: "child-1", name: "Child Two", age: 4 },
    year: YEAR,
    narrative,
    sections: {
      artwork: { count: 2, items: [{ id: "a1", title: "A rocket", approx_date: `${YEAR}-03`, image_url: "/artworks/a1/image" }] },
      growth: { start: { date: `${YEAR}-01-10`, height_cm: 80, weight_kg: 10 }, end: { date: `${YEAR}-11-10`, height_cm: 88, weight_kg: 12.5 }, grew_cm: 8, gained_kg: 2.5, measurements: 4 },
      star_charts: { completed: 3, earned_pence: 1500, titles: ["Potty training"] },
      learning: { reading_sessions: 40, minutes_read: 600, books: ["The Gruffalo"], book_count: 8, spelling_tests: 2 },
      illnesses: { count: 1, items: [{ started_at: `${YEAR}-02-01T09:00:00Z`, notes: "Chickenpox" }] },
      adventures: { count: 1, items: [{ title: "Swimming gala", start_time: `${YEAR}-06-01T09:00:00Z`, location: "Example Town" }] },
      favourite_meals: ["Spaghetti bolognese"],
      photos: { count: 3, highlights: [{ asset_id: "p1", thumbnail_url: "/photos/p1/thumbnail?size=preview" }] },
    },
  };
}

describe("YearbookView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path: string) => {
      if (path.endsWith("/years")) return { years: [YEAR, YEAR - 1] };
      if (path.endsWith("/options")) return {
        child: { id: "child-1", name: "Child Two" },
        year: YEAR,
        artwork: [
          { id: "a1", title: "A rocket", approx_date: `${YEAR}-03`, include_in_yearbook: true, yearbook_position: 0, image_url: "/artworks/a1/image" },
        ],
        photos: [
          { id: "p1", caption: "Beach day", taken_on: `${YEAR}-05-01`, location: "Walberswick", include_in_yearbook: true, yearbook_position: 0, image_url: "/child-photos/p1/image?size=thumb" },
          { id: "p2", caption: "Birthday tea", taken_on: `${YEAR}-06-10`, location: null, include_in_yearbook: false, yearbook_position: null, image_url: "/child-photos/p2/image?size=thumb" },
        ],
      };
      if (path.endsWith("/arrangement")) return book("What a year of growing and drawing.");
      if (path.endsWith("/refresh")) return book("A rewritten story about growing and drawing.");
      if (/^\/yearbook\/child-1\/\d+$/.test(path)) return book("What a year of growing and drawing.");
      return {};
    });
  });

  it("renders a warm keepsake with sections and a print action", async () => {
    render(<YearbookView children={[{ id: "child-1", name: "Child Two", date_of_birth: "2021-05-01" }]} />);

    expect(await screen.findByRole("heading", { name: "Child Two", level: 1 })).toBeInTheDocument();
    expect(screen.getByText(`${YEAR} · aged 4`)).toBeInTheDocument();
    expect(screen.getByText("What a year of growing and drawing.")).toBeInTheDocument();
    expect(screen.getByText("8 cm")).toBeInTheDocument();
    expect(screen.getByText("A rocket")).toBeInTheDocument();
    expect(screen.getByText("Swimming gala")).toBeInTheDocument();
    expect(screen.getByText("Spaghetti bolognese")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Export PDF" })).toBeEnabled();
  });

  it("rewrites the narrative on demand", async () => {
    render(<YearbookView children={[{ id: "child-1", name: "Child Two", date_of_birth: "2021-05-01" }]} />);

    fireEvent.click(await screen.findByRole("button", { name: "Rewrite the story" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(`/yearbook/child-1/${YEAR}/refresh`, expect.objectContaining({ method: "POST" })));
    expect(await screen.findByText("A rewritten story about growing and drawing.")).toBeInTheDocument();
  });

  it("guides choose, arrange, preview and export while persisting exact order", async () => {
    const print = vi.spyOn(window, "print").mockImplementation(() => {});
    render(<YearbookView children={[{ id: "child-1", name: "Child Two", date_of_birth: "2021-05-01" }]} />);

    fireEvent.click(await screen.findByRole("button", { name: "Choose & arrange" }));
    const choose = await screen.findByRole("dialog", { name: "Choose the moments" });
    expect(within(choose).getByText("1 of 2")).toBeInTheDocument();
    fireEvent.click(within(choose).getByRole("checkbox", { name: /Birthday tea/ }));
    expect(within(choose).getByText("2 of 2")).toBeInTheDocument();
    fireEvent.click(within(choose).getByRole("button", { name: "Arrange pages" }));

    const arrange = screen.getByRole("dialog", { name: "Arrange the pages" });
    fireEvent.click(within(arrange).getByRole("button", { name: "Move Birthday tea earlier" }));
    fireEvent.click(within(arrange).getByRole("button", { name: "Preview yearbook" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(`/yearbook/child-1/${YEAR}/arrangement`, {
      method: "PUT",
      body: JSON.stringify({ artwork_ids: ["a1"], photo_ids: ["p2", "p1"] }),
    }));
    const preview = await screen.findByRole("dialog", { name: "Your yearbook is ready" });
    expect(within(preview).getByText("Selection and order saved")).toBeInTheDocument();
    fireEvent.click(within(preview).getByRole("button", { name: "Export PDF" }));
    await waitFor(() => expect(print).toHaveBeenCalledOnce());
    print.mockRestore();
  });
});
