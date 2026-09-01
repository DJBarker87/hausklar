import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FamilyMember } from "../types";
import { RoutinesView } from "../views/RoutinesView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const members: FamilyMember[] = [
  { id: "child", name: "Child One", member_type: "child" },
  { id: "sibling", name: "Anna", member_type: "child" },
  { id: "dom", name: "Alex", member_type: "user" },
];
const swimming = {
  id: "routine-swim",
  person_id: "child",
  name: "Swimming",
  color: "#22b8cf",
  days_of_week: [2],
  sort_order: 0,
  time_of_day: "16:15",
  location: "School pool",
  preparation_note: "Costume under uniform",
  prep_template_id: "pack-swim",
  reminder_minutes: 60,
  calendar_projection: true,
  term_only: true,
};
const pack = {
  id: "pack-swim",
  name: "Swim kit",
  match_terms: ["swimming"],
  items: ["Costume", "Towel"],
  lead_hours: 24,
  assigned_to: "dom",
  enabled: true,
};

describe("Routines guided setup", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/routines/items" && !options) return [] as never;
      if (path === "/routines/terms" && !options) return [] as never;
      if (path === "/prep-packs/templates" && !options) return [pack] as never;
      if (path === "/routines/override/child" && !options) {
        return { person_id: "child", mode: "auto", expires_on: null } as never;
      }
      if (path === "/routines/items" && options?.method === "POST") return swimming as never;
      return {} as never;
    });
  });

  it("keeps the weekly preview simple while saving the practical detail behind More", async () => {
    render(<RoutinesView members={members} revision={0} onDataChanged={vi.fn()} notify={vi.fn()} />);

    expect(await screen.findByRole("heading", { name: "Child One's week" })).toBeInTheDocument();
    expect(screen.getByText("Weekly activities carry forward automatically between terms. Only add what changed.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Add activity" }));
    fireEvent.click(screen.getByRole("button", { name: "Swimming" }));
    fireEvent.change(screen.getByLabelText("Time (optional)"), { target: { value: "16:15" } });
    fireEvent.click(screen.getByText("More"));
    fireEvent.change(screen.getByLabelText("Location"), { target: { value: "School pool" } });
    fireEvent.change(screen.getByLabelText("Preparation note"), { target: { value: "Costume under uniform" } });
    fireEvent.change(screen.getByLabelText("Reusable packing list"), { target: { value: "pack-swim" } });
    fireEvent.change(screen.getByLabelText("Reminder"), { target: { value: "60" } });
    fireEvent.click(screen.getByRole("button", { name: "Add activity" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/routines/items",
      expect.objectContaining({
        method: "POST",
        body: expect.stringContaining("Costume under uniform"),
      }),
    ));
    const request = apiMock.mock.calls.find(([path, options]) => path === "/routines/items" && options?.method === "POST");
    expect(JSON.parse(String(request?.[1]?.body))).toMatchObject({
      person_id: "child",
      name: "Swimming",
      time_of_day: "16:15",
      location: "School pool",
      prep_template_id: "pack-swim",
      reminder_minutes: 60,
      calendar_projection: true,
      term_only: true,
    });
  });

  it("copies the full activity context to a sibling", async () => {
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/routines/items" && !options) return [swimming] as never;
      if (path === "/routines/terms" && !options) return [] as never;
      if (path === "/prep-packs/templates" && !options) return [pack] as never;
      if (path.startsWith("/routines/override/") && !options) return { mode: "auto" } as never;
      if (path === "/routines/items/routine-swim/duplicate" && options?.method === "POST") {
        return { ...swimming, id: "copy", person_id: "sibling" } as never;
      }
      return {} as never;
    });

    render(<RoutinesView members={members} revision={0} onDataChanged={vi.fn()} notify={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Copy Swimming" }));
    fireEvent.change(screen.getByLabelText("Copy to"), { target: { value: "sibling" } });
    fireEvent.click(screen.getByRole("button", { name: "Copy routine" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/routines/items/routine-swim/duplicate",
      { method: "POST", body: JSON.stringify({ target_person_id: "sibling" }) },
    ));
  });

  it("lets an imported term date be corrected in place", async () => {
    const imported = {
      id: "term-autumn",
      person_id: "child",
      label: "Imported Autumn",
      start_date: "2026-09-03",
      end_date: "2026-10-23",
      is_imported: true,
      is_overridden: false,
    };
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/routines/items" && !options) return [] as never;
      if (path === "/routines/terms" && !options) return [imported] as never;
      if (path === "/prep-packs/templates" && !options) return [] as never;
      if (path === "/routines/override/child" && !options) return { mode: "auto" } as never;
      if (path === "/routines/terms/term-autumn" && options?.method === "PUT") {
        return { ...imported, start_date: "2026-09-09", is_overridden: true } as never;
      }
      return {} as never;
    });
    const onDataChanged = vi.fn();
    const notify = vi.fn();

    render(<RoutinesView members={members} revision={0} onDataChanged={onDataChanged} notify={notify} />);

    expect(await screen.findByText("3 Sep 2026 – 23 Oct 2026 · Imported")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Edit Imported Autumn" }));
    const editor = screen.getByRole("dialog", { name: "Edit term dates" });
    fireEvent.change(within(editor).getByLabelText("Starts"), { target: { value: "2026-09-09" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/routines/terms/term-autumn",
      expect.objectContaining({
        method: "PUT",
        body: JSON.stringify({ label: "Imported Autumn", start_date: "2026-09-09", end_date: "2026-10-23" }),
      }),
    ));
    expect(notify).toHaveBeenCalledWith("Term dates updated.");
    expect(onDataChanged).toHaveBeenCalled();
  });
});
