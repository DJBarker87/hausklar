export type TaskRepeatOption = "never" | "daily" | "weekly" | "monthly" | "yearly";

const weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] as const;

export function taskRepeatOption(rule?: string | null): TaskRepeatOption {
  const frequency = rule
    ?.match(/(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i)?.[1]
    ?.toLowerCase();
  if (frequency === "daily" || frequency === "weekly" || frequency === "monthly" || frequency === "yearly") {
    return frequency;
  }
  return "never";
}

export function taskRecurrenceRule(option: TaskRepeatOption, dueDate: Date): string | null {
  if (option === "daily") return "FREQ=DAILY";
  if (option === "weekly") return `FREQ=WEEKLY;BYDAY=${weekdayCodes[dueDate.getDay()]}`;
  if (option === "monthly") return "FREQ=MONTHLY";
  if (option === "yearly") return "FREQ=YEARLY";
  return null;
}

export function taskRecurrenceLabel(rule?: string | null): string | null {
  const labels: Record<TaskRepeatOption, string | null> = {
    never: null,
    daily: "Every day",
    weekly: "Every week",
    monthly: "Every month",
    yearly: "Every year",
  };
  return labels[taskRepeatOption(rule)];
}
