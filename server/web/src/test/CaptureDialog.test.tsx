import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { CaptureDialog } from "../components/CaptureDialog";
import type { CaptureProposal, CaptureResponse } from "../types";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

function localDateTimeInput(value: string): string {
  const parsed = new Date(value);
  const part = (number: number) => String(number).padStart(2, "0");
  return `${parsed.getFullYear()}-${part(parsed.getMonth() + 1)}-${part(parsed.getDate())}T${part(parsed.getHours())}:${part(parsed.getMinutes())}`;
}

function response(proposals: CaptureProposal[]): CaptureResponse {
  return { proposals, processor: "hermes", warning: null };
}

function proposal(overrides: Partial<CaptureProposal> = {}): CaptureProposal {
  return {
    id: "proposal-1",
    kind: "event",
    title: "Football",
    details: "Bring boots",
    start_time: "2026-07-15T15:00:00+01:00",
    end_time: null,
    due_date: null,
    all_day: false,
    assigned_to: null,
    assigned_to_name: null,
    confidence: 0.95,
    ...overrides,
  };
}

function renderCapture(onContinueInBismarck?: (text: string) => void) {
  render(
    <CaptureDialog
      open
      initialMode="plan"
      members={[{ id: "max", name: "Child One", member_type: "child" }]}
      onOpenChange={vi.fn()}
      onCreated={vi.fn()}
      notify={vi.fn()}
      onContinueInBismarck={onContinueInBismarck}
    />,
  );
  return screen.getByRole("dialog", { name: "Add" });
}

async function parseIntoReview(dialog: HTMLElement) {
  fireEvent.change(within(dialog).getByLabelText("What do you need to add?"), {
    target: { value: "Add football" },
  });
  fireEvent.click(within(dialog).getByRole("button", { name: "Review drafts" }));
  await within(dialog).findByText("Check every detail before adding it to HausKlar.");
}

