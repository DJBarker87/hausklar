import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FamilyMember, FamilyTask } from "../types";
import { TasksView } from "../views/TasksView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

vi.mock("../AuthContext", () => ({
  useAuth: () => ({
    user: { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family" },
  }),
}));

const apiMock = vi.mocked(api);

const members: FamilyMember[] = [
  { id: "dom", name: "Alex", member_type: "user" },
  { id: "kat", name: "Morgan", member_type: "user" },
  { id: "max", name: "Child One", member_type: "child" },
];

function task(overrides: Partial<FamilyTask> = {}): FamilyTask {
  return {
    id: "task-dom",
    title: "Alex task",
    description: "A useful description",
    assigned_to: null,
    due_date: "2026-07-20T18:00:00+01:00",
    completed_at: null,
    category: "household",
    recurrence_rule: null,
    priority: 2,
    actionable_from: null,
    created_by: "kat",
    assignees: [{
      id: "assignment-dom",
      assignee_id: "dom",
      assignee_name: "Alex",
      assignee_type: "user",
      completed_at: null,
    }],
    ...overrides,
  };
}

function renderTasks(onDataChanged = vi.fn(), notify = vi.fn()) {
  return render(<TasksView members={members} revision={0} onDataChanged={onDataChanged} notify={notify} />);
}

describe("TasksView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    window.history.replaceState({}, "", "/");
  });

  it("opens the exact task linked from an assistant result", async () => {
    const linked = task({
      id: "task-kat",
      title: "Morgan linked task",
      assignees: [{ id: "assignment-kat", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user" }],
    });
    apiMock.mockResolvedValue([linked]);
    window.history.replaceState({}, "", "/?view=lists&section=tasks&task=task-kat&task_status=active");

    renderTasks();

    expect(await screen.findByRole("dialog", { name: "Morgan linked task" })).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledTimes(1));
    const path = String(apiMock.mock.calls[0]?.[0]);
    expect(path).toContain("order=attention");
    expect(path).toContain("limit=200");
    expect(path).not.toContain("status=");
    expect(path).not.toContain("actionable=");
    expect(new URL(window.location.href).searchParams.has("task")).toBe(false);
  });

  it("defaults to Mine and includes assigned, created, and shared tasks", async () => {
    const tasks = [
      task(),
      task({ id: "task-kat", title: "Morgan only", assignees: [{ id: "assignment-kat", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user" }] }),
      task({ id: "task-created", title: "Created by Alex", created_by: "dom", assignees: [{ id: "assignment-kat-2", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user" }] }),
      task({ id: "task-shared", title: "Shared task", created_by: "kat", assignees: [] }),
    ];
    apiMock.mockResolvedValue(tasks);

    renderTasks();

    expect(await screen.findByRole("button", { name: "Open task Alex task" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open task Created by Alex" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open task Shared task" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open task Morgan only" })).not.toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(expect.not.stringContaining("status="));
    expect(apiMock).toHaveBeenCalledWith(expect.not.stringContaining("actionable="));

    fireEvent.click(screen.getByRole("button", { name: /^Filters/ }));
    const filters = screen.getByRole("dialog", { name: "Filter tasks" });
    fireEvent.click(within(within(filters).getByRole("group", { name: "Task owner" })).getByRole("button", { name: "Everyone" }));
    fireEvent.click(within(filters).getByRole("button", { name: "Done" }));
    expect(screen.getByRole("button", { name: "Open task Morgan only" })).toBeInTheDocument();
  });

  it("keeps managed bin collections in Mine when the other adult is responsible", async () => {
    const bins = task({
      id: "bins-kat",
      title: "Bins",
      category: "bins",
      created_by: "bin-scraper",
      assigned_to: "kat",
      assignees: [{
        id: "assignment-kat-bins",
        assignee_id: "kat",
        assignee_name: "Morgan",
        assignee_type: "user",
      }],
    });
    apiMock.mockResolvedValue([bins]);

    renderTasks();

    expect(await screen.findByRole("button", { name: "Open task Bins" })).toBeInTheDocument();
  });

  it("groups the day into today, soon, waiting, and completed", async () => {
    const now = Date.now();
    apiMock.mockResolvedValue([
      task({ id: "today", title: "Due today", due_date: new Date(now - 60_000).toISOString(), created_by: "dom" }),
      task({ id: "soon", title: "Do soon", due_date: null, created_by: "dom" }),
      task({ id: "waiting", title: "Wait for this", actionable_from: new Date(now + 86_400_000).toISOString(), created_by: "dom" }),
      task({ id: "done", title: "Finished filing", completed_at: new Date(now - 120_000).toISOString(), created_by: "dom" }),
    ]);
    renderTasks();

    expect(await screen.findByRole("heading", { name: "Today & overdue" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Soon" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Waiting" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Completed" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open task Wait for this" })).toHaveTextContent("Hide until");
  });

  it("keeps owner, category, and priority in one filter dialog without reloading", async () => {
    apiMock.mockResolvedValue([
      task({ id: "high-shopping", title: "Buy uniform", category: "shopping", priority: 3, created_by: "dom" }),
      task({ id: "low-household", title: "Oil hinge", category: "household", priority: 1, created_by: "dom" }),
    ]);
    renderTasks();

    expect(await screen.findByRole("button", { name: "Open task Buy uniform" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Filters/ }));
    const filters = screen.getByRole("dialog", { name: "Filter tasks" });
    expect(within(filters).getByRole("group", { name: "Task owner" })).toBeInTheDocument();
    fireEvent.change(within(filters).getByLabelText("Category"), { target: { value: "shopping" } });
    fireEvent.click(within(within(filters).getByRole("group", { name: "Task priority" })).getByRole("button", { name: "High" }));
    fireEvent.click(within(filters).getByRole("button", { name: "Done" }));

    expect(screen.getByRole("button", { name: "Open task Buy uniform" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open task Oil hinge" })).not.toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledTimes(1);
  });

  it("renders managed bin tasks with friendly labels and a date-only due date", async () => {
    const bins = task({
      id: "bins-1",
      title: "Bins",
      description: "blue,black",
      due_date: "2026-07-23",
      category: "bins",
      created_by: "bin-scraper",
    });
    apiMock.mockResolvedValue([bins]);
    renderTasks();

    const row = await screen.findByRole("button", { name: "Open task Bins" });
    expect(row).toHaveTextContent("Recycling, refuse");
    expect(row).toHaveTextContent("Thu 23 Jul");
    expect(row).not.toHaveTextContent("00:00");
    expect(row).not.toHaveTextContent("blue,black");

    fireEvent.click(row);
    const detail = screen.getByRole("dialog", { name: "Bins" });
    expect(detail).toHaveTextContent("Managed from the council schedule.");
    expect(within(detail).getByRole("button", { name: "Complete task" })).toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
  });

  it("creates a detailed task for multiple family members", async () => {
    const changed = vi.fn();
    apiMock.mockImplementation(async (path, init) => {
      if (init?.method === "POST") return task({ id: "created-task", title: "Prepare school bags", created_by: "dom" });
      return [];
    });
    renderTasks(changed);

    await waitFor(() => expect(apiMock).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("button", { name: "New task" }));
    const editor = screen.getByRole("dialog", { name: "New task" });
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Prepare school bags" } });
    fireEvent.click(within(editor).getByRole("checkbox", { name: "Alex" }));
    fireEvent.click(within(editor).getByRole("checkbox", { name: "Child One" }));
    fireEvent.click(within(editor).getByRole("checkbox", { name: "Add a due date" }));
    fireEvent.change(within(editor).getByLabelText("Date", { selector: "#task-due-date" }), { target: { value: "2026-07-22" } });
    fireEvent.change(within(editor).getByLabelText("Time", { selector: "#task-due-time" }), { target: { value: "19:30" } });
    fireEvent.change(within(editor).getByLabelText("Repeat"), { target: { value: "monthly" } });
    fireEvent.click(within(editor).getByRole("button", { name: "More" }));
    fireEvent.change(within(editor).getByLabelText("Description (optional)"), { target: { value: "PE kit and reading books" } });
    fireEvent.change(within(editor).getByLabelText("Category"), { target: { value: "admin" } });
    fireEvent.click(within(editor).getByRole("button", { name: "High" }));
    fireEvent.click(within(editor).getByRole("checkbox", { name: "Hide until" }));
    fireEvent.change(within(editor).getByLabelText("Date", { selector: "#task-actionable-date" }), { target: { value: "2026-07-21" } });
    fireEvent.change(within(editor).getByLabelText("Time", { selector: "#task-actionable-time" }), { target: { value: "08:00" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Create task" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/", expect.objectContaining({ method: "POST" })));
    const createCall = apiMock.mock.calls.find(([path, init]) => path === "/tasks/" && init?.method === "POST");
    const body = JSON.parse(String(createCall?.[1]?.body));
    expect(body).toMatchObject({
      id: expect.stringMatching(/^[0-9a-f-]{36}$/i),
      title: "Prepare school bags",
      description: "PE kit and reading books",
      category: "admin",
      priority: 3,
      due_date: expect.stringContaining("2026-07-22T19:30:00"),
      recurrence_rule: "FREQ=MONTHLY",
      actionable_from: expect.stringContaining("2026-07-21T08:00:00"),
      assignees: [
        { assignee_id: "dom", assignee_type: "user" },
        { assignee_id: "max", assignee_type: "child" },
      ],
    });
    expect(changed).toHaveBeenCalled();
  });

  it("reuses the task operation ID after an ambiguous response failure", async () => {
    let attempts = 0;
    apiMock.mockImplementation(async (_path, init) => {
      if (init?.method === "POST") {
        attempts += 1;
        if (attempts === 1) throw new Error("Connection dropped");
        return task({ id: "created-task", title: "Pack bags", created_by: "dom" });
      }
      return [];
    });
    renderTasks();
    await waitFor(() => expect(apiMock).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("button", { name: "New task" }));
    const editor = screen.getByRole("dialog", { name: "New task" });
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Pack bags" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Create task" }));
    expect(await within(editor).findByText("Connection dropped")).toBeInTheDocument();
    fireEvent.click(within(editor).getByRole("button", { name: "Create task" }));

    await waitFor(() => expect(attempts).toBe(2));
    const bodies = apiMock.mock.calls
      .filter(([, init]) => init?.method === "POST")
      .map(([, init]) => JSON.parse(String(init?.body)));
    expect(bodies[1].id).toBe(bodies[0].id);
    expect(bodies[1].client_timestamp).toBe(bodies[0].client_timestamp);
  });

  it("edits assignments and confirms deletion", async () => {
    const original = task({
      title: "Pack bags",
      recurrence_rule: "FREQ=MONTHLY;BYMONTHDAY=20",
      assignees: [
        { id: "a-dom", assignee_id: "dom", assignee_name: "Alex", assignee_type: "user" },
        { id: "a-kat", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user" },
      ],
    });
    apiMock.mockImplementation(async (path, init) => {
      if (init?.method === "PUT") {
        const body = JSON.parse(String(init.body));
        return task({ ...original, ...body, title: body.title, assignees: [{ id: "a-dom", assignee_id: "dom", assignee_name: "Alex", assignee_type: "user" }] });
      }
      if (init?.method === "DELETE") return undefined;
      return [original];
    });
    renderTasks();

    fireEvent.click(await screen.findByRole("button", { name: "Open task Pack bags" }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Pack bags" })).getByRole("button", { name: "Edit" }));
    const editor = await screen.findByRole("dialog", { name: "Edit task" });
    fireEvent.change(within(editor).getByLabelText("Title"), { target: { value: "Pack school bags" } });
    fireEvent.click(within(editor).getByRole("checkbox", { name: "Morgan" }));
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/task-dom", expect.objectContaining({ method: "PUT" })));
    const updateCall = apiMock.mock.calls.find(([path, init]) => path === "/tasks/task-dom" && init?.method === "PUT");
    expect(JSON.parse(String(updateCall?.[1]?.body))).toMatchObject({
      title: "Pack school bags",
      assigned_to: null,
      assignees: [{ assignee_id: "dom", assignee_type: "user" }],
    });
    expect(JSON.parse(String(updateCall?.[1]?.body))).not.toHaveProperty("recurrence_rule");

    fireEvent.click(await screen.findByRole("button", { name: "Open task Pack school bags" }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Pack school bags" })).getByRole("button", { name: "Delete" }));
    const confirmation = screen.getByRole("dialog", { name: "Delete task?" });
    expect(confirmation).toHaveTextContent("removed for everyone");
    fireEvent.click(within(confirmation).getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/task-dom", { method: "DELETE" }));
  });

  it("supports per-person and whole-task completion", async () => {
    const shared = task({
      title: "Pack lunches",
      assignees: [
        { id: "a-dom", assignee_id: "dom", assignee_name: "Alex", assignee_type: "user", completed_at: null },
        { id: "a-kat", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user", completed_at: null },
      ],
    });
    apiMock.mockImplementation(async (path, init) => {
      if (init?.method === "PATCH" && String(path).endsWith("/complete/dom")) {
        return { ...shared, assignees: [{ ...shared.assignees[0], completed_at: "2026-07-11T10:00:00Z" }, shared.assignees[1]] };
      }
      if (init?.method === "PATCH" && String(path).endsWith("/complete")) {
        return { ...shared, completed_at: "2026-07-11T10:05:00Z", assignees: shared.assignees.map((assignee) => ({ ...assignee, completed_at: "2026-07-11T10:05:00Z" })) };
      }
      return [shared];
    });
    const notify = vi.fn();
    renderTasks(vi.fn(), notify);

    fireEvent.click(await screen.findByRole("button", { name: "Open task Pack lunches" }));
    const detail = screen.getByRole("dialog", { name: "Pack lunches" });
    fireEvent.click(within(detail).getByRole("button", { name: "Complete Pack lunches for Alex" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/task-dom/complete/dom", { method: "PATCH" }));
    expect(within(detail).getByRole("button", { name: "Complete Pack lunches for Alex" })).toBeDisabled();

    fireEvent.click(within(detail).getByRole("button", { name: "Complete task" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/task-dom/complete", { method: "PATCH" }));
    expect(within(detail).getByRole("button", { name: "Reopen task" })).toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Close" }));
    expect(screen.getByRole("heading", { name: "Completed" })).toBeInTheDocument();
    expect(notify).toHaveBeenCalledWith("Assignment completed.");
    expect(notify).toHaveBeenCalledWith("Task completed.");
  });

  it("opens a dismissible attachment viewer and can unlink the task", async () => {
    const attached = task({
      title: "Return form",
      source_document_id: "document-1",
      source_document: {
        id: "document-1",
        title: "Permission form",
        original_filename: "permission.pdf",
        media_type: "application/pdf",
        file_size: 2048,
        download_url: "/api/documents/document-1/content",
      },
    });
    apiMock.mockImplementation(async (_path, init) => {
      if (init?.method === "PUT") {
        return { ...attached, source_document_id: null, source_document: null };
      }
      return [attached];
    });
    renderTasks();

    fireEvent.click(await screen.findByRole("button", { name: "Open task Return form" }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Return form" })).getByRole("button", { name: /Permission form/ }));
    const viewer = screen.getByRole("dialog", { name: "Permission form" });
    expect(await within(viewer).findByTitle("Permission form")).toHaveAttribute("src", "/api/documents/document-1/content");
    fireEvent.click(within(viewer).getByRole("button", { name: "Close preview" }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Permission form" })).not.toBeInTheDocument());

    const restored = screen.getByRole("dialog", { name: "Return form" });
    fireEvent.click(within(restored).getByRole("button", { name: "Edit" }));
    const editor = screen.getByRole("dialog", { name: "Edit task" });
    fireEvent.change(within(editor).getByLabelText("Choose an existing document"), { target: { value: "" } });
    fireEvent.click(within(editor).getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/task-dom", expect.objectContaining({ method: "PUT" })));
    const update = apiMock.mock.calls.find(([, init]) => init?.method === "PUT");
    expect(JSON.parse(String(update?.[1]?.body))).toMatchObject({ source_document_id: null });
  });

  it("keeps Finance-managed tasks read-only and supports reopening", async () => {
    const managed = task({
      id: "finance-task-1",
      title: "Review car insurance",
      description: "£900 from Household current account",
      category: "admin",
      completed_at: "2026-07-11T10:00:00Z",
      read_only: true,
      managed_source: {
        kind: "finance_renewal",
        source_id: "renewal-1",
        deep_link: "/?view=finance&section=more&renewal=renewal-1",
        label: "Household renewal",
      },
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/tasks/finance-task-1/reopen" && init?.method === "PATCH") return { ...managed, completed_at: null };
      return [managed];
    });
    const notify = vi.fn();
    renderTasks(vi.fn(), notify);

    fireEvent.click(await screen.findByRole("button", { name: "Open task Review car insurance" }));
    const detail = screen.getByRole("dialog", { name: "Review car insurance" });
    expect(detail).toHaveAccessibleDescription("Medium priority · Money");
    expect(detail).not.toHaveTextContent("£900");
    expect(within(detail).getByRole("link", { name: /Open Household renewal/ })).toHaveAttribute("href", "/?view=finance&section=more&renewal=renewal-1");
    expect(within(detail).queryByRole("button", { name: /Complete Review car insurance for Alex/ })).not.toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(within(detail).queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: "Reopen task" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/finance-task-1/reopen", { method: "PATCH" }));
    expect(notify).toHaveBeenCalledWith("Task reopened.");
  });

  it("shows shared library loan tasks with a hand-off to current status", async () => {
    const managed = task({
      id: "library-task-group-2026-08-18-batch",
      title: "Renew or return 2 library books",
      description: "Books due together: The Wild Robot; The Gruffalo. Library cards: Children.",
      assigned_to: null,
      assignees: [
        { id: "library-dom", assignee_id: "dom", assignee_name: "Alex", assignee_type: "user" },
        { id: "library-kat", assignee_id: "kat", assignee_name: "Morgan", assignee_type: "user" },
      ],
      category: "admin",
      read_only: true,
      managed_source: {
        kind: "library_loan",
        source_id: "loan-1",
        deep_link: "/?view=lists&section=renewals&library=loan-1",
        label: "Library book",
      },
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/tasks/library-task-group-2026-08-18-batch/complete" && init?.method === "PATCH") {
        return { ...managed, completed_at: "2026-08-12T10:00:00Z" };
      }
      return [managed];
    });
    renderTasks();

    expect(await screen.findByText("Library")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Open task Renew or return 2 library books" }));
    const detail = screen.getByRole("dialog", { name: "Renew or return 2 library books" });
    expect(detail).toHaveAccessibleDescription("Medium priority · Library");
    expect(within(detail).getByText(/The Wild Robot; The Gruffalo/)).toBeInTheDocument();
    expect(within(detail).getByText("Alex")).toBeInTheDocument();
    expect(within(detail).getByText("Morgan")).toBeInTheDocument();
    expect(within(detail).getByText(/Completing this shared task/)).toBeInTheDocument();
    expect(within(detail).getByRole("link", { name: /Open Library books/ })).toHaveAttribute(
      "href",
      "/?view=lists&section=renewals&library=loan-1",
    );
    fireEvent.click(within(detail).getByRole("button", { name: "Complete task" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/tasks/library-task-group-2026-08-18-batch/complete",
      { method: "PATCH" },
    ));
  });
});
