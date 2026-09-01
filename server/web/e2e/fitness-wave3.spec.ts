import { expect, test, type Page, type TestInfo } from "@playwright/test";

const food = {
  id: "food-1",
  name: "Greek yoghurt",
  active: true,
  favourite: true,
  quick_use: { usual_amount: 170, usual_unit: "g", frequency_count: 5 },
  current_version: { id: "food-version-1", reference_amount: 100, reference_unit: "g", calories_kcal: 97, protein_g: 9 },
};
const recipe = {
  id: "recipe-1",
  name: "Tomato pasta",
  active: true,
  household_shared: true,
  current_version: { id: "recipe-version-1", yield_servings: 4, components: [] },
};

function onboardingProfile(status: "draft" | "skipped" | "complete") {
  return {
    id: "setup-1", status, main_outcome: null, availability: [], activities: [], equipment: [],
    food_preferences: [], source_connections: [], coach_style: null, use_family_calendar: false,
    use_household_meals: false, use_weather: false, memory_enabled: false, preview: null, confirmation: null,
  };
}

async function mockWave3(page: Page) {
  let status: "draft" | "skipped" | "complete" = "draft";
  let savedProfile = onboardingProfile(status);
  const requests: string[] = [];
  const syncBatches: Array<Array<{ entity_type: string; operation: string }>> = [];
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    requests.push(path);
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members" || path === "/api/meals/") {
      body = [];
    } else if (path === "/api/fitness/onboarding") {
      if (request.method() === "PUT") {
        status = "draft";
        savedProfile = { ...savedProfile, ...(request.postDataJSON() as Record<string, unknown>), status };
      }
      body = savedProfile;
    } else if (path === "/api/fitness/onboarding/preview-week") {
      body = {
        preview_id: "preview-1",
        week_start: "2026-08-03",
        summary: "Two useful sessions that fit your week.",
        sessions: [
          { day: "Monday", date: "2026-08-03", start_time: "18:00", activity: "Walking", title: "Easy family walk", duration_minutes: 30, reason: "Fits your Monday evening." },
          { day: "Saturday", date: "2026-08-08", start_time: "09:00", activity: "Strength", title: "Simple strength", duration_minutes: 35, reason: "Uses the time you chose." },
        ],
      };
    } else if (path === "/api/fitness/onboarding/confirm") {
      status = "complete";
      savedProfile = { ...savedProfile, status };
      body = {
        status: "complete",
        completed_at: "2026-08-03T10:00:00Z",
        goal_id: "goal-1",
        session_ids: ["walk-1", "strength-1"],
        week: {
          preview_id: "preview-1", week_start: "2026-08-03", summary: "Two useful sessions that fit your week.",
          sessions: [],
        },
      };
    } else if (path === "/api/fitness/onboarding/skip") {
      status = "skipped";
      savedProfile = { ...savedProfile, status };
      body = savedProfile;
    } else if (path === "/api/fitness/sync") {
      const input = request.postDataJSON?.() as { mutations?: Array<{ mutation_id: string; entity_id: string; entity_type: string; operation: string }> } | undefined;
      const mutations = input?.mutations ?? [];
      syncBatches.push(mutations.map(({ entity_type, operation }) => ({ entity_type, operation })));
      body = {
        status: "ok", current_sync_protocol_version: 1, current_client_schema_version: 1,
        minimum_supported_client_schema_version: 1,
        accepted: mutations.map((mutation) => ({ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 1 })),
        acked_mutation_ids: mutations.map((mutation) => mutation.mutation_id), rejected_mutations: [],
        changes: [], redirects: [], notices: [], next_cursor: 1,
      };
    } else if (path === "/api/fitness/overview") {
      body = { date: "2026-08-03", session: null, primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null }, secondary_action: null, quick_actions: [{ kind: "log_food", label: "Log food", destination: "log", target_id: null }], coach_nudge: null, safety_adjustment: null };
    } else if (path === "/api/fitness/foods") {
      body = [food];
    } else if (path === "/api/fitness/recipes") {
      body = [recipe];
    } else if (path === "/api/fitness/food-log") {
      body = { nutrition_date: "2026-08-03", entries: [], totals: {} };
    } else if (path === "/api/fitness/planned-meals") {
      body = [{
        meal_plan_id: "meal-plan-1", date: "2026-08-03", meal_type: "dinner", meal_id: "meal-1",
        meal_name: "Family pasta night", link_id: "link-1", recipe_id: "recipe-1",
        recipe_version_id: "recipe-version-1", recipe_name: "Tomato pasta", suggested_portion: 1,
        suggested_unit: "serving",
      }];
    } else if (path === "/api/fitness/planned-meals/meal-plan-1/log") {
      body = {
        id: "planned-log-1", source_meal_plan_id: "meal-plan-1", household_meal_link_id: "link-1",
        recipe_version_id: "recipe-version-1", logged_at_utc: "2026-08-03T17:00:00Z",
        local_timezone: "Europe/London", nutrition_date: "2026-08-03", meal_key: "dinner",
        entered_amount: 1, entered_unit: "serving", canonical_amount: 1, canonical_unit: "serving",
        measurement_quality: "standard_serving",
      };
    } else if (path === "/api/fitness/meal-templates" || path === "/api/fitness/nutrition/targets" || path === "/api/fitness/phases" || path === "/api/fitness/household-meals") {
      body = [];
    } else if (path === "/api/fitness/nutrition/settings") {
      body = { id: "nutrition-settings", timezone: "Europe/London", nutrition_day_start_minutes: 240 };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
  return { requests, syncBatches };
}

