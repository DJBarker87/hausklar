import { expect, test, type Page, type TestInfo } from "@playwright/test";

function localDay(offset = 0): string {
  const value = new Date();
  value.setDate(value.getDate() + offset);
  return [
    value.getFullYear(),
    String(value.getMonth() + 1).padStart(2, "0"),
    String(value.getDate()).padStart(2, "0"),
  ].join("-");
}

const today = localDay();

function completedOnboarding() {
  return {
    id: "setup-wave7", status: "complete", main_outcome: "move_consistently",
    availability: ["monday"], activities: ["running", "strength"], equipment: ["dumbbells"],
    food_preferences: [], source_connections: [], coach_style: "balanced",
    use_family_calendar: true, use_household_meals: true, use_weather: true,
    memory_enabled: false, preview: null, confirmation: null,
  };
}

function syncResponse(mutations: Array<{ mutation_id: string; entity_id: string }>) {
  return {
    status: "ok", current_sync_protocol_version: 1, current_client_schema_version: 1,
    minimum_supported_client_schema_version: 1,
    accepted: mutations.map((mutation) => ({ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 1 })),
    acked_mutation_ids: mutations.map((mutation) => mutation.mutation_id), rejected_mutations: [],
    changes: [], redirects: [], notices: [], next_cursor: 1,
  };
}

function emptyDashboard() {
  return {
    generated_at: new Date().toISOString(), date: today,
    events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: null,
    coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [], birthdays: [],
    weather: null, finance_action: null, unavailable: [],
  };
}

async function mockTodayCalendar(page: Page) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true, show_nutrition_today: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/briefing/dashboard") {
      body = emptyDashboard();
    } else if (path === "/api/fitness/today-card") {
      body = {
        date: today,
        session: { id: "session-run", kind: "planned_session", title: "Riverside easy run", sport_key: "running", status: "accepted", starts_at: `${today}T17:30:00Z`, scheduled_date: today, duration_minutes: 45, movable: true },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "session-run" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "session-run" },
        nutrition: {
          calories_kcal: 1_240, calorie_target_kcal: 2_100,
          protein_g: 86, protein_target_g: 140,
          calories_complete: true, protein_complete: true,
        },
      };
    } else if (path === "/api/fitness/onboarding") {
      body = completedOnboarding();
    } else if (path === "/api/fitness/sync") {
      const mutations = (request.postDataJSON() as { mutations?: Array<{ mutation_id: string; entity_id: string }> } | null)?.mutations ?? [];
      body = syncResponse(mutations);
    } else if (path === "/api/fitness/planned-sessions") {
      body = [{ id: "session-run", revision: 1, title: "Riverside easy run", sport_key: "running", status: "accepted", scheduled_date: today, scheduled_start_utc: `${today}T17:30:00Z`, expected_duration_s: 2_700, movable: true }];
    } else if (path === "/api/fitness/training-programmes") {
      body = [];
    } else if (path === "/api/fitness/calendar-preferences") {
      body = { show_planned: true, show_completed: false };
    } else if (path === "/api/fitness/calendar-layer") {
      body = [{ id: "layer-run", owner_user_id: "dom", layer_kind: "planned", display_title: "Riverside easy run", sport_key: "running", status: "accepted", scheduled_start_utc: `${today}T17:30:00Z`, scheduled_date: today, duration_s: 2_700, detail_id: "session-run" }];
    } else if (path === "/api/calendar/" || path === "/api/tasks/" || path === "/api/routines/active" || path === "/api/meals/plan") {
      body = [];
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function mockStrength(page: Page) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/onboarding") {
      body = completedOnboarding();
    } else if (path === "/api/fitness/sync") {
      const mutations = (request.postDataJSON() as { mutations?: Array<{ mutation_id: string; entity_id: string }> } | null)?.mutations ?? [];
      body = syncResponse(mutations);
    } else if (path === "/api/fitness/exercises") {
      body = [{
        id: "exercise-squat", revision: 1, name: "Goblet squat", active: true, favourite: true,
        movement_pattern_key: "squat", measurement_mode: "reps_load", rep_count_mode: "total",
        load_entry_mode: "total_external", default_unit: "kg", bodyweight_involved: false,
      }];
    } else if (path === "/api/fitness/exercise-setups") {
      body = [{ id: "setup-squat", revision: 1, exercise_id: "exercise-squat", name: "Home dumbbell", active: true, is_default: true, load_entry_mode: "total_external", rep_count_mode: "total" }];
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function mockEmptyTodayStrength(page: Page) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/briefing/dashboard") {
      body = emptyDashboard();
    } else if (path === "/api/fitness/today-card") {
      body = {
        date: today, has_completed_activity_today: false, session: null,
        primary_action: { kind: "start_strength", label: "Start workout", destination: "plan", target_id: null },
        secondary_action: null, nutrition: null,
      };
    } else if (path === "/api/fitness/onboarding") {
      body = completedOnboarding();
    } else if (path === "/api/fitness/sync") {
      const mutations = (request.postDataJSON() as { mutations?: Array<{ mutation_id: string; entity_id: string }> } | null)?.mutations ?? [];
      body = syncResponse(mutations);
    } else if (path === "/api/fitness/exercises") {
      body = [{
        id: "exercise-squat", revision: 1, name: "Goblet squat", active: true, favourite: true,
        movement_pattern_key: "squat", measurement_mode: "reps_load", rep_count_mode: "total",
        load_entry_mode: "total_external", default_unit: "kg", bodyweight_involved: false,
      }];
    } else if (path === "/api/fitness/exercise-setups") {
      body = [{ id: "setup-squat", revision: 1, exercise_id: "exercise-squat", name: "Home dumbbell", active: true, is_default: true, load_entry_mode: "total_external", rep_count_mode: "total" }];
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function expectNoOverflow(page: Page) {
  const widths = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth, body: document.body.scrollWidth }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
  expect(widths.body, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

async function capture(page: Page, testInfo: TestInfo, name: string) {
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await page.waitForTimeout(250);
  await page.screenshot({ path: testInfo.outputPath(`${name}-${testInfo.project.name}.png`), fullPage: false });
}

test("Today and Calendar open the same accepted workout", async ({ page }, testInfo) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockTodayCalendar(page);
  await page.goto("/?view=today");
  const card = page.locator(".today-fitness-card");
  await expect(card.getByRole("heading", { name: "Riverside easy run" })).toBeVisible();
  const nutrition = page.getByRole("heading", { name: "Nutrition today" }).locator("xpath=ancestor::section[1]");
  await expect(nutrition.getByText("1,240 kcal")).toBeVisible();
  await expect(nutrition.getByText("of 2,100 kcal")).toBeVisible();
  await expect(nutrition.getByText("86 g")).toBeVisible();
  await expect(nutrition.getByText("of 140 g")).toBeVisible();
  await expect(nutrition.getByRole("progressbar", { name: "Calories: 1240 of 2100 kcal" })).toBeVisible();
  await expect(nutrition.getByRole("button", { name: "Log food" })).toBeVisible();
  await capture(page, testInfo, "fitness-wave7-today-workout");
  await card.getByRole("button", { name: "Start" }).click();
  await expect(page.getByRole("heading", { name: "Sessions", exact: true })).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get("session")).toBe("session-run");

  await page.goto(`/?view=calendar&event_date=${today}`);
  const calendarWorkout = page.getByRole("button", { name: /Riverside easy run/ }).first();
  await expect(calendarWorkout).toBeVisible();
  await capture(page, testInfo, "fitness-wave7-calendar-workout");
  const calendarChoices = page.getByRole("button", { name: "Choose calendars" });
  await calendarChoices.click();
  const calendarChoicesDialog = page.getByRole("dialog", { name: "Calendars" });
  await expect(calendarChoicesDialog).toBeVisible();
  await expect(calendarChoicesDialog.getByRole("button", { name: "My training" })).toHaveAttribute("aria-pressed", "true");
  await capture(page, testInfo, "fitness-wave7-calendar-choices");
  await page.keyboard.press("Escape");
  await expect(calendarChoicesDialog).toHaveCount(0);
  await expect(calendarChoices).toBeFocused();
  await calendarWorkout.click();
  await expect(page.getByRole("heading", { name: "Sessions", exact: true })).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get("session")).toBe("session-run");
  await expectNoOverflow(page);
  expect(pageErrors).toEqual([]);
});

