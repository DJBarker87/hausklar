import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { QuickAddDialog } from "../components/QuickAddDialog";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

function localTimeInput(value: string): string {
  const parsed = new Date(value);
  const part = (number: number) => String(number).padStart(2, "0");
  return `${part(parsed.getHours())}:${part(parsed.getMinutes())}`;
}

function setOnline(online: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, value: online });
}

function requestBody(path: string, method: string): Record<string, unknown> {
  const call = apiMock.mock.calls.find(([candidate, init]) => candidate === path && init?.method === method);
  return JSON.parse(String(call?.[1]?.body)) as Record<string, unknown>;
}

describe("QuickAddDialog calendar events", () => {
  beforeEach(() => {
    setOnline(true);
    apiMock.mockReset();
  });
  afterEach(() => setOnline(true));

  it("creates an event for multiple participants and an affected adult", async () => {
    apiMock.mockResolvedValue({});
    const onCreated = vi.fn();
    const notify = vi.fn();
    render(
      <QuickAddDialog
        open
        initialKind="event"
        members={[
          { id: "dom", name: "Alex", member_type: "user" },
          { id: "kat", name: "Morgan", member_type: "user" },
          { id: "max", name: "Child One", member_type: "child" },
        ]}
        onOpenChange={vi.fn()}
        onCreated={onCreated}
        notify={notify}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Football" } });
    fireEvent.click(within(dialog).getByLabelText("Morgan"));
    fireEvent.click(within(dialog).getByLabelText("Child One"));
    fireEvent.click(within(dialog).getByLabelText("Affects Alex too"));
    fireEvent.change(within(dialog).getByLabelText("Date"), { target: { value: "2026-07-15" } });
    fireEvent.change(within(dialog).getByLabelText("Starts"), { target: { value: "15:00" } });
    fireEvent.change(within(dialog).getByLabelText("End date"), { target: { value: "2026-07-15" } });
    fireEvent.change(within(dialog).getByLabelText("Ends"), { target: { value: "16:15" } });
    fireEvent.change(within(dialog).getByLabelText("Repeat"), { target: { value: "weekly" } });
    fireEvent.change(within(dialog).getByLabelText("Location (optional)"), { target: { value: "School pitch" } });
    fireEvent.change(within(dialog).getByLabelText("Notes (optional)"), { target: { value: "Term time" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const body = requestBody("/calendar/", "POST");
    expect(body).toMatchObject({
      id: expect.stringMatching(/^[0-9a-f-]{36}$/i),
      title: "Football",
      description: "Term time",
      start_time: expect.stringContaining("2026-07-15T15:00:00"),
      end_time: expect.stringContaining("2026-07-15T16:15:00"),
      all_day: false,
      recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
      location: "School pitch",
      assigned_to: null,
      family_member_ids: ["kat", "max"],
      affected_member_ids: ["dom"],
    });
    expect(onCreated).toHaveBeenCalled();
    expect(notify).toHaveBeenCalledWith("Added to the family calendar.");
  });

  it("reuses the event operation ID after an ambiguous response failure", async () => {
    let attempts = 0;
    apiMock.mockImplementation(async (_path, init) => {
      if (init?.method === "POST") {
        attempts += 1;
        if (attempts === 1) throw new Error("Connection dropped");
      }
      return {};
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Football" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));
    expect(await within(dialog).findByText("Connection dropped")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(attempts).toBe(2));
    const bodies = apiMock.mock.calls
      .filter(([path, init]) => path === "/calendar/" && init?.method === "POST")
      .map(([, init]) => JSON.parse(String(init?.body)));
    expect(bodies[1].id).toBe(bodies[0].id);
    expect(bodies[1].client_timestamp).toBe(bodies[0].client_timestamp);
  });

  it("refuses an end time before the event starts", async () => {
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Invalid meeting" } });
    fireEvent.change(within(dialog).getByLabelText("Starts"), { target: { value: "16:00" } });
    fireEvent.change(within(dialog).getByLabelText("Ends"), { target: { value: "15:00" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    expect(await within(dialog).findByRole("alert")).toHaveTextContent("The end time must be after the start time.");
    expect(apiMock.mock.calls.some(([path]) => path === "/calendar/")).toBe(false);
  });

  it("defaults a new event to 15 minutes and keeps duration shortcuts in sync", async () => {
    apiMock.mockResolvedValue({});
    render(
      <QuickAddDialog
        open
        initialKind="event"
        initialDate={new Date(2026, 6, 15, 9, 0)}
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });

    expect(within(dialog).getByLabelText("Duration (optional)")).toHaveValue("15");
    expect(within(dialog).getByLabelText("Ends")).toHaveValue("09:15");
    fireEvent.change(within(dialog).getByLabelText("Starts"), { target: { value: "14:00" } });
    expect(within(dialog).getByLabelText("Ends")).toHaveValue("14:15");
    fireEvent.change(within(dialog).getByLabelText("Duration (optional)"), { target: { value: "60" } });
    expect(within(dialog).getByLabelText("Ends")).toHaveValue("15:00");

    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Appointment" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const body = requestBody("/calendar/", "POST");
    expect(body.start_time).toContain("2026-07-15T14:00:00");
    expect(body.end_time).toContain("2026-07-15T15:00:00");
  });

  it("creates an all-day multi-day event with an exclusive stored end date", async () => {
    apiMock.mockResolvedValue({});
    render(<QuickAddDialog open initialKind="event" initialDate={new Date(2026, 6, 15, 9, 0)} members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Family holiday" } });
    fireEvent.click(within(dialog).getByLabelText("All-day event"));
    fireEvent.click(within(dialog).getByLabelText("Multi-day"));
    fireEvent.change(within(dialog).getByLabelText("Last day"), { target: { value: "2026-07-18" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const body = requestBody("/calendar/", "POST");
    expect(body).toMatchObject({
      start_time: "2026-07-15",
      end_time: "2026-07-19",
      all_day: true,
    });
  });

  it("moves a simple weekly rule when the series start day changes", async () => {
    apiMock.mockResolvedValue({});
    render(
      <QuickAddDialog
        open
        initialKind="event"
        initialEvent={{
          id: "weekly-football",
          title: "Football",
          start_time: "2026-07-15T15:00:00+01:00",
          all_day: false,
          recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
        }}
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Edit event" });
    fireEvent.change(within(dialog).getByLabelText("Date"), { target: { value: "2026-07-16" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/weekly-football", expect.objectContaining({ method: "PUT" })));
    const body = requestBody("/calendar/weekly-football", "PUT");
    expect(body.start_time).toContain(
      `2026-07-16T${localTimeInput("2026-07-15T15:00:00+01:00")}:00`,
    );
    expect(body.recurrence_rule).toBe("FREQ=WEEKLY;BYDAY=TH");
  });

  it("keeps an occurrence anchor and exact recurrence rule on a scoped title-only edit", async () => {
    apiMock.mockResolvedValue({});
    render(
      <QuickAddDialog
        open
        initialKind="event"
        initialEvent={{
          id: "series::2026-09-22T16:00:00Z",
          series_id: "series",
          is_generated_occurrence: true,
          title: "Swimming",
          start_time: "2026-09-22T16:00:00Z",
          end_time: "2026-09-22T17:00:00Z",
          all_day: false,
          recurrence_rule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10",
        }}
        recurrenceScope="entire_series"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Edit event" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Swimming lesson" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/series/occurrences/edit",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    const body = requestBody("/calendar/series/occurrences/edit", "POST");
    const updates = body.updates as Record<string, unknown>;
    expect(body.scope).toBe("entire_series");
    expect(body.occurrence_start).toBe("2026-09-22T16:00:00Z");
    expect(updates.title).toBe("Swimming lesson");
    expect(updates).not.toHaveProperty("start_time");
    expect(updates).not.toHaveProperty("end_time");
    expect(updates).not.toHaveProperty("recurrence_rule");
    expect(updates.client_id).toMatch(/^[0-9a-f-]{36}$/i);
    expect(updates.client_timestamp).toBeTruthy();
  });

  it("isolates one occurrence without offering a repeat-rule edit", async () => {
    apiMock.mockResolvedValue({});
    render(
      <QuickAddDialog
        open
        initialKind="event"
        initialEvent={{
          id: "series::2026-09-22T16:00:00Z",
          series_id: "series",
          is_generated_occurrence: true,
          title: "Swimming",
          start_time: "2026-09-22T16:00:00Z",
          all_day: false,
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
        }}
        recurrenceScope="only_this"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Edit event" });
    expect(within(dialog).getAllByText("Other events in the series stay unchanged.")).not.toHaveLength(0);
    expect(within(dialog).queryByLabelText("Repeat")).not.toBeInTheDocument();
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Swimming with Morgan" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/calendar/series/occurrences/edit",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    const body = requestBody("/calendar/series/occurrences/edit", "POST");
    expect(body).toMatchObject({
      scope: "only_this",
      occurrence_start: "2026-09-22T16:00:00Z",
      updates: { title: "Swimming with Morgan" },
    });
    expect(body.updates).not.toHaveProperty("recurrence_rule");
  });

  it("blocks unavailable people controls and preserves stored participants", async () => {
    apiMock.mockResolvedValue({});
    render(
      <QuickAddDialog
        open
        initialKind="event"
        initialEvent={{
          id: "doctor",
          title: "Doctor",
          start_time: "2026-09-22T09:00:00Z",
          end_time: "2026-09-22T09:30:00Z",
          all_day: false,
          assigned_to: "kat",
          family_member_ids: ["kat", "child"],
          affected_member_ids: ["dom"],
        }}
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Edit event" });
    expect(within(dialog).getByText(/Existing people will be kept/)).toBeInTheDocument();
    expect(within(dialog).getByLabelText("Everyone")).toBeDisabled();
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Doctor appointment" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/doctor", expect.objectContaining({ method: "PUT" })));
    const body = requestBody("/calendar/doctor", "PUT");
    expect(body).not.toHaveProperty("assigned_to");
    expect(body).not.toHaveProperty("family_member_ids");
    expect(body).not.toHaveProperty("affected_member_ids");
  });

  it("links an existing family document when creating an event", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/?limit=200") return [{
        id: "letter-1",
        title: "Doctor letter",
        original_filename: "doctor.pdf",
      }];
      return {};
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Doctor" } });
    const selector = within(dialog).getByLabelText("Choose an existing document");
    fireEvent.focus(selector);
    await screen.findByRole("option", { name: "Doctor letter · doctor.pdf" });
    fireEvent.change(selector, { target: { value: "letter-1" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const calendarCall = apiMock.mock.calls.find(([path]) => path === "/calendar/");
    expect(JSON.parse(String(calendarCall?.[1]?.body))).toMatchObject({ source_document_id: "letter-1" });
  });

  it("keeps several labelled documents on one event", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/?limit=200") return [
        { id: "ticket-1", title: "Train ticket", original_filename: "ticket.pdf" },
        { id: "booking-1", title: "Hotel booking", original_filename: "hotel.pdf" },
      ];
      return {};
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Family trip" } });
    const selector = within(dialog).getByLabelText("Choose an existing document");
    await screen.findByRole("option", { name: "Train ticket · ticket.pdf" });
    fireEvent.change(within(dialog).getByLabelText("Type"), { target: { value: "ticket" } });
    fireEvent.change(selector, { target: { value: "ticket-1" } });
    fireEvent.change(within(dialog).getByLabelText("Type"), { target: { value: "booking" } });
    fireEvent.change(selector, { target: { value: "booking-1" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    expect(requestBody("/calendar/", "POST")).toMatchObject({
      source_document_id: "ticket-1",
      attachments: [
        { document_id: "ticket-1", role: "ticket" },
        { document_id: "booking-1", role: "booking" },
      ],
    });
  });

  it("still creates offline with a previously loaded saved document", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/?limit=200") return [{
        id: "letter-1",
        title: "Doctor letter",
        original_filename: "doctor.pdf",
      }];
      return {};
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    const selector = within(dialog).getByLabelText("Choose an existing document");
    await screen.findByRole("option", { name: "Doctor letter · doctor.pdf" });
    fireEvent.change(selector, { target: { value: "letter-1" } });
    setOnline(false);
    fireEvent(window, new Event("offline"));
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Doctor" } });
    expect(within(dialog).getByRole("button", { name: "Add event" })).toBeEnabled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    expect(requestBody("/calendar/", "POST")).toMatchObject({ source_document_id: "letter-1" });
  });

  it("saves a new attachment and its event while offline", async () => {
    apiMock.mockImplementation(async (path) => path === "/documents/" ? { id: "photo-1" } : {});
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "School concert" } });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "concert.pdf", { type: "application/pdf" })] },
    });

    setOnline(false);
    fireEvent(window, new Event("offline"));
    await waitFor(() => expect(within(dialog).getByRole("button", { name: "Add event" })).toBeEnabled());
    expect(within(dialog).getByText("concert.pdf")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/", expect.objectContaining({ method: "POST" })));
    expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" }));
  });

  it("uploads the original photo before linking it to a new event", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/") return { id: "photo-1" };
      return {};
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "School concert" } });
    const photo = new File(["image"], "concert.jpg", { type: "image/jpeg" });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), { target: { files: [photo] } });
    expect(within(dialog).getByAltText("Preview of concert.jpg")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const uploadCall = apiMock.mock.calls.find(([path]) => path === "/documents/");
    const form = uploadCall?.[1]?.body as FormData;
    expect(form.get("file")).toBe(photo);
    expect(form.get("source")).toBe("photo");
    expect(form.get("document_id")).toMatch(/^[0-9a-f-]{36}$/i);
    const calendarCall = apiMock.mock.calls.find(([path]) => path === "/calendar/");
    expect(JSON.parse(String(calendarCall?.[1]?.body))).toMatchObject({ source_document_id: "photo-1" });
  });

  it("reuses the pending document ID after an ambiguous upload failure", async () => {
    let uploadAttempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/") {
        uploadAttempts += 1;
        if (uploadAttempts === 1) throw new Error("Connection dropped after upload");
        return { id: "photo-1" };
      }
      return [];
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "School concert" } });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "concert.pdf", { type: "application/pdf" })] },
    });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Connection dropped after upload");
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(uploadAttempts).toBe(2));
    const forms = apiMock.mock.calls
      .filter(([path, init]) => path === "/documents/" && init?.method === "POST")
      .map(([, init]) => init?.body as FormData);
    expect(forms[0].get("document_id")).toMatch(/^[0-9a-f-]{36}$/i);
    expect(forms[1].get("document_id")).toBe(forms[0].get("document_id"));
  });

  it("really removes an uploaded attachment after the event save fails", async () => {
    let calendarAttempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/") return { id: "uploaded-document" };
      if (path === "/calendar/") {
        calendarAttempts += 1;
        if (calendarAttempts === 1) throw new Error("Event could not be saved");
        return {};
      }
      return [];
    });
    render(<QuickAddDialog open initialKind="event" members={[]} onOpenChange={vi.fn()} onCreated={vi.fn()} notify={vi.fn()} />);
    const dialog = screen.getByRole("dialog", { name: "Add to the plan" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "School concert" } });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "concert.pdf", { type: "application/pdf" })] },
    });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Event could not be saved");

    fireEvent.click(within(dialog).getByRole("button", { name: "Remove concert.pdf" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Add event" }));

    await waitFor(() => expect(calendarAttempts).toBe(2));
    const eventBodies = apiMock.mock.calls
      .filter(([path, init]) => path === "/calendar/" && init?.method === "POST")
      .map(([, init]) => JSON.parse(String(init?.body)) as Record<string, unknown>);
    expect(eventBodies[0].source_document_id).toBe("uploaded-document");
    expect(eventBodies[1].source_document_id).toBeNull();
    expect(apiMock.mock.calls.filter(([path]) => path === "/documents/")).toHaveLength(1);
  });
});
