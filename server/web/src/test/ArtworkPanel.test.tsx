import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { ArtworkPanel, type Artwork } from "../views/ArtworkPanel";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const children = [
  { id: "child-1", name: "Ada", date_of_birth: "2020-01-01" },
  { id: "child-2", name: "Leo", date_of_birth: "2022-02-02" },
];

function artwork(overrides: Partial<Artwork> = {}): Artwork {
  return {
    id: "art-1",
    child_id: "child-1",
    child_name: "Ada",
    title: "Rainbow",
    approx_date: "2026-05",
    date_precision: "month",
    age_label: "Age 6",
    notes: "Made after lunch",
    medium: "Watercolour",
    story: "A storm passed and the sun came out.",
    child_quote: "The sun is back",
    school_year: "Year 1",
    favourite: false,
    include_in_yearbook: true,
    yearbook_position: null,
    original_available: true,
    rotation_degrees: 0,
    enhanced: false,
    created_at: "2026-05-12T12:00:00Z",
    updated_at: "2026-05-12T12:00:00Z",
    image_url: "/artworks/art-1/image?v=20260512120000",
    original_image_url: "/artworks/art-1/image?size=original",
    ...overrides,
  };
}

function renderPanel(props: Partial<React.ComponentProps<typeof ArtworkPanel>> = {}) {
  return render(
    <ArtworkPanel
      children={children}
      selectedChild="all"
      revision={0}
      onDataChanged={vi.fn()}
      {...props}
    />,
  );
}

async function openArtwork(title = "Rainbow") {
  fireEvent.click(await screen.findByRole("button", { name: new RegExp(title) }));
  return screen.getByRole("dialog", { name: title });
}

