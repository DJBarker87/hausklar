import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { RenewalsView } from "../views/RenewalsView";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);

const renewals = [
  {
    id: "r1",
    title: "Car MOT",
    category: "vehicle",
    due_date: "2026-07-01",
    days_until: -11,
    status: "overdue",
    recurrence_months: 12,
    cost_pence: 5499,
    previous_cost_pence: 4999,
    cost_change_pence: 500,
    reminder_days_before: 30,
    reminders_enabled: true,
    escalate_after_days: 3,
    provider: "Local Garage",
    reference: "MOT-123",
    action_url: "https://example.com/book",
    comparison_url: null,
    contact_url: "tel:+00000000005",
    source_document_id: null,
    source_document: null,
    notes: "Book a morning slot",
    finance_commitment_id: "commitment-1",
    show_in_calendar: true,
    show_in_tasks: true,
    responsible_user_id: "dom",
    responsible_user_name: "Alex",
    payment_handling: "RENEWAL",
    checklist: [{ id: "check-1", title: "Check tyres", checked_at: null }],
    history: [],
    created_at: "2026-01-01T00:00:00Z",
  },
  {
    id: "r2",
    title: "Alex's passport",
    category: "document",
    due_date: "2026-07-20",
    days_until: 8,
    status: "due_soon",
    recurrence_months: null,
    cost_pence: null,
    reminder_days_before: 30,
    source_document_id: null,
    notes: "Ten-year adult passport",
    checklist: [],
    history: [],
    created_at: "2026-01-01T00:00:00Z",
  },
];

const members = [{ id: "dom", name: "Alex", member_type: "user" as const }];

function renderRenewals(withMembers = false) {
  return render(
    <RenewalsView
      members={withMembers ? members : []}
      revision={0}
      onDataChanged={vi.fn()}
      notify={vi.fn()}
    />,
  );
}

