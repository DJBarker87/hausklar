export type FacilityTimeWindow = { start: string; end: string };

export type FacilityDaySummary = {
  date: string;
  covered: boolean;
  family_swimming: FacilityTimeWindow[];
  lane_swimming: FacilityTimeWindow[];
  weights_room: FacilityTimeWindow[];
  pool_closed: boolean;
  weights_room_status: "open" | "closed" | "unknown" | "not_relevant";
  weights_relevant: boolean;
};

export type FacilityQuickFact = {
  provider: "Example School College";
  source_title: string | null;
  source_document_id: string | null;
  current_from: string | null;
  current_to: string | null;
  update_due: boolean;
  today: FacilityDaySummary;
  tomorrow: FacilityDaySummary;
};

export type FacilityCalendarPreferences = {
  show_family_swimming: boolean;
  show_personal_facilities: boolean;
};

export type FacilityCalendarLayerItem = {
  id: string;
  layer_kind: "family_swimming" | "lane_swimming" | "weights_room";
  display_title: string;
  start_time: string;
  end_time: string;
  owner_user_id: string | null;
  source_document_id: string | null;
  source_title: string;
  location: string;
  read_only: true;
};

export type FacilityImportCounts = {
  days: number;
  family_swimming_sessions: number;
  lane_swimming_sessions: number;
  weights_room_open_days: number;
  pool_closed_days: number;
  weights_room_closed_days: number;
};

export type FacilityImportPreview = {
  filename: string;
  title: string;
  sha256: string;
  valid_from: string;
  valid_to: string;
  counts: FacilityImportCounts;
  changes: { added_days: number; changed_days: number; removed_days: number };
  sample_days: FacilityDaySummary[];
  issues: string[];
  already_imported: boolean;
  can_confirm: boolean;
};

export type FacilityImportResult = {
  version_id: string;
  document_id: string | null;
  imported: boolean;
  preview: FacilityImportPreview;
};

export function facilityWindowLabel(windows: FacilityTimeWindow[]): string {
  return windows.map((window) => `${window.start}–${window.end}`).join(", ");
}

export function familySwimmingLabel(day: FacilityDaySummary): string {
  if (day.family_swimming.length) return `Family swim ${facilityWindowLabel(day.family_swimming)}`;
  if (day.pool_closed) return "Pool closed";
  return "No family swimming";
}

export function weightsRoomLabel(day: FacilityDaySummary): string | null {
  if (!day.weights_relevant) return null;
  if (day.weights_room.length) return `Weights ${facilityWindowLabel(day.weights_room)}`;
  if (day.weights_room_status === "closed") return "Weights closed";
  return "Weights times unavailable";
}
