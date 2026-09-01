import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import App, { readLocation } from "../App";
import { api } from "../api";

vi.mock("../AuthContext", () => ({
  useAuth: () => ({
    user: { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family" },
    loading: false,
    signOut: vi.fn(),
    updateUser: vi.fn(),
  }),
}));

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
  flushOfflineQueue: vi.fn().mockResolvedValue(undefined),
  offlineQueueSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, held: 0 }),
}));

vi.mock("../offlineQueue", () => ({
  heldQueuedMutations: vi.fn().mockResolvedValue([]),
  queuedMutations: vi.fn().mockResolvedValue([]),
  removeQueuedMutation: vi.fn().mockResolvedValue(undefined),
}));

const apiMock = vi.mocked(api);
const birthday = {
  id: "birthday-1",
  person_name: "Nana",
  date_of_birth: null,
  birth_month: 9,
  birth_day: 3,
  year_known: false,
  relationship: "family",
  reminder_days_before: 14,
  age: null,
  turning_age: null,
  next_birthday: "2026-09-03",
  days_until: 12,
  preparation_due: true,
};

const preparation = {
  birthday,
  occurrence_year: 2026,
  card_status: "not_started",
  card_message: null,
  celebration_status: "planning",
  notes: null,
  tasks: [{ id: "task-card", title: "Post Nana's card", completed: false }],
  calendar_event: { id: "event-party", title: "Nana's birthday", completed: false },
  gifts_total: 0,
  gifts_remaining: 0,
};

describe("Family query routing", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=family&section=birthdays");
    window.scrollTo = vi.fn();
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/family/members") return [];
      if (path === "/children/") return [{ id: "child-1", name: "Child One", date_of_birth: "2020-01-02" }];
      if (path === "/birthdays/") return [birthday];
      if (path === "/birthdays/birthday-1/preparation") return preparation;
      return [];
    });
  });

  it("recognises Birthdays as a canonical household Family destination", () => {
    expect(readLocation()).toMatchObject({ view: "family", family: "birthdays" });
  });

  it("opens the exact task linked from a birthday plan", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: /Nana.*3 September/ }, { timeout: 5_000 }));
    fireEvent.click(await screen.findByRole("button", { name: /Post Nana's card/ }));

    const query = new URLSearchParams(window.location.search);
    expect(query.get("view")).toBe("lists");
    expect(query.get("section")).toBe("tasks");
    expect(query.get("task")).toBe("task-card");
    expect(query.get("event")).toBeNull();
  });

  it("opens the exact Planner event on its birthday date", async () => {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: /Nana.*3 September/ }, { timeout: 5_000 }));
    fireEvent.click(await screen.findByRole("button", { name: /Nana's birthday.*In Planner/ }));

    const query = new URLSearchParams(window.location.search);
    expect(query.get("view")).toBe("calendar");
    expect(query.get("section")).toBeNull();
    expect(query.get("event")).toBe("event-party");
    expect(query.get("event_date")).toBe("2026-09-03");
    expect(query.get("task")).toBeNull();
  });
});
