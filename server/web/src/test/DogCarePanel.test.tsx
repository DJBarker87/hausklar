import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { DogCarePanel } from "../views/DogCarePanel";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const members = [
  { id: "dom", name: "Alex", member_type: "user" as const },
  { id: "kat", name: "Morgan", member_type: "user" as const },
];

const profile = {
  id: "profile-1",
  name: "Mabel",
  date_of_birth: "2020-03-01",
  breed: "Labrador",
  microchip_number: "981000000000001",
  insurance_provider: "ManyPets",
  insurance_policy_number: "POL-123",
  vet_name: "Village Vets",
  vet_phone: "+00000000003",
  allergies: "Chicken",
  medicine_notes: "Tablet with food",
  breakfast_window_start: "07:30",
  breakfast_window_end: "08:30",
  walk_window_start: "10:00",
  walk_window_end: "12:00",
  dinner_window_start: "17:30",
  dinner_window_end: "19:00",
};

const activity = {
  id: "walk-1",
  activity_type: "walk" as const,
  started_at: "2026-08-08T10:00:00Z",
  ended_at: "2026-08-08T10:45:00Z",
  notes: "Park loop",
  is_active: false,
  done_by: "kat",
};

const vaccination = {
  id: "vaccination-1",
  vaccine_name: "Leptospirosis",
  given_on: "2026-06-01",
  next_due_on: "2027-06-01",
  notes: "Annual booster",
};

const weight = {
  id: "weight-1",
  measured_on: "2026-07-01",
  weight_kg: 22.4,
  notes: "Home scales",
};

function dogStatus(overrides: Record<string, unknown> = {}) {
  return {
    walked_today: false,
    fed_breakfast_today: false,
    fed_dinner_today: false,
    last_walk: activity,
    last_feed_breakfast: null,
    last_feed_dinner: null,
    active_walk: null,
    dog_name: "Mabel",
    walk_state: "due",
    breakfast_state: "overdue",
    dinner_state: "upcoming",
    ...overrides,
  };
}

function baseMock() {
  apiMock.mockImplementation(async (path) => {
    if (path.startsWith("/dog/status?")) return dogStatus() as never;
    if (path === "/dog/profile") return profile as never;
    if (path.startsWith("/dog/activities?")) return [activity] as never;
    if (path.startsWith("/dog/weights?")) return [weight] as never;
    if (path.startsWith("/dog/vaccinations?")) return [vaccination] as never;
    if (path === "/dog/documents") return [] as never;
    return [] as never;
  });
}

function renderPanel(onDataChanged = vi.fn()) {
  return render(<DogCarePanel members={members} revision={0} onDataChanged={onDataChanged} />);
}

async function openPetRecord() {
  const summary = (await screen.findByText("Pet record")).closest("summary");
  if (!summary) throw new Error("Pet record summary missing");
  fireEvent.click(summary);
}

