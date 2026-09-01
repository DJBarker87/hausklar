import {
  CalendarPlus,
  ClipboardCheck,
  ClipboardList,
  FileUp,
  ListPlus,
  MoonStar,
  Pill,
  ShoppingCart,
} from "lucide-react";

import { Modal } from "./ui";

export type AddHubDestination =
  | "event"
  | "task"
  | "shopping"
  | "medicine"
  | "nap"
  | "document"
  | "capture"
  | "commitment";

const choices: Array<{
  id: AddHubDestination;
  label: string;
  detail: string;
  icon: typeof CalendarPlus;
}> = [
  { id: "event", label: "Event", detail: "Add a date or appointment", icon: CalendarPlus },
  { id: "task", label: "Task", detail: "Add something that needs doing", icon: ListPlus },
  { id: "shopping", label: "Shopping item", detail: "Add to the shared shopping list", icon: ShoppingCart },
  { id: "medicine", label: "Record medicine", detail: "Log a dose time and compare your saved limits", icon: Pill },
  { id: "nap", label: "Sleep & naps", detail: "Open the children's sleep controls", icon: MoonStar },
  { id: "document", label: "Letter or file", detail: "Scan or file family paperwork", icon: FileUp },
  { id: "commitment", label: "Plan from message", detail: "Turn a message or booking into one reviewed family plan", icon: ClipboardCheck },
  { id: "capture", label: "Several events or tasks", detail: "Paste a message and review every draft", icon: ClipboardList },
];

export function AddHub({
  open,
  onOpenChange,
  onChoose,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChoose: (destination: AddHubDestination) => void;
}) {
  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title="Add to HausKlar"
      description="Choose the quickest route. You will review anything sensitive before it is saved."
      size="wide"
    >
      <div className="add-hub-grid">
        {choices.map((choice) => {
          const Icon = choice.icon;
          return (
            <button
              type="button"
              className="add-hub-choice"
              key={choice.id}
              onClick={() => onChoose(choice.id)}
            >
              <span className="add-hub-icon"><Icon aria-hidden="true" size={21} /></span>
              <span><strong>{choice.label}</strong><small>{choice.detail}</small></span>
            </button>
          );
        })}
      </div>
    </Modal>
  );
}
