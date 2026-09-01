import { ChevronRight, ClipboardCheck } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../api";
import {
  commitmentKindLabel,
  commitmentUrgency,
  openCommitments,
  type Commitment,
} from "../commitments/contract";

function whenLabel(commitment: Commitment): string {
  const values = [
    ...commitment.plan.events.map((event) => event.start_time),
    ...commitment.plan.tasks.map((task) => task.due_date).filter((value): value is string => Boolean(value)),
    ...(commitment.plan.external_action?.due_at ? [commitment.plan.external_action.due_at] : []),
  ];
  if (!values.length) return commitmentKindLabel(commitment.kind);
  const selected = values.sort((left, right) => left.localeCompare(right))[0];
  const parsed = new Date(selected.length === 10 ? `${selected}T12:00:00` : selected);
  if (Number.isNaN(parsed.getTime())) return commitmentKindLabel(commitment.kind);
  return parsed.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
}

export function PlansToSortCard({
  revision,
  onOpen,
}: {
  revision: number;
  onOpen: (commitmentID?: string) => void;
}) {
  const [items, setItems] = useState<Commitment[]>([]);

  useEffect(() => {
    let active = true;
    void api<Commitment[]>("/commitments/?open_only=true&limit=50")
      .then((loaded) => { if (active && Array.isArray(loaded)) setItems(openCommitments(loaded)); })
      .catch(() => undefined);
    return () => { active = false; };
  }, [revision]);

  const urgent = useMemo(() => [...items].sort((left, right) => (
    commitmentUrgency(left) - commitmentUrgency(right)
    || left.updated_at.localeCompare(right.updated_at)
  ))[0] ?? null, [items]);

  if (!urgent) return null;

  return (
    <button type="button" className="today-plans-card" onClick={() => onOpen(urgent.id)}>
      <span className="today-plans-card__icon"><ClipboardCheck aria-hidden="true" size={20} /></span>
      <span>
        <small>{items.length} {items.length === 1 ? "plan" : "plans"} waiting</small>
        <strong>Plans to sort</strong>
        <span><b>{urgent.title}</b> · {whenLabel(urgent)}{urgent.visibility === "owner" ? " · Just mine" : ""}</span>
      </span>
      <ChevronRight aria-hidden="true" size={18} />
    </button>
  );
}
