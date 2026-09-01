import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { Commitment } from "../commitments/contract";
import { CommitmentCreateFlow } from "../components/CommitmentCreateFlow";
import { CommitmentReview } from "../components/CommitmentReview";
import { CommitmentsHub } from "../components/CommitmentsHub";
import { PlansToSortCard } from "../components/PlansToSortCard";
import type { FamilyMember } from "../types";

vi.mock("../api", async (importOriginal) => {
  const original = await importOriginal<typeof import("../api")>();
  return { ...original, api: vi.fn() };
});

const apiMock = vi.mocked(api);
const members: FamilyMember[] = [
  { id: "dom", name: "Alex", member_type: "user" },
  { id: "kat", name: "Morgan", member_type: "user" },
  { id: "child", name: "Child", member_type: "child" },
];

function commitment(overrides: Partial<Commitment> = {}): Commitment {
  return {
    id: "commitment-1",
    kind: "school",
    visibility: "family",
    owner_user_id: "dom",
    title: "School photograph day",
    summary: "Children should wear winter uniform.",
    status: "ready",
    revision: 1,
    sources: [{ id: "source-1", kind: "manual", label: "School email", provider_reference: "PHOTO-1", observed_at: "2026-08-12T10:00:00Z" }],
    plan: {
      events: [{ id: "event-1", title: "School photograph day", description: null, start_time: "2026-08-13", end_time: null, all_day: true, location: "School", person_ids: ["child"], affected_adult_ids: [], assigned_to: null, event_type: "school", document_ids: [] }],
      tasks: [{ id: "task-1", title: "Prepare winter uniform", description: null, due_date: "2026-08-12", actionable_from: null, assigned_to: "dom", priority: 2, document_id: null }],
      preparations: [{ id: "prep-1", event_id: "event-1", name: "School preparation", items: ["Prepare winter uniform"], lead_hours: 24, assigned_to: "dom" }],
      external_action: null,
    },
    review_issues: [],
    external_action_status: "not_required",
    external_action_outcome: null,
    external_action_completed_at: null,
    group_key: null,
    interpretation_processor: "fallback",
    supersedes_id: null,
    change_summary: [],
    confirmed_at: null,
    declined_at: null,
    results: [],
    created_at: "2026-08-12T10:00:00Z",
    updated_at: "2026-08-12T10:00:00Z",
    ...overrides,
  };
}