describe("CaptureDialog proposal review", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(window, "webkitSpeechRecognition", { configurable: true, value: undefined });
  });

  it("keeps dictated plan text editable before review", () => {
    let recognition: {
      onresult: ((event: { results: { length: number; [index: number]: { [index: number]: { transcript: string } } } }) => void) | null;
      onerror: ((event: { error: string }) => void) | null;
      onend: (() => void) | null;
      start: ReturnType<typeof vi.fn>;
      stop: ReturnType<typeof vi.fn>;
      abort: ReturnType<typeof vi.fn>;
    } | null = null;
    class MockSpeechRecognition {
      continuous = false;
      interimResults = false;
      lang = "";
      onresult = null;
      onerror = null;
      onend = null;
      start = vi.fn();
      stop = vi.fn();
      abort = vi.fn();

      constructor() {
        recognition = this;
      }
    }
    Object.defineProperty(window, "webkitSpeechRecognition", { configurable: true, value: MockSpeechRecognition });

    const dialog = renderCapture();
    fireEvent.click(within(dialog).getByRole("button", { name: "Dictate" }));
    expect(recognition).not.toBeNull();
    expect(recognition!.start).toHaveBeenCalledOnce();
    act(() => {
      recognition!.onresult?.({ results: { length: 1, 0: { 0: { transcript: "Swimming on Thursday" } } } });
    });

    const input = within(dialog).getByLabelText("What do you need to add?");
    expect(input).toHaveValue("Swimming on Thursday");
    fireEvent.change(input, { target: { value: "Swimming on Thursday at 5pm" } });
    expect(input).toHaveValue("Swimming on Thursday at 5pm");
    fireEvent.click(within(dialog).getByRole("button", { name: "Stop dictation" }));
    expect(recognition!.stop).toHaveBeenCalledOnce();
  });

  it("reviews every event field before creating the calendar item", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/capture/parse") return response([proposal()]);
      return {};
    });
    const dialog = renderCapture();
    await parseIntoReview(dialog);

    const item = within(dialog).getByRole("group", { name: "Captured item 1" });
    fireEvent.change(within(item).getByLabelText("Title"), { target: { value: "Child One football" } });
    fireEvent.change(within(item).getByLabelText("Notes (optional)"), { target: { value: "Term time only" } });
    fireEvent.change(within(item).getByLabelText("For"), { target: { value: "max" } });
    fireEvent.change(within(item).getByLabelText("Duration (optional)"), { target: { value: "custom" } });
    fireEvent.change(within(item).getByLabelText("Ends"), { target: { value: "2026-07-15T16:15" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add selected" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const calendarCall = apiMock.mock.calls.find(([path]) => path === "/calendar/");
    const body = JSON.parse(String(calendarCall?.[1]?.body));
    expect(body).toMatchObject({
      id: expect.stringMatching(/^[0-9a-f-]{36}$/i),
      title: "Child One football",
      description: "Term time only",
      start_time: expect.stringContaining("2026-07-15T15:00:00"),
      end_time: expect.stringContaining("2026-07-15T16:15:00"),
      all_day: false,
      assigned_to: "max",
      family_member_ids: ["max"],
    });
  });

  it("hands the unchanged plan text to Bismarck without parsing or saving", () => {
    const continueInBismarck = vi.fn();
    const dialog = renderCapture(continueInBismarck);
    fireEvent.change(within(dialog).getByLabelText("What do you need to add?"), {
      target: { value: "Add milk, swimming on Thursday, and a task for Morgan" },
    });
    expect(within(dialog).queryByText("Improve with Bismarck")).not.toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Continue in Bismarck" }));

    expect(continueInBismarck).toHaveBeenCalledWith("Add milk, swimming on Thursday, and a task for Morgan");
    expect(apiMock).not.toHaveBeenCalled();
  });

  it("keeps direct plan parsing deterministic", async () => {
    apiMock.mockResolvedValue(response([]));
    const dialog = renderCapture(vi.fn());
    await parseIntoReview(dialog);

    expect(apiMock).toHaveBeenCalledWith("/capture/parse", expect.objectContaining({
      method: "POST",
      body: expect.stringContaining('"use_hermes":false'),
    }));
  });

  it("asks for explicit OpenAI permission before enabling document AI", async () => {
    const disclosure = "Selected text and bounded family context may be sent to OpenAI.";
    apiMock.mockImplementation(async (path, options) => {
      if (path === "/auth/ai-consent" && options?.method === "PUT") {
        return { consented: true, version: "2026-07-13", consented_at: "now", provider: "OpenAI", disclosure, background_processing: false };
      }
      if (path === "/auth/ai-consent") {
        return { consented: false, version: "2026-07-13", consented_at: null, provider: "OpenAI", disclosure, background_processing: false };
      }
      return {};
    });
    render(
      <CaptureDialog
        open
        initialMode="document"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );
    const option = await screen.findByRole("checkbox", { name: /Find action drafts with Bismarck/ });
    await waitFor(() => expect(option).toBeEnabled());

    fireEvent.click(option);

    expect(await screen.findByRole("heading", { name: "Allow Bismarck to use OpenAI?" })).toBeInTheDocument();
    expect(option).not.toBeChecked();
    fireEvent.click(screen.getByRole("button", { name: "Allow and continue" }));
    await waitFor(() => expect(option).toBeChecked());
    expect(apiMock).toHaveBeenCalledWith(
      "/auth/ai-consent",
      expect.objectContaining({ method: "PUT", body: expect.stringContaining('"accepted":true') }),
    );
  });

  it("normalizes event-only fields when a draft is changed to a task", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/capture/parse") {
        return response([proposal({ end_time: "2026-07-15T16:00:00+01:00" })]);
      }
      return {};
    });
    const dialog = renderCapture();
    await parseIntoReview(dialog);

    const item = within(dialog).getByRole("group", { name: "Captured item 1" });
    const type = within(item).getByRole("group", { name: "Item 1 type" });
    fireEvent.click(within(type).getByRole("button", { name: "Task" }));

    expect(within(item).queryByLabelText("Starts")).not.toBeInTheDocument();
    expect(within(item).queryByLabelText("Ends")).not.toBeInTheDocument();
    expect(within(item).getByLabelText("Due (optional)")).toHaveValue(
      localDateTimeInput("2026-07-15T15:00:00+01:00"),
    );
    fireEvent.change(within(item).getByLabelText("Notes (optional)"), { target: { value: "Ask the coach" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add selected" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/tasks/", expect.objectContaining({ method: "POST" })));
    const taskCall = apiMock.mock.calls.find(([path]) => path === "/tasks/");
    const body = JSON.parse(String(taskCall?.[1]?.body));
    expect(body).toMatchObject({
      title: "Football",
      description: "Ask the coach",
      assigned_to: null,
      category: "other",
      priority: 2,
    });
    expect(new Date(body.due_date).getTime()).toBe(
      new Date("2026-07-15T15:00:00+01:00").getTime(),
    );
    expect(body).not.toHaveProperty("start_time");
    expect(body).not.toHaveProperty("end_time");
    expect(body).not.toHaveProperty("all_day");
  });

  it("lets a user add an all-day event when parsing returns no drafts", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/capture/parse") return response([]);
      return {};
    });
    const dialog = renderCapture();
    await parseIntoReview(dialog);

    expect(within(dialog).getByText("No draft items yet")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Event" }));
    const item = within(dialog).getByRole("group", { name: "Captured item 1" });
    expect(within(item).getByLabelText("Duration (optional)")).toHaveValue("15");
    expect(within(item).getByLabelText("Ends")).toBeInTheDocument();
    fireEvent.change(within(item).getByLabelText("Title"), { target: { value: "School inset day" } });
    fireEvent.click(within(item).getByLabelText("All day"));
    fireEvent.change(within(item).getByLabelText("Date"), { target: { value: "2026-09-04" } });
    expect(within(item).queryByLabelText("Duration (optional)")).not.toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Add selected" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/calendar/", expect.objectContaining({ method: "POST" })));
    const calendarCall = apiMock.mock.calls.find(([path]) => path === "/calendar/");
    const body = JSON.parse(String(calendarCall?.[1]?.body));
    expect(body).toMatchObject({
      title: "School inset day",
      start_time: expect.stringContaining("2026-09-04T00:00:00"),
      end_time: null,
      all_day: true,
    });
  });

  it("retains the operation identity across an ambiguous task retry", async () => {
    let taskAttempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/capture/parse") {
        return response([proposal({ kind: "task", start_time: null, due_date: null, all_day: true })]);
      }
      if (path === "/tasks/") {
        taskAttempts += 1;
        if (taskAttempts === 1) throw new Error("Connection dropped");
      }
      return {};
    });
    const dialog = renderCapture();
    await parseIntoReview(dialog);

    fireEvent.click(within(dialog).getByRole("button", { name: "Add selected" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Connection dropped");

    const item = within(dialog).getByRole("group", { name: "Captured item 1" });
    const type = within(item).getByRole("group", { name: "Item 1 type" });
    fireEvent.click(within(type).getByRole("button", { name: "Event" }));
    expect(within(dialog).getByRole("alert")).toHaveTextContent("Retry it before changing its type");
    fireEvent.change(within(item).getByLabelText("Notes (optional)"), { target: { value: "Retry detail" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add selected" }));

    await waitFor(() => expect(taskAttempts).toBe(2));
    const bodies = apiMock.mock.calls
      .filter(([path]) => path === "/tasks/")
      .map(([, init]) => JSON.parse(String(init?.body)));
    expect(bodies[1].id).toBe(bodies[0].id);
    expect(bodies[1].client_timestamp).toBe(bodies[0].client_timestamp);
  });

  it("keeps camera scanning separate from photo-library and file upload", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/auth/ai-consent") {
        return { consented: false, version: "2026-07-13", provider: "OpenAI", disclosure: "Disclosure", background_processing: false };
      }
      return {};
    });
    render(
      <CaptureDialog
        open
        initialMode="document"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );
    const dialog = screen.getByRole("dialog", { name: "Add" });
    expect(within(dialog).getByRole("button", { name: "Scan document" })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "Upload photo or file" })).toBeInTheDocument();
    const photo = new File(["photo"], "school-letter.jpg", { type: "image/jpeg" });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), { target: { files: [photo] } });
    expect(within(dialog).getByLabelText("Title")).toHaveValue("school letter");
    fireEvent.click(within(dialog).getByRole("button", { name: "Add to inbox" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/", expect.objectContaining({ method: "POST" })));
    const upload = apiMock.mock.calls.find(([path]) => path === "/documents/");
    const form = upload?.[1]?.body as FormData;
    expect(form.get("file")).toBe(photo);
    expect(form.get("source")).toBe("photo");
    expect(form.get("document_id")).toMatch(/^[0-9a-f-]{36}$/i);
  });

  it("distinguishes shared household finance filing from Private Finance", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/auth/ai-consent") {
        return { consented: false, version: "2026-07-13", provider: "OpenAI", disclosure: "Disclosure", background_processing: false };
      }
      return {};
    });
    render(
      <CaptureDialog
        open
        initialMode="document"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Add" });
    const category = within(dialog).getByLabelText("Category");
    expect(within(category).getByRole("option", { name: "Household financial document" })).toHaveValue("finance");
    expect(within(dialog).getByRole("link", { name: /Private Finance instead/ })).toHaveAttribute(
      "href",
      "/?view=finance&section=setup#private-finance-files",
    );
    expect(within(dialog).queryByText("Finance (shared with family)")).not.toBeInTheDocument();
  });

  it("reuses the direct document upload ID after an ambiguous failure", async () => {
    let attempts = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/auth/ai-consent") {
        return { consented: false, version: "2026-07-13", provider: "OpenAI", disclosure: "Disclosure", background_processing: false };
      }
      if (path === "/documents/") {
        attempts += 1;
        if (attempts === 1) throw new Error("Connection dropped after upload");
      }
      return {};
    });
    render(
      <CaptureDialog
        open
        initialMode="document"
        members={[]}
        onOpenChange={vi.fn()}
        onCreated={vi.fn()}
        notify={vi.fn()}
      />,
    );
    const dialog = screen.getByRole("dialog", { name: "Add" });
    fireEvent.change(within(dialog).getByLabelText("Upload photo or document"), {
      target: { files: [new File(["document"], "letter.pdf", { type: "application/pdf" })] },
    });
    fireEvent.click(within(dialog).getByRole("button", { name: "Add to inbox" }));
    expect(await within(dialog).findByRole("alert")).toHaveTextContent("Connection dropped after upload");
    fireEvent.click(within(dialog).getByRole("button", { name: "Add to inbox" }));

    await waitFor(() => expect(attempts).toBe(2));
    const forms = apiMock.mock.calls
      .filter(([path, init]) => path === "/documents/" && init?.method === "POST")
      .map(([, init]) => init?.body as FormData);
    expect(forms[0].get("document_id")).toMatch(/^[0-9a-f-]{36}$/i);
    expect(forms[1].get("document_id")).toBe(forms[0].get("document_id"));
  });
});
