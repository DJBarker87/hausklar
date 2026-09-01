import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ComponentProps } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { BismarckChat } from "../components/BismarckChat";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);
const consented = {
  consented: true,
  version: "2026-07-13",
  consented_at: "2026-07-13T10:00:00Z",
  provider: "OpenAI",
  disclosure: "Family data is sent to OpenAI only when you choose an AI feature.",
  background_processing: false,
};

function mockRequests(...responses: unknown[]) {
  let index = 0;
  apiMock.mockImplementation(async (path) => {
    if (path === "/auth/ai-consent") return consented as never;
    return responses[index++] as never;
  });
}

function renderChat(overrides: Partial<ComponentProps<typeof BismarckChat>> = {}) {
  return render(chat(overrides));
}

function chat(overrides: Partial<ComponentProps<typeof BismarckChat>> = {}) {
  return <BismarckChat
    open
    onOpenChange={vi.fn()}
    online
    members={[]}
    onDataChanged={vi.fn()}
    onViewResult={vi.fn()}
    {...overrides}
  />;
}

describe("BismarckChat", () => {
  beforeEach(() => { apiMock.mockReset(); mockRequests(); });

  it("requires explicit confirmation before executing a proposed family change", async () => {
    const changed = vi.fn();
    const viewResult = vi.fn();
    mockRequests(
      {
        answer: "I can add that for you.",
        actions: [{
          id: "action-1",
          kind: "create_task",
          summary: "Add task: Pay nursery bill",
          status: "pending",
          expires_at: "2026-07-10T17:00:00Z",
        }],
      },
      { status: "executed", message: "Task added.", result_id: "task-result" },
    );

    renderChat({ onDataChanged: changed, onViewResult: viewResult });
    await screen.findByLabelText("Message Bismarck");
    fireEvent.change(screen.getByLabelText("Message Bismarck"), {
      target: { value: "Add a task to pay the nursery bill" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(await screen.findByText("Add task: Pay nursery bill")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledTimes(2);
    expect(changed).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => {
      expect(apiMock).toHaveBeenNthCalledWith(
        3,
        "/assistant/actions/action-1/execute",
        { method: "POST", body: JSON.stringify({}) },
      );
      expect(changed).toHaveBeenCalledOnce();
    });
    expect(screen.getByText("Task added.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /View tasks/ }));
    expect(viewResult).toHaveBeenCalledWith("create_task", "task-result");
  });

  it("submits only one decision while an action is in flight", async () => {
    let resolveExecution: ((value: { status: string; message: string }) => void) | undefined;
    mockRequests(
      {
        answer: "Ready.",
        actions: [{
          id: "action-1",
          kind: "create_task",
          summary: "Create task",
          status: "pending",
          expires_at: "2026-07-10T17:00:00Z",
        }],
      },
      new Promise((resolve) => { resolveExecution = resolve; }),
    );

    renderChat();
    await screen.findByLabelText("Message Bismarck");
    fireEvent.change(screen.getByLabelText("Message Bismarck"), { target: { value: "Create task" } });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    await screen.findByText("Create task", { selector: ".assistant-action-summary strong" });

    const confirm = screen.getByRole("button", { name: "Confirm" });
    fireEvent.click(confirm);
    fireEvent.click(confirm);
    expect(apiMock).toHaveBeenCalledTimes(3);

    await act(async () => {
      resolveExecution?.({ status: "executed", message: "Done." });
    });
  });

  it("dictates editable English or German text without sending it", async () => {
    let recognition: FakeSpeechRecognition | undefined;

    class FakeSpeechRecognition {
      continuous = false;
      interimResults = false;
      lang = "";
      onresult: ((event: unknown) => void) | null = null;
      onerror: ((event: unknown) => void) | null = null;
      onend: (() => void) | null = null;
      start = vi.fn();
      stop = vi.fn();
      abort = vi.fn();

      constructor() {
        recognition = this;
      }
    }

    Object.defineProperty(window, "webkitSpeechRecognition", { configurable: true, value: FakeSpeechRecognition });
    renderChat();
    await screen.findByLabelText("Message Bismarck");
    fireEvent.click(screen.getByRole("button", { name: "Dictate message" }));

    expect(recognition?.lang).toBe("en-GB");
    expect(recognition?.start).toHaveBeenCalledOnce();
    act(() => {
      recognition?.onresult?.({
        resultIndex: 0,
        results: Object.assign([[{ transcript: "add football on Wednesday" }]], { length: 1 }),
      });
    });
    expect(screen.getByLabelText("Message Bismarck")).toHaveValue("add football on Wednesday");
    expect(apiMock).not.toHaveBeenCalledWith("/assistant/message", expect.anything());

    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }));
    fireEvent.click(screen.getByRole("button", { name: /Dictation language: English/ }));
    expect(screen.getByRole("button", { name: /Dictation language: German/ })).toBeInTheDocument();
    Reflect.deleteProperty(window, "webkitSpeechRecognition");
  });

  it("edits a typed proposal before confirmation", async () => {
    const preview = {
      kind: "create_task" as const,
      title: "Return form",
      description: null,
      due_date: "2026-07-15T09:00:00+01:00",
      recurrence_rule: null,
      assigned_to: null,
      category: "admin" as const,
      priority: 2,
    };
    mockRequests(
      {
        answer: "I have drafted that task.",
        actions: [{ id: "action-edit", kind: "create_task", summary: "Return form", status: "pending", expires_at: "2026-07-15T10:00:00Z", editable: true, preview }],
      },
      { id: "action-edit", kind: "create_task", summary: "Return nursery form", status: "pending", expires_at: "2026-07-15T10:00:00Z", editable: true, preview: { ...preview, title: "Return nursery form" } },
    );

    renderChat();
    await screen.findByLabelText("Message Bismarck");
    fireEvent.change(screen.getByLabelText("Message Bismarck"), { target: { value: "Remind me to return the form" } });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    fireEvent.click(await screen.findByRole("button", { name: "Edit" }));
    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Return nursery form" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenNthCalledWith(3, "/assistant/actions/action-edit", {
      method: "PATCH",
      body: JSON.stringify({ ...preview, title: "Return nursery form" }),
    }));
    expect(await screen.findByText("Return nursery form")).toBeInTheDocument();
  });

  it("makes event recurrence and term-time rules understandable and editable", async () => {
    const preview = {
      kind: "calendar_event" as const,
      title: "Swimming",
      description: null,
      start_time: "2026-07-16T16:00:00+01:00",
      end_time: "2026-07-16T17:00:00+01:00",
      all_day: false,
      recurrence_rule: "FREQ=WEEKLY;BYDAY=TH",
      assigned_to: null,
      term_time_only: true,
    };
    mockRequests(
      {
        answer: "I have drafted that event.",
        actions: [{ id: "event-edit", kind: "calendar_event", summary: "Swimming", status: "pending", expires_at: "2026-07-15T10:00:00Z", editable: true, preview }],
      },
      {
        id: "event-edit", kind: "calendar_event", summary: "Swimming", status: "pending", expires_at: "2026-07-15T10:00:00Z", editable: true,
        preview: { ...preview, recurrence_rule: "FREQ=MONTHLY", term_time_only: false },
      },
    );

    renderChat();
    await screen.findByLabelText("Message Bismarck");
    fireEvent.change(screen.getByLabelText("Message Bismarck"), { target: { value: "Add weekly swimming during term" } });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    fireEvent.click(await screen.findByRole("button", { name: "Edit" }));

    expect(screen.getByLabelText("Repeat")).toHaveValue("weekly");
    expect(screen.getByRole("checkbox", { name: "Term time only" })).toBeChecked();
    fireEvent.change(screen.getByLabelText("Repeat"), { target: { value: "monthly" } });
    fireEvent.click(screen.getByRole("checkbox", { name: "Term time only" }));
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenNthCalledWith(3, "/assistant/actions/event-edit", {
      method: "PATCH",
      body: JSON.stringify({ ...preview, recurrence_rule: "FREQ=MONTHLY", term_time_only: false }),
    }));
  });

  it("keeps Bismarck visible offline with an actionable explanation", async () => {
    renderChat({ online: false });
    expect(await screen.findByText("Bismarck needs a connection")).toBeInTheDocument();
    expect(screen.getByText(/Existing family information remains available/)).toBeInTheDocument();
    expect(screen.getByText(/Reconnect to add or change anything/)).toBeInTheDocument();
    expect(screen.getByLabelText("Message Bismarck")).toBeDisabled();
  });

  it("disables every proposal mutation while offline", async () => {
    const preview = {
      kind: "create_task" as const,
      title: "Pack bags",
      description: null,
      due_date: null,
      recurrence_rule: null,
      assigned_to: null,
      category: "household" as const,
      priority: 2,
    };
    mockRequests({
      answer: "Ready for you to check.",
      actions: [{ id: "offline-action", kind: "create_task", summary: "Pack bags", status: "pending", expires_at: "2026-07-15T10:00:00Z", editable: true, preview }],
    });
    const result = renderChat();
    await screen.findByLabelText("Message Bismarck");
    fireEvent.change(screen.getByLabelText("Message Bismarck"), { target: { value: "Add pack bags" } });
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    await screen.findByText("Pack bags", { selector: ".assistant-action-summary strong" });
    result.rerender(chat({ online: false }));

    expect(screen.getByRole("button", { name: "Confirm" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Edit" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Dismiss" })).toBeDisabled();
    expect(screen.getByText(/Reconnect to confirm, edit or dismiss/)).toBeInTheDocument();
  });

  it("auto-scrolls new chat content without smooth motion when reduced motion is requested", async () => {
    const originalScroll = HTMLElement.prototype.scrollIntoView;
    const originalMatchMedia = window.matchMedia;
    const scrollIntoView = vi.fn();
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView });
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }),
    });

    try {
      renderChat();
      await waitFor(() => expect(scrollIntoView).toHaveBeenCalled());
      expect(scrollIntoView.mock.calls.at(-1)?.[0]).toMatchObject({ behavior: "auto", block: "nearest" });
    } finally {
      if (originalScroll) Object.defineProperty(HTMLElement.prototype, "scrollIntoView", { configurable: true, value: originalScroll });
      else Reflect.deleteProperty(HTMLElement.prototype, "scrollIntoView");
      if (originalMatchMedia) Object.defineProperty(window, "matchMedia", { configurable: true, value: originalMatchMedia });
      else Reflect.deleteProperty(window, "matchMedia");
    }
  });

  it("accepts a text-preserving handoff from Add", async () => {
    const consumed = vi.fn();
    renderChat({ initialDraft: { text: "Add swimming on Thursday", nonce: 1 }, onInitialDraftConsumed: consumed });
    expect(await screen.findByLabelText("Message Bismarck")).toHaveValue("Add swimming on Thursday");
    expect(consumed).toHaveBeenCalledOnce();
    expect(apiMock).not.toHaveBeenCalledWith("/assistant/message", expect.anything());
  });

  it("hands the exact unsent draft to Fitness Coach after closing Bismarck without messaging", async () => {
    const order: string[] = [];
    const close = vi.fn((open: boolean) => order.push(`close:${open}`));
    const openCoach = vi.fn((draft: string) => order.push(`coach:${draft}`));
    renderChat({ onOpenChange: close, onOpenFitnessCoach: openCoach });

    const composer = await screen.findByLabelText("Message Bismarck");
    fireEvent.change(composer, { target: { value: "  Fit my run around parents evening  " } });
    fireEvent.click(screen.getByRole("button", { name: "Open Fitness Coach" }));

    expect(close).toHaveBeenCalledWith(false);
    expect(openCoach).toHaveBeenCalledWith("  Fit my run around parents evening  ");
    expect(order).toEqual(["close:false", "coach:  Fit my run around parents evening  "]);
    expect(apiMock).not.toHaveBeenCalledWith("/assistant/message", expect.anything());
  });

  it("requires an explicit OpenAI choice before showing the composer", async () => {
    const notConsented = { ...consented, consented: false, consented_at: null };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/auth/ai-consent" && init?.method === "PUT") return consented as never;
      if (path === "/auth/ai-consent") return notConsented as never;
      return undefined as never;
    });

    renderChat();
    expect(await screen.findByRole("heading", { name: "Allow Bismarck to use OpenAI?" })).toBeInTheDocument();
    expect(screen.queryByLabelText("Message Bismarck")).not.toBeInTheDocument();
    expect(screen.getByText("No unattended or nightly AI processing")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Allow and continue" }));

    expect(await screen.findByLabelText("Message Bismarck")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/auth/ai-consent", {
      method: "PUT",
      body: JSON.stringify({ accepted: true, version: consented.version }),
    });
  });
});
