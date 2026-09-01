import { expect, test, type Page, type TestInfo } from "@playwright/test";

function localDate() {
  const date = new Date();
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

async function mockSessions(page: Page) {
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/fitness/onboarding") {
      body = {
        id: "setup", status: "complete", main_outcome: "run_faster", availability: [], activities: ["running", "strength"],
        equipment: [], food_preferences: [], source_connections: [], coach_style: "direct", use_family_calendar: true,
        use_household_meals: false, use_weather: false, memory_enabled: false, preview: null, confirmation: null,
      };
    } else if (path === "/api/fitness/sync") {
      body = {
        status: "ok", current_sync_protocol_version: 1, current_client_schema_version: 1,
        minimum_supported_client_schema_version: 1, accepted: [], acked_mutation_ids: [], rejected_mutations: [],
        changes: [], redirects: [], notices: [], next_cursor: 1,
      };
    } else if (path === "/api/fitness/planned-sessions") {
      body = [{
        id: "next-run", revision: 1, title: "Easy run", sport_key: "running", status: "accepted",
        scheduled_date: localDate(), scheduled_start_utc: `${localDate()}T17:30:00Z`, movable: true,
      }];
    } else if (path === "/api/fitness/training-programmes") {
      body = [];
    } else if (path === "/api/fitness/activity-registry") {
      body = {
        sports: [
          { key: "running", display_name: "Run" },
          { key: "strength", display_name: "Strength" },
          { key: "walking", display_name: "Walk" },
          { key: "cycling", display_name: "Ride" },
          { key: "hiking", display_name: "Hike" },
        ],
        metrics: [],
      };
    } else if (path === "/api/fitness/integrations/strava/status") {
      body = { configured: true, connected: true, status: "connected", athlete_name: "Alex Runner", imported_activity_count: 3 };
    } else if (path === "/api/fitness/integrations/strava/sync") {
      body = {
        imported_count: 1, updated_count: 0, unchanged_count: 3,
        latest_activity: { id: "strava-run", title: "Morning run", sport_key: "running", started_at_utc: `${localDate()}T06:00:00Z`, duration_s: 1_500, distance_m: 5_000 },
        status: { configured: true, connected: true, status: "connected", athlete_name: "Alex Runner", imported_activity_count: 4 },
      };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function expectNoOverflow(page: Page) {
  const widths = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

async function screenshot(page: Page, testInfo: TestInfo, name: string) {
  await page.screenshot({ path: testInfo.outputPath(name), fullPage: false });
}

for (const viewport of [
  { name: "phone", width: 375, height: 812 },
  { name: "tablet", width: 768, height: 1024 },
  { name: "desktop", width: 1280, height: 900 },
]) {
  test(`combined plan and log session flow at ${viewport.name} width`, async ({ page }, testInfo) => {
    await page.setViewportSize(viewport);
    await mockSessions(page);
    await page.goto("/?view=fitness&section=training");

    await expect(page.getByRole("heading", { name: "Sessions", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "What do you want to do?" })).toBeVisible();
    const launcher = page.getByRole("heading", { name: "What do you want to do?" }).locator("xpath=ancestor::section[1]");
    await expect(launcher.getByRole("button", { name: "Run", exact: true })).toBeVisible();
    await expect(launcher.getByRole("button", { name: "Strength", exact: true })).toBeVisible();
    await expect(launcher.getByRole("button", { name: "Other", exact: true })).toBeVisible();
    await expect(launcher.getByRole("button", { name: "Walk", exact: true })).toHaveCount(0);
    await expect(launcher.getByRole("button", { name: "Ride", exact: true })).toHaveCount(0);
    await expect(page.getByText("Easy run", { exact: true }).first()).toBeVisible();
    await expectNoOverflow(page);

    const stravaResponse = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/fitness/integrations/strava/sync");
    await page.getByRole("button", { name: "Pull latest from Strava" }).click();
    expect((await stravaResponse).ok()).toBe(true);

    await page.getByRole("button", { name: "Other", exact: true }).click();
    const activityPicker = page.getByRole("combobox", { name: "Activity", exact: true });
    await expect(activityPicker).toContainText("Walk");
    await expect(activityPicker).toContainText("Ride");
    await page.getByRole("button", { name: "Close" }).click();

    await page.getByRole("button", { name: "Run", exact: true }).click();
    await expect(page.getByRole("radio", { name: /Now.*I’m about to do it/i })).toBeChecked();
    await expect(page.getByText("Every target and detail is optional.")).toBeVisible();
    await expect(page.getByLabel("Name (optional)")).toHaveCount(0);
    await page.getByLabel(/Distance/).fill("5");
    await page.getByRole("button", { name: "Target pace" }).click();
    const pace = page.getByRole("group", { name: "Target pace" });
    await pace.getByLabel("Minutes").fill("5");
    await pace.getByLabel("Seconds").fill("00");
    await expect(page.getByRole("button", { name: "Add run for now" })).toBeEnabled();
    await expectNoOverflow(page);
    await screenshot(page, testInfo, `fitness-sessions-${viewport.name}.png`);

    await page.getByRole("radio", { name: /Done.*I already did it/i }).check();
    await page.getByLabel(/Minutes/).fill("42");
    await expect(page.getByRole("button", { name: "Log run" })).toBeEnabled();
    await page.getByRole("button", { name: "Log run" }).click();
    await expect(page.getByRole("heading", { name: "What are you doing?" })).toHaveCount(0);

    await page.getByRole("button", { name: "Strength", exact: true }).click();
    await expect.poll(() => new URL(page.url()).searchParams.get("section")).toBe("strength");
  });
}