describe("ArtworkPanel", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.sessionStorage.clear();
  });

  it("loads versioned thumbnails in pages and asks the server for favourites", async () => {
    const firstPage = Array.from({ length: 40 }, (_, index) => artwork({
      id: `art-${index}`,
      title: `Piece ${index}`,
      image_url: `/artworks/art-${index}/image?v=${index}`,
    }));
    const favourite = artwork({ id: "favourite", title: "Best dragon", favourite: true });
    apiMock.mockImplementation(async (path) => {
      if (path.includes("favourites_only=true")) return [favourite] as never;
      if (path.includes("offset=40")) return [artwork({ id: "art-40", title: "Piece 40" })] as never;
      return firstPage as never;
    });

    renderPanel();
    const thumbnail = await screen.findByAltText("Piece 0");
    expect(thumbnail).toHaveAttribute("src", "/api/artworks/art-0/image?v=0&size=thumb");
    fireEvent.click(screen.getByRole("button", { name: "Load more artwork" }));
    expect(await screen.findByText("Piece 40")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("offset=40"));

    fireEvent.click(screen.getByRole("button", { name: "Favourites" }));
    expect(await screen.findByText("Best dragon")).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("favourites_only=true")));
  });

  it("captures a multi-photo pile, applies optional details, and remembers child and rough date", async () => {
    const uploadedForms: FormData[] = [];
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/artworks/?")) return [] as never;
      if (path === "/artworks/" && init?.method === "POST") {
        const form = init.body as FormData;
        uploadedForms.push(form);
        const index = uploadedForms.length;
        return artwork({
          id: `new-${index}`,
          child_id: String(form.get("child_id")),
          child_name: "Leo",
          approx_date: String(form.get("approx_date")),
          date_precision: "month",
          title: String(form.get("title")),
        }) as never;
      }
      return [] as never;
    });

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: "Add artwork" }));
    const dialog = screen.getByRole("dialog", { name: "Add artwork" });
    const files = [
      new File(["first"], "first.jpg", { type: "image/jpeg" }),
      new File(["second"], "second.png", { type: "image/png" }),
    ];
    fireEvent.change(within(dialog).getByLabelText(/Photograph or choose a pile/), { target: { files } });
    expect(within(dialog).getByText("Piece 1")).toBeInTheDocument();
    expect(within(dialog).getByText("Piece 2")).toBeInTheDocument();
    fireEvent.change(within(dialog).getByLabelText("Whose masterpiece?"), { target: { value: "child-2" } });
    fireEvent.change(within(dialog).getByLabelText("Year"), { target: { value: "2024" } });
    fireEvent.change(within(dialog).getByLabelText("Month"), { target: { value: "05" } });
    fireEvent.click(within(dialog).getByRole("button", { name: /More details/ }));
    fireEvent.change(within(dialog).getByLabelText("Title (optional)"), { target: { value: "Garden creatures" } });
    fireEvent.change(within(dialog).getByLabelText("Medium"), { target: { value: "Collage" } });
    fireEvent.change(within(dialog).getByLabelText("The story behind it"), { target: { value: "A rainy afternoon project" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save 2 pieces" }));

    expect(await screen.findByText("2 pieces added to the family gallery.")).toBeInTheDocument();
    expect(uploadedForms).toHaveLength(2);
    expect(uploadedForms.map((form) => form.get("title"))).toEqual(["Garden creatures 1", "Garden creatures 2"]);
    expect(uploadedForms[0]?.get("child_id")).toBe("child-2");
    expect(uploadedForms[0]?.get("approx_date")).toBe("2024-05");
    expect(uploadedForms[0]?.get("medium")).toBe("Collage");
    expect(uploadedForms[0]?.get("story")).toBe("A rainy afternoon project");
    expect(uploadedForms[0]?.get("client_id")).toEqual(expect.any(String));
    expect(uploadedForms[0]?.get("include_in_yearbook")).toBe("false");

    fireEvent.click(screen.getByRole("button", { name: "Add artwork" }));
    const reopened = screen.getByRole("dialog", { name: "Add artwork" });
    expect(within(reopened).getByLabelText("Whose masterpiece?")).toHaveValue("child-2");
    expect(within(reopened).getByLabelText("Year")).toHaveValue("2024");
    expect(within(reopened).getByLabelText("Month")).toHaveValue("05");
  });

  it("communicates pile capacity and does not prepare previews for discarded files", async () => {
    apiMock.mockResolvedValue([] as never);
    const createObjectURL = vi.fn((file: File) => `blob:${file.name}`);
    const revokeObjectURL = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: createObjectURL });
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revokeObjectURL });

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: "Add artwork" }));
    const dialog = screen.getByRole("dialog", { name: "Add artwork" });
    const files = Array.from({ length: 31 }, (_, index) => new File([String(index)], `piece-${index + 1}.jpg`, { type: "image/jpeg" }));
    fireEvent.change(within(dialog).getByLabelText(/Photograph or choose a pile/), { target: { files } });

    expect(createObjectURL).toHaveBeenCalledTimes(30);
    expect(within(dialog).getByText("Piece 30")).toBeInTheDocument();
    expect(within(dialog).queryByText("Piece 31")).not.toBeInTheDocument();
    expect(within(dialog).getByText("Pile full")).toBeInTheDocument();
    expect(within(dialog).getByRole("alert")).toHaveTextContent("Added 30");
  });

  it("toggles favourite and Yearbook choices using partial updates", async () => {
    let current = artwork();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/artworks/?")) return [current] as never;
      if (path === "/artworks/art-1" && init?.method === "PATCH") {
        const payload = JSON.parse(String(init.body)) as Partial<Artwork> & { include_in_yearbook?: boolean };
        current = { ...current, ...payload };
        return current as never;
      }
      return [] as never;
    });

    renderPanel();
    let dialog = await openArtwork();
    fireEvent.click(within(dialog).getByRole("button", { name: "Favourite" }));
    await waitFor(() => expect(within(dialog).getByRole("button", { name: "Remove favourite" })).toBeInTheDocument());
    fireEvent.click(within(dialog).getByRole("button", { name: "In Yearbook" }));
    await waitFor(() => expect(within(dialog).getByRole("button", { name: "Add to Yearbook" })).toBeInTheDocument());

    const patchCalls = apiMock.mock.calls.filter(([path, init]) => path === "/artworks/art-1" && init?.method === "PATCH");
    expect(JSON.parse(String(patchCalls[0]?.[1]?.body))).toEqual({ favourite: true });
    expect(JSON.parse(String(patchCalls[1]?.[1]?.body))).toEqual({ include_in_yearbook: false });
  });

  it("edits the full record and applies reversible photo adjustments", async () => {
    let current = artwork();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/artworks/?")) return [current] as never;
      if (path === "/artworks/art-1" && init?.method === "PATCH") {
        const payload = JSON.parse(String(init.body));
        current = { ...current, ...payload, child_name: payload.child_id === "child-2" ? "Leo" : "Ada" };
        return current as never;
      }
      if (path === "/artworks/art-1/appearance" && init?.method === "PUT") {
        const payload = JSON.parse(String(init.body));
        current = { ...current, ...payload, image_url: "/artworks/art-1/image?v=adjusted" };
        return current as never;
      }
      return [] as never;
    });

    renderPanel();
    let dialog = await openArtwork();
    fireEvent.click(within(dialog).getByRole("button", { name: "Edit details" }));
    const edit = screen.getByRole("dialog", { name: "Edit artwork" });
    fireEvent.change(within(edit).getByLabelText("Child"), { target: { value: "child-2" } });
    fireEvent.change(within(edit).getByLabelText("The story behind it"), { target: { value: "The corrected story" } });
    fireEvent.change(within(edit).getByLabelText("What they said about it"), { target: { value: "It can fly" } });
    fireEvent.click(within(edit).getByRole("button", { name: "Save changes" }));
    dialog = await screen.findByRole("dialog", { name: "Rainbow" });
    expect(within(dialog).getByText("The corrected story")).toBeInTheDocument();
    expect(within(dialog).getByText("“It can fly”")).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Adjust photo" }));
    const adjust = screen.getByRole("dialog", { name: "Adjust photo" });
    fireEvent.click(within(adjust).getByRole("button", { name: "Turn right" }));
    fireEvent.click(within(adjust).getByLabelText("Improve paper and lighting"));
    fireEvent.click(within(adjust).getByRole("button", { name: "Apply" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/artworks/art-1/appearance", {
      method: "PUT",
      body: JSON.stringify({ rotation_degrees: 90, enhanced: true }),
      timeoutMs: 60_000,
    }));
    expect(await screen.findByText("Photo adjustments applied. The original is still safe.")).toBeInTheDocument();
  });

  it("removes artwork only after confirmation and restores it with Undo", async () => {
    const current = artwork();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/artworks/?")) return [current] as never;
      if (path === "/artworks/art-1" && init?.method === "DELETE") return undefined as never;
      if (path === "/artworks/art-1/restore" && init?.method === "POST") return current as never;
      return [] as never;
    });

    renderPanel();
    const dialog = await openArtwork();
    fireEvent.click(within(dialog).getByRole("button", { name: "Remove" }));
    const confirmation = screen.getByRole("dialog", { name: "Remove this artwork?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Remove artwork" }));
    expect(await screen.findByText("Removed Rainbow")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Rainbow/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(await screen.findByRole("button", { name: /Rainbow/ })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/artworks/art-1/restore", { method: "POST" });
  });

  it("shares the preserved original as a file and offers browser printing", async () => {
    apiMock.mockImplementation(async (path) => path.startsWith("/artworks/?") ? [artwork()] as never : [] as never);
    const share = vi.fn().mockResolvedValue(undefined);
    const canShare = vi.fn().mockReturnValue(true);
    Object.defineProperty(navigator, "share", { configurable: true, value: share });
    Object.defineProperty(navigator, "canShare", { configurable: true, value: canShare });
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      blob: async () => new Blob(["image"], { type: "image/jpeg" }),
    });
    vi.stubGlobal("fetch", fetchMock);
    const print = vi.spyOn(window, "print").mockImplementation(() => {});

    renderPanel();
    const dialog = await openArtwork();
    expect(within(dialog).getByRole("link", { name: "Original" })).toHaveAttribute("href", "/api/artworks/art-1/image?size=original");
    fireEvent.click(within(dialog).getByRole("button", { name: "Share" }));
    await waitFor(() => expect(share).toHaveBeenCalled());
    expect(fetchMock).toHaveBeenCalledWith("/api/artworks/art-1/image?size=original", { credentials: "same-origin" });
    const shared = share.mock.calls[0]?.[0] as ShareData;
    expect(shared.files?.[0]?.name).toBe("Rainbow.jpg");
    fireEvent.click(within(dialog).getByRole("button", { name: "Print" }));
    expect(print).toHaveBeenCalledOnce();

    print.mockRestore();
    vi.unstubAllGlobals();
  });
});
