import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FitnessCoachConversation, FitnessCoachMemoryCandidate } from "../fitness/contract";
import { setOfflineQueueOwner } from "../offlineQueue";
import { FitnessCoachMemoryCandidates, FitnessCoachMemoryPanel } from "../views/fitness/FitnessCoachMemory";
import { FitnessCoachView } from "../views/fitness/FitnessCoachView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);

const panelCallbacks = {
  onEnabledChange: vi.fn(),
  onOpenConversation: vi.fn(),
  onNewConversation: vi.fn(),
  onDetachConversation: vi.fn(),
  onStoredDataChanged: vi.fn(),
};

function panel(ownerKey = "family-a:user-a") {
  return <FitnessCoachMemoryPanel
    online
    ownerKey={ownerKey}
    revision={0}
    activeConversationId={null}
    {...panelCallbacks}
  />;
}

describe("Fitness Coach private memory", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.values(panelCallbacks).forEach((callback) => callback.mockReset());
    window.localStorage.clear();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    setOfflineQueueOwner({ id: "user-a", family_id: "family-a" });
  });

  it("keeps memory off without repeating the choice for that owner or sharing it with another owner", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/coach/memory/settings") return { enabled: false } as never;
      if (path === "/fitness/coach/conversations" || path === "/fitness/coach/memories") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    const view = render(panel());

    expect(await screen.findByText("Save Coach conversations privately on your NUC?")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Keep chats temporary" }));
    expect(screen.getByText("Temporary chat")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "New temporary chat" }));
    expect(panelCallbacks.onNewConversation).toHaveBeenCalledWith(null);
    expect(apiMock.mock.calls.some(([path, init]) => path === "/fitness/coach/conversations" && init?.method === "POST")).toBe(false);

    view.rerender(panel());
    expect(screen.queryByText("Save Coach conversations privately on your NUC?")).not.toBeInTheDocument();

    view.rerender(panel("family-a:user-b"));
    expect(await screen.findByText("Save Coach conversations privately on your NUC?")).toBeInTheDocument();
  });

  it("keeps existing saved data manageable while memory is off without allowing resume", async () => {
    const detail: FitnessCoachConversation = {
      id: "conversation-1",
      title: "Race week",
      revision: 1,
      created_at: "2026-08-01T08:00:00Z",
      updated_at: "2026-08-01T08:00:00Z",
      messages: [{ id: "message-1", conversation_id: "conversation-1", sequence: 1, role: "assistant", content: "Keep the race week calm.", created_at: "2026-08-01T08:00:00Z" }],
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/memory/settings") return { enabled: false } as never;
      if (path === "/fitness/coach/conversations") return [{ id: "conversation-1", title: "Race week", revision: 1, created_at: "2026-08-01T08:00:00Z", updated_at: "2026-08-01T08:00:00Z" }] as never;
      if (path === "/fitness/coach/memories") return [{ id: "memory-1", content: "Prefers concise race-week advice", category: "communication", confirmed_at: "2026-08-01T08:00:00Z", revision: 1, created_at: "2026-08-01T08:00:00Z", updated_at: "2026-08-01T08:00:00Z" }] as never;
      if (path === "/fitness/coach/conversations/conversation-1" && !init?.method) return detail as never;
      if (path === "/fitness/coach/conversations/conversation-1" && init?.method === "DELETE") return undefined as never;
      if (path === "/fitness/coach/memories/memory-1" && init?.method === "DELETE") return undefined as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(panel());

    const storedConversation = (await screen.findByText("Race week")).closest("button");
    expect(storedConversation).toBeEnabled();
    expect(screen.getByText(/Open one as a read-only copy/i)).toBeInTheDocument();
    fireEvent.click(storedConversation!);
    await waitFor(() => expect(panelCallbacks.onOpenConversation).toHaveBeenCalledWith(detail, false));
    expect(screen.getByText(/new reply stays temporary and will not update the saved conversation/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Delete conversation Race week" }));
    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/conversations/conversation-1", { method: "DELETE" }, true, false));

    fireEvent.click(screen.getByText("What Coach remembers"));
    expect(screen.getByRole("button", { name: "Clear saved conversations and memories" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Forget memory Prefers concise race-week advice" }));
    fireEvent.click(screen.getByRole("button", { name: "Forget" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/memories/memory-1", { method: "DELETE" }, true, false));
  });

  it("starts visibly fresh when memory is enabled after a temporary chat", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/memory/settings" && init?.method === "PUT") return { enabled: true, enabled_at: "2026-08-02T10:00:00Z" } as never;
      if (path === "/fitness/coach/memory/settings") return { enabled: false } as never;
      if (path === "/fitness/coach/conversations" || path === "/fitness/coach/memories") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(panel());

    fireEvent.click(await screen.findByRole("button", { name: "Keep chats temporary" }));
    fireEvent.click(screen.getByRole("button", { name: "Turn on" }));

    await waitFor(() => expect(panelCallbacks.onNewConversation).toHaveBeenCalledWith(null));
    expect(await screen.findByText(/earlier temporary chat was not saved; this is a fresh chat/i)).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path, init]) => path === "/fitness/coach/conversations" && init?.method === "POST")).toBe(false);
  });

  it("turns memory off without clearing the currently displayed page chat", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/memory/settings" && init?.method === "PUT") return { enabled: false } as never;
      if (path === "/fitness/coach/memory/settings") return { enabled: true, enabled_at: "2026-08-02T10:00:00Z" } as never;
      if (path === "/fitness/coach/conversations" || path === "/fitness/coach/memories") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(panel());

    fireEvent.click(await screen.findByRole("button", { name: "Turn off" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/memory/settings", {
      method: "PUT",
      body: JSON.stringify({ enabled: false }),
    }, true, false));
    expect(panelCallbacks.onDetachConversation).toHaveBeenCalledOnce();
    expect(panelCallbacks.onNewConversation).not.toHaveBeenCalled();
    expect(screen.getByText(/chat already open on this page remains here/i)).toBeInTheDocument();
  });

  it("resumes a stored conversation and starts a fresh persisted chat", async () => {
    const detail: FitnessCoachConversation = {
      id: "conversation-1",
      title: "Race week",
      revision: 2,
      created_at: "2026-08-01T08:00:00Z",
      updated_at: "2026-08-02T08:00:00Z",
      last_message_at: "2026-08-02T08:00:00Z",
      messages: [
        { id: "message-1", conversation_id: "conversation-1", sequence: 1, role: "user", content: "Keep race week calm", intent: "discussion", created_at: "2026-08-02T07:59:00Z" },
        { id: "message-2", conversation_id: "conversation-1", sequence: 2, role: "assistant", content: "Use the accepted plan.", created_at: "2026-08-02T08:00:00Z" },
      ],
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/memory/settings") return { enabled: true } as never;
      if (path === "/fitness/coach/conversations" && init?.method === "POST") return { id: "conversation-new", title: "New conversation", revision: 1, created_at: "2026-08-02T09:00:00Z", updated_at: "2026-08-02T09:00:00Z" } as never;
      if (path === "/fitness/coach/conversations") return [{ id: "conversation-1", title: "Race week", revision: 2, created_at: "2026-08-01T08:00:00Z", updated_at: "2026-08-02T08:00:00Z", last_message_at: "2026-08-02T08:00:00Z" }] as never;
      if (path === "/fitness/coach/conversations/conversation-1") return detail as never;
      if (path === "/fitness/coach/memories") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(panel());

    fireEvent.click(await screen.findByText("Race week"));
    await waitFor(() => expect(panelCallbacks.onOpenConversation).toHaveBeenCalledWith(detail, true));

    fireEvent.click(screen.getByRole("button", { name: "New chat" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/conversations", {
      method: "POST",
      body: JSON.stringify({}),
    }, true, false));
    expect(panelCallbacks.onNewConversation).toHaveBeenCalledWith("conversation-new");
  });

  it("requires confirmation before clearing every stored conversation and memory", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/coach/memory/settings") return { enabled: true } as never;
      if (path === "/fitness/coach/conversations") return [{ id: "conversation-1", title: "Race week", revision: 1, created_at: "2026-08-01T08:00:00Z", updated_at: "2026-08-01T08:00:00Z" }] as never;
      if (path === "/fitness/coach/memories") return [{ id: "memory-1", content: "Prefers concise race-week advice", category: "communication", confirmed_at: "2026-08-01T08:00:00Z", revision: 1, created_at: "2026-08-01T08:00:00Z", updated_at: "2026-08-01T08:00:00Z" }] as never;
      if (path === "/fitness/coach/memory/clear" && init?.method === "POST") return { conversations: 1, messages: 2, memories: 1 } as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    render(panel());

    fireEvent.click(await screen.findByText("What Coach remembers"));
    fireEvent.click(screen.getByRole("button", { name: "Clear saved conversations and memories" }));
    const confirmation = screen.getByRole("group", { name: "Confirm clear Coach memory" });
    expect(within(confirmation).getByText(/cannot be undone/i)).toBeInTheDocument();
    fireEvent.click(within(confirmation).getByRole("button", { name: "Clear all" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/memory/clear", { method: "POST" }, true, false));
    expect(panelCallbacks.onNewConversation).toHaveBeenCalledWith(null);
    expect(panelCallbacks.onDetachConversation).not.toHaveBeenCalled();
    expect(await screen.findByText(/Cleared 1 saved conversation and 1 confirmed memory.*current page chat was cleared too/i)).toBeInTheDocument();
  });

  it("presents candidates as unsaved chips with an explicit Remember action", async () => {
    const candidate: FitnessCoachMemoryCandidate = { category: "communication", content: "Prefers concise race-week advice" };
    const remember = vi.fn().mockResolvedValue(undefined);
    render(<FitnessCoachMemoryCandidates candidates={[candidate]} online onRemember={remember} />);

    expect(screen.getByText(/Nothing is saved until you choose Remember/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Remember" }));
    await waitFor(() => expect(remember).toHaveBeenCalledWith(candidate));
  });

  it("posts a confirmed candidate and drops in-memory chat when the signed-in owner changes", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/auth/ai-consent") return { consented: true, version: "2026-07-13", consented_at: "2026-08-02T10:00:00Z", provider: "OpenAI", disclosure: "Explicit requests only", background_processing: false } as never;
      if (path === "/fitness/today") return { planned_sessions: [] } as never;
      if (path === "/fitness/goals" || path === "/fitness/planned-sessions" || path === "/fitness/body-issues" || path === "/fitness/session-checkins" || path === "/fitness/coach/recommendations") return [] as never;
      if (path === "/fitness/coach/preferences") return { personality_preset: "balanced_supportive", directness: 3, challenge_bias: "balanced", detail_level: "standard", custom_instruction: null, coach_memory_enabled: true } as never;
      if (path === "/fitness/coach/memory/settings") return { enabled: true } as never;
      if (path === "/fitness/coach/conversations") return [] as never;
      if (path === "/fitness/coach/memories" && init?.method === "POST") return { id: "memory-1", content: "Prefers concise race-week advice", category: "communication", confirmed_at: "2026-08-02T10:00:00Z", revision: 1, created_at: "2026-08-02T10:00:00Z", updated_at: "2026-08-02T10:00:00Z" } as never;
      if (path === "/fitness/coach/memories") return [] as never;
      if (path === "/fitness/coach/status") return { status: "available", provider: "openai", model: "gpt-health", intents: ["discussion"] } as never;
      if (path === "/fitness/coach/message" && init?.method === "POST") return { status: "complete", answer: "Keep the plan simple.", conversation_id: "conversation-1", memory_candidates: [{ category: "communication", content: "Prefers concise race-week advice" }], evidence: [], recommendation: null, proposal: null } as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    const props = { online: true, revision: 0, onDataChanged: vi.fn(), onSectionChange: vi.fn() };
    const view = render(<FitnessCoachView {...props} />);

    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "Keep this concise" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText("Keep the plan simple.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Remember" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/coach/memories", {
      method: "POST",
      body: JSON.stringify({ content: "Prefers concise race-week advice", category: "communication" }),
    }, true, false));

    setOfflineQueueOwner({ id: "user-b", family_id: "family-a" });
    view.rerender(<FitnessCoachView {...props} revision={1} />);
    await waitFor(() => expect(screen.queryByText("Keep the plan simple.")).not.toBeInTheDocument());
  });
});
