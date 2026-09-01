import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page, type TestInfo } from "@playwright/test";

const today = "2026-08-03";

function onboardingComplete() {
  return {
    id: "setup-a11y", status: "complete", main_outcome: "run_consistently",
    availability: ["monday"], activities: ["running", "strength"], equipment: [], food_preferences: [],
    source_connections: [], coach_style: "balanced", use_family_calendar: true,
    use_household_meals: true, use_weather: true, memory_enabled: false, preview: null, confirmation: null,
  };
}

async function mockFitness(page: Page, { consented = true }: { consented?: boolean } = {}) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/onboarding") {
      body = onboardingComplete();
    } else if (path === "/api/fitness/sync") {
      body = { status: "ok", current_sync_protocol_version: 1, current_client_schema_version: 1, minimum_supported_client_schema_version: 1, accepted: [], acked_mutation_ids: [], rejected_mutations: [], changes: [], redirects: [], notices: [], next_cursor: 1 };
    } else if (path === "/api/fitness/overview") {
      body = {
        date: today,
        session: { id: "session-run", kind: "planned_session", title: "Riverside easy run", sport_key: "running", status: "accepted", starts_at: `${today}T17:30:00Z`, scheduled_date: today, duration_minutes: 45, movable: true },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "session-run" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "session-run" },
        quick_actions: [{ kind: "log_food", label: "Log food", destination: "log", target_id: null }],
        coach_nudge: null, safety_adjustment: null,
      };
    } else if (path === "/api/fitness/foods") {
      body = [{ id: "food-yoghurt", name: "Greek yoghurt", active: true, favourite: true, quick_use: { usual_amount: 170, usual_unit: "g", frequency_count: 4 }, current_version: { id: "version-yoghurt", reference_amount: 100, reference_unit: "g", calories_kcal: 97, protein_g: 9 } }];
    } else if (path === "/api/fitness/recipes") {
      body = [];
    } else if (path === "/api/fitness/food-log") {
      body = { nutrition_date: today, entries: [], totals: {} };
    } else if (path === "/api/fitness/planned-meals") {
      body = [];
    } else if (path === "/api/fitness/nutrition/settings") {
      body = { id: "nutrition-settings", timezone: "Europe/London", nutrition_day_start_minutes: 240 };
    } else if (path === "/api/fitness/planned-sessions") {
      body = [{ id: "session-run", revision: 1, title: "Riverside easy run", sport_key: "running", status: "accepted", scheduled_date: today, scheduled_start_utc: `${today}T17:30:00Z`, expected_duration_s: 2_700, movable: true }];
    } else if (path === "/api/fitness/training-programmes") {
      body = [];
    } else if (path === "/api/fitness/goals") {
      body = [{ id: "goal-run", name: "Run 20 km each week", goal_type: "running", metric_key: "running.distance_m", starts_on: "2026-07-01", target_value: 20_000, unit_key: "m", status: "active" }];
    } else if (path === "/api/fitness/weekly-review") {
      body = {
        week_start: today, week_end: "2026-08-09",
        totals: { completed_sessions: 2, active_days: 2, duration_minutes: 83, distance_km: 12.4 },
        goal: { goal_id: "goal-run", goal_name: "Run 20 km each week", progress_text: "12.4 of 20 km", progress_percent: 62 },
        highlight: { title: "A useful week", detail: "Two planned runs became completed activity." },
        opportunity: { title: "Place the next run", detail: "Choose a day that fits the family calendar.", destination: "plan", action: "plan_session", action_label: "Plan the next run" },
      };
    } else if (path === "/api/fitness/activities") {
      body = [{ id: "activity-run", title: "Riverside run", sport_key: "running", started_at_utc: "2026-08-02T07:00:00Z", status: "completed", distance_m: 7_400, duration_s: 2_300 }];
    } else if (path === "/api/auth/ai-consent") {
      body = { consented, version: "2026-07-13", consented_at: consented ? "2026-08-03T08:00:00Z" : null, provider: "OpenAI", disclosure: "Explicit requests only.", background_processing: false };
    } else if (path === "/api/fitness/coach/status") {
      body = { status: "available", provider: "private", model: "private", intents: ["discussion", "weekly", "run_plan", "strength_plan"] };
    } else if (path === "/api/fitness/coach/memory/settings") {
      body = { enabled: false };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

function violationSummary(violations: Awaited<ReturnType<AxeBuilder["analyze"]>>["violations"]) {
  return violations.map((violation) => ({
    id: violation.id,
    impact: violation.impact,
    help: violation.help,
    nodes: violation.nodes.map((node) => ({ target: node.target, failure: node.failureSummary })),
  }));
}

async function expectLayoutGuardrails(page: Page) {
  const geometry = await page.evaluate(() => ({
    viewport: innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(geometry.document, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.viewport + 1);
  expect(geometry.body, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.viewport + 1);
  const positiveTabIndexes = await page.locator(".fitness-module [tabindex]").evaluateAll((nodes) => nodes.filter((node) => Number(node.getAttribute("tabindex")) > 0).map((node) => node.outerHTML));
  expect(positiveTabIndexes).toEqual([]);
  const shortTargets = await page.locator(".fitness-module__content > section button:visible").evaluateAll((buttons) => buttons.flatMap((button) => {
    const box = button.getBoundingClientRect();
    return box.height < 39.5 ? [{ label: button.textContent?.trim(), width: box.width, height: box.height }] : [];
  }));
  expect(shortTargets).toEqual([]);
}

async function audit(page: Page, destination: string) {
  const results = await new AxeBuilder({ page })
    .include(".fitness-module")
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
    .analyze();
  expect(violationSummary(results.violations), `${destination} accessibility violations`).toEqual([]);
  await expectLayoutGuardrails(page);
}

test("everyday Fitness destinations pass the release accessibility gate", async ({ page }, testInfo: TestInfo) => {
  test.setTimeout(90_000);
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockFitness(page);
  await page.emulateMedia({
    colorScheme: testInfo.project.name === "desktop" ? "dark" : "light",
    reducedMotion: testInfo.project.name === "tablet" ? "reduce" : "no-preference",
    contrast: testInfo.project.name === "mobile" ? "more" : "no-preference",
  });
  await page.addInitScript(() => localStorage.removeItem("hausklar-theme"));

  const destinations = [
    { section: "progress", heading: "Review", label: "review" },
    { section: "nutrition", heading: "Log", label: "food" },
    { section: "training", heading: "Sessions", label: "train" },
    { section: "today", heading: "More", label: "more" },
    { section: "coach", heading: "Coach", label: "coach" },
  ];

  for (const destination of destinations) {
    await page.goto(`/?view=fitness&section=${destination.section}`);
    await expect(page.getByRole("heading", { name: destination.heading, exact: true })).toBeVisible();
    const navigation = page.getByRole("navigation", { name: "Fitness sections" });
    expect(await navigation.getByRole("button").allTextContents()).toEqual(["Review", "Food", "Train", "More"]);
    await audit(page, destination.label);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    await page.screenshot({ path: testInfo.outputPath(`fitness-wave7-a11y-${destination.label}-${testInfo.project.name}.png`), fullPage: false });
  }

  await page.goto("/?view=fitness&section=progress");
  await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible();
  const rail = page.locator(".app-action-rail:visible");
  const launcher = rail.getByRole("button", { name: "Log or ask Coach" });
  await launcher.click();
  await expect(rail.getByRole("button", { name: "Log", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(launcher).toBeFocused();
  expect(pageErrors).toEqual([]);
});

test("Coach consent gate passes the release accessibility gate", async ({ page }, testInfo: TestInfo) => {
  await mockFitness(page, { consented: false });
  await page.emulateMedia({ colorScheme: testInfo.project.name === "desktop" ? "dark" : "light" });
  await page.goto("/?view=fitness&section=coach");

  await expect(page.getByRole("heading", { name: "Allow Fitness Coach to use OpenAI?" })).toBeVisible();
  await expect(page.getByText("What may be included")).toBeVisible();
  await audit(page, "coach consent");
});
