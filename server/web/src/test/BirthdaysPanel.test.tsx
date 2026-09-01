import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { BirthdaysPanel, type BirthdayRecord } from "../views/BirthdaysPanel";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

const nana: BirthdayRecord = {
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

const coach: BirthdayRecord = {
  ...nana,
  id: "birthday-2",
  person_name: "Coach",
  birth_month: 12,
  birth_day: 10,
  next_birthday: "2026-12-10",
  days_until: 123,
  preparation_due: false,
};

const plan = {
  birthday: nana,
  occurrence_year: 2026,
  card_status: "not_started",
  card_message: null,
  celebration_status: "not_started",
  notes: null,
  tasks: [],
  calendar_event: null,
  gifts_total: 0,
  gifts_remaining: 0,
};

describe("BirthdaysPanel", () => {
  beforeEach(() => {
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/birthdays/") return [nana, coach] as never;
      if (path === "/birthdays/birthday-1/preparation") return plan as never;
      return {} as never;
    });
  });

  it("brings only due preparation forward and never invents an age", async () => {
    render(<BirthdaysPanel />);

    expect(await screen.findByRole("heading", { name: "Prepare now" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Later" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Nana.*3 September.*in 12 days/i })).not.toHaveTextContent("turning");
    expect(screen.getByRole("button", { name: /Coach.*10 December.*in 123 days/i })).toBeInTheDocument();
  });

  it("opens one preparation page and adds its exact Planner event", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/birthdays/") return [nana] as never;
      if (path === "/birthdays/birthday-1/preparation" && !init?.method) return plan as never;
      if (path === "/birthdays/birthday-1/preparation/event") {
        return { ...plan, calendar_event: { id: "event-1", title: "Nana's birthday", completed: false } } as never;
      }
      return {} as never;
    });
    render(<BirthdaysPanel />);

    fireEvent.click(await screen.findByRole("button", { name: /Nana/ }));
    expect(await screen.findByRole("heading", { name: "Present" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Add to Planner" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/birthdays/birthday-1/preparation/event",
      { method: "POST", body: "{}" },
    ));
    expect(await screen.findByRole("button", { name: /Nana's birthday.*In Planner/ })).toBeInTheDocument();
  });

  it("reviews a pasted unknown-year birthday before saving it", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/birthdays/" && init?.method === "POST") return coach as never;
      if (path === "/birthdays/") return [] as never;
      if (path === "/birthdays/import-preview") return {
        drafts: [{ line_number: 1, source_line: "Coach, 3 September", person_name: "Coach", date_of_birth: null, birth_month: 9, birth_day: 3, duplicate_id: null, issue: null }],
      } as never;
      return {} as never;
    });
    render(<BirthdaysPanel />);

    fireEvent.click(await screen.findByRole("button", { name: "Paste a list" }));
    const dialog = screen.getByRole("dialog", { name: "Import birthdays" });
    fireEvent.change(within(dialog).getByLabelText("One person per line"), { target: { value: "Coach, 3 September" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Review" }));

    expect(await within(dialog).findByText("3 September · year unknown")).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/birthdays/", expect.objectContaining({ method: "POST" }));
  });
});