describe("Plans to sort", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  });

  it("shows one calm Today summary with the most urgent date-only plan", async () => {
    const open = vi.fn();
    apiMock.mockResolvedValue([
      commitment({ id: "later", title: "Later invitation", plan: { ...commitment().plan, events: [{ ...commitment().plan.events[0], id: "later-event", start_time: "2026-08-20" }], tasks: [], preparations: [] } }),
      commitment({ id: "urgent", title: "Photograph day", plan: { ...commitment().plan, events: [{ ...commitment().plan.events[0], start_time: "2026-08-13" }], tasks: [], preparations: [] } }),
    ] as never);

    render(<PlansToSortCard revision={0} onOpen={open} />);
    const card = await screen.findByRole("button", { name: /Plans to sort/ });
    expect(card).toHaveTextContent("2 plans waiting");
    expect(card).toHaveTextContent(/Photograph day · Thu,? 13 Aug/);
    expect(card).not.toHaveTextContent("12:00");
    fireEvent.click(card);
    expect(open).toHaveBeenCalledWith("urgent");
  });

  it("offers all six situations in one accessible hub", async () => {
    apiMock.mockResolvedValue([] as never);
    render(<CommitmentsHub open startCreate currentUserID="dom" members={members} onOpenChange={vi.fn()} onDataChanged={vi.fn()} />);

    expect(screen.getByRole("dialog", { name: "Plans to sort" })).toBeInTheDocument();
    for (const name of ["School message", "Invitation", "Family outing", "Childcare gap", "Appointment", "Travel booking"]) {
      expect(await screen.findByRole("button", { name: new RegExp(name) })).toBeInTheDocument();
    }
  });

  it("keeps a date-only deadline date-only in the hub list", async () => {
    apiMock.mockResolvedValue([commitment({ plan: { ...commitment().plan, tasks: [], preparations: [] } })] as never);
    render(<CommitmentsHub open currentUserID="dom" members={members} onOpenChange={vi.fn()} onDataChanged={vi.fn()} />);
    const row = await screen.findByRole("button", { name: /School photograph day/ });
    expect(row).toHaveTextContent(/Thu,? 13 Aug/);
    expect(row).not.toHaveTextContent(/12:00|noon/i);
  });

  it("creates a source-backed school draft from reviewed text with Hermes off", async () => {
    const created = commitment();
    apiMock.mockImplementation(async (path) => {
      if (path === "/commitments/?open_only=true&limit=100") return [] as never;
      if (path === "/auth/ai-consent") return { consented: true, version: "v1", provider: "hermes", disclosure: "Reviewed text may be sent.", background_processing: false } as never;
      if (path.startsWith("/documents/")) return [{ id: "document-1", title: "School letter", status: "filed", extracted_text: "Photograph day is Thursday 13 August. Wear winter uniform." }] as never;
      if (path === "/commitments/from-source") return { commitment: created, processor: "fallback", warning: null, deduplicated: false, material_changes: [] } as never;
      return [] as never;
    });
    render(<CommitmentsHub open startCreate currentUserID="dom" members={members} onOpenChange={vi.fn()} onDataChanged={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /School message/ }));
    const hermes = await screen.findByRole("checkbox", { name: /Ask Bismarck/ });
    expect(hermes).not.toBeChecked();
    fireEvent.change(await screen.findByLabelText("Source document (optional)"), { target: { value: "document-1" } });
    expect(screen.getByLabelText("Reviewed text")).toHaveValue("Photograph day is Thursday 13 August. Wear winter uniform.");
    fireEvent.change(screen.getByLabelText(/Message reference/), { target: { value: "PHOTO-1" } });
    fireEvent.click(screen.getByRole("button", { name: "Create plan to review" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/commitments/from-source",
      expect.objectContaining({ method: "POST" }),
      true,
      false,
    ));
    const request = apiMock.mock.calls.find(([path]) => path === "/commitments/from-source")?.[1];
    expect(JSON.parse(String(request?.body))).toMatchObject({ kind: "school", text: expect.stringContaining("Photograph day"), source_document_id: "document-1", provider_reference: "PHOTO-1", use_hermes: false });
    expect(await screen.findByRole("heading", { name: "School photograph day" })).toBeInTheDocument();
  });

  it("chooses privacy before writing and marks a reviewed source as an update", async () => {
    const familyPrior = commitment({ id: "family-prior", title: "Family photograph plan" });
    const privatePrior = commitment({ id: "private-prior", title: "Private photograph plan", visibility: "owner" });
    const existing = commitment({ id: "existing-plan", visibility: "owner", supersedes_id: "private-prior" });
    const created = vi.fn();
    apiMock.mockImplementation(async (path) => {
      if (path === "/auth/ai-consent") return { consented: false, version: "v1", provider: "off", disclosure: "Off", background_processing: false } as never;
      if (path.startsWith("/documents/")) return [] as never;
      if (path === "/commitments/from-source") return { commitment: existing, processor: "fallback", warning: null, deduplicated: true, material_changes: [] } as never;
      return [] as never;
    });

    render(<CommitmentCreateFlow kind="school" members={members} openPlans={[familyPrior, privatePrior, commitment({ id: "other-kind", kind: "travel", title: "Germany trip" })]} onCreated={created} onQueued={vi.fn()} />);
    let updateSelect = screen.getByLabelText(/This updates an existing plan/);
    expect(within(updateSelect).getByRole("option", { name: "Family photograph plan" })).toBeInTheDocument();
    expect(within(updateSelect).queryByRole("option", { name: "Private photograph plan" })).not.toBeInTheDocument();
    expect(within(updateSelect).queryByRole("option", { name: "Germany trip" })).not.toBeInTheDocument();
    fireEvent.change(updateSelect, { target: { value: "family-prior" } });

    fireEvent.click(screen.getByRole("radio", { name: /Just me/ }));
    updateSelect = screen.getByLabelText(/This updates an existing plan/);
    expect(updateSelect).toHaveValue("");
    expect(within(updateSelect).queryByRole("option", { name: "Family photograph plan" })).not.toBeInTheDocument();
    expect(within(updateSelect).getByRole("option", { name: "Private photograph plan" })).toBeInTheDocument();
    fireEvent.change(updateSelect, { target: { value: "private-prior" } });
    fireEvent.change(screen.getByLabelText("Reviewed text"), { target: { value: "Photograph day has moved to Friday." } });
    fireEvent.click(screen.getByRole("button", { name: "Create plan to review" }));

    await waitFor(() => expect(created).toHaveBeenCalled());
    const request = apiMock.mock.calls.find(([path]) => path === "/commitments/from-source")?.[1];
    expect(JSON.parse(String(request?.body))).toMatchObject({ visibility: "owner", supersedes_id: "private-prior" });
    expect(created).toHaveBeenCalledWith(existing, expect.stringContaining("Nothing was duplicated"));
  });
});

