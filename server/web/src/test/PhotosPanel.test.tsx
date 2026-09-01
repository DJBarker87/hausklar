import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { PhotosPanel, type ChildPhoto } from "../views/PhotosPanel";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const children = [
  { id: "child-1", name: "Ada", date_of_birth: "2020-01-01" },
  { id: "child-2", name: "Leo", date_of_birth: "2022-02-02" },
];

function photo(overrides: Partial<ChildPhoto> = {}): ChildPhoto {
  return {
    id: "photo-1",
    child_id: "child-1",
    child_name: "Ada",
    caption: "Beach day",
    taken_on: "2026-06-12",
    location: "Walberswick",
    story: "Ada ran straight into the sea.",
    favourite: false,
    include_in_yearbook: true,
    yearbook_position: null,
    original_available: true,
    created_at: "2026-06-12T12:00:00Z",
    updated_at: "2026-06-12T12:00:00Z",
    image_url: "/child-photos/photo-1/image?v=20260612120000",
    original_image_url: "/child-photos/photo-1/image?size=original",
    ...overrides,
  };
}

function renderPanel(props: Partial<React.ComponentProps<typeof PhotosPanel>> = {}) {
  return render(<PhotosPanel children={children} selectedChild="all" revision={0} onDataChanged={vi.fn()} {...props} />);
}

async function openPhoto(label = "Beach day") {
  fireEvent.click(await screen.findByRole("button", { name: new RegExp(`Open ${label}`) }));
  return screen.getByRole("dialog", { name: label });
}

