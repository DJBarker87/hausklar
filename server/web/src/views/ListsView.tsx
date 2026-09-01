import {
  ArrowLeft,
  BellRing,
  CheckSquare2,
  ChevronRight,
  ForkKnife,
  ListTodo,
  Backpack,
  Repeat2,
} from "lucide-react";
import { lazy, Suspense, useEffect, useState } from "react";

import type { FamilyMember } from "../types";
import { SkeletonList } from "../components/ui";

const MealsView = lazy(() => import("./MealsView").then((module) => ({ default: module.MealsView })));
const PrepPacksView = lazy(() => import("./PrepPacksView").then((module) => ({ default: module.PrepPacksView })));
const RenewalsView = lazy(() => import("./RenewalsView").then((module) => ({ default: module.RenewalsView })));
const RoutinesView = lazy(() => import("./RoutinesView").then((module) => ({ default: module.RoutinesView })));
const TasksView = lazy(() => import("./TasksView").then((module) => ({ default: module.TasksView })));

export type ListsArea = "hub" | "tasks" | "meals" | "routines" | "renewals" | "prep";

export function ListsView({
  members,
  revision,
  initialArea = "hub",
  initialMealsTab = "meals",
  financeEnabled = true,
  onAddTask,
  onDataChanged,
  notify,
  onAreaChange,
}: {
  members: FamilyMember[];
  revision: number;
  initialArea?: ListsArea;
  initialMealsTab?: "meals" | "tesco";
  financeEnabled?: boolean;
  onAddTask: () => void;
  onDataChanged: () => void;
  notify: (message: string) => void;
  onAreaChange?: (area: ListsArea) => void;
}) {
  const [area, setArea] = useState<ListsArea>(initialArea);

  useEffect(() => setArea(initialArea), [initialArea]);

  function open(next: ListsArea) {
    setArea(next);
    onAreaChange?.(next);
  }

  if (area !== "hub") {
    return (
      <div className="nested-view">
        <button type="button" className="nested-back" onClick={() => open("hub")}><ArrowLeft aria-hidden="true" size={18} /> Lists</button>
        <Suspense fallback={<SkeletonList rows={7} />}>
        {area === "tasks" ? <TasksView members={members} revision={revision} onDataChanged={onDataChanged} notify={notify} /> : null}
        {area === "meals" ? <MealsView revision={revision} initialTab={initialMealsTab} financeEnabled={financeEnabled} onDataChanged={onDataChanged} notify={notify} /> : null}
        {area === "routines" ? <RoutinesView members={members} revision={revision} onDataChanged={onDataChanged} notify={notify} /> : null}
        {area === "renewals" ? <RenewalsView members={members} revision={revision} onDataChanged={onDataChanged} notify={notify} /> : null}
        {area === "prep" ? <PrepPacksView members={members} revision={revision} onDataChanged={onDataChanged} notify={notify} /> : null}
        </Suspense>
      </div>
    );
  }

  return (
    <div className="lists-page standard-page">
      <header className="page-header"><div><p className="page-eyebrow">Shared household tools</p><h1>Lists</h1></div></header>
      <section className="ios-list-section" aria-labelledby="get-things-done">
        <h2 id="get-things-done">Get things done</h2>
        <ListDestination title="Tasks" subtitle="Today, upcoming and household jobs" icon={ListTodo} tone="blue" onClick={() => open("tasks")} />
        <ListDestination title="Meals & Shopping" subtitle="Plan meals, shop and manage the pantry" icon={ForkKnife} tone="orange" onClick={() => open("meals")} />
      </section>
      <section className="ios-list-section" aria-labelledby="plan-ahead">
        <h2 id="plan-ahead">Plan ahead</h2>
        <ListDestination title="Routines & school dates" subtitle="Maintain recurring school and family commitments" icon={Repeat2} tone="green" onClick={() => open("routines")} />
        <ListDestination title="Packing lists" subtitle="Reusable checklists for swimming, trips and activities" icon={Backpack} tone="orange" onClick={() => open("prep")} />
      </section>
      <section className="ios-list-section" aria-labelledby="stay-ahead">
        <h2 id="stay-ahead">Stay ahead</h2>
        <ListDestination title="Renewals" subtitle="Passports, insurance and household dates" icon={BellRing} tone="purple" onClick={() => open("renewals")} />
      </section>
    </div>
  );
}

function ListDestination({ title, subtitle, icon: Icon, tone, onClick }: { title: string; subtitle: string; icon: typeof CheckSquare2; tone: string; onClick: () => void }) {
  return (
    <button type="button" className={`ios-list-row is-${tone}`} onClick={onClick}>
      <Icon aria-hidden="true" size={23} />
      <div><strong>{title}</strong><span>{subtitle}</span></div>
      <ChevronRight aria-hidden="true" size={18} />
    </button>
  );
}