test("an empty Today starts one live strength workout without a setup step", async ({ page }) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockEmptyTodayStrength(page);
  await page.goto("/?view=today");

  const card = page.locator(".today-fitness-card");
  await expect(card.getByRole("heading", { name: "Strength workout" })).toBeVisible();
  await expect(card.getByText("Nothing logged today")).toBeVisible();
  await card.getByRole("button", { name: "Start workout" }).click();

  await expect(page.getByRole("region", { name: "Active workout summary" })).toBeVisible();
  await expect(page.getByLabel("Exercise to add")).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get("fitness-strength-start")).toBeNull();
  await expectNoOverflow(page);
  expect(pageErrors).toEqual([]);
});

test("Strength workout survives reopening and finishes cleanly", async ({ page }, testInfo) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockStrength(page);
  await page.goto("/?view=fitness&section=strength");
  await expect(page.getByRole("heading", { name: "Strength", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Start workout" }).click();
  await expect(page.getByRole("region", { name: "Active workout summary" })).toBeVisible();
  await page.getByLabel("Exercise to add").selectOption("exercise-squat");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Goblet squat" })).toBeVisible();
  await page.getByLabel("Weight (kg total)").fill("20");
  await page.getByLabel("Repetitions").fill("10");
  await page.getByRole("button", { name: "Start set" }).click();
  const stopSet=page.getByRole("button", { name: "Stop set" });
  await expect(stopSet).toBeEnabled();
  await stopSet.click();
  await expect(page.getByText(/20 kg × 10/)).toBeVisible();
  await expect(page.getByText("Rest elapsed")).toBeVisible();
  await capture(page, testInfo, "fitness-wave7-strength-active");

  await page.reload();
  await expect(page.getByRole("region", { name: "Active workout summary" })).toBeVisible();
  await expect(page.getByText(/20 kg × 10/)).toBeVisible();
  const finish = page.getByRole("button", { name: "Finish", exact: true });
  await finish.click();
  const dialog = page.getByRole("dialog", { name: "Finish workout" });
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(finish).toBeFocused();
  await finish.click();
  await page.getByRole("button", { name: "Finish workout" }).click();
  await expect(page.getByRole("button", { name: "Start workout" })).toBeVisible();
  await expect(page.getByText("Strength workout", { exact: true }).last()).toBeVisible();
  await capture(page, testInfo, "fitness-wave7-strength-finished");
  await expectNoOverflow(page);
  expect(pageErrors).toEqual([]);
});