describe("PhotosPanel", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.sessionStorage.clear();
  });

  it("browses a person-labelled timeline in pages and asks the server for favourites", async () => {
    const firstPage = Array.from({ length: 40 }, (_, index) => photo({
      id: `photo-${index}`,
      caption: `Moment ${index}`,
      image_url: `/child-photos/photo-${index}/image?v=${index}`,
    }));
    apiMock.mockImplementation(async (path) => {
      if (path.includes("favourites_only=true")) return [photo({ id: "best", caption: "Best day", favourite: true })] as never;
      if (path.includes("offset=40")) return [photo({ id: "last", caption: "Last moment" })] as never;
      return firstPage as never;
    });

    renderPanel();
    expect(await screen.findByRole("heading", { name: /June 2026/ })).toBeInTheDocument();
    expect(screen.getAllByText("Ada").length).toBeGreaterThan(0);
    expect(screen.getByAltText("Moment 0")).toHaveAttribute("src", "/api/child-photos/photo-0/image?v=0&size=thumb");
    fireEvent.click(screen.getByRole("button", { name: "Load more photos" }));
    expect(await screen.findByText("Last moment")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Favourites" }));
    expect(await screen.findByText("Best day")).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("favourites_only=true")));
  });

  it("captures a person-and-moment pile while sending the original files unchanged", async () => {
    const forms: FormData[] = [];
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/child-photos/?")) return [] as never;
      if (path === "/child-photos/" && init?.method === "POST") {
        const form = init.body as FormData;
        forms.push(form);
        return { photos: [photo({ id: `new-${forms.length}`, child_id: "child-2", child_name: "Leo", caption: String(form.get("caption")) })] } as never;
      }
      return [] as never;
    });
    renderPanel();
    fireEvent.click((await screen.findAllByRole("button", { name: "Add a moment" }))[0]!);
    const dialog = screen.getByRole("dialog", { name: "Add a moment" });
    fireEvent.change(within(dialog).getByLabelText("Who is this about?"), { target: { value: "child-2" } });
    const first = new File(["full-original-one"], "one.png", { type: "image/png", lastModified: Date.UTC(2025, 4, 2) });
    const second = new File(["full-original-two"], "two.webp", { type: "image/webp", lastModified: Date.UTC(2025, 4, 2) });
    fireEvent.change(within(dialog).getByLabelText("Choose photos for this moment"), { target: { files: [first, second] } });
    expect(await within(dialog).findAllByText("2 May 2025")).toHaveLength(2);
    fireEvent.change(within(dialog).getByLabelText("What was the moment?"), { target: { value: "Tea with Granny" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add place, story or one shared date" }));
    fireEvent.change(within(dialog).getByLabelText("Place"), { target: { value: "Granny's kitchen" } });
    fireEvent.change(within(dialog).getByLabelText("The story worth remembering"), { target: { value: "Leo poured the milk." } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save 2 photos" }));

    expect(await screen.findByText("2 photos added to this moment.")).toBeInTheDocument();
    expect(forms).toHaveLength(1);
    expect(forms[0]?.getAll("files").map((file) => (file as File).name)).toEqual(["one.png", "two.webp"]);
    expect(forms[0]?.getAll("files").map((file) => (file as File).type)).toEqual(["image/png", "image/webp"]);
    expect(forms[0]?.getAll("taken_on")).toEqual(["2025-05-02", "2025-05-02"]);
    expect(forms[0]?.get("child_id")).toBe("child-2");
    expect(forms[0]?.get("caption")).toBe("Tea with Granny");
    expect(forms[0]?.get("location")).toBe("Granny's kitchen");
    expect(forms[0]?.get("story")).toBe("Leo poured the milk.");
  });

  it("curates favourite and Yearbook flags and edits the deeper moment details", async () => {
    let current = photo();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/child-photos/?")) return [current] as never;
      if (path === "/child-photos/photo-1" && init?.method === "PATCH") {
        const payload = JSON.parse(String(init.body));
        current = { ...current, ...payload, child_name: payload.child_id === "child-2" ? "Leo" : current.child_name };
        return current as never;
      }
      return [] as never;
    });
    renderPanel();
    let dialog = await openPhoto();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add favourite" }));
    await waitFor(() => expect(within(dialog).getByRole("button", { name: "Favourite" })).toBeInTheDocument());
    fireEvent.click(within(dialog).getByRole("button", { name: "In Yearbook" }));
    await waitFor(() => expect(within(dialog).getByRole("button", { name: "Add to Yearbook" })).toBeInTheDocument());
    fireEvent.click(within(dialog).getByRole("button", { name: "Edit" }));
    const edit = screen.getByRole("dialog", { name: "Edit this moment" });
    fireEvent.change(within(edit).getByLabelText("Person"), { target: { value: "child-2" } });
    fireEvent.change(within(edit).getByLabelText("Place"), { target: { value: "Southwold" } });
    fireEvent.change(within(edit).getByLabelText("Story"), { target: { value: "A corrected memory." } });
    fireEvent.click(within(edit).getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Edit this moment" })).not.toBeInTheDocument());

    const patches = apiMock.mock.calls.filter(([path, init]) => path === "/child-photos/photo-1" && init?.method === "PATCH");
    expect(JSON.parse(String(patches[0]?.[1]?.body))).toEqual({ favourite: true });
    expect(JSON.parse(String(patches[1]?.[1]?.body))).toEqual({ include_in_yearbook: false });
    expect(JSON.parse(String(patches[2]?.[1]?.body))).toMatchObject({ child_id: "child-2", location: "Southwold", story: "A corrected memory." });
  });

  it("shares the preserved original and keeps a direct original download", async () => {
    apiMock.mockImplementation(async (path) => path.startsWith("/child-photos/?") ? [photo()] as never : [] as never);
    const share = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "share", { configurable: true, value: share });
    Object.defineProperty(navigator, "canShare", { configurable: true, value: vi.fn().mockReturnValue(true) });
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, blob: async () => new Blob(["original"], { type: "image/png" }) });
    vi.stubGlobal("fetch", fetchMock);

    const dialog = await (renderPanel(), openPhoto());
    expect(within(dialog).getByRole("link", { name: "Original" })).toHaveAttribute("href", "/api/child-photos/photo-1/image?size=original");
    fireEvent.click(within(dialog).getByRole("button", { name: "Share" }));
    await waitFor(() => expect(share).toHaveBeenCalled());
    expect(fetchMock).toHaveBeenCalledWith("/api/child-photos/photo-1/image?size=original", { credentials: "same-origin" });
    const shared = share.mock.calls[0]?.[0] as ShareData;
    expect(shared.files?.[0]?.name).toBe("Beach day.png");
  });

  it("removes only after confirmation and restores the same photo with Undo", async () => {
    const current = photo();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/child-photos/?")) return [current] as never;
      if (path === "/child-photos/photo-1" && init?.method === "DELETE") return undefined as never;
      if (path === "/child-photos/photo-1/restore" && init?.method === "POST") return current as never;
      return [] as never;
    });
    renderPanel();
    const dialog = await openPhoto();
    fireEvent.click(within(dialog).getByRole("button", { name: "Remove" }));
    const confirmation = screen.getByRole("dialog", { name: "Remove this photo?" });
    fireEvent.click(within(confirmation).getByRole("button", { name: "Remove photo" }));
    expect(await screen.findByText("Removed Beach day")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(await screen.findByRole("button", { name: /Open Beach day/ })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/child-photos/photo-1/restore", { method: "POST" });
  });
});
