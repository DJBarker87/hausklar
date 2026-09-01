import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { TaskEditorDialog } from "../components/TaskEditorDialog";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

describe("TaskEditorDialog document attachments", () => {
  beforeEach(() => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    apiMock.mockReset();
  });

  it("really removes an uploaded attachment after the task save fails", async () => {
    let taskAttempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/documents/") return { id: "uploaded-document" };
      if (path === "/tasks/") {
        taskAttempts += 1;
        if (taskAttempts === 1) throw new Error("Task could not be saved");
        return { id: "saved-task", title: "Return form", category: "other", priority: 2, assignees: [] };
      }
      return [];
    });
    render(
      <TaskEditorDialog
        open
        task={null}
        members={[]}
        onOpenChange={vi.fn()}
        onSaved={vi.fn()}
        notify={vi.fn()}
      />,
    );
    const dialog = screen.getByRole("dialog", { name: "New task" });
    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Return form" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "More" }));
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "form.pdf", { type: "application/pdf" })] },
    });
    fireEvent.click(within(dialog).getByRole("button", { name: "Create task" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Task could not be saved");

    fireEvent.click(within(dialog).getByRole("button", { name: "Remove form.pdf" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Create task" }));

    await waitFor(() => expect(taskAttempts).toBe(2));
    const taskBodies = apiMock.mock.calls
      .filter(([path, init]) => path === "/tasks/" && init?.method === "POST")
      .map(([, init]) => JSON.parse(String(init?.body)) as Record<string, unknown>);
    expect(taskBodies[0].source_document_id).toBe("uploaded-document");
    expect(taskBodies[1].source_document_id).toBeNull();
    expect(apiMock.mock.calls.filter(([path]) => path === "/documents/")).toHaveLength(1);
  });
});