describe("commitment review", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  });

  it("edits a multi-event travel plan while preserving nested IDs and expected revision", async () => {
    const travel = commitment({
      kind: "travel",
      title: "Germany trip",
      group_key: "BA-ABC123",
      plan: {
        ...commitment().plan,
        events: [
          { ...commitment().plan.events[0], id: "flight-out", title: "Outbound flight", start_time: "2026-09-01T09:00:00+01:00", all_day: false },
          { ...commitment().plan.events[0], id: "hotel", title: "Hotel check-in", start_time: "2026-09-01T15:00:00+02:00", all_day: false },
        ],
        preparations: [{ ...commitment().plan.preparations[0], event_id: "flight-out" }],
      },
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/commitments/commitment-1" && init?.method === "PATCH") {
        const body = JSON.parse(String(init.body));
        return { ...travel, ...body, revision: 2 } as never;
      }
      return travel as never;
    });

    render(<CommitmentReview commitment={travel} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={vi.fn()} onQueued={vi.fn()} />);
    const eventOne = screen.getByText("Event 1").closest("article")!;
    fireEvent.change(within(eventOne).getByLabelText("Title"), { target: { value: "Flight to Munich" } });
    fireEvent.change(screen.getByLabelText("Trip group or reference"), { target: { value: "TRIP-2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/commitments/commitment-1",
      expect.objectContaining({ method: "PATCH" }),
    ));
    const request = apiMock.mock.calls.find(([path, init]) => path === "/commitments/commitment-1" && init?.method === "PATCH")?.[1];
    const body = JSON.parse(String(request?.body));
    expect(body.expected_revision).toBe(1);
    expect(body.group_key).toBe("TRIP-2026");
    expect(body.plan.events.map((event: { id: string }) => event.id)).toEqual(["flight-out", "hotel"]);
    expect(body.plan.tasks[0].id).toBe("task-1");
    expect(body.plan.preparations[0].id).toBe("prep-1");
    expect(body.sources[0].id).toBe("source-1");
  });

  it("opens a safe RSVP target, records Done, then confirms", async () => {
    const invitation = commitment({
      kind: "invitation",
      title: "Birthday party",
      status: "action_required",
      external_action_status: "pending",
      plan: { ...commitment().plan, external_action: { kind: "rsvp", label: "Reply to the invitation", target_type: "https", target: "https://example.com/rsvp", due_at: "2026-08-15", requires_completion_before_confirm: true } },
    });
    const done = { ...invitation, revision: 2, status: "ready" as const, external_action_status: "completed" as const, external_action_outcome: "replied" };
    const confirmed = { ...done, revision: 3, status: "confirmed" as const };
    apiMock.mockImplementation(async (path) => {
      if (path.endsWith("/external-action/complete")) return done as never;
      if (path.endsWith("/confirm")) return confirmed as never;
      return invitation as never;
    });

    function Harness() {
      const [value, setValue] = useState(invitation);
      return <CommitmentReview commitment={value} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={setValue} onQueued={vi.fn()} />;
    }
    render(<Harness />);
    expect(screen.getByRole("link", { name: /Reply to the invitation/ })).toHaveAttribute("href", "https://example.com/rsvp");
    expect(screen.getByRole("button", { name: "Confirm plan" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Mark Done" }));
    expect(await screen.findByRole("button", { name: "Done" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Confirm plan" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Confirm plan" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/commitments/commitment-1/confirm",
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"expected_revision":2') }),
    ));
  });

  it("reports replayable offline edits honestly and stops the stale revision flow", async () => {
    apiMock.mockResolvedValue({ queued_offline: true } as never);
    const queued = vi.fn();
    render(<CommitmentReview commitment={commitment()} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={vi.fn()} onQueued={queued} />);
    fireEvent.change(screen.getByLabelText("Summary (optional)"), { target: { value: "Changed while offline" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(queued).toHaveBeenCalledWith(expect.stringContaining("saved on this device")));
  });

  it("keeps visibility owner-controlled on a shared plan", () => {
    render(<CommitmentReview commitment={commitment()} currentUserID="kat" members={members} onBack={vi.fn()} onUpdated={vi.fn()} onQueued={vi.fn()} />);
    expect(screen.getByLabelText("Who can see it?")).toBeDisabled();
    expect(screen.getByText("Only the person who started this plan can change who sees it.")).toBeInTheDocument();
    expect(screen.getByLabelText("Summary (optional)")).toBeEnabled();
  });

  it("shows material changes from the prior plan", () => {
    render(<CommitmentReview commitment={commitment({ supersedes_id: "prior-plan", change_summary: ["Event details or times changed", "Actions or deadlines changed"] })} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={vi.fn()} onQueued={vi.fn()} />);
    expect(screen.getByRole("heading", { name: "What changed from the earlier plan" })).toBeInTheDocument();
    expect(screen.getByText("Event details or times changed")).toBeInTheDocument();
    expect(screen.getByText("The earlier plan has not been altered or removed.")).toBeInTheDocument();
  });

  it("reviews affected adults and advanced event and task fields without dropping them", async () => {
    const detailed = commitment({
      plan: {
        ...commitment().plan,
        events: [{ ...commitment().plan.events[0], description: "Use the side entrance", affected_adult_ids: ["kat"], assigned_to: "dom" }],
        tasks: [{ ...commitment().plan.tasks[0], description: "Check the named jumper", actionable_from: "2026-08-11", priority: 3, document_id: "document-1" }],
      },
    });
    apiMock.mockImplementation(async (path, init) => {
      if (path.startsWith("/documents/")) return [{ id: "document-1", title: "School letter", status: "filed" }] as never;
      if (path === "/commitments/commitment-1" && init?.method === "PATCH") return { ...detailed, ...JSON.parse(String(init.body)), revision: 2 } as never;
      return detailed as never;
    });
    render(<CommitmentReview commitment={detailed} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={vi.fn()} onQueued={vi.fn()} />);

    const eventDetails = screen.getByText(/More event details/).closest("details")!;
    fireEvent.click(within(eventDetails).getByText(/More event details/));
    expect(within(eventDetails).getByLabelText("Notes (optional)")).toHaveValue("Use the side entrance");
    expect(within(eventDetails).getByRole("checkbox", { name: "Morgan" })).toBeChecked();
    fireEvent.change(within(eventDetails).getByLabelText("Lead person (optional)"), { target: { value: "kat" } });
    expect(within(eventDetails).getByRole("checkbox", { name: "Morgan" })).not.toBeChecked();

    const taskDetails = screen.getByText("More task details").closest("details")!;
    fireEvent.click(within(taskDetails).getByText("More task details"));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/documents/?offset=0&limit=100"));
    expect(within(taskDetails).getByLabelText("Notes (optional)")).toHaveValue("Check the named jumper");
    expect(within(taskDetails).getByLabelText("Available from (optional)")).toHaveValue("2026-08-11");
    expect(within(taskDetails).getByLabelText("Priority")).toHaveValue("3");
    await waitFor(() => expect(within(taskDetails).getByLabelText("Linked document (optional)")).toHaveValue("document-1"));
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    const request = await waitFor(() => apiMock.mock.calls.find(([path, init]) => path === "/commitments/commitment-1" && init?.method === "PATCH")?.[1]);
    const body = JSON.parse(String(request?.body));
    expect(body.plan.events[0]).toMatchObject({ description: "Use the side entrance", assigned_to: "kat", affected_adult_ids: [] });
    expect(body.plan.tasks[0]).toMatchObject({ description: "Check the named jumper", actionable_from: "2026-08-11", priority: 3, document_id: "document-1" });
  });

  it("declines without creating downstream items and sends the reviewed revision", async () => {
    const declined = commitment({ status: "declined", revision: 2, declined_at: "2026-08-12T11:00:00Z" });
    apiMock.mockResolvedValue(declined as never);
    const updated = vi.fn();
    render(<CommitmentReview commitment={commitment()} currentUserID="dom" members={members} onBack={vi.fn()} onUpdated={updated} onQueued={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Decline" }));
    fireEvent.change(screen.getByLabelText("Reason (optional)"), { target: { value: "We cannot attend" } });
    fireEvent.click(screen.getByRole("button", { name: "Decline plan" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/commitments/commitment-1/decline",
      expect.objectContaining({ method: "POST", body: expect.stringContaining('"expected_revision":1') }),
    ));
    const request = apiMock.mock.calls[0][1];
    expect(JSON.parse(String(request?.body))).toMatchObject({ reason: "We cannot attend" });
    expect(updated).toHaveBeenCalledWith(declined);
  });
});

describe("calendar-aware plan creation", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(navigator, "onLine", { configurable: true, value: true });
  });

  it("searches free windows and turns a viable outing into a typed draft", async () => {
    const created = commitment({ kind: "outing", title: "Example Town Castle" });
    apiMock.mockImplementation(async (path) => {
      if (path === "/commitments/free-windows/query") return { windows: [{ start_time: "2026-08-20T10:00:00+01:00", end_time: "2026-08-20T18:00:00+01:00", duration_minutes: 480 }], viable_outings: [{ candidate_id: "candidate", title: "Example Town Castle", proposed_start: "2026-08-20T10:00:00+01:00", proposed_end: "2026-08-20T12:00:00+01:00", location: "Example Town", booking_url: "https://example.com/book" }] } as never;
      if (path === "/commitments/") return created as never;
      return [] as never;
    });
    render(<CommitmentCreateFlow kind="outing" members={members} onCreated={vi.fn()} onQueued={vi.fn()} />);
    fireEvent.click(screen.getByRole("radio", { name: /Just me/ }));
    fireEvent.click(screen.getByRole("checkbox", { name: "Alex" }));
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Example Town Castle" } });
    fireEvent.click(screen.getByRole("button", { name: "Find a time" }));
    fireEvent.click(await screen.findByRole("button", { name: "Use this time" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/commitments/", expect.objectContaining({ method: "POST" })));
    const request = apiMock.mock.calls.find(([path]) => path === "/commitments/")?.[1];
    const body = JSON.parse(String(request?.body));
    expect(body).toMatchObject({ kind: "outing", visibility: "owner", plan: { events: [{ title: "Example Town Castle", person_ids: ["dom"] }], external_action: { kind: "book", target: "https://example.com/book" } } });
    expect(body.id).toMatch(/[0-9a-f-]+/i);
    expect(body.sources[0].id).toMatch(/[0-9a-f-]+/i);
    expect(body.plan.events[0].id).toMatch(/[0-9a-f-]+/i);
  });

  it("reuses an outing operation only for the same reviewed body", async () => {
    const created = commitment({ kind: "outing", title: "Example Town Castle", visibility: "owner" });
    let saves = 0;
    apiMock.mockImplementation(async (path) => {
      if (path === "/commitments/free-windows/query") return { windows: [], viable_outings: [{ candidate_id: "candidate", title: "Example Town Castle", proposed_start: "2026-08-20T10:00:00+01:00", proposed_end: "2026-08-20T12:00:00+01:00", location: "Example Town", booking_url: null }] } as never;
      if (path === "/commitments/") {
        saves += 1;
        if (saves < 3) throw new Error("Temporary network problem");
        return created as never;
      }
      return [] as never;
    });
    const onCreated = vi.fn();
    render(<CommitmentCreateFlow kind="outing" members={members} onCreated={onCreated} onQueued={vi.fn()} />);
    fireEvent.click(screen.getByRole("checkbox", { name: "Alex" }));
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Example Town Castle" } });
    fireEvent.click(screen.getByRole("button", { name: "Find a time" }));
    const useTime = await screen.findByRole("button", { name: "Use this time" });
    fireEvent.click(useTime);
    expect(await screen.findByRole("alert")).toHaveTextContent("Temporary network problem");
    fireEvent.click(useTime);
    await waitFor(() => expect(apiMock.mock.calls.filter(([path]) => path === "/commitments/")).toHaveLength(2));
    const firstTwo = apiMock.mock.calls.filter(([path]) => path === "/commitments/").map(([, init]) => JSON.parse(String(init?.body)));
    expect(firstTwo[1].id).toBe(firstTwo[0].id);
    expect(firstTwo[1].sources[0].id).toBe(firstTwo[0].sources[0].id);
    expect(firstTwo[1].plan.events[0].id).toBe(firstTwo[0].plan.events[0].id);
    expect(firstTwo[1].sources[0].observed_at).toBe(firstTwo[0].sources[0].observed_at);
    expect(firstTwo[1].client_timestamp).toBe(firstTwo[0].client_timestamp);

    fireEvent.click(screen.getByRole("radio", { name: /Just me/ }));
    fireEvent.click(screen.getByRole("button", { name: "Use this time" }));
    await waitFor(() => expect(onCreated).toHaveBeenCalledWith(created));
    const changed = JSON.parse(String(apiMock.mock.calls.filter(([path]) => path === "/commitments/")[2][1]?.body));
    expect(changed.visibility).toBe("owner");
    expect(changed.id).not.toBe(firstTwo[0].id);
  });

  it("finds a child's uncovered date and creates one all-day childcare draft", async () => {
    const created = commitment({ kind: "childcare", title: "Childcare for Child" });
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/commitments/childcare-gaps?")) return [{ date: "2026-10-26", label: "Half term", source: "explicit_holiday" }] as never;
      if (path === "/commitments/") return created as never;
      return [] as never;
    });
    render(<CommitmentCreateFlow kind="childcare" members={members} onCreated={vi.fn()} onQueued={vi.fn()} />);
    fireEvent.click(screen.getByRole("radio", { name: /Just me/ }));
    fireEvent.click(screen.getByRole("button", { name: "Find uncovered days" }));
    fireEvent.click(await screen.findByRole("button", { name: "Plan childcare" }));

    const request = await waitFor(() => apiMock.mock.calls.find(([path]) => path === "/commitments/")?.[1]);
    const body = JSON.parse(String(request?.body));
    expect(body).toMatchObject({ kind: "childcare", visibility: "owner", plan: { events: [{ start_time: "2026-10-26", all_day: true, person_ids: ["child"], event_type: "childcare" }] } });
  });

  it("reuses a childcare operation only while child, gap and privacy stay the same", async () => {
    const created = commitment({ kind: "childcare", title: "Childcare for Child", visibility: "owner" });
    let saves = 0;
    apiMock.mockImplementation(async (path) => {
      if (path.startsWith("/commitments/childcare-gaps?")) return [{ date: "2026-10-26", label: "Half term", source: "explicit_holiday" }] as never;
      if (path === "/commitments/") {
        saves += 1;
        if (saves < 3) throw new Error("Temporary network problem");
        return created as never;
      }
      return [] as never;
    });
    const onCreated = vi.fn();
    render(<CommitmentCreateFlow kind="childcare" members={members} onCreated={onCreated} onQueued={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Find uncovered days" }));
    const plan = await screen.findByRole("button", { name: "Plan childcare" });
    fireEvent.click(plan);
    expect(await screen.findByRole("alert")).toHaveTextContent("Temporary network problem");
    fireEvent.click(plan);
    await waitFor(() => expect(apiMock.mock.calls.filter(([path]) => path === "/commitments/")).toHaveLength(2));
    const firstTwo = apiMock.mock.calls.filter(([path]) => path === "/commitments/").map(([, init]) => JSON.parse(String(init?.body)));
    expect(firstTwo[1].id).toBe(firstTwo[0].id);
    expect(firstTwo[1].sources[0].id).toBe(firstTwo[0].sources[0].id);
    expect(firstTwo[1].plan.events[0].id).toBe(firstTwo[0].plan.events[0].id);
    expect(firstTwo[1].sources[0].observed_at).toBe(firstTwo[0].sources[0].observed_at);
    expect(firstTwo[1].client_timestamp).toBe(firstTwo[0].client_timestamp);

    fireEvent.click(screen.getByRole("radio", { name: /Just me/ }));
    fireEvent.click(plan);
    await waitFor(() => expect(onCreated).toHaveBeenCalledWith(created));
    const changed = JSON.parse(String(apiMock.mock.calls.filter(([path]) => path === "/commitments/")[2][1]?.body));
    expect(changed.visibility).toBe("owner");
    expect(changed.id).not.toBe(firstTwo[0].id);
  });
});
