import { MessageCircleMore, MessageSquareText, Plus, PlusCircle, Search, X } from "lucide-react";
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";

import { cn } from "./ui";

export function ActionRail({
  placement,
  onCapture,
  onAdd,
  onSearch,
  context = "default",
  onFitnessLog,
  onFitnessCoach,
}: {
  placement: "sidebar" | "mobile";
  onCapture: (trigger: HTMLButtonElement) => void;
  onAdd: (trigger: HTMLButtonElement) => void;
  onSearch: (trigger: HTMLButtonElement) => void;
  context?: "default" | "fitness";
  onFitnessLog?: (trigger: HTMLButtonElement) => void;
  onFitnessCoach?: (trigger: HTMLButtonElement) => void;
}) {
  const [open, setOpen] = useState(false);
  const layerID = useId();
  const titleID = `${layerID}-title`;
  const firstDetailID = `${layerID}-first-detail`;
  const secondDetailID = `${layerID}-second-detail`;
  const rootRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const firstActionRef = useRef<HTMLButtonElement | null>(null);
  const fitness = context === "fitness";

  useEffect(() => {
    if (!fitness) {
      if (open) setOpen(false);
      return;
    }
    if (!open) return;
    firstActionRef.current?.focus();

    const dismissOutside = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", dismissOutside);
    return () => document.removeEventListener("pointerdown", dismissOutside);
  }, [fitness, open]);

  if (!fitness) {
    return (
      <section className={cn("app-action-rail", `app-action-rail--${placement}`)} aria-label="Quick actions">
        <div className="app-action-entry" role="group" aria-label="Quick actions">
          <button
            type="button"
            className="app-action-launcher"
            onClick={(event) => onCapture(event.currentTarget)}
          >
            <MessageSquareText aria-hidden="true" size={19} />
            <span>Tell HausKlar…</span>
          </button>
          <button
            type="button"
            className="app-action-shortcut"
            aria-label="Add directly"
            title="Add directly"
            onClick={(event) => onAdd(event.currentTarget)}
          >
            <Plus aria-hidden="true" size={20} />
          </button>
          {placement === "sidebar" ? <button
            type="button"
            className="app-action-shortcut"
            aria-label="Find anything"
            title="Find anything"
            onClick={(event) => onSearch(event.currentTarget)}
          >
            <Search aria-hidden="true" size={19} />
          </button> : null}
        </div>
      </section>
    );
  }

  function closeAndRestoreFocus() {
    setOpen(false);
    triggerRef.current?.focus();
  }

  function choose(action: (trigger: HTMLButtonElement) => void, fallback: HTMLButtonElement) {
    setOpen(false);
    action(triggerRef.current ?? fallback);
  }

  function handleLayerKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      closeAndRestoreFocus();
      return;
    }
    if (event.key !== "Tab") return;

    const buttons = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)"));
    const first = buttons[0];
    const last = buttons.at(-1);
    if (!first || !last) return;
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  return (
    <section ref={rootRef} className={cn("app-action-rail", `app-action-rail--${placement}`)} aria-label="Fitness quick actions">
      <button
        ref={triggerRef}
        type="button"
        className="app-action-launcher"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? layerID : undefined}
        onClick={() => setOpen((current) => !current)}
      >
        <PlusCircle aria-hidden="true" size={19} />
        <span>Log or ask Coach</span>
      </button>

      {open ? (
        <div
          id={layerID}
          className="app-action-layer"
          role="dialog"
          aria-modal="false"
          aria-labelledby={titleID}
          onKeyDown={handleLayerKeyDown}
        >
          <div className="app-action-layer-heading">
            <div>
              <strong id={titleID}>Fitness quick actions</strong>
              <span>Log something or talk it through.</span>
            </div>
            <button type="button" className="icon-button" aria-label="Close quick actions" onClick={closeAndRestoreFocus}>
              <X aria-hidden="true" size={19} />
            </button>
          </div>
          <div className="app-action-layer-actions">
            <button
              ref={firstActionRef}
              type="button"
              className="app-action-choice is-add"
              aria-label="Log"
              aria-describedby={firstDetailID}
              onClick={(event) => onFitnessLog && choose(onFitnessLog, event.currentTarget)}
            >
              <Plus aria-hidden="true" size={19} />
              <span><strong>Log</strong><small id={firstDetailID}>Food and other fitness records</small></span>
            </button>
            <button
              type="button"
              className="app-action-choice"
              aria-label="Coach"
              aria-describedby={secondDetailID}
              onClick={(event) => onFitnessCoach && choose(onFitnessCoach, event.currentTarget)}
            >
              <MessageCircleMore aria-hidden="true" size={19} />
              <span><strong>Coach</strong><small id={secondDetailID}>Ask about your training</small></span>
            </button>
          </div>
        </div>
      ) : null}
    </section>
  );
}
