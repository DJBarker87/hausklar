import { expect, test, type Page, type TestInfo } from "@playwright/test";

async function mockFitnessApi(page: Page) {
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: true, pinned: true };
    } else if (path === "/api/family/members") {
      body = [];
    } else if (path === "/api/fitness/sync") {
      body = { status: "ok", accepted: [], changes: [], redirects: [], notices: [], next_cursor: 0 };
    } else if (path === "/api/fitness/body/measurements") {
      body = [
        { id: "weight-1", metric_key: "body.weight_kg", value: 78.2, unit_key: "kg", measured_at_utc: "2026-07-20T07:00:00Z" },
        { id: "weight-2", metric_key: "body.weight_kg", value: 77.6, unit_key: "kg", measured_at_utc: "2026-08-02T07:00:00Z" },
      ];
    } else if (path === "/api/fitness/activities") {
      body = [{
        id: "run-1", title: "Riverside run", sport_key: "running", status: "completed",
        started_at_utc: "2026-08-02T07:00:00Z", duration_s: 2_650, distance_m: 8_000,
        planned_session_title: "Riverside easy run",
      }];
    } else if (path === "/api/fitness/overview") {
      body = {
        date: "2026-08-03",
        session: {
          id: "strength-plan-1",
          kind: "planned_session",
          title: "Full body strength",
          sport_key: "strength",
          status: "accepted",
          starts_at: "2026-08-03T17:00:00Z",
          scheduled_date: "2026-08-03",
          duration_minutes: 45,
          movable: true,
        },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "strength-plan-1" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "strength-plan-1" },
        quick_actions: [
          { kind: "record_readiness", label: "Readiness", destination: "log", target_id: "strength-plan-1" },
          { kind: "log_food", label: "Log food", destination: "log", target_id: null },
        ],
        coach_nudge: null,
        safety_adjustment: null,
      };
    } else if (path === "/api/fitness/activity-registry") {
      body = { sports: [], metrics: [] };
    } else if (path === "/api/fitness/running/load") {
      body = {
        windows: {
          "7d": { days: 7, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
          "28d": { days: 28, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
          "42d": { days: 42, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
        },
        volume_change_pct: null,
        missing_rpe_sessions: 0,
        explanation: "Running load keeps distance and duration separate.",
      };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

async function expectNoDocumentOverflow(page: Page) {
  const widths = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
  expect(widths.body, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

test("Fitness convergence stays action-first and responsive", async ({ page }, testInfo: TestInfo) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockFitnessApi(page);
  await page.addInitScript(() => localStorage.removeItem("hausklar-theme"));

  await page.goto("/?view=fitness");
  await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible();
  await expect(page.getByRole("article", { name: "Weight progress" })).toBeVisible();
  await expect(page.getByText("Matched to Riverside easy run", { exact: true })).toBeVisible();

  const fitnessNavigation = page.getByRole("navigation", { name: "Fitness sections" });
  await expect(fitnessNavigation.getByRole("button")).toHaveCount(4);
  expect(await fitnessNavigation.getByRole("button").allTextContents()).toEqual([
    "Review", "Food", "Train", "More",
  ]);
  for (const button of await fitnessNavigation.getByRole("button").all()) {
    const box = await button.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.height).toBeGreaterThanOrEqual(40);
  }

  await expect(page.getByRole("heading", { name: "Recent activity" })).toBeVisible();
  await page.getByRole("button", { name: "Open activity history" }).click();
  await expect(page.getByRole("heading", { name: "Activities", exact: true })).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get("section")).toBe("activity");
  await expect(fitnessNavigation.getByRole("button", { name: "Review", exact: true })).toHaveAttribute("aria-current", "page");
  await fitnessNavigation.getByRole("button", { name: "More", exact: true }).click();
  await expect(page.getByRole("heading", { name: "More", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: /Body measurements/ })).toBeVisible();
  await expect(page.getByRole("button", { name: /Connections/ })).toBeVisible();
  await fitnessNavigation.getByRole("button", { name: "Review", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible();

  await expect(page.getByText(/Private to you|Up to date|syncing|waiting to sync|More fitness areas/i)).toHaveCount(0);
  const rail = page.locator(".app-action-rail:visible");
  const launcher = rail.getByRole("button", { name: "Log or ask Coach", exact: true });
  await expect(launcher).toBeVisible();
  await launcher.click();
  const actions = rail.getByRole("dialog", { name: "Fitness quick actions" });
  await expect(actions.getByRole("button", { name: "Log", exact: true })).toBeFocused();
  await expect(actions.getByRole("button", { name: "Coach", exact: true })).toBeVisible();
  await expect(actions.getByRole("button", { name: "Bismarck", exact: true })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(launcher).toBeFocused();
  await page.evaluate(() => { (document.activeElement as HTMLElement | null)?.blur(); window.scrollTo(0, 0); });
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("fitness-overview-system.png"), fullPage: false });

  const mobileNavigation = page.locator(".mobile-nav:visible");
  if (await mobileNavigation.count()) {
    await expect(mobileNavigation.getByRole("button")).toHaveCount(5);
    await expect(mobileNavigation.getByRole("button", { name: "Fitness", exact: true })).toHaveAttribute("aria-current", "page");
    const labels = await fitnessNavigation.locator("button > span").evaluateAll((elements) => elements.map((element) => {
      const box = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return { width: box.width, height: box.height, visibility: style.visibility };
    }));
    expect(labels.every(({ width, height, visibility }) => width > 0 && height > 0 && visibility === "visible")).toBe(true);

    const geometry = await page.evaluate(() => {
      const actionRail = document.querySelector<HTMLElement>(".app-action-rail--mobile");
      const navigation = document.querySelector<HTMLElement>(".mobile-nav");
      const content = document.querySelector<HTMLElement>(".app-content");
      if (!actionRail || !navigation || !content) return null;
      const railBox = actionRail.getBoundingClientRect();
      const navigationBox = navigation.getBoundingClientRect();
      return {
        railBottom: railBox.bottom,
        navigationTop: navigationBox.top,
        paddingBottom: Number.parseFloat(getComputedStyle(content).paddingBottom),
        reserved: railBox.height + navigationBox.height,
      };
    });
    expect(geometry).not.toBeNull();
    expect(geometry!.railBottom).toBeLessThanOrEqual(geometry!.navigationTop + 1);
    expect(geometry!.paddingBottom).toBeGreaterThanOrEqual(geometry!.reserved - 4);

    await page.getByRole("button", { name: "More navigation and appearance" }).click();
    const overflow = page.getByRole("dialog", { name: "More HausKlar" });
    await expect(overflow.getByRole("button", { name: /House/ })).toBeVisible();
    await expect(overflow.getByRole("button", { name: /Finance/ })).toBeVisible();
    await expect(overflow.getByRole("button", { name: "System", exact: true })).toHaveAttribute("aria-pressed", "true");
    await overflow.getByRole("button", { name: "Dark", exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await page.keyboard.press("Escape");
    await expect(overflow).toHaveCount(0);
  } else {
    await page.getByRole("button", { name: /Appearance:/i }).click();
    await page.getByRole("button", { name: /Appearance:/i }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  }

  await page.getByRole("heading", { name: "Review", exact: true }).click();
  await page.evaluate(() => { (document.activeElement as HTMLElement | null)?.blur(); window.scrollTo(0, 0); });
  await page.mouse.move(200, 500);
  await page.waitForTimeout(500);
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("fitness-overview-dark.png"), fullPage: false });
  expect(pageErrors).toEqual([]);
});
