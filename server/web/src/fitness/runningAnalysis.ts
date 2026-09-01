import type { FitnessAnalysisFinding, FitnessComparableRun, FitnessDataQualityFinding } from "./contract";

export function visibleRunningFindings(
  findings: FitnessAnalysisFinding[],
  qualityFindings: FitnessDataQualityFinding[],
): FitnessAnalysisFinding[] {
  const limitedKeys = new Set(qualityFindings.flatMap((finding) => finding.limits_analysis_keys ?? []));
  return findings.map((finding) => (
    limitedKeys.has(finding.key) && finding.status === "valid"
      ? { ...finding, status: "limited", quality: "limited_by_source_data" }
      : finding
  ));
}

export function orderedComparableRuns(comparables: FitnessComparableRun[]): FitnessComparableRun[] {
  return [...comparables].sort((left, right) => right.score - left.score || (
    right.activity.started_at_utc.localeCompare(left.activity.started_at_utc)
  ));
}

export function comparisonSelectionExplanation(comparables: FitnessComparableRun[]): string {
  const selected = orderedComparableRuns(comparables).filter((entry) => entry.selected !== false);
  if (!selected.length) return "Choose up to five previous runs to compare.";
  const reasons = [...new Set(selected.flatMap((entry) => entry.reasons))];
  return `Comparing with ${selected.length} similar run${selected.length === 1 ? "" : "s"}${reasons.length ? ` · ${reasons.slice(0, 2).join(" · ")}` : ""}.`;
}
