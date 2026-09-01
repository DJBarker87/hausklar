import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { ExistingRecordLinker } from "../components/ExistingRecordLinker";
import type { FamilyDocument } from "../types";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const sourceDocument = {
  id: "document-1",
  title: "Doctor letter",
  original_filename: "doctor.pdf",
  media_type: "application/pdf",
  file_size: 2048,
  source: "upload",
  category: "medical",
  status: "inbox",
  document_date: "2026-07-10",
  page_count: 1,
  processor: "device",
  people: [],
  suggestions: [],
  linked_events: [{ id: "already-linked", title: "Linked", start_time: "2026-07-11", all_day: true }],
  linked_tasks: [{ id: "linked-task", title: "Linked task", completed_at: null }],
  pending_suggestion_count: 0,
  download_url: "/api/documents/document-1/content",
  created_at: "2026-07-10T08:00:00Z",
  updated_at: "2026-07-10T08:00:00Z",
} satisfies FamilyDocument;

const events = [
  { id: "eligible", title: "Dentist follow-up", start_time: "2026-07-21T10:00:00Z", end_time: null, all_day: false, source_document_id: null },
  { id: "already-linked", title: "Already linked", start_time: "2026-07-11", all_day: true, source_document_id: "document-1" },
  { id: "occupied", title: "Has another file", start_time: "2026-07-22", all_day: true, source_document_id: "other-document" },
  { id: "series::one", series_id: "series", title: "Swimming", start_time: "2026-07-23T16:00:00Z", all_day: false, source_document_id: null },
  { id: "series::two", series_id: "series", title: "Swimming", start_time: "2026-07-30T16:00:00Z", all_day: false, source_document_id: null },
];

describe("ExistingRecordLinker", () => {
  beforeEach(() => apiMock.mockReset());

  it("searches deduplicated unattached events and revalidates before linking", async () => {
    const onLinked = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (String(path).startsWith("/calendar/?")) return events;
      if (path === "/calendar/eligible" && init?.method === "PUT") return {};
      return [];
    });
    render(<ExistingRecordLinker sourceDocument={sourceDocument} onCancel={vi.fn()} onLinked={onLinked} />);

    expect(await screen.findByRole("radio", { name: /Dentist follow-up/ })).toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: /Already linked/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: /Has another file/ })).not.toBeInTheDocument();
    expect(screen.getAllByRole("radio", { name: /Swimming/ })).toHaveLength(1);

    fireEvent.change(screen.getByLabelText("Search existing events"), { target: { value: "dentist" } });
    expect(screen.getByRole("radio", { name: /Dentist follow-up/ })).toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: /Swimming/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("radio", { name: /Dentist follow-up/ }));
    fireEvent.click(screen.getByRole("button", { name: "Attach to event" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/eligible", {
      method: "PUT",
      body: JSON.stringify({ source_document_id: "document-1" }),
    }));
    expect(apiMock.mock.calls.filter(([path]) => String(path).startsWith("/calendar/?"))).toHaveLength(2);
    expect(onLinked).toHaveBeenCalledWith("event", "Dentist follow-up");
  });

  it("switches to tasks and links an existing task without replacing another attachment", async () => {
    const tasks = [
      { id: "open-task", title: "Return medical form", category: "admin", priority: 2, assignees: [], source_document_id: null },
      { id: "linked-task", title: "Already linked task", category: "admin", priority: 2, assignees: [], source_document_id: "document-1" },
      { id: "occupied-task", title: "Task with file", category: "admin", priority: 2, assignees: [], source_document_id: "other-document" },
      { id: "managed-task", title: "Council bins", category: "bins", priority: 2, assignees: [], source_document_id: null, created_by: "bin-scraper" },
    ];
    const onLinked = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/tasks/?limit=200") return tasks;
      if (path === "/tasks/open-task" && init?.method === "PUT") return {};
      if (String(path).startsWith("/calendar/?")) return [];
      return [];
    });
    render(<ExistingRecordLinker sourceDocument={sourceDocument} onCancel={vi.fn()} onLinked={onLinked} />);

    fireEvent.click(screen.getByRole("button", { name: "Task" }));
    fireEvent.click(await screen.findByRole("radio", { name: /Return medical form/ }));
    expect(screen.queryByRole("radio", { name: /Already linked task/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: /Task with file/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: /Council bins/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Attach to task" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/open-task", {
      method: "PUT",
      body: JSON.stringify({ source_document_id: "document-1" }),
    }));
    expect(onLinked).toHaveBeenCalledWith("task", "Return medical form");
  });

  it("rejects a choice that became stale before attachment", async () => {
    let loads = 0;
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/calendar/?")) {
        loads += 1;
        return loads === 1 ? [events[0]] : [];
      }
      return [];
    });
    render(<ExistingRecordLinker sourceDocument={sourceDocument} onCancel={vi.fn()} onLinked={vi.fn()} />);

    fireEvent.click(await screen.findByRole("radio", { name: /Dentist follow-up/ }));
    fireEvent.click(screen.getByRole("button", { name: "Attach to event" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("no longer available");
    expect(apiMock.mock.calls.some(([path, init]) => path === "/calendar/eligible" && init?.method === "PUT")).toBe(false);
  });
});
