import { expect, test, type Page, type TestInfo } from "@playwright/test";

function localDate(daysFromToday = 0) {
  const date = new Date();
  date.setDate(date.getDate() + daysFromToday);
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

const today = localDate();
const weekEnd = localDate(6);

function onboardingComplete() {
  return {
    id: "setup-1", status: "complete", main_outcome: "run_consistently", availability: [], activities: ["running", "strength"], equipment: [],
    food_preferences: [], source_connections: [], coach_style: "direct", use_family_calendar: true,
    use_household_meals: true, use_weather: false, memory_enabled: false, preview: null, confirmation: null,
  };
}

async function mockWave4(page: Page) {
  const requests: string[] = [];
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    requests.push(`${request.method()} ${path}${url.search}`);
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/onboarding") {
      body = onboardingComplete();
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/fitness/sync") {
      body = { status: "ok", current_sync_protocol_version: 1, current_client_schema_version: 1, minimum_supported_client_schema_version: 1, accepted: [], acked_mutation_ids: [], rejected_mutations: [], changes: [], redirects: [], notices: [], next_cursor: 1 };
    } else if (path === "/api/fitness/planned-sessions") {
      body = [{ id: "session-run", revision: 3, title: "Riverside easy run", sport_key: "running", status: "accepted", scheduled_date: today, scheduled_start_utc: `${today}T17:30:00Z`, expected_duration_s: 2_700, movable: true, training_programme_id: "programme-base" }];
    } else if (path === "/api/fitness/training-programmes") {
      body = [{ id: "programme-base", name: "Autumn base", purpose: "Build a calm, durable running habit", starts_on: "2026-07-20", ends_on: "2026-09-13", status: "active" }];
    } else if (path === "/api/fitness/integrations/strava/status") {
      body = { configured: false, connected: false, status: "not_configured", imported_activity_count: 0 };
    } else if (path === "/api/fitness/goals") {
      body = [{ id: "goal-run", name: "Run 20 km each week", goal_type: "running", metric_key: "running.distance_m", starts_on: "2026-07-01", target_value: 20_000, unit_key: "m", status: "active" }];
    } else if (path === "/api/fitness/weekly-review") {
      body = {
        week_start: today, week_end: weekEnd,
        totals: { completed_sessions: 2, active_days: 2, duration_minutes: 83, distance_km: 12.4 },
        goal: { goal_id: "goal-run", goal_name: "Run 20 km each week", progress_text: "12.4 of 20 km", progress_percent: 62 },
        highlight: { title: "A useful week", detail: "Two planned runs became completed activity." },
        opportunity: { title: "Place the next run", detail: "Choose a day that fits the family calendar.", destination: "plan", action: "plan_session", action_label: "Plan the next run" },
      };
    } else if (path === "/api/fitness/activities") {
      body = [
        { id: "activity-2", title: "Park run", sport_key: "running", started_at_utc: `${today}T07:00:00Z`, status: "completed", distance_m: 5_000, duration_s: 1_700 },
        { id: "activity-1", title: "Riverside run", sport_key: "running", started_at_utc: `${today}T06:00:00Z`, status: "complete", distance_m: 7_400, duration_s: 2_300 },
        { id: "activity-pending", title: "Half imported activity", sport_key: "running", started_at_utc: `${today}T05:00:00Z`, status: "importing", distance_m: 99_000, duration_s: 9_000 },
      ];
    } else if (path === "/api/fitness/progress/charts") {
      body = {
        weight: [],
        running: [{
          key: "5k", label: "5K", distance_m: 5_000,
          points: [
            { activity_id: "run-old", started_at_utc: `${localDate(-14)}T07:00:00Z`, duration_s: 1_800, source: "best_effort" },
            { activity_id: "activity-2", started_at_utc: `${localDate(-4)}T07:00:00Z`, duration_s: 1_700, source: "best_effort" },
          ],
        }],
        strength: [{
          key: "squat", label: "Squat", exercise_id: "squat", exercise_name: "Barbell Back Squat",
          setup_id: "rack", setup_name: "Home rack", points: [
            { activity_id: "lift-old", performed_at_utc: `${localDate(-14)}T18:00:00Z`, load_kg: 80, repetitions: 6, working_set_count: 3 },
            { activity_id: "lift-new", performed_at_utc: `${localDate(-3)}T18:00:00Z`, load_kg: 85, repetitions: 6, working_set_count: 3 },
          ],
        }],
      };
    } else if (path === "/api/fitness/body/measurements") {
      body = [
        { id: "weight-old", metric_key: "body.weight_kg", value: 78.4, unit_key: "kg", measured_at_utc: `${localDate(-28)}T07:00:00Z` },
        { id: "weight-middle", metric_key: "body.weight_kg", value: 77.8, unit_key: "kg", measured_at_utc: `${localDate(-14)}T07:00:00Z` },
        { id: "weight-latest", metric_key: "body.weight_kg", value: 77.2, unit_key: "kg", measured_at_utc: `${localDate(-2)}T07:00:00Z` },
      ];
    } else if (path === "/api/fitness/measurements/history") {
      body = {
        metric: "weight",
        title: "Weight",
        unit: "kg",
        smoothing_method: "time_weighted_exponential",
        smoothing_half_life_days: 7,
        sample_count: 3,
        series: [{
          key: "weight",
          label: "Weight",
          unit: "kg",
          points: [
            { id: "weight-old", measured_at_utc: `${localDate(-28)}T07:00:00Z`, raw_value: 78.4, trend_value: 78.2 },
            { id: "weight-middle", measured_at_utc: `${localDate(-14)}T07:00:00Z`, raw_value: 77.8, trend_value: 77.9 },
            { id: "weight-latest", measured_at_utc: `${localDate(-2)}T07:00:00Z`, raw_value: 77.2, trend_value: 77.5 },
          ],
        }],
      };
    } else if (path === "/api/fitness/integrations/withings/status") {
      body = { configured: false, connected: false, status: "not_configured" };
    } else if (path === "/api/fitness/sleep/sessions") {
      body = [
        { id: "sleep-3", sleep_start_utc: "2026-08-01T22:15:00Z", sleep_end_utc: "2026-08-02T06:20:00Z", duration_s: 29_100, source_quality: "wearable", source_stages: [], source: { origin_provider_key: "apple", transport_key: "healthkit", source_name: "Apple Watch", state: "active" } },
        { id: "sleep-2", sleep_start_utc: "2026-07-31T22:30:00Z", sleep_end_utc: "2026-08-01T06:10:00Z", duration_s: 27_600, source_quality: "wearable", source_stages: [], source: { origin_provider_key: "apple", transport_key: "healthkit", source_name: "Apple Watch", state: "active" } },
        { id: "sleep-1", sleep_start_utc: "2026-07-30T22:05:00Z", sleep_end_utc: "2026-07-31T06:00:00Z", duration_s: 28_500, source_quality: "manual", source_stages: [], source: null },
      ];
    } else if (path === "/api/fitness/recovery/summary") {
      body = { window: { from_date: "2026-07-07", to_date: today, expected_days: 28, days_with_sleep: 23 }, sleep: { average_duration_s: 27_540, average_bedtime_minutes: 1_335, average_wake_time_minutes: 385, timing_regularity_minutes: 24 }, baselines: [{ metric_key: "recovery.hrv_rmssd_ms", label: "Heart-rate variability", current_value: 46, unit_key: "ms", status: "within_baseline", window_days: 28 }], relationships: [] };
    } else if (path === "/api/fitness/recovery/observations" || path === "/api/fitness/body-issues" || path === "/api/fitness/body-locations") {
      body = [];
    } else if (path === "/api/fitness/analysis/registry") {
      body = {
        dimensions: [{ key: "week", label: "Week", value_type: "date" }],
        measures: [{ key: "running.comparable_pace", label: "Running pace", unit_key: "s_per_km", supported_dimensions: ["week"], chart_types: ["line"], allowed_filter_keys: [], comparison_forms: [], default_chart_type: "line", classification: "descriptive", minimum_sample_size: 2 }],
        chart_types: [{ key: "line", label: "Line" }], filters: [], comparisons: [], limits: { max_window_days: 366, max_output_points: 200, max_filters: 4 },
        default_queries: [{ key: "running-progress", label: "Running progress", description: "Comparable runs over time", dimension_key: "week", measure_key: "running.comparable_pace", chart_type_key: "line", date_window_days: 84, surface: "both", category: "running" }],
      };
    } else if (path === "/api/fitness/analysis/query") {
      body = { status: "complete", title: "Running pace", summary: "Your recent runs became a little quicker.", dimension_key: "week", measure_key: "running.comparable_pace", chart_type_key: "line", unit_key: "s_per_km", series: [{ key: "pace", label: "Pace", points: [{ key: "one", label: "Week one", value: 315 }, { key: "two", label: "Week two", value: 304 }] }], metadata: { period: { start: "2026-07-07", end: today }, sample_size: 5, missing_rate: 0, source_quality: [], measurement_quality: [], classification: "descriptive" }, limitations: [] };
    } else if (path === "/api/fitness/analysis/charts") {
      body = [];
    } else if (path === "/api/fitness/overview") {
      body = { date: today, session: null, primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null }, secondary_action: null, quick_actions: [], coach_nudge: null, safety_adjustment: null };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
  return requests;
}

