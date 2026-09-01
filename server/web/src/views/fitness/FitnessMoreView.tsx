import {
  Activity,
  ChevronRight,
  HeartPulse,
  Link2,
  MessageCircle,
  Scale,
  TrendingUp,
} from "lucide-react";

import type { FitnessViewProps } from "./FitnessModuleView";
import { FitnessPageHeading } from "./shared";

export function FitnessMoreView({ onSectionChange }: FitnessViewProps) {
  function openConnections() {
    const url = new URL(window.location.href);
    url.searchParams.set("intervals", "setup");
    window.history.replaceState(window.history.state, "", url);
    onSectionChange("training");
  }

  function openMeasurements() {
    const url = new URL(window.location.href);
    url.searchParams.set("fitness-progress", "measurements");
    window.history.replaceState(window.history.state, "", url);
    onSectionChange("progress");
  }

  const destinations = [
    { label: "Activities", detail: "Every completed run, ride and workout", icon: Activity, open: () => onSectionChange("activity") },
    { label: "Coach", detail: "Review your evidence and decide what comes next", icon: MessageCircle, open: () => onSectionChange("coach") },
    { label: "Recovery", detail: "Sleep, readiness and body issues", icon: HeartPulse, open: () => onSectionChange("recovery") },
    { label: "Body measurements", detail: "Weight, body composition and trends", icon: Scale, open: openMeasurements },
    { label: "Insights", detail: "Explore a focused question across your records", icon: TrendingUp, open: () => onSectionChange("explore") },
    { label: "Connections", detail: "Strava, Intervals.icu, Garmin and Withings", icon: Link2, open: openConnections },
  ];

  return <section aria-label="More Fitness tools" className="fitness-more">
    <FitnessPageHeading title="More" detail="History, coaching, recovery and connections when you need them." />
    <div className="fitness-more__grid">
      {destinations.map((destination) => {
        const Icon = destination.icon;
        return <button type="button" key={destination.label} onClick={destination.open}>
          <Icon aria-hidden="true" size={21} />
          <span><strong>{destination.label}</strong><small>{destination.detail}</small></span>
          <ChevronRight aria-hidden="true" size={18} />
        </button>;
      })}
    </div>
  </section>;
}
