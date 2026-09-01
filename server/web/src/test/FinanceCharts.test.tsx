import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import {
  CompositionBar,
  Donut,
  FundingRing,
  HealthGauge,
  OutlookChart,
  SeriesLine,
  Waterfall,
  type OutlookPoint,
  type SeriesPoint,
} from "../components/FinanceCharts";

const SERIES: SeriesPoint[] = [
  { key: "jul", label: "July", value: 120_000, display: "£1,200" },
  { key: "aug", label: "August", value: 90_000, display: "£900" },
  { key: "sep", label: "September", value: 150_000, display: "£1,500" },
];

describe("Finance charts", () => {
  it("funding ring shows the funded percentage and an accessible label", () => {
    render(<FundingRing allocatedMinor={12_000} targetMinor={48_000} currency="GBP" locale="en" />);
    const ring = screen.getByRole("img", { name: /25%\s+funded/i });
    expect(ring).toBeInTheDocument();
    expect(ring.querySelector("circle.finance-ring-value")).not.toBeNull();
    expect(screen.getByText("25%")).toBeInTheDocument();
  });

  it("funding ring degrades to the amount when there is no target", () => {
    render(<FundingRing allocatedMinor={5_000} targetMinor={null} currency="GBP" locale="en" />);
    // No target => no value arc, and the centre falls back to a dash.
    expect(document.querySelector("circle.finance-ring-value")).toBeNull();
    expect(screen.getByText("—")).toBeInTheDocument();
  });

  it("composition bar renders one segment per positive layer and skips zero layers", () => {
    render(
      <CompositionBar
        currency="GBP"
        locale="en"
        emptyLabel="Nothing yet"
        segments={[
          { key: "cash", label: "Operating cash", amountMinor: 90_000 },
          { key: "isa", label: "Brokerage", amountMinor: 30_000 },
          { key: "empty", label: "Pension", amountMinor: 0 },
        ]}
      />,
    );
    expect(document.querySelectorAll(".finance-composition-seg")).toHaveLength(2);
    expect(screen.getByText("Operating cash")).toBeInTheDocument();
    expect(screen.getByText("75%")).toBeInTheDocument(); // 90k of 120k
    expect(screen.queryByText("Pension")).not.toBeInTheDocument();
  });

  it("composition bar shows the empty label when every layer is zero", () => {
    render(
      <CompositionBar currency="GBP" locale="en" emptyLabel="Nothing yet" segments={[{ key: "x", label: "X", amountMinor: 0 }]} />,
    );
    expect(screen.getByText("Nothing yet")).toBeInTheDocument();
  });

  it("outlook chart plots the balance line, marks the lowest point and pins events", () => {
    const points: OutlookPoint[] = [
      { day: "2026-08-01", freeMinor: 120_000, belowPlan: false },
      { day: "2026-08-02", freeMinor: 40_000, belowPlan: false },
      { day: "2026-08-03", freeMinor: 15_000, belowPlan: true },
      { day: "2026-08-04", freeMinor: 90_000, belowPlan: false },
    ];
    render(
      <OutlookChart
        points={points}
        floorMinor={10_000}
        minDate="2026-08-03"
        events={[{ day: "2026-08-03", amountMinor: -48_000, positive: false }]}
        currency="GBP"
        locale="en"
        lowestLabel="Lowest free cash"
        floorLabel="Protected hold"
      />,
    );
    const chart = screen.getByRole("img", { name: /Lowest free cash: £150\.00/ });
    expect(chart).toBeInTheDocument();
    expect(chart.querySelector("path.finance-outlook-line")).not.toBeNull();
    expect(chart.querySelector("path.finance-outlook-area")).not.toBeNull();
    expect(chart.querySelector("line.finance-outlook-floor")).not.toBeNull();
    expect(chart.querySelector("circle.finance-outlook-low")).not.toBeNull();
    expect(chart.querySelector("circle.finance-outlook-event.is-negative")).not.toBeNull();
  });

  it("outlook chart renders nothing for a single point", () => {
    const { container } = render(
      <OutlookChart
        points={[{ day: "2026-08-01", freeMinor: 100, belowPlan: false }]}
        floorMinor={0}
        minDate="2026-08-01"
        events={[]}
        currency="GBP"
        locale="en"
        lowestLabel="Low"
        floorLabel="Floor"
      />,
    );
    expect(container.querySelector("svg")).toBeNull();
  });

  it("waterfall draws a bar per step plus a total and labels each", () => {
    render(
      <Waterfall
        currency="GBP"
        locale="en"
        steps={[
          { key: "income", label: "Income", deltaMinor: 360_000 },
          { key: "spend", label: "Spending", deltaMinor: -174_800 },
          { key: "net", label: "Net", deltaMinor: 0, isTotal: true, totalMinor: 187_000 },
        ]}
      />,
    );
    expect(screen.getByRole("img", { name: /Income .* Spending .* Net/ })).toBeInTheDocument();
    expect(document.querySelector(".finance-waterfall-bar.is-positive")).not.toBeNull();
    expect(document.querySelector(".finance-waterfall-bar.is-negative")).not.toBeNull();
    expect(document.querySelector(".finance-waterfall-bar.is-total")).not.toBeNull();
  });

  it("series line draws current and comparison paths with a dot per point", () => {
    render(<SeriesLine series={SERIES} comparison={SERIES} ariaLabel="Spending over time" />);
    const chart = screen.getByRole("img", { name: "Spending over time" });
    expect(chart.querySelector("path.finance-series-line.is-current")).not.toBeNull();
    expect(chart.querySelector("path.finance-series-line.is-earlier")).not.toBeNull();
    expect(chart.querySelectorAll("circle.finance-series-dot")).toHaveLength(3);
  });

  it("series line renders nothing for a single point", () => {
    const { container } = render(<SeriesLine series={SERIES.slice(0, 1)} ariaLabel="x" />);
    expect(container.querySelector("svg")).toBeNull();
  });

  it("donut draws one arc per positive slice with a share legend", () => {
    render(<Donut series={SERIES} locale="en" ariaLabel="Spending by category" />);
    expect(screen.getByRole("img", { name: "Spending by category" })).toBeInTheDocument();
    expect(document.querySelectorAll("circle.finance-donut-seg")).toHaveLength(3);
    // 90k of 360k total ≈ 25%.
    expect(screen.getByText("25%")).toBeInTheDocument();
    expect(screen.getByText("July")).toBeInTheDocument();
  });

  it("health gauge fills fully when on plan and exposes the headline", () => {
    render(<HealthGauge status="ON_PLAN" tone="positive" headline="£3,780.00" caption="Spending room" />);
    const gauge = screen.getByRole("img", { name: /£3,780\.00\. Spending room/ });
    const value = gauge.querySelector("path.finance-gauge-value") as SVGPathElement | null;
    expect(value).not.toBeNull();
    // ON_PLAN => fraction 1 => zero dash offset.
    expect(value?.getAttribute("stroke-dashoffset")).toBe("0");
    expect(screen.getByText("£3,780.00")).toBeInTheDocument();
  });
});
