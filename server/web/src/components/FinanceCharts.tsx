// Dependency-free, theme-aware inline-SVG chart primitives for the Finance
// module. Every chart is decorative (role="img" with a descriptive aria-label);
// the exact figures always remain available in an adjacent table or list, so
// the charts never become the only way to read a value. Colours come from CSS
// custom properties defined in styles.css (finance chart palette), so light and
// dark themes are handled by the stylesheet rather than hard-coded fills.

import type { FinanceLocale } from "../financeStrings";

function money(minor: number, currency: string, locale: FinanceLocale, signed = false) {
  const value = minor / 100;
  const formatted = new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
    maximumFractionDigits: Math.abs(value) >= 1000 ? 0 : 2,
  }).format(value);
  return signed && minor > 0 ? `+${formatted}` : formatted;
}

function percent(fraction: number, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "percent",
    maximumFractionDigits: 0,
  }).format(fraction);
}

/* -------------------------------------------------------------------------- */
/* Funding ring — a small donut for goal / reserve / commitment progress.      */
/* -------------------------------------------------------------------------- */

export function FundingRing({
  allocatedMinor,
  targetMinor,
  currency,
  locale,
  tone = "accent",
  size = 60,
}: {
  allocatedMinor: number;
  targetMinor: number | null;
  currency: string;
  locale: FinanceLocale;
  tone?: "accent" | "positive" | "warning" | "neutral";
  size?: number;
}) {
  const stroke = 6;
  const radius = (size - stroke) / 2;
  const circumference = 2 * Math.PI * radius;
  const fraction = targetMinor && targetMinor > 0
    ? Math.max(0, Math.min(1, allocatedMinor / targetMinor))
    : null;
  const label = fraction === null
    ? money(allocatedMinor, currency, locale)
    : `${percent(fraction, locale)} ${locale === "de" ? "finanziert" : "funded"}`;
  const centre = fraction === null ? "—" : percent(fraction, locale);
  return (
    <div className="finance-ring" role="img" aria-label={label}>
      <svg viewBox={`0 0 ${size} ${size}`} width={size} height={size} aria-hidden="true">
        <circle className="finance-ring-track" cx={size / 2} cy={size / 2} r={radius} strokeWidth={stroke} fill="none" />
        {fraction === null ? null : (
          <circle
            className={`finance-ring-value is-${tone}`}
            cx={size / 2}
            cy={size / 2}
            r={radius}
            strokeWidth={stroke}
            fill="none"
            strokeLinecap="round"
            strokeDasharray={circumference}
            strokeDashoffset={circumference * (1 - fraction)}
            transform={`rotate(-90 ${size / 2} ${size / 2})`}
          />
        )}
      </svg>
      <span className="finance-ring-centre">{centre}</span>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Composition bar — a horizontal stacked bar for net-worth layers.            */
/* -------------------------------------------------------------------------- */

export type CompositionSegment = { key: string; label: string; amountMinor: number };

export function CompositionBar({
  segments,
  currency,
  locale,
  emptyLabel,
}: {
  segments: CompositionSegment[];
  currency: string;
  locale: FinanceLocale;
  emptyLabel: string;
}) {
  const positive = segments.filter((segment) => segment.amountMinor > 0);
  const total = positive.reduce((sum, segment) => sum + segment.amountMinor, 0);
  if (!positive.length || total <= 0) {
    return <p className="finance-composition-empty">{emptyLabel}</p>;
  }
  const description = positive
    .map((segment) => `${segment.label} ${money(segment.amountMinor, currency, locale)}`)
    .join(", ");
  return (
    <div className="finance-composition">
      <div className="finance-composition-bar" role="img" aria-label={description}>
        {positive.map((segment, index) => (
          <span
            key={segment.key}
            className={`finance-composition-seg finance-series-${(index % 6) + 1}`}
            style={{ width: `${(segment.amountMinor / total) * 100}%` }}
          />
        ))}
      </div>
      <ul className="finance-composition-legend">
        {positive.map((segment, index) => (
          <li key={segment.key}>
            <span className={`finance-legend-swatch finance-series-${(index % 6) + 1}`} aria-hidden="true" />
            <span className="finance-legend-label">{segment.label}</span>
            <span className="finance-legend-value">{money(segment.amountMinor, currency, locale)}</span>
            <span className="finance-legend-share">{percent(segment.amountMinor / total, locale)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Outlook chart — a 90-day balance line with the lowest point + event pins.   */
/* -------------------------------------------------------------------------- */

export type OutlookPoint = { day: string; freeMinor: number; belowPlan: boolean };
export type OutlookEvent = { day: string; amountMinor: number; positive: boolean };

export function OutlookChart({
  points,
  floorMinor,
  minDate,
  events,
  currency,
  locale,
  lowestLabel,
  floorLabel,
  scenarioValues,
}: {
  points: OutlookPoint[];
  floorMinor: number;
  minDate: string;
  events: OutlookEvent[];
  currency: string;
  locale: FinanceLocale;
  lowestLabel: string;
  floorLabel: string;
  scenarioValues?: number[];
}) {
  if (points.length < 2) return null;
  const width = 720;
  const height = 220;
  const padX = 12;
  const padTop = 24;
  const padBottom = 28;
  const values = points.map((point) => point.freeMinor);
  const scenario = scenarioValues && scenarioValues.length === points.length ? scenarioValues : null;
  const domainMin = Math.min(floorMinor, ...values, ...(scenario ?? []));
  const domainMax = Math.max(floorMinor, ...values, ...(scenario ?? []));
  const span = domainMax - domainMin || 1;
  const x = (index: number) => padX + (index / (points.length - 1)) * (width - padX * 2);
  const y = (value: number) => padTop + (1 - (value - domainMin) / span) * (height - padTop - padBottom);
  const dayIndex = new Map(points.map((point, index) => [point.day, index]));

  const linePath = points.map((point, index) => `${index === 0 ? "M" : "L"} ${x(index).toFixed(1)} ${y(point.freeMinor).toFixed(1)}`).join(" ");
  const areaPath = `${linePath} L ${x(points.length - 1).toFixed(1)} ${(height - padBottom).toFixed(1)} L ${x(0).toFixed(1)} ${(height - padBottom).toFixed(1)} Z`;
  const scenarioPath = scenario
    ? scenario.map((value, index) => `${index === 0 ? "M" : "L"} ${x(index).toFixed(1)} ${y(value).toFixed(1)}`).join(" ")
    : null;
  const scenarioMinValue = scenario ? Math.min(...scenario) : null;
  const scenarioMinIndex = scenario ? scenario.indexOf(scenarioMinValue as number) : -1;

  const minIndex = dayIndex.get(minDate) ?? values.indexOf(Math.min(...values));
  const minValue = points[minIndex]?.freeMinor ?? Math.min(...values);
  const floorY = y(floorMinor);
  const label = `${lowestLabel}: ${money(minValue, currency, locale)}. ${floorLabel}: ${money(floorMinor, currency, locale)}.${scenarioMinValue !== null ? ` Scenario lowest: ${money(scenarioMinValue, currency, locale)}.` : ""}`;

  return (
    <svg
      className="finance-outlook-chart"
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="none"
      role="img"
      aria-label={label}
    >
      <path className="finance-outlook-area" d={areaPath} />
      <line className="finance-outlook-floor" x1={padX} x2={width - padX} y1={floorY} y2={floorY} />
      {scenarioPath ? <path className="finance-outlook-scenario" d={scenarioPath} fill="none" /> : null}
      {scenario && scenarioMinIndex >= 0 ? <circle className="finance-outlook-scenario-low" cx={x(scenarioMinIndex)} cy={y(scenario[scenarioMinIndex])} r={4} /> : null}
      <path className="finance-outlook-line" d={linePath} fill="none" />
      {events.map((event, index) => {
        const idx = dayIndex.get(event.day);
        if (idx === undefined) return null;
        return (
          <circle
            key={`${event.day}-${index}`}
            className={`finance-outlook-event ${event.positive ? "is-positive" : "is-negative"}`}
            cx={x(idx)}
            cy={height - padBottom}
            r={3}
          />
        );
      })}
      <circle className="finance-outlook-low" cx={x(minIndex)} cy={y(minValue)} r={5} />
      <text className="finance-outlook-low-label" x={x(minIndex)} y={Math.max(padTop - 8, y(minValue) - 12)} textAnchor="middle">
        {money(minValue, currency, locale)}
      </text>
    </svg>
  );
}

/* -------------------------------------------------------------------------- */
/* Waterfall — income / spending / net for the Explore overview.               */
/* -------------------------------------------------------------------------- */

export type WaterfallStep = { key: string; label: string; deltaMinor: number; isTotal?: boolean; totalMinor?: number };

export function Waterfall({
  steps,
  currency,
  locale,
}: {
  steps: WaterfallStep[];
  currency: string;
  locale: FinanceLocale;
}) {
  // Compute the running cumulative so each floating bar spans from the previous
  // total to the new one; total steps are drawn as a full bar from zero.
  let running = 0;
  const bars = steps.map((step) => {
    if (step.isTotal) {
      const top = step.totalMinor ?? running;
      return { ...step, from: 0, to: top };
    }
    const from = running;
    running += step.deltaMinor;
    return { ...step, from, to: running };
  });
  const extents = bars.flatMap((bar) => [bar.from, bar.to]);
  const domainMax = Math.max(0, ...extents);
  const domainMin = Math.min(0, ...extents);
  const span = domainMax - domainMin || 1;
  const height = 160;
  const zeroY = (1 - (0 - domainMin) / span) * height;
  const yFor = (value: number) => (1 - (value - domainMin) / span) * height;
  const label = steps
    .map((step) => `${step.label} ${money(step.isTotal ? (step.totalMinor ?? 0) : step.deltaMinor, currency, locale, !step.isTotal)}`)
    .join(", ");

  return (
    <div className="finance-waterfall" role="img" aria-label={label}>
      <div className="finance-waterfall-plot" style={{ height }}>
        <span className="finance-waterfall-zero" style={{ top: `${zeroY}px` }} aria-hidden="true" />
        {bars.map((bar) => {
          const top = Math.min(yFor(bar.from), yFor(bar.to));
          const barHeight = Math.max(2, Math.abs(yFor(bar.to) - yFor(bar.from)));
          const positive = bar.isTotal ? bar.to >= 0 : bar.deltaMinor >= 0;
          const tone = bar.isTotal ? "is-total" : positive ? "is-positive" : "is-negative";
          return (
            <span
              key={bar.key}
              className={`finance-waterfall-bar ${tone}`}
              style={{ top: `${top}px`, height: `${barHeight}px` }}
            />
          );
        })}
      </div>
      <ul className="finance-waterfall-labels">
        {bars.map((bar) => (
          <li key={bar.key}>
            <span className="finance-waterfall-caption">{bar.label}</span>
            <span className={`finance-waterfall-amount ${bar.isTotal ? "is-total" : bar.deltaMinor >= 0 ? "is-positive" : "is-negative"}`}>
              {money(bar.isTotal ? (bar.totalMinor ?? 0) : bar.deltaMinor, currency, locale, !bar.isTotal)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Health gauge — a semicircular arc for the "spending room" status on Today.  */
/* -------------------------------------------------------------------------- */

const HEALTH_FRACTION: Record<string, number> = {
  ON_PLAN: 1,
  WATCH: 0.55,
  OFF_PLAN: 0.2,
  UNKNOWN: 0,
};

export function HealthGauge({
  status,
  headline,
  caption,
  tone,
}: {
  status: keyof typeof HEALTH_FRACTION | string;
  headline: string;
  caption?: string;
  tone: "positive" | "warning" | "critical" | "neutral";
}) {
  const fraction = HEALTH_FRACTION[status] ?? 0;
  const radius = 52;
  const circumference = Math.PI * radius; // semicircle
  return (
    <div className={`finance-gauge is-${tone}`} role="img" aria-label={`${headline}${caption ? `. ${caption}` : ""}`}>
      <svg viewBox="0 0 120 68" width="120" height="68" aria-hidden="true">
        <path className="finance-gauge-track" d="M 8 60 A 52 52 0 0 1 112 60" fill="none" strokeWidth="8" strokeLinecap="round" />
        <path
          className="finance-gauge-value"
          d="M 8 60 A 52 52 0 0 1 112 60"
          fill="none"
          strokeWidth="8"
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - fraction)}
        />
      </svg>
      <div className="finance-gauge-readout">
        <strong>{headline}</strong>
        {caption ? <small>{caption}</small> : null}
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Generic series types for the analysis chart-type switch.                    */
/* -------------------------------------------------------------------------- */

export type SeriesPoint = { key: string; label: string; value: number; display: string };

/* Line chart — best for time-ordered groupings (day / week / month).          */
export function SeriesLine({
  series,
  comparison,
  ariaLabel,
}: {
  series: SeriesPoint[];
  comparison?: SeriesPoint[];
  ariaLabel: string;
}) {
  if (series.length < 2) return null;
  const width = 720;
  const height = 240;
  const padX = 12;
  const padTop = 18;
  const padBottom = 34;
  const all = [...series.map((point) => point.value), ...(comparison?.map((point) => point.value) ?? []), 0];
  const domainMin = Math.min(...all);
  const domainMax = Math.max(...all);
  const span = domainMax - domainMin || 1;
  const x = (index: number, length: number) => padX + (length <= 1 ? 0 : (index / (length - 1)) * (width - padX * 2));
  const y = (value: number) => padTop + (1 - (value - domainMin) / span) * (height - padTop - padBottom);
  const path = (points: SeriesPoint[]) =>
    points.map((point, index) => `${index === 0 ? "M" : "L"} ${x(index, points.length).toFixed(1)} ${y(point.value).toFixed(1)}`).join(" ");
  const zeroY = y(0);
  return (
    <svg className="finance-series-chart" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img" aria-label={ariaLabel}>
      {domainMin < 0 && domainMax > 0 ? <line className="finance-series-zero" x1={padX} x2={width - padX} y1={zeroY} y2={zeroY} /> : null}
      {comparison && comparison.length > 1 ? <path className="finance-series-line is-earlier" d={path(comparison)} fill="none" /> : null}
      <path className="finance-series-line is-current" d={path(series)} fill="none" />
      {series.map((point, index) => (
        <circle key={point.key} className="finance-series-dot" cx={x(index, series.length)} cy={y(point.value)} r={3} />
      ))}
    </svg>
  );
}

/* Donut — best for share-of-total groupings (category / merchant).            */
export function Donut({
  series,
  ariaLabel,
  locale,
}: {
  series: SeriesPoint[];
  ariaLabel: string;
  locale: FinanceLocale;
}) {
  const positive = series.filter((point) => point.value > 0);
  const total = positive.reduce((sum, point) => sum + point.value, 0);
  if (!positive.length || total <= 0) return null;
  const size = 180;
  const radius = 70;
  const centre = size / 2;
  const circumference = 2 * Math.PI * radius;
  let offset = 0;
  const arcs = positive.map((point, index) => {
    const fraction = point.value / total;
    const arc = { point, index, fraction, dash: fraction * circumference, offset };
    offset += fraction * circumference;
    return arc;
  });
  return (
    <div className="finance-donut">
      <svg viewBox={`0 0 ${size} ${size}`} width={size} height={size} role="img" aria-label={ariaLabel}>
        {arcs.map((arc) => (
          <circle
            key={arc.point.key}
            className={`finance-donut-seg finance-series-${(arc.index % 6) + 1}`}
            cx={centre}
            cy={centre}
            r={radius}
            fill="none"
            strokeWidth={22}
            strokeDasharray={`${arc.dash} ${circumference - arc.dash}`}
            strokeDashoffset={-arc.offset}
            transform={`rotate(-90 ${centre} ${centre})`}
          />
        ))}
      </svg>
      <ul className="finance-donut-legend">
        {arcs.map((arc) => (
          <li key={arc.point.key}>
            <span className={`finance-legend-swatch finance-series-${(arc.index % 6) + 1}`} aria-hidden="true" />
            <span className="finance-legend-label">{arc.point.label}</span>
            <span className="finance-legend-value">{arc.point.display}</span>
            <span className="finance-legend-share">{percent(arc.fraction, locale)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
