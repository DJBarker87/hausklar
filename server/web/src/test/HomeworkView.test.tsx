import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { HomeworkView } from "../views/HomeworkView";

vi.mock("../api", () => ({ api: vi.fn() }));

const apiMock = vi.mocked(api);

const spelling = {
  id: "spellings-1",
  child_id: "child-1",
  word_list: ["because", "different"],
  test_date: "2026-08-12",
  score: null,
  practice_count: 0,
  completed_at: null,
  notes: null,
  link_url: null,
  source_document_id: null,
  source_document: null,
  status: "upcoming" as const,
  practice_sessions: [],
  mastery: [
    { word: "because", attempts: 0, correct_attempts: 0, mastered: false, needs_practice: true },
    { word: "different", attempts: 0, correct_attempts: 0, mastered: false, needs_practice: true },
  ],
  created_at: "2026-08-09T10:00:00Z",
  updated_at: "2026-08-09T10:00:00Z",
};

const reading = {
  id: "reading-1",
  child_id: "child-1",
  book_title: "The Wild Robot",
  minutes: 15,
  date: "2026-08-08",
  notes: null,
  created_at: "2026-08-08T18:00:00Z",
  updated_at: "2026-08-08T18:00:00Z",
};

function renderHomework(props: Partial<React.ComponentProps<typeof HomeworkView>> = {}) {
  return render(<HomeworkView
    children={[{ id: "child-1", name: "Child One", date_of_birth: "2020-01-02" }]}
    selectedChild="child-1"
    revision={0}
    initialHomeworkId={null}
    onDataChanged={vi.fn()}
    {...props}
  />);
}

describe("HomeworkView", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/homework/reading?") && !init) return [reading];
      if (path.startsWith("/homework/spellings?") && !init) return [spelling];
      if (path === "/homework/reading" && init?.method === "POST") return {
        ...reading,
        id: "reading-2",
        date: "2026-08-09",
        created_at: "2026-08-09T18:00:00Z",
        updated_at: "2026-08-09T18:00:00Z",
      };
      if (path === "/homework/spellings/spellings-1/practice" && init?.method === "POST") return {
        ...spelling,
        practice_count: 1,
        practice_sessions: [{
          id: "practice-1",
          practised_at: "2026-08-09T18:30:00Z",
          attempts: [{ word: "because", correct: true }, { word: "different", correct: false }],
          correct_count: 1,
          total_count: 2,
        }],
        mastery: [
          { word: "because", attempts: 1, correct_attempts: 1, mastered: false, needs_practice: true },
          { word: "different", attempts: 1, correct_attempts: 0, mastered: false, needs_practice: true },
        ],
      };
      if (path === "/homework/spellings/spellings-1" && init?.method === "DELETE") return undefined;
      if (path === "/homework/spellings/spellings-1/restore" && init?.method === "POST") return spelling;
      if (path === "/documents/?limit=200") return [];
      if (path === "/homework/spellings" && init?.method === "POST") return { ...spelling, id: "spellings-2" };
      return [];
    });
  });

  it("makes the usual reading session one tap without losing full correction", async () => {
    const changed = vi.fn();
    renderHomework({ onDataChanged: changed });

    fireEvent.click(await screen.findByRole("button", { name: "Log 15 min" }));

    await waitFor(() => {
      const call = apiMock.mock.calls.find(([path, init]) => path === "/homework/reading" && init?.method === "POST");
      expect(call).toBeTruthy();
      const payload = JSON.parse(String(call?.[1]?.body));
      expect(payload).toMatchObject({ child_id: "child-1", book_title: "The Wild Robot", minutes: 15, notes: null });
      expect(payload.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    });
    expect(changed).toHaveBeenCalled();

    fireEvent.click(screen.getAllByRole("button", { name: /The Wild Robot/ })[0]);
    const editor = screen.getByRole("dialog", { name: "Correct reading" });
    expect(within(editor).getByLabelText("Book title")).toHaveValue("The Wild Robot");
    expect(within(editor).getByRole("button", { name: "Remove" })).toBeInTheDocument();
  });

  it("records per-word outcomes through the hide and reveal practice flow", async () => {
    renderHomework();
    fireEvent.click(await screen.findByRole("button", { name: "Start practice" }));

    let dialog = screen.getByRole("dialog", { name: "Spelling practice" });
    expect(within(dialog).getByText("because")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Hide word and ask" }));
    expect(within(dialog).queryByText("because")).not.toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Reveal spelling" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Got it" }));

    dialog = screen.getByRole("dialog", { name: "Spelling practice" });
    expect(within(dialog).getByText("different")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Hide word and ask" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Reveal spelling" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Try again" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/homework/spellings/spellings-1/practice", {
      method: "POST",
      body: JSON.stringify({ attempts: [{ word: "because", correct: true }, { word: "different", correct: false }] }),
    }));
    expect(await screen.findByRole("heading", { name: "Practice history" })).toBeInTheDocument();
  });

  it("keeps school details tucked away and restores a removed list", async () => {
    renderHomework();
    await screen.findByText("2 spelling words");
    expect(apiMock).not.toHaveBeenCalledWith("/documents/?limit=200");

    fireEvent.click(screen.getByRole("button", { name: "Add spellings" }));
    const editor = screen.getByRole("dialog", { name: "Add spellings" });
    fireEvent.click(within(editor).getByText("More school details"));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/?limit=200"));

    fireEvent.click(within(editor).getByRole("button", { name: "Close" }));
    fireEvent.click(screen.getByText("2 spelling words"));
    const detail = screen.getByRole("dialog", { name: "Spellings" });
    fireEvent.click(within(detail).getByRole("button", { name: "Remove list" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/homework/spellings/spellings-1", { method: "DELETE" }));

    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/homework/spellings/spellings-1/restore", { method: "POST" }));
    expect(await screen.findByText("2 spelling words")).toBeInTheDocument();
  });
});