async function expectNoOverflow(page: Page) {
  const widths = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth, body: document.body.scrollWidth }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
  expect(widths.body, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

async function expectUsefulTargets(page: Page) {
  const undersized = await page.locator(".fitness-module__content > section button:visible").evaluateAll((buttons) => buttons.flatMap((button) => {
    const box = button.getBoundingClientRect();
    return box.height < 39.5 ? [{ label: button.textContent?.trim(), width: box.width, height: box.height }] : [];
  }));
  expect(undersized).toEqual([]);
}

async function screenshot(page: Page, testInfo: TestInfo, path: string) {
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await page.waitForTimeout(300);
  await page.screenshot({ path: testInfo.outputPath(path), fullPage: false });
}

const forbiddenNormalCopy = /\b(canonical|unknown hardness|e1rm|sync(?:ed|ing)?|stale|provider|model|confidence|evidence|validation)\b|source priority/i;

for (const viewport of [
  { name: "phone", width: 375, height: 812 },
  { name: "tablet", width: 768, height: 1024 },
  { name: "desktop", width: 1280, height: 900 },
]) {
  test(`Wave 4 Plan, Progress, Recovery and Insights at ${viewport.width}px`, async ({ page }, testInfo) => {
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await page.emulateMedia({ colorScheme: viewport.name === "desktop" ? "dark" : "light", reducedMotion: viewport.name === "tablet" ? "reduce" : "no-preference" });
    const requests = await mockWave4(page);
    await page.addInitScript(() => localStorage.removeItem("hausklar-theme"));

    let requestStart = requests.length;
    await page.goto("/?view=fitness&section=training");
    await expect(page.getByRole("heading", { name: "Sessions", exact: true })).toBeVisible();
    await expect(page.getByText("Riverside easy run", { exact: true }).first()).toBeVisible();
    const launcher = page.getByRole("heading", { name: "What do you want to do?" }).locator("xpath=ancestor::section[1]");
    const next = page.getByText("Up next", { exact: true }).locator("xpath=ancestor::section[1]");
    const week = page.getByRole("region", { name: "Seven days at a glance" });
    const programmes = page.getByRole("region", { name: "The longer view" });
    expect(await launcher.evaluate((element, following) => Boolean(element.compareDocumentPosition(following as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await next.elementHandle())).toBe(true);
    expect(await next.evaluate((element, following) => Boolean(element.compareDocumentPosition(following as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await week.elementHandle())).toBe(true);
    expect(await week.evaluate((element, following) => Boolean(element.compareDocumentPosition(following as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await programmes.elementHandle())).toBe(true);
    await expect(next.getByRole("button", { name: "Open" })).toBeVisible();
    await expect(next.getByRole("button", { name: "Move" })).toBeVisible();
    await expect(page.getByText("Running plans")).toBeVisible();
    const planRequests = requests.slice(requestStart);
    expect(planRequests.some((request) => request.includes("/api/fitness/goal-templates") || request.includes("/api/fitness/gear") || request.includes("/api/fitness/exercises"))).toBe(false);
    await expect(page.locator("body")).not.toContainText(forbiddenNormalCopy);
    await expectNoOverflow(page);
    await expectUsefulTargets(page);
    await page.getByRole("button", { name: "Run", exact: true }).click();
    await expect(page.getByRole("radio", { name: /Now.*I’m about to do it/i })).toBeChecked();
    await expect(page.getByText("Every target and detail is optional.")).toBeVisible();
    expect(requests.slice(requestStart).some((request) => request.includes("/api/fitness/goals") || request.includes("/api/fitness/exercises"))).toBe(false);
    await expectNoOverflow(page);
    await screenshot(page, testInfo, `fitness-wave4-plan-${viewport.name}.png`);

    requestStart = requests.length;
    await page.goto("/?view=fitness&section=progress");
    await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible();
    const review = page.getByText("A useful week").locator("xpath=ancestor::section[1]");
    const goal = page.getByRole("heading", { name: "Run 20 km each week" }).locator("xpath=ancestor::section[1]");
    const history = page.getByRole("heading", { name: "Recent activity" }).locator("xpath=ancestor::section[1]");
    await expect(review).toBeVisible();
    expect(await review.evaluate((element, following) => Boolean(element.compareDocumentPosition(following as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await goal.elementHandle())).toBe(true);
    expect(await goal.evaluate((element, following) => Boolean(element.compareDocumentPosition(following as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await history.elementHandle())).toBe(true);
    await expect(page.getByRole("img", { name: /Synthetic public demo record 2: 12.4 km this week/i })).toBeVisible();
    await expect(page.getByRole("article", { name: "Weight progress" })).toBeVisible();
    await expect(page.getByRole("img", { name: /Weight smoothed chart with 3 readings/i })).toBeVisible();
    await expect(page.getByText("Half imported activity")).toHaveCount(0);
    const progressRequests = requests.slice(requestStart);
    expect(progressRequests.some((request) => /\/api\/fitness\/activities\?date_from=\d{4}-\d{2}-\d{2}&date_to=\d{4}-\d{2}-\d{2}&limit=200/.test(request))).toBe(true);
    expect(progressRequests.some((request) => request.includes("/api/fitness/body/measurements"))).toBe(true);
    expect(progressRequests.some((request) => request.includes("/api/fitness/analysis/") || request.includes("/api/fitness/recovery/summary"))).toBe(false);
    await expect(page.locator("body")).not.toContainText(forbiddenNormalCopy);
    await expectNoOverflow(page);
    await expectUsefulTargets(page);
    await screenshot(page, testInfo, `fitness-wave4-progress-${viewport.name}.png`);
    await expect(review).toBeInViewport({ ratio: 0.2 });
    const progressLayout = await page.locator(".fitness-wave4__progress").evaluate((element) => {
      const pageRect = element.getBoundingClientRect();
      const reviewElement = element.querySelector<HTMLElement>(".fitness-wave4__weekly-review");
      const reviewRect = reviewElement?.getBoundingClientRect();
      return {
        pageHeight: pageRect.height,
        reviewHeight: reviewRect?.height ?? 0,
        reviewTop: reviewRect?.top ?? Number.POSITIVE_INFINITY,
        reviewBottom: reviewRect?.bottom ?? Number.NEGATIVE_INFINITY,
      };
    });
    expect(progressLayout.pageHeight, JSON.stringify(progressLayout)).toBeGreaterThan(480);
    expect(progressLayout.reviewHeight, JSON.stringify(progressLayout)).toBeGreaterThan(120);
    expect(progressLayout.reviewTop, JSON.stringify(progressLayout)).toBeLessThan(viewport.height);
    expect(progressLayout.reviewBottom, JSON.stringify(progressLayout)).toBeGreaterThan(0);
    await page.getByRole("button", { name: /Body\s+Measurements and trends/i }).click();
    await expect(page.getByRole("heading", { name: "Body measurements", exact: true })).toBeVisible();
    await expect.poll(() => new URL(page.url()).searchParams.get("fitness-progress")).toBe("measurements");

    await expect(page.getByRole("heading", { name: "Detailed measurement graph", exact: true })).toBeVisible();
    await expect(page.getByRole("radio", { name: "Smoothed", exact: true })).toBeChecked();
    await expect(page.getByRole("radio", { name: "Fit", exact: true })).toBeChecked();
    await expect(page.getByRole("radio", { name: "90 Days", exact: true })).toBeChecked();
    await expect(page.getByRole("img", { name: /Weight smoothed chart with 3 readings and fit vertical scale/i })).toBeVisible();

    for (const groupName of ["Display", "Vertical scale", "Time range"]) {
      const labels = page.getByRole("group", { name: groupName }).locator("label");
      for (const label of await labels.all()) {
        const box = await label.locator("span").boundingBox();
        expect(box?.height ?? 0, `${groupName}: ${await label.textContent()}`).toBeGreaterThanOrEqual(40);
      }
    }

    await page.getByRole("group", { name: "Display" }).getByText("Raw", { exact: true }).click();
    await page.getByRole("group", { name: "Vertical scale" }).getByText("Wide", { exact: true }).click();
    await page.getByRole("group", { name: "Time range" }).getByText("30 Days", { exact: true }).click();
    await expect.poll(() => new URL(page.url()).searchParams.get("fitness-chart-display")).toBe("raw");
    await expect.poll(() => new URL(page.url()).searchParams.get("fitness-chart-scale")).toBe("wide");
    await expect.poll(() => new URL(page.url()).searchParams.get("fitness-chart-range")).toBe("30d");
    await expect(page.getByRole("img", { name: /Weight raw chart with 3 readings and wide vertical scale/i })).toBeVisible();

    for (const action of ["Zoom out", "Zoom in", "Reset"]) {
      const button = page.getByRole("button", { name: action, exact: true });
      await expect(button).toBeVisible();
      const box = await button.boundingBox();
      expect(box?.height ?? 0, action).toBeGreaterThanOrEqual(40);
    }
    await expectNoOverflow(page);
    await page.locator(".fitness-measurements").scrollIntoViewIfNeeded();
    await page.waitForTimeout(150);
    await page.screenshot({ path: testInfo.outputPath(`fitness-wave4-measurements-${viewport.name}.png`), fullPage: false });
    await page.getByRole("button", { name: "Back to Review" }).click();
    await expect(page.getByText("A useful week")).toBeVisible();

    requestStart = requests.length;
    await page.goto("/?view=fitness&section=recovery");
    await expect(page.getByRole("heading", { name: "Recovery", exact: true })).toBeVisible();
    await expect(page.getByText(/7h 39m average sleep/)).toBeVisible();
    await expect(page.getByRole("heading", { name: "How ready do you feel?" })).toBeVisible();
    await expect(page.getByText("Connected apps")).toHaveCount(0);
    const recoveryRequests = requests.slice(requestStart);
    expect(recoveryRequests.some((request) => request.includes("/api/fitness/recovery/observations") || request.includes("/api/fitness/body-issues") || request.includes("/api/fitness/cycles"))).toBe(false);
    await expect(page.locator("body")).not.toContainText(forbiddenNormalCopy);
    await expectNoOverflow(page);
    await expectUsefulTargets(page);
    await screenshot(page, testInfo, `fitness-wave4-recovery-${viewport.name}.png`);

    requestStart = requests.length;
    await page.goto("/?view=fitness&section=explore");
    await expect(page.getByRole("heading", { name: "Insights", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: /What changed this month\?/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /Why has recovery fallen\?/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /Am I progressing toward my goal\?/ })).toBeVisible();
    expect(requests.slice(requestStart).some((request) => request.includes("/api/fitness/analysis/"))).toBe(false);
    await expect(page.locator("body")).not.toContainText(forbiddenNormalCopy);
    await expectNoOverflow(page);
    await expectUsefulTargets(page);
    await screenshot(page, testInfo, `fitness-wave4-insights-${viewport.name}.png`);

    await page.getByRole("button", { name: /What changed this month\?/ }).click();
    await expect(page.getByText("Your recent runs became a little quicker.")).toBeVisible();
    expect(requests.some((request) => request.includes("/api/fitness/analysis/registry"))).toBe(true);
    expect(requests.some((request) => request.includes("/api/fitness/analysis/query"))).toBe(true);
    expect(pageErrors).toEqual([]);
  });
}