describe("DogCarePanel", () => {
  beforeEach(() => {
    apiMock.mockReset();
    baseMock();
  });

  it("uses the server's care states and starts and ends one shared timed walk", async () => {
    let currentStatus = dogStatus();
    const active = {
      id: "walk-live",
      activity_type: "walk" as const,
      started_at: new Date(Date.now() - 61_000).toISOString(),
      ended_at: null,
      notes: null,
      is_active: true,
      done_by: "dom",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return currentStatus as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [activity] as never;
      if (path.startsWith("/dog/weights?")) return [] as never;
      if (path.startsWith("/dog/vaccinations?")) return [] as never;
      if (path === "/dog/documents") return [] as never;
      if (path === "/dog/activities" && init?.method === "POST") {
        currentStatus = dogStatus({ active_walk: active });
        return active as never;
      }
      if (path === "/dog/activities/walk-live" && init?.method === "PUT") {
        const ended = { ...active, ended_at: "2026-08-09T11:00:00Z", is_active: false };
        currentStatus = dogStatus({ walked_today: true, active_walk: null, walk_state: "done", last_walk: ended });
        return ended as never;
      }
      return [] as never;
    });

    renderPanel();
    expect(await screen.findByRole("button", { name: /Walk due now/ })).toHaveTextContent("10:00–12:00");
    expect(screen.getByRole("button", { name: /Breakfast overdue/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Dinner later/ })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Walk due now/ }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/dog/activities", {
      method: "POST",
      body: expect.stringContaining('"is_active":true'),
    }));
    const liveWalk = await screen.findByRole("button", { name: /Walking now/ });
    expect(liveWalk).toHaveTextContent(/1:0\d/);

    fireEvent.click(liveWalk);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/dog/activities/walk-live", {
      method: "PUT",
      body: expect.stringContaining('"is_active":false'),
    }));
    expect(await screen.findByRole("button", { name: /Walk done/ })).toBeInTheDocument();
  });

  it("requires an explicit choice before logging a second feed", async () => {
    const breakfast = { ...activity, id: "breakfast-1", activity_type: "feed_breakfast" as const };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return dogStatus({
        fed_breakfast_today: true,
        breakfast_state: "done",
        last_feed_breakfast: breakfast,
      }) as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [breakfast] as never;
      if (path.startsWith("/dog/weights?") || path.startsWith("/dog/vaccinations?") || path === "/dog/documents") return [] as never;
      if (path === "/dog/activities" && init?.method === "POST") return { ...breakfast, id: "breakfast-2" } as never;
      return [] as never;
    });

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: /Breakfast done/ }));
    expect(apiMock).not.toHaveBeenCalledWith("/dog/activities", expect.objectContaining({ method: "POST" }));
    const dialog = screen.getByRole("dialog", { name: "Breakfast is already logged" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Log another feed" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/dog/activities", expect.objectContaining({ method: "POST" })));
  });

  it("keeps a saved quick action visible when only the follow-up status refresh fails", async () => {
    let statusCalls = 0;
    const dinner = { ...activity, id: "dinner-1", activity_type: "feed_dinner" as const };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) {
        statusCalls += 1;
        if (statusCalls > 1) throw new Error("Refresh dropped");
        return dogStatus() as never;
      }
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [] as never;
      if (path.startsWith("/dog/weights?") || path.startsWith("/dog/vaccinations?") || path === "/dog/documents") return [] as never;
      if (path === "/dog/activities" && init?.method === "POST") return dinner as never;
      return [] as never;
    });

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: /Dinner later/ }));
    expect(await screen.findByRole("button", { name: /Dinner done/ })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("change was saved");
  });

  it("keeps today's care usable when optional pet-record history fails", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/dog/status?")) return dogStatus() as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) throw new Error("History unavailable");
      if (path.startsWith("/dog/weights?") || path.startsWith("/dog/vaccinations?") || path === "/dog/documents") return [] as never;
      return [] as never;
    });

    renderPanel();

    expect(await screen.findByRole("button", { name: /Walk due now/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Breakfast overdue/ })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("Today’s care is available");
  });

  it("edits the full profile and the care windows that drive reminders", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return dogStatus() as never;
      if (path === "/dog/profile" && init?.method === "PUT") return { ...profile, name: "Mabel Example", walk_window_start: "09:30" } as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [activity] as never;
      if (path.startsWith("/dog/weights?")) return [weight] as never;
      if (path.startsWith("/dog/vaccinations?")) return [vaccination] as never;
      if (path === "/dog/documents") return [] as never;
      return [] as never;
    });

    renderPanel();
    await openPetRecord();
    const details = (await screen.findByRole("heading", { name: "Important details" })).closest("section")!;
    fireEvent.click(within(details).getByRole("button", { name: "Edit" }));
    const dialog = screen.getByRole("dialog", { name: "Edit Mabel's pet record" });
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Mabel Example" } });
    const fromInputs = within(dialog).getAllByLabelText("From");
    fireEvent.change(fromInputs[0], { target: { value: "07:15" } });
    fireEvent.change(fromInputs[1], { target: { value: "09:30" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save pet record" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/dog/profile" && init?.method === "PUT");
      expect(call).toBeTruthy();
      expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({
        name: "Mabel Example",
        breakfast_window_start: "07:15",
        walk_window_start: "09:30",
        microchip_number: "981000000000001",
      });
    });
    expect(await screen.findByRole("heading", { name: "Mabel Example" })).toBeInTheDocument();
  });

  it("corrects, removes and restores a care record", async () => {
    const corrected = { ...activity, notes: "Corrected park route" };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return dogStatus() as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [activity] as never;
      if (path.startsWith("/dog/weights?")) return [] as never;
      if (path.startsWith("/dog/vaccinations?")) return [] as never;
      if (path === "/dog/documents") return [] as never;
      if (path === "/dog/activities/walk-1" && init?.method === "PUT") return corrected as never;
      if (path === "/dog/activities/walk-1" && init?.method === "DELETE") return undefined as never;
      if (path === "/dog/activities/walk-1/restore" && init?.method === "POST") return corrected as never;
      return [] as never;
    });

    renderPanel();
    fireEvent.click(await screen.findByRole("button", { name: /Walk.*Park loop/ }));
    let dialog = screen.getByRole("dialog", { name: "Correct care record" });
    fireEvent.change(within(dialog).getByLabelText("Notes (optional)"), { target: { value: "Corrected park route" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save correction" }));
    await waitFor(() => expect(screen.getByRole("button", { name: /Walk.*Corrected park route/ })).toBeInTheDocument());

    fireEvent.click(screen.getByRole("button", { name: /Walk.*Corrected park route/ }));
    dialog = screen.getByRole("dialog", { name: "Correct care record" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Remove" }));
    const confirm = screen.getByRole("dialog", { name: "Remove this record?" });
    fireEvent.click(within(confirm).getByRole("button", { name: "Remove record" }));
    const undo = await screen.findByRole("button", { name: "Undo" });
    expect(undo).toHaveFocus();
    fireEvent.click(undo);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/dog/activities/walk-1/restore", { method: "POST" }));
    await waitFor(() => expect(screen.getByRole("button", { name: /Walk.*Corrected park route/ })).toBeInTheDocument());
  });

  it("adds and corrects weights and vaccinations", async () => {
    const addedWeight = { id: "weight-2", measured_on: "2026-08-01", weight_kg: 22.1, notes: "Vet scales" };
    const correctedVaccination = { ...vaccination, next_due_on: "2027-07-01" };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return dogStatus() as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [activity] as never;
      if (path.startsWith("/dog/weights?")) return [weight] as never;
      if (path.startsWith("/dog/vaccinations?")) return [vaccination] as never;
      if (path === "/dog/documents") return [] as never;
      if (path === "/dog/weights" && init?.method === "POST") return addedWeight as never;
      if (path === "/dog/vaccinations/vaccination-1" && init?.method === "PATCH") return correctedVaccination as never;
      return [] as never;
    });

    renderPanel();
    await openPetRecord();
    const weightSection = (await screen.findByRole("heading", { name: "Weight" })).closest("section")!;
    fireEvent.click(within(weightSection).getByRole("button", { name: "Add" }));
    let dialog = screen.getByRole("dialog", { name: "Add weight" });
    fireEvent.change(within(dialog).getByLabelText("Date"), { target: { value: "2026-08-01" } });
    fireEvent.change(within(dialog).getByLabelText("Weight (kg)"), { target: { value: "22.1" } });
    fireEvent.change(within(dialog).getByLabelText("Notes (optional)"), { target: { value: "Vet scales" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add weight" }));
    expect(await within(weightSection).findByText("22.1 kg")).toBeInTheDocument();

    const vaccinationSection = screen.getByRole("heading", { name: "Vaccinations" }).closest("section")!;
    fireEvent.click(within(vaccinationSection).getByRole("button", { name: /Leptospirosis/ }));
    dialog = screen.getByRole("dialog", { name: "Correct vaccination" });
    fireEvent.change(within(dialog).getByLabelText("Next due (optional)"), { target: { value: "2027-07-01" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save correction" }));
    expect(await within(vaccinationSection).findByText(/Next due 1 Jul 2027/)).toBeInTheDocument();
  });

  it("links a filed document in its exact pet-record context and can remove only the link", async () => {
    const candidate = {
      id: "document-1",
      title: "Pet insurance policy",
      original_filename: "policy.pdf",
      media_type: "application/pdf",
      file_size: 12_000,
      download_url: "/api/documents/document-1/content",
      status: "filed" as const,
    };
    const linked = { ...candidate, id: "link-1", document_id: candidate.id, role: "insurance" as const };
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/dog/status?")) return dogStatus() as never;
      if (path === "/dog/profile") return profile as never;
      if (path.startsWith("/dog/activities?")) return [activity] as never;
      if (path.startsWith("/dog/weights?")) return [] as never;
      if (path.startsWith("/dog/vaccinations?")) return [] as never;
      if (path === "/dog/documents" && init?.method === "POST") return linked as never;
      if (path === "/dog/documents") return [] as never;
      if (path === "/documents/?status=filed&offset=0&limit=200") return [candidate] as never;
      if (path === "/dog/documents/link-1" && init?.method === "DELETE") return undefined as never;
      return [] as never;
    });

    renderPanel();
    await openPetRecord();
    const documentsSection = (await screen.findByRole("heading", { name: "Documents" })).closest("section")!;
    fireEvent.click(within(documentsSection).getByRole("button", { name: "Add" }));
    const dialog = screen.getByRole("dialog", { name: "Add pet document" });
    fireEvent.change(await within(dialog).findByLabelText("Document"), { target: { value: "document-1" } });
    fireEvent.change(within(dialog).getByLabelText("Type"), { target: { value: "insurance" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add document" }));
    expect(await within(documentsSection).findByText("Pet insurance policy")).toBeInTheDocument();

    fireEvent.click(within(documentsSection).getByRole("button", { name: "Remove Pet insurance policy from the pet record" }));
    const confirm = screen.getByRole("dialog", { name: "Remove this document link?" });
    expect(confirm).toHaveTextContent("original stays safely filed");
    fireEvent.click(within(confirm).getByRole("button", { name: "Remove link" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/dog/documents/link-1", { method: "DELETE" }));
    expect(within(documentsSection).queryByText("Pet insurance policy")).not.toBeInTheDocument();
  });
});
