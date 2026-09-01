import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { PresentsView, type PresentIdea } from "../views/PresentsView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

const idea: PresentIdea = {
  id: "gift-1",
  child_id: "child-1",
  recipient_name: "Child One",
  title: "Wooden castle",
  occasion: "birthday",
  event_year: 2026,
  birthday_id: null,
  status: "arrived",
  status_updated_at: "2026-08-09T10:00:00Z",
  owner_id: "adult-1",
  owner_name: "Alex",
  notes: "Blue roof",
  url: "https://example.com/castle",
  retailer: "Toy shop",
  budget_minor: 5000,
  price_minor: 4299,
  currency: "GBP",
  deadline: "2026-08-14",
  hiding_location: "Garage loft",
  recipient_can_see: false,
  status_history: [{
    id: "history-1",
    from_status: "bought",
    to_status: "arrived",
    changed_at: "2026-08-09T10:00:00Z",
    changed_by_name: "Alex",
  }],
};

function renderPresents(props: Partial<React.ComponentProps<typeof PresentsView>> = {}) {
  return render(<PresentsView
    children={[{ id: "child-1", name: "Child One", date_of_birth: "2020-01-02" }]}
    members={[
      { id: "adult-1", name: "Alex", member_type: "user" },
      { id: "adult-2", name: "Morgan", member_type: "user" },
      { id: "child-1", name: "Child One", member_type: "child" },
    ]}
    selectedChild="child-1"
    revision={0}
    initialPresentId={null}
    initialBirthdayId={null}
    onDataChanged={vi.fn()}
    {...props}
  />);
}

describe("PresentsView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/children/presents/ideas?") && !init) return [idea];
      if (path === "/children/presents/ideas/check-duplicate" && init?.method === "POST") return { matches: [] };
      if (path === "/children/presents/ideas" && init?.method === "POST") {
        const body = JSON.parse(String(init.body));
        return { ...idea, id: "gift-2", title: body.title, status: body.status, occasion: body.occasion, status_history: [] };
      }
      if (path === "/children/presents/ideas/gift-1/status" && init?.method === "PATCH") {
        const body = JSON.parse(String(init.body));
        return { ...idea, status: body.status };
      }
      if (path === "/children/presents/ideas/gift-1" && init?.method === "PUT") {
        const body = JSON.parse(String(init.body));
        return { ...idea, ...body };
      }
      if (path === "/children/presents/ideas/gift-1" && init?.method === "DELETE") return undefined;
      if (path === "/children/presents/ideas/gift-1/restore" && init?.method === "POST") return idea;
      return [];
    });
  });

  it("loads only the selected recipient and keeps quick capture genuinely quick", async () => {
    const changed = vi.fn();
    renderPresents({ onDataChanged: changed });

    expect(await screen.findByRole("heading", { name: "Gifts for Child One" })).toBeInTheDocument();
    expect(apiMock.mock.calls[0]?.[0]).toContain("child_id=child-1");
    expect(screen.getByText("Wooden castle")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Gift idea"), { target: { value: "Marble run" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/children/presents/ideas/check-duplicate", expect.objectContaining({ method: "POST" })));
    await waitFor(() => {
      const createCall = apiMock.mock.calls.find(([path, init]) => path === "/children/presents/ideas" && init?.method === "POST");
      expect(createCall).toBeTruthy();
      expect(JSON.parse(String(createCall?.[1]?.body))).toMatchObject({
        child_id: "child-1",
        title: "Marble run",
        status: "idea",
        recipient_can_see: false,
      });
    });
    expect(changed).toHaveBeenCalled();
  });

  it("supports one-tap progress and explicit backwards correction", async () => {
    renderPresents();
    fireEvent.click(await screen.findByRole("button", { name: "Mark wrapped" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/children/presents/ideas/gift-1/status", {
      method: "PATCH",
      body: JSON.stringify({ status: "wrapped" }),
    }));

    fireEvent.click(screen.getByText("Wooden castle"));
    const detail = screen.getByRole("dialog", { name: "Wooden castle" });
    fireEvent.change(within(detail).getByLabelText("Correct status"), { target: { value: "bought" } });
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/children/presents/ideas/gift-1/status", {
      method: "PATCH",
      body: JSON.stringify({ status: "bought" }),
    }));
  });

  it("tucks logistics away while retaining edit, private details and Undo", async () => {
    renderPresents();
    await screen.findByText("Wooden castle");
    fireEvent.click(screen.getByRole("button", { name: "Edit Wooden castle" }));
    const editor = screen.getByRole("dialog", { name: "Edit gift" });
    expect(within(editor).queryByLabelText("Hiding place")).not.toBeVisible();
    fireEvent.click(within(editor).getByText("More details"));
    expect(within(editor).getByLabelText("Hiding place")).toHaveValue("Garage loft");
    expect(within(editor).getByLabelText(/Keep hidden from recipient/)).toBeChecked();
    fireEvent.click(within(editor).getByRole("button", { name: "Cancel" }));

    fireEvent.click(screen.getByRole("button", { name: "Delete Wooden castle" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/children/presents/ideas/gift-1", { method: "DELETE" }));
    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/children/presents/ideas/gift-1/restore", { method: "POST" }));
    expect(await screen.findByText("Wooden castle")).toBeInTheDocument();
  });

  it("warns about duplicates and requires an explicit add-anyway choice", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/children/presents/ideas?") && !init) return [idea];
      if (path === "/children/presents/ideas/check-duplicate") return {
        matches: [{ id: idea.id, title: idea.title, occasion: idea.occasion, event_year: idea.event_year, status: idea.status }],
      };
      if (path === "/children/presents/ideas" && init?.method === "POST") return { ...idea, id: "gift-2", title: "Wooden castle" };
      return [];
    });
    renderPresents();
    await screen.findByText("Wooden castle");
    fireEvent.change(screen.getByLabelText("Gift idea"), { target: { value: "Wooden castle" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));

    const warning = await screen.findByRole("dialog", { name: "Possible duplicate" });
    expect(within(warning).getByText(/similar active gift/i)).toBeInTheDocument();
    fireEvent.click(within(warning).getByRole("button", { name: "Add anyway" }));
    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/children/presents/ideas" && init?.method === "POST");
      expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({ allow_duplicate: true });
    });
  });

  it("preserves an optional birthday link through filtering and capture", async () => {
    renderPresents({ initialBirthdayId: "birthday-1" });
    await screen.findByText("Showing gifts linked to this birthday.");
    expect(apiMock.mock.calls[0]?.[0]).toContain("birthday_id=birthday-1");

    fireEvent.change(screen.getByLabelText("Gift idea"), { target: { value: "Birthday book" } });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => {
      const createCall = apiMock.mock.calls.find(([path, init]) => path === "/children/presents/ideas" && init?.method === "POST");
      expect(JSON.parse(String(createCall?.[1]?.body))).toMatchObject({
        birthday_id: "birthday-1",
        occasion: "birthday",
      });
    });
  });
});
