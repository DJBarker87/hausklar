import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { DocumentsView } from "../views/DocumentsView";

vi.mock("../api", () => ({
  api: vi.fn(),
  localISODateTime: vi.fn((date: Date) => date.toISOString()),
}));

const apiMock = vi.mocked(api);

function familyDocument(id: string, title: string, personID: string, personName: string) {
  return {
    id,
    title,
    original_filename: `${id}.pdf`,
    media_type: "application/pdf",
    file_size: 4_096,
    source: "upload",
    category: "school",
    status: "inbox",
    page_count: 1,
    processor: "device",
    people: [{ id: `person-${id}`, person_id: personID, person_name: personName, person_type: "child" }],
    suggestions: [],
    linked_events: [],
    linked_tasks: [],
    pending_suggestion_count: 0,
    download_url: `/documents/${id}/download`,
    created_at: "2026-07-11T08:00:00Z",
    updated_at: "2026-07-11T08:00:00Z",
  };
}

describe("DocumentsView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path === "/documents/stats") return { storage_bytes: 4096, storage_quota_bytes: 1048576 };
      if (path.startsWith("/documents/?")) return [
        familyDocument("letter-max", "Child One nursery letter", "max", "Child One"),
        familyDocument("letter-lily", "Lily school letter", "lily", "Lily"),
      ];
      return [];
    });
  });

  it("exposes labelled person filters as pressed controls and filters the inbox", async () => {
    render(
      <DocumentsView
        members={[
          { id: "max", name: "Child One", member_type: "child" },
          { id: "lily", name: "Lily", member_type: "child" },
        ]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    expect(await screen.findByText("Child One nursery letter")).toBeInTheDocument();
    const filters = screen.getByRole("group", { name: "Filter documents by person" });
    expect(within(filters).getByRole("button", { name: "Everyone" })).toHaveAttribute("aria-pressed", "true");

    fireEvent.click(within(filters).getByRole("button", { name: "Child One" }));
    expect(within(filters).getByRole("button", { name: "Child One" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByText("Child One nursery letter")).toBeInTheDocument();
    expect(screen.queryByText("Lily school letter")).not.toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("person_id=max")));
  });

  it("uses server-side search so text inside scanned letters can be found", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path.includes("search=account+reference")) return [familyDocument("hidden-text", "Nursery statement", "max", "Child One")];
      if (path.startsWith("/documents/?")) return [];
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByPlaceholderText("Search documents"), { target: { value: "account reference" } });

    expect(await screen.findByText("Nursery statement")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(expect.stringContaining("search=account+reference"));
  });

  it("refreshes the inbox after returning to the PWA", async () => {
    render(
      <DocumentsView
        members={[]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );
    await screen.findByText("Child One nursery letter");
    fireEvent.click(screen.getByRole("button", { name: "Manage" }));
    expect(await screen.findByText("Only active family account addresses are accepted.")).toBeInTheDocument();
    const before = apiMock.mock.calls.filter(([path]) => String(path).startsWith("/documents/?")).length;
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => {
      const after = apiMock.mock.calls.filter(([path]) => String(path).startsWith("/documents/?")).length;
      expect(after).toBeGreaterThan(before);
    });
  });

  it("labels shared finance filing without implying Private Finance access", async () => {
    const document = familyDocument("letter-max", "Child One nursery letter", "max", "Child One");
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path === "/documents/letter-max") return document;
      if (path.startsWith("/documents/?")) return [document];
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /Child One nursery letter/ }));
    const detail = screen.getByRole("dialog", { name: "Child One nursery letter" });
    fireEvent.click(await within(detail).findByRole("button", { name: "Edit details" }));
    const category = within(detail).getByLabelText("Category");
    expect(within(category).getByRole("option", { name: "Household finance" })).toHaveValue("finance");
    expect(within(category).queryByRole("option", { name: /shared with family/i })).not.toBeInTheDocument();
  });

  it("previews a document with a close button and shows reverse event links", async () => {
    const linked = {
      ...familyDocument("doctor", "Doctor letter", "max", "Child One"),
      linked_events: [{
        id: "event-1",
        title: "Doctor appointment",
        start_time: "2026-07-21T10:00:00Z",
        end_time: "2026-07-21T10:30:00Z",
        all_day: false,
      }],
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path === "/documents/doctor") return linked;
      if (path.startsWith("/documents/?")) return [linked];
      if (path === "/calendar/event-1" && init?.method === "PUT") return {};
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /Doctor letter/ }));
    const detail = screen.getByRole("dialog", { name: "Doctor letter" });
    expect(await within(detail).findByRole("link", { name: /Doctor appointment/ })).toHaveAttribute("href", "?view=planner&event=event-1&event_date=2026-07-21");
    fireEvent.click(within(detail).getByRole("button", { name: "Open file" }));
    const viewer = screen.getByRole("dialog", { name: "Doctor letter" });
    expect(await within(viewer).findByTitle("Doctor letter")).toHaveAttribute("src", linked.download_url);
    expect(within(viewer).getByTitle("Doctor letter")).toHaveAttribute("sandbox", "allow-same-origin");
    fireEvent.click(within(viewer).getByRole("button", { name: "Close preview" }));
    const restored = await screen.findByRole("dialog", { name: "Doctor letter" });
    expect(within(restored).getByRole("button", { name: "Open file" })).toBeInTheDocument();
    expect(within(restored).queryByTitle("Doctor letter")).not.toBeInTheDocument();
  });

  it("attaches the open document to an existing calendar event", async () => {
    const original = familyDocument("doctor", "Doctor letter", "max", "Child One");
    const linked = {
      ...original,
      linked_events: [{
        id: "event-available",
        title: "Dentist follow-up",
        start_time: "2026-07-21T10:00:00Z",
        end_time: null,
        all_day: false,
      }],
    };
    let attached = false;
    const notify = vi.fn();
    const changed = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path === "/documents/doctor") return attached ? linked : original;
      if (path.startsWith("/documents/?")) return [original];
      if (String(path).startsWith("/calendar/?")) return [{
        id: "event-available",
        title: "Dentist follow-up",
        start_time: "2026-07-21T10:00:00Z",
        end_time: null,
        all_day: false,
        source_document_id: null,
      }];
      if (path === "/calendar/event-available" && init?.method === "PUT") {
        attached = true;
        return {};
      }
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={changed}
        notify={notify}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /Doctor letter/ }));
    const detail = screen.getByRole("dialog", { name: "Doctor letter" });
    fireEvent.click(await within(detail).findByRole("button", { name: "Attach existing" }));
    const linker = screen.getByRole("dialog", { name: "Attach to an existing item" });
    fireEvent.click(await within(linker).findByRole("radio", { name: /Dentist follow-up/ }));
    fireEvent.click(within(linker).getByRole("button", { name: "Attach to event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/event-available", {
      method: "PUT",
      body: JSON.stringify({ source_document_id: "doctor" }),
    }));
    const restored = await screen.findByRole("dialog", { name: "Doctor letter" });
    expect(within(restored).getByRole("link", { name: /Dentist follow-up/ })).toBeInTheDocument();
    expect(notify).toHaveBeenCalledWith("Event “Dentist follow-up” attached.");
    expect(changed).toHaveBeenCalled();
  });

  it("saves the complete family-facing filing metadata", async () => {
    const document = {
      ...familyDocument("passport", "Passport scan", "max", "Child One"),
      category: "other",
      category_confidence: 0.25,
      document_date: "2026-07-01",
      document_date_confidence: 0.35,
      notes: "Old note",
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/documents/passport" && init?.method === "PATCH") return document;
      if (path === "/documents/passport") return document;
      if (path.startsWith("/documents/?")) return [document];
      return [];
    });
    render(
      <DocumentsView
        members={[
          { id: "max", name: "Child One", member_type: "child" },
          { id: "lily", name: "Lily", member_type: "child" },
        ]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /Passport scan/ }));
    const detail = screen.getByRole("dialog", { name: "Passport scan" });
    fireEvent.click(await within(detail).findByRole("button", { name: "Edit details" }));
    fireEvent.change(within(detail).getByLabelText("Title"), { target: { value: "Child One passport" } });
    fireEvent.change(within(detail).getByLabelText("Category"), { target: { value: "identity" } });
    fireEvent.change(within(detail).getByLabelText("Document date"), { target: { value: "2026-08-01" } });
    fireEvent.change(within(detail).getByLabelText("Notes"), { target: { value: "Renew before next summer" } });
    fireEvent.click(within(detail).getByRole("checkbox", { name: "Lily" }));
    fireEvent.click(within(detail).getByRole("button", { name: "Save details" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/passport", {
      method: "PATCH",
      body: JSON.stringify({
        title: "Child One passport",
        category: "identity",
        document_date: "2026-08-01",
        notes: "Renew before next summer",
        person_ids: ["max", "lily"],
      }),
    }));
  });

  it("batch-files only documents the server marked as safe", async () => {
    const ready = { ...familyDocument("ready", "Reviewed policy", "max", "Child One"), ready_for_batch_filing: true };
    const uncertain = {
      ...familyDocument("uncertain", "Forwarded invoice", "max", "Child One"),
      category_confidence: 0.25,
      ready_for_batch_filing: false,
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/documents/file-ready" && init?.method === "POST") {
        return { filed_ids: ["ready"], skipped_ids: [] };
      }
      if (path.startsWith("/documents/?")) return [uncertain, ready];
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    expect(await screen.findByRole("heading", { name: "Needs your attention" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Ready to file" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "File 1" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/file-ready", {
      method: "POST",
      body: JSON.stringify({ document_ids: ["ready"] }),
    }));
  });

  it("keeps storage and archive tools inside management and restores archived files", async () => {
    const archived = { ...familyDocument("archive", "Old insurance policy", "max", "Child One"), status: "archived" };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/documents/stats") return { storage_bytes: 4096, storage_quota_bytes: 1048576 };
      if (path === "/documents/email-address") return { configured: true, address: "demo-person-10@example.invalid" };
      if (path.includes("status=archived")) return [archived];
      if (path === "/documents/archive" && init?.method === "PATCH") return archived;
      if (path.startsWith("/documents/?")) return [];
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    await screen.findByText("Nothing needs your attention");
    expect(screen.queryByText(/used$/)).not.toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/documents/stats");

    fireEvent.click(screen.getByRole("button", { name: "Manage" }));
    const management = await screen.findByRole("dialog", { name: "Manage documents" });
    expect(within(management).getByText("4 KB used")).toBeInTheDocument();
    expect(within(management).getByText("Old insurance policy")).toBeInTheDocument();
    fireEvent.click(within(management).getByRole("button", { name: "Restore" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/archive", {
      method: "PATCH",
      body: JSON.stringify({ status: "filed" }),
    }));
    await waitFor(() => expect(within(management).queryByText("Old insurance policy")).not.toBeInTheDocument());
  });

  it("keeps dismissed action history out of the family-facing detail", async () => {
    const document = {
      ...familyDocument("letter", "School letter", "max", "Child One"),
      suggestions: [{
        id: "dismissed-action",
        document_id: "letter",
        kind: "task",
        title: "Old rejected guess",
        details: null,
        start_time: null,
        end_time: null,
        due_date: null,
        all_day: true,
        assigned_to: null,
        assigned_to_name: null,
        confidence: 0.3,
        source_text: null,
        status: "dismissed",
        result_id: null,
        result_status: "dismissed",
        result_completed_at: null,
        created_at: "2026-07-11T08:00:00Z",
        updated_at: "2026-07-11T08:00:00Z",
      }],
    };
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/letter") return document;
      if (path.startsWith("/documents/?")) return [document];
      return [];
    });
    render(
      <DocumentsView
        members={[{ id: "max", name: "Child One", member_type: "child" }]}
        revision={0}
        onAddDocument={vi.fn()}
        onDataChanged={vi.fn()}
        notify={vi.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole("button", { name: /School letter/ }));
    const detail = screen.getByRole("dialog", { name: "School letter" });
    expect(await within(detail).findByText("No actions attached.")).toBeInTheDocument();
    expect(within(detail).queryByText("Old rejected guess")).not.toBeInTheDocument();
  });
});
