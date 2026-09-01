export type PrepPackTemplate = {
  id: string;
  name: string;
  match_terms: string[];
  items: string[];
  lead_hours: number;
  assigned_to?: string | null;
  enabled: boolean;
};

export type PrepPackSuggestion = {
  id: string;
  template_id: string;
  template_name: string;
  event_id: string;
  event_title: string;
  event_all_day: boolean;
  event_start: string;
  occurrence_start: string;
  items: string[];
  lead_hours: number;
  assigned_to?: string | null;
};

export function prepPackAction(suggestion: PrepPackSuggestion) {
  return {
    template_id: suggestion.template_id,
    event_id: suggestion.event_id,
    occurrence_start: suggestion.occurrence_start,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London",
  };
}
