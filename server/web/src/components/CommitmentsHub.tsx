import {
  Baby,
  CalendarHeart,
  ChevronLeft,
  ChevronRight,
  ClipboardCheck,
  MapPinned,
  PartyPopper,
  Plane,
  Plus,
  School,
  Stethoscope,
  type LucideIcon,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";

import { api } from "../api";
import {
  commitmentKindLabel,
  commitmentUrgency,
  openCommitments,
  type Commitment,
  type CommitmentKind,
} from "../commitments/contract";
import type { FamilyMember } from "../types";
import { CommitmentCreateFlow } from "./CommitmentCreateFlow";
import { CommitmentReview } from "./CommitmentReview";
import { EmptyState, ErrorState, Modal, SkeletonList } from "./ui";
import "./commitments.css";

const WORKFLOWS: Array<{
  kind: CommitmentKind;
  title: string;
  detail: string;
  icon: LucideIcon;
}> = [
  { kind: "school", title: "School message", detail: "Dates, actions and things to bring", icon: School },
  { kind: "invitation", title: "Invitation", detail: "Date, RSVP and party preparation", icon: PartyPopper },
  { kind: "outing", title: "Family outing", detail: "Find a time that works before booking", icon: MapPinned },
  { kind: "childcare", title: "Childcare gap", detail: "Find uncovered holiday days", icon: Baby },
  { kind: "appointment", title: "Appointment", detail: "Keep the booking and what it needs", icon: Stethoscope },
  { kind: "travel", title: "Travel booking", detail: "Keep journeys and stays together", icon: Plane },
];

function dueCopy(commitment: Commitment): string {
  const values = [
    ...commitment.plan.events.map((event) => event.start_time),
    ...commitment.plan.tasks.map((task) => task.due_date).filter((value): value is string => Boolean(value)),
    ...(commitment.plan.external_action?.due_at ? [commitment.plan.external_action.due_at] : []),
  ].sort((left, right) => left.localeCompare(right));
  const selected = values[0];
  if (!selected) return "No date yet";
  const parsed = new Date(selected.length === 10 ? `${selected}T12:00:00` : selected);
  if (Number.isNaN(parsed.getTime())) return "Date needs checking";
  return parsed.toLocaleDateString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    ...(selected.length === 10 ? {} : { hour: "2-digit", minute: "2-digit" }),
  });
}