async function expectNoOverflow(page: Page) {
  const widths = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth, body: document.body.scrollWidth }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
  expect(widths.body, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

async function expectSettledActionLauncher(page: Page, viewportHeight: number) {
  const launcher = page.locator(".app-action-rail:visible").getByRole("button", { name: "Log or ask Coach" });
  await expect(launcher).toBeVisible();
  await page.waitForTimeout(500);
  const box = await launcher.boundingBox();
  expect(box).not.toBeNull();
  expect(box!.height).toBeGreaterThanOrEqual(40);
  expect(box!.y).toBeGreaterThanOrEqual(0);
  expect(box!.y + box!.height).toBeLessThanOrEqual(viewportHeight + 1);
  expect(await page.evaluate(({ x, y }) => Boolean(document.elementFromPoint(x, y)?.closest(".app-action-rail")), { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 })).toBe(true);
  return launcher;
}

const forbiddenCopy = /\b(confidence|canonical|authoritative|provider|evidence|model|indexeddb|synced?|syncing|reconnect|stale)\b/i;

for (const viewport of [
  { name: "phone", width: 375, height: 812 },
  { name: "tablet", width: 768, height: 1024 },
  { name: "desktop", width: 1280, height: 900 },
]) {
  test(`Wave 3 first-run and Log are production-ready at ${viewport.width}px`, async ({ page }, testInfo: TestInfo) => {
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    const api = await mockWave3(page);
    await page.addInitScript(() => {
      localStorage.removeItem("hausklar-theme");
    });
    await page.goto("/?view=fitness&section=nutrition");

    await expect(page.getByRole("heading", { name: "Set up Fitness" })).toBeVisible();
    await expect(page.getByRole("navigation", { name: "Fitness sections" })).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Log or ask Coach" })).toHaveCount(0);
    await expect(page.locator(".primary-nav:visible, .mobile-nav:visible").getByRole("button", { name: "Fitness" })).toBeVisible();
    await expect(page.getByRole("radio")).toHaveCount(6);
    const outcomeControl = page.getByRole("radio").first();
    const outcomeControlBox = await outcomeControl.boundingBox();
    const outcomeCardBox = await outcomeControl.locator("xpath=..").boundingBox();
    expect(outcomeControlBox).not.toBeNull();
    expect(outcomeControlBox!.width).toBe(18);
    expect(outcomeControlBox!.height).toBe(18);
    expect(outcomeCardBox).not.toBeNull();
    expect(outcomeCardBox!.height).toBeGreaterThanOrEqual(48);
    await expect(page.getByRole("button", { name: "Finish later" })).toBeVisible();
    expect(api.requests).not.toContain("/api/fitness/foods");
    expect(api.requests).not.toContain("/api/fitness/food-log");
    expect(api.requests).not.toContain("/api/fitness/planned-meals");
    await expect(page.locator("body")).not.toContainText(forbiddenCopy);
    await expectNoOverflow(page);
    await page.screenshot({ path: testInfo.outputPath(`fitness-wave3-onboarding-${viewport.name}.png`), fullPage: false });

    await page.getByRole("radio", { name: "Feel fitter" }).click();
    await page.getByRole("button", { name: /Continue/ }).click();
    await expect(page.getByRole("heading", { name: "Step 2 of 4: Time" })).toBeFocused();
    await page.getByRole("checkbox", { name: "Monday" }).click();
    await page.getByRole("button", { name: /Continue/ }).click();
    await page.getByRole("checkbox", { name: "Walking" }).click();
    await page.getByRole("button", { name: /Continue/ }).click();
    await expect(page.getByRole("heading", { name: "Your first week" })).toBeVisible();
    await expect(page.getByText("Easy family walk")).toBeVisible();
    await expect(page.getByText("Simple strength")).toBeVisible();
    expect(api.requests).not.toContain("/api/fitness/onboarding/confirm");
    await page.getByRole("button", { name: "Confirm my week" }).click();
    await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible();
    await expect(page.getByText("Make Fitness yours")).toHaveCount(0);
    const fitnessNavigation = page.getByRole("navigation", { name: "Fitness sections" });
    await expect(fitnessNavigation).toBeVisible();
    await expectSettledActionLauncher(page, viewport.height);
    await fitnessNavigation.getByRole("button", { name: "Food" }).click();
    await expect(page.getByRole("heading", { name: "Log", exact: true })).toBeVisible();
    await expect.poll(() => api.requests.includes("/api/fitness/foods")).toBe(true);

    const quick = page.getByRole("heading", { name: "Add food" });
    const planned = page.getByRole("heading", { name: "From the family meal plan" });
    const diary = page.getByRole("heading", { name: "Today’s diary" });
    await expect(quick).toBeVisible();
    await expect(planned).toBeVisible();
    await expect(diary).toBeVisible();
    expect(await quick.evaluate((element, next) => Boolean(element.compareDocumentPosition(next as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await diary.elementHandle())).toBe(true);
    expect(await diary.evaluate((element, next) => Boolean(element.compareDocumentPosition(next as Node) & Node.DOCUMENT_POSITION_FOLLOWING), await planned.elementHandle())).toBe(true);
    await expect(page.getByRole("button", { name: "Add food to Breakfast" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Add food to Lunch" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Add food to Dinner" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Add food to Snacks" })).toBeVisible();
    await expect(page.getByText("Log the suggested portion, or adjust it first.")).toBeVisible();
    await expect(page.getByText(/Only your own diary state/)).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText(forbiddenCopy);

    const modeTabs = page.getByRole("tablist", { name: "What to log" }).getByRole("tab");
    await expect(modeTabs).toHaveCount(4);
    for (const tab of await modeTabs.all()) {
      const box = await tab.boundingBox();
      expect(box).not.toBeNull();
      expect(box!.height).toBeGreaterThanOrEqual(40);
    }
    for (const [tab, heading] of [["Measurement", "Record a measurement"], ["Sleep", "Log sleep"], ["Body issue", "Log a body issue"], ["Food", "Add food"]] as const) {
      await page.getByRole("tab", { name: tab }).click();
      await expect(page.getByRole("heading", { name: heading })).toBeVisible();
    }
    await expectNoOverflow(page);
    await expectSettledActionLauncher(page, viewport.height);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    if (viewport.width <= 820) await expect(page.locator(".mobile-header")).toBeVisible();
    else await expect(page.locator(".sidebar-brand")).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath(`fitness-wave3-log-${viewport.name}.png`), fullPage: false });

    const syncCountBeforeOfflineLog = api.syncBatches.length;
    await page.context().setOffline(true);
    await page.getByRole("searchbox", { name: "Search foods" }).fill("Greek yoghurt");
    const yoghurtResult = page.getByRole("group", { name: "Greek yoghurt" });
    await expect(yoghurtResult.getByRole("button", { name: "Quick add" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Search full food database" })).toBeVisible();
    await yoghurtResult.getByRole("button", { name: "Quick add" }).click();
    const undo = page.getByRole("button", { name: "Undo" });
    await expect(undo).toBeFocused();
    await expect(page.getByText("15.3 g protein")).toBeVisible();
    expect(api.syncBatches.slice(syncCountBeforeOfflineLog).flat()).not.toContainEqual(expect.objectContaining({ entity_type: "food_log_entry" }));
    await page.context().setOffline(false);
    await page.evaluate(() => window.dispatchEvent(new Event("online")));
    await expect.poll(() => api.syncBatches.slice(syncCountBeforeOfflineLog).flat().some((mutation) => mutation.entity_type === "food_log_entry" && mutation.operation === "upsert")).toBe(true);
    await page.reload();
    await expect(page.getByRole("heading", { name: "Log", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Undo" })).toBeVisible();
    await expectSettledActionLauncher(page, viewport.height);
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    if (viewport.width <= 820) await expect(page.locator(".mobile-header")).toBeVisible();
    else await expect(page.locator(".sidebar-brand")).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath(`fitness-wave3-undo-${viewport.name}.png`), fullPage: false });

    await page.getByRole("button", { name: "Undo" }).click();
    await expect(page.getByRole("button", { name: "Undo" })).toHaveCount(0);
    await page.getByRole("button", { name: "Log 1 serving" }).click();
    const plannedMealUndo = page.locator(".fitness-log__undo");
    await expect(plannedMealUndo.locator("strong")).toHaveText("Tomato pasta logged.");
    await expect(plannedMealUndo.locator("small")).toHaveText("Saved to today’s diary.");
    await expect.poll(() => api.requests.includes("/api/fitness/planned-meals/meal-plan-1/log")).toBe(true);

    if (viewport.width === 1280) {
      await page.locator(".fitness-log__manage > summary").click();
      await expect(page.getByRole("button", { name: "Finish Fitness setup" })).toHaveCount(0);
      await page.locator(".fitness-log__manage > summary").click();
      for (const destination of ["Foods, barcode & labels", "Recipes", "Meal templates", "Targets & day", "Family meal links", "Connections"] as const) {
        await page.locator(".fitness-log__manage > summary").click();
        await page.getByRole("group", { name: "Manage food and connections" }).getByRole("button", { name: destination }).click();
        await expect(page.getByRole("heading", { name: destination, exact: true, level: 2 })).toBeVisible();
        await expect(page.locator("body")).not.toContainText(forbiddenCopy);
        await page.getByRole("button", { name: "Back to Log" }).click();
      }
    }

    await expectNoOverflow(page);
    expect(pageErrors).toEqual([]);
  });
}