describe("RenewalsView", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/");
    apiMock.mockReset();
    apiMock.mockImplementation(async (path: string, options?: RequestInit) => {
      if (path === "/renewals/") {
        if (options?.method === "POST") return { ...renewals[0], id: "created" } as never;
        return renewals as never;
      }
      if (path === "/documents/?limit=200") return [] as never;
      if (path === "/renewals/r1/decision") return { ...renewals[0], due_date: "2027-07-01" } as never;
      if (path === "/renewals/r1/restore") return renewals[0] as never;
      return {} as never;
    });
  });

  it("shows what is due without making the list feel like a form", async () => {
    renderRenewals();

    expect(await screen.findByText("Car MOT")).toBeInTheDocument();
    expect(screen.getByText("Alex's passport")).toBeInTheDocument();
    expect(screen.getByText("Overdue")).toBeInTheDocument();
    expect(screen.getByText("Due soon")).toBeInTheDocument();
    expect(screen.getByText("11 days ago")).toBeInTheDocument();
    expect(screen.getByText("in 8 days")).toBeInTheDocument();
    expect(screen.getByText("£54.99")).toBeInTheDocument();
    expect(screen.getByText("0/1 ready")).toBeInTheDocument();
  });

  it("keeps family library status here and offers the official renewal link within a week", async () => {
    const libraryOverview = {
      accounts: [{
        id: "library-account-1",
        provider: "local_authority_spydus",
        label: "Children",
        card_last_four: "D123",
        sync_enabled: true,
        reminder_days_before: 7,
        status: "connected",
        last_sync_at: "2026-08-12T08:00:00Z",
        last_success_at: "2026-08-12T08:00:00Z",
        next_sync_at: "2026-08-12T14:00:00Z",
        error_message: null,
      }],
      loans: [{
        id: "loan-1",
        account_id: "library-account-1",
        account_label: "Children",
        title: "The Wild Robot",
        author: "Peter Brown",
        material_format: "Book",
        due_date: "2026-08-18",
        days_until: 6,
        status: "due_soon",
        provider_status: "Renewable",
        renewable: true,
        renewal_count: 0,
        renew_url: "https://library.example.invalid/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LB/1?ISGLB=1",
      }],
    };
    apiMock.mockImplementation(async (path: string) => {
      if (path === "/renewals/") return renewals as never;
      if (path === "/library/") return libraryOverview as never;
      return {} as never;
    });

    renderRenewals();

    expect(await screen.findByRole("heading", { name: "Library books" })).toBeInTheDocument();
    expect(screen.getByText("The Wild Robot")).toBeInTheDocument();
    expect(screen.getByText("Card ending D123 · Connected")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Renew online" })).toHaveAttribute(
      "href",
      libraryOverview.loans[0].renew_url,
    );
  });

  it("lets one family member enter a card and PIN without embedding credentials", async () => {
    apiMock.mockImplementation(async (path: string, options?: RequestInit) => {
      if (path === "/renewals/") return renewals as never;
      if (path === "/library/") return { accounts: [], loans: [] } as never;
      if (path === "/library/accounts" && options?.method === "POST") {
        return { accounts: [], loans: [] } as never;
      }
      return {} as never;
    });
    renderRenewals();
    fireEvent.click(await screen.findByRole("button", { name: "Add library card" }));

    const dialog = screen.getByRole("dialog", { name: "Connect your library" });
    const pin = within(dialog).getByLabelText("Catalogue PIN");
    expect(pin).toHaveAttribute("type", "password");
    expect(within(dialog).getByLabelText("Remind us this many days before")).toHaveValue("7");
    fireEvent.change(within(dialog).getByLabelText("Whose card?"), { target: { value: "Children" } });
    fireEvent.change(within(dialog).getByLabelText("Library card barcode"), { target: { value: "TESTCARD123" } });
    fireEvent.change(pin, { target: { value: "2468" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Show catalogue PIN" }));
    expect(pin).toHaveAttribute("type", "text");
    fireEvent.click(within(dialog).getByRole("button", { name: "Connect and check loans" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/library/accounts",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          label: "Children",
          card_number: "TESTCARD123",
          pin: "2468",
          reminder_days_before: 7,
        }),
      }),
    ));
  });

  it("records the renewed price and carries the date forward", async () => {
    renderRenewals();
    fireEvent.click(await screen.findByRole("button", { name: "Open Car MOT" }));

    const detail = screen.getByRole("dialog", { name: "Car MOT" });
    expect(within(detail).getByText("+£5.00 since last time")).toBeInTheDocument();
    fireEvent.click(within(detail).getByRole("button", { name: /It’s renewed/ }));

    const decision = screen.getByRole("dialog", { name: "Finish Car MOT" });
    expect(within(decision).getByLabelText("Price paid (£)")).toHaveValue("54.99");
    expect(within(decision).getByLabelText("Next due date")).toHaveValue("2027-07-01");
    fireEvent.click(within(decision).getByRole("button", { name: "Save renewed" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/renewals/r1/decision",
      expect.objectContaining({
        method: "POST",
        body: expect.stringContaining('"next_due_date":"2027-07-01"'),
      }),
    ));
  });

  it("creates a detailed renewal while keeping every extra choice optional", async () => {
    renderRenewals(true);
    await screen.findByText("Car MOT");
    fireEvent.click(screen.getByRole("button", { name: /Add renewal/ }));

    const dialog = await screen.findByRole("dialog", { name: "Add renewal" });
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Home insurance" } });
    fireEvent.change(within(dialog).getByLabelText("Provider"), { target: { value: "Friendly Mutual" } });
    fireEvent.click(within(dialog).getByRole("checkbox", { name: /Show the due date in Calendar/ }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Add renewal" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/renewals/",
      expect.objectContaining({
        method: "POST",
        body: expect.stringMatching(/"title":"Home insurance".*"provider":"Friendly Mutual"/),
      }),
    ));
    const request = apiMock.mock.calls.find(([path, options]) => path === "/renewals/" && options?.method === "POST");
    expect(request?.[1]?.body).toContain('"show_in_calendar":true');
    expect(request?.[1]?.body).toContain('"responsible_user_id":"dom"');
  });

  it("removes a renewal and lets the family undo it immediately", async () => {
    renderRenewals();
    fireEvent.click(await screen.findByRole("button", { name: "Open Car MOT" }));
    fireEvent.click(within(screen.getByRole("dialog", { name: "Car MOT" })).getByRole("button", { name: /Remove this record/ }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/renewals/r1", { method: "DELETE" }));
    expect(screen.getByRole("status")).toHaveTextContent("Car MOT removed");
    fireEvent.click(screen.getByRole("button", { name: /Undo/ }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/renewals/r1/restore", { method: "POST" }));
  });

  it("opens an exact reminder link at the useful detail, then allows editing", async () => {
    window.history.replaceState({}, "", "/?view=finance&section=more&renewal=r1");
    renderRenewals(true);

    const detail = await screen.findByRole("dialog", { name: "Car MOT" });
    expect(within(detail).getByText("Local Garage")).toBeInTheDocument();
    expect(within(detail).getByText("Alex")).toBeInTheDocument();
    expect(new URL(window.location.href).searchParams.has("renewal")).toBe(false);
    fireEvent.click(within(detail).getByRole("button", { name: /Edit/ }));

    const edit = await screen.findByRole("dialog", { name: "Edit renewal" });
    expect(within(edit).getByRole("checkbox", { name: /Include the cost in Household Finance/ })).toBeChecked();
    expect(within(edit).getByLabelText("Payment")).toHaveValue("RENEWAL");
    expect(within(edit).getByLabelText("Responsible adult")).toHaveValue("dom");
    expect(within(edit).getByRole("checkbox", { name: /Show the due date in Calendar/ })).toBeChecked();
    expect(within(edit).getByRole("checkbox", { name: /Add a task for the responsible adult/ })).toBeChecked();
  });

  it("keeps Calendar, Tasks and Household Finance as independent choices", async () => {
    renderRenewals(true);
    await screen.findByText("Car MOT");
    fireEvent.click(screen.getByRole("button", { name: /Add renewal/ }));

    const dialog = await screen.findByRole("dialog", { name: "Add renewal" });
    const calendar = within(dialog).getByRole("checkbox", { name: /Show the due date in Calendar/ });
    const task = within(dialog).getByRole("checkbox", { name: /Add a task for the responsible adult/ });
    const finance = within(dialog).getByRole("checkbox", { name: /Include the cost in Household Finance/ });
    expect(calendar).not.toBeChecked();
    expect(task).not.toBeChecked();
    expect(finance).not.toBeChecked();
    fireEvent.click(task);
    expect(task).toBeChecked();
    expect(calendar).not.toBeChecked();
    expect(finance).not.toBeChecked();
  });

  it("opens the document from the renewal that owns it", async () => {
    const linkedDocument = {
      id: "passport-document",
      title: "Passport scan",
      original_filename: "passport.pdf",
      media_type: "application/pdf",
      file_size: 42_000,
      download_url: "/api/documents/passport-document/content",
    };
    apiMock.mockImplementation(async (path: string) => {
      if (path === "/renewals/") {
        return [{ ...renewals[1], source_document_id: linkedDocument.id, source_document: linkedDocument }] as never;
      }
      return {} as never;
    });

    renderRenewals();
    fireEvent.click(await screen.findByRole("button", { name: "Open Alex's passport" }));
    const detail = screen.getByRole("dialog", { name: "Alex's passport" });
    fireEvent.click(within(detail).getByRole("button", { name: /Document/ }));

    const viewer = screen.getByRole("dialog", { name: "Passport scan" });
    expect(await within(viewer).findByTitle("Passport scan")).toHaveAttribute(
      "src",
      "/api/documents/passport-document/content",
    );
  });
});