export function CommitmentsHub({
  open,
  initialCommitmentID,
  startCreate = false,
  currentUserID,
  members,
  onOpenChange,
  onDataChanged,
}: {
  open: boolean;
  initialCommitmentID?: string;
  startCreate?: boolean;
  currentUserID: string;
  members: FamilyMember[];
  onOpenChange: (open: boolean) => void;
  onDataChanged: () => void;
}) {
  const [items, setItems] = useState<Commitment[]>([]);
  const [selectedID, setSelectedID] = useState<string | null>(initialCommitmentID ?? null);
  const [creating, setCreating] = useState(startCreate);
  const [createKind, setCreateKind] = useState<CommitmentKind | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const loaded = await api<Commitment[]>("/commitments/?open_only=true&limit=100");
      const pending = openCommitments(Array.isArray(loaded) ? loaded : [])
        .sort((left, right) => commitmentUrgency(left) - commitmentUrgency(right));
      setItems(pending);
      if (initialCommitmentID && !pending.some((item) => item.id === initialCommitmentID)) {
        const selected = await api<Commitment>(`/commitments/${encodeURIComponent(initialCommitmentID)}`);
        if (["draft", "action_required", "ready"].includes(selected.status)) {
          setItems((current) => [selected, ...current.filter((item) => item.id !== selected.id)]);
        } else {
          setSelectedID(null);
        }
      }
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Plans to sort could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [initialCommitmentID]);

  useEffect(() => { if (open) void load(); }, [load, nonce, open]);

  const selected = useMemo(
    () => items.find((item) => item.id === selectedID) ?? null,
    [items, selectedID],
  );

  function updateItem(updated: Commitment) {
    if (["confirmed", "declined"].includes(updated.status)) {
      setItems((current) => current.filter((item) => item.id !== updated.id));
      setSelectedID(null);
    } else {
      setItems((current) => [updated, ...current.filter((item) => item.id !== updated.id)]);
    }
    onDataChanged();
  }

  function finishCreate(created: Commitment, creationNotice?: string) {
    setItems((current) => [created, ...current.filter((item) => item.id !== created.id)]);
    setNotice(creationNotice ?? null);
    setCreating(false);
    setCreateKind(null);
    setSelectedID(created.id);
    onDataChanged();
  }

  function queued(message: string) {
    setNotice(message);
    setCreating(false);
    setCreateKind(null);
    setSelectedID(null);
    onDataChanged();
  }

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title="Plans to sort"
      description="Turn incoming details into one calm, reviewed plan before anything reaches the family calendar or task list."
      size="activity"
    >
      <div className="commitments-hub">
        {notice ? <div className="commitments-notice" role="status"><ClipboardCheck aria-hidden="true" size={19} /><span>{notice}</span></div> : null}

        {selected ? (
          <CommitmentReview
            commitment={selected}
            currentUserID={currentUserID}
            members={members}
            onBack={() => setSelectedID(null)}
            onUpdated={updateItem}
            onQueued={(message) => { setNotice(message); setSelectedID(null); onDataChanged(); }}
          />
        ) : creating ? (
          <section className="commitments-create" aria-labelledby="commitment-create-title">
            <button type="button" className="commitments-back" onClick={() => createKind ? setCreateKind(null) : setCreating(false)}>
              <ChevronLeft aria-hidden="true" size={17} /> {createKind ? "Choose another" : "Plans to sort"}
            </button>
            {!createKind ? (
              <>
                <header className="commitments-section-heading">
                  <span><Plus aria-hidden="true" size={20} /></span>
                  <div><h2 id="commitment-create-title">What are you sorting out?</h2><p>Choose the real-life situation. HausKlar will keep its dates, actions and preparation together.</p></div>
                </header>
                <div className="commitment-kind-grid">
                  {WORKFLOWS.map((workflow) => {
                    const Icon = workflow.icon;
                    return <button type="button" key={workflow.kind} onClick={() => setCreateKind(workflow.kind)}><Icon aria-hidden="true" size={22} /><span><strong>{workflow.title}</strong><small>{workflow.detail}</small></span><ChevronRight aria-hidden="true" size={17} /></button>;
                  })}
                </div>
              </>
            ) : (
              <CommitmentCreateFlow kind={createKind} members={members} openPlans={items} onCreated={finishCreate} onQueued={queued} />
            )}
          </section>
        ) : (
          <section className="commitments-list" aria-labelledby="commitments-list-title">
            <header className="commitments-section-heading">
              <span><CalendarHeart aria-hidden="true" size={20} /></span>
              <div><h2 id="commitments-list-title">{items.length ? `${items.length} ${items.length === 1 ? "plan" : "plans"} waiting` : "Nothing waiting"}</h2><p>The likely next plan is first. Open one to edit the details, finish any outside step, then confirm it.</p></div>
              <button type="button" className="button button--primary" onClick={() => { setNotice(null); setCreating(true); }}>New plan</button>
            </header>
            {loading ? <SkeletonList rows={5} /> : null}
            {!loading && error ? <ErrorState message={error} retry={() => setNonce((value) => value + 1)} /> : null}
            {!loading && !error && !items.length ? <EmptyState title="You’re all sorted" detail="School messages, invitations, bookings and gaps will wait here for review." action={() => setCreating(true)} actionLabel="Start a plan" /> : null}
            {!loading && !error && items.length ? (
              <div className="commitments-list__rows">
                {items.map((item) => (
                  <button type="button" key={item.id} onClick={() => { setNotice(null); setSelectedID(item.id); }}>
                    <span className={`commitment-kind-mark is-${item.kind}`}>{commitmentKindLabel(item.kind).slice(0, 1)}</span>
                    <span><strong>{item.title}</strong><small>{commitmentKindLabel(item.kind)} · {dueCopy(item)}{item.visibility === "owner" ? " · Just mine" : " · Family"}</small></span>
                    {item.review_issues.length ? <em>{item.review_issues.length} to check</em> : item.external_action_status === "pending" ? <em>Outside step</em> : <em>Ready</em>}
                    <ChevronRight aria-hidden="true" size={18} />
                  </button>
                ))}
              </div>
            ) : null}
          </section>
        )}
      </div>
    </Modal>
  );
}
