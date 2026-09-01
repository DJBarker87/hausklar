import { expect, test, type Page, type TestInfo } from "@playwright/test";

function onboardingComplete() {
  return {
    id: "setup-1", status: "complete", main_outcome: "Fit training around family life",
    availability: [], activities: ["running", "strength"], equipment: [], food_preferences: [],
    source_connections: [], coach_style: "balanced", use_family_calendar: true,
    use_household_meals: true, use_weather: true, memory_enabled: false,
    preview: null, confirmation: null,
  };
}

async function mockWave5(page: Page) {
  const requests: string[] = [];
  let coachMessages = 0;
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    requests.push(`${request.method()} ${path}${url.search}`);
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
    } else if (path === "/api/auth/ai-consent") {
      body = { consented: true, version: "2026-07-13", consented_at: "2026-08-03T08:00:00Z", provider: "OpenAI", disclosure: "Explicit requests only.", background_processing: false };
    } else if (path === "/api/fitness/coach/status") {
      body = { status: "available", provider: "private", model: "private", intents: ["discussion", "weekly", "run_plan", "strength_plan"] };
    } else if (path === "/api/fitness/coach/memory/settings") {
      body = { enabled: false };
    } else if (path === "/api/fitness/coach/message" && request.method() === "POST") {
      coachMessages += 1;
      body = coachMessages === 1 ? {
        status: "complete",
        answer: "This places the run cleanly around your family week.",
        evidence: [{ id: "hidden", label: "Must not render", summary: "Must not render" }],
        recommendation: null,
        proposal: {
          id: "proposal-family-week", kind: "family_calendar_event",
          payload: { internal_calendar_id: "must-not-render", title: "Training" },
          preview: {
            change: ["Add Training to Family Calendar — Tue 4 Aug · 17:30–18:15", "Link it to Easy run"],
            visibility: "Visible to your family",
          },
          validation: { valid: true, issues: [] }, warnings: [{ message: "Must not render" }],
          confirmable: true, review_only_reason: null, expires_at: "2099-08-03T12:00:00Z",
        },
      } : {
        status: "complete",
        answer: "Here is the useful shopping change.",
        evidence: [], recommendation: null,
        proposal: {
          id: "proposal-shopping", kind: "shopping_list",
          payload: { internal_list_id: "must-not-render", items: [{ name: "Bananas" }] },
          preview: { change: ["Add Bananas to Shopping — 6 · Fruit"], visibility: "Visible to your family" },
          validation: { valid: true, issues: [] }, warnings: [], confirmable: true,
          review_only_reason: null, expires_at: "2099-08-03T12:00:00Z",
        },
      };
    } else if (path === "/api/fitness/coach/proposals/proposal-family-week/confirm" && request.method() === "POST") {
      body = { status: "confirmed", message: "Saved.", result_ids: ["calendar-event-1"], next_destinations: [] };
    } else if (path === "/api/fitness/coach/proposals/proposal-family-week/undo" && request.method() === "POST") {
      body = { status: "undone", message: "The confirmed change was undone.", affected_ids: ["calendar-event-1"] };
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

async function screenshot(page: Page, testInfo: TestInfo, name: string, reset = true) {
  if (reset) await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await page.waitForTimeout(200);
  await page.screenshot({ path: testInfo.outputPath(name), fullPage: false });
}

const forbiddenCoachCopy = /\b(provider|model|evidence|validation|warnings?|expires?|review.only|sample|completeness|stale|internal_(?:calendar|list)_id)\b/i;

for (const viewport of [
  { name: "phone", width: 375, height: 812 },
  { name: "tablet", width: 768, height: 1024 },
  { name: "desktop", width: 1280, height: 900 },
]) {
  test(`Wave 5 Coach is action-first and family-aware at ${viewport.width}px`, async ({ page }, testInfo) => {
    const pageErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await page.emulateMedia({ colorScheme: viewport.name === "desktop" ? "dark" : "light", reducedMotion: viewport.name === "tablet" ? "reduce" : "no-preference" });
    const requests = await mockWave5(page);
    await page.addInitScript(() => localStorage.removeItem("hausklar-theme"));
    await page.goto("/?view=fitness&section=coach");

    await expect(page.getByRole("heading", { name: "Coach", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Ask Coach" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Review my week" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Plan a run" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Plan strength" })).toBeVisible();
    const composer = page.getByLabel("Message your Fitness coach");
    await expect(composer).toBeVisible();
    const composerBox = await composer.boundingBox();
    expect(composerBox).not.toBeNull();
    expect(composerBox!.y + composerBox!.height).toBeLessThanOrEqual(viewport.height);
    await expect(page.getByText("Reminders and coaching only — not medical advice.", { exact: true })).toHaveCount(1);
    expect(requests.some((value) => value.includes("/api/fitness/today") || value.includes("/api/fitness/planned-sessions") || value.includes("/api/fitness/coach/recommendations"))).toBe(false);
    await expect(page.locator("body")).not.toContainText(forbiddenCoachCopy);
    await expectNoOverflow(page);
    await screenshot(page, testInfo, `fitness-wave5-coach-${viewport.name}.png`);

    await page.getByRole("button", { name: "Plan a run" }).click();
    await page.getByRole("button", { name: "Send" }).click();
    const familyReview = page.getByRole("article", { name: "Family Calendar event proposal" });
    await expect(familyReview.getByText("Add Training to Family Calendar — Tue 4 Aug · 17:30–18:15", { exact: true })).toBeVisible();
    await expect(familyReview.getByText("Link it to Easy run", { exact: true })).toBeVisible();
    await expect(familyReview.getByText("Visible to your family", { exact: true })).toBeVisible();

    const writesBeforeConfirm = requests.filter((value) => /POST|PATCH|PUT|DELETE/.test(value) && !value.includes("/api/fitness/coach/message") && !value.includes("/api/fitness/sync"));
    expect(writesBeforeConfirm).toEqual([]);
    await familyReview.getByRole("button", { name: "Confirm" }).click();
    await expect(familyReview.getByText("Saved", { exact: true })).toBeVisible();
    await familyReview.getByRole("button", { name: "Undo" }).click();
    await expect(familyReview.getByText("Undone", { exact: true })).toBeVisible();
    expect(requests).toContain("POST /api/fitness/coach/proposals/proposal-family-week/confirm");
    expect(requests).toContain("POST /api/fitness/coach/proposals/proposal-family-week/undo");

    await composer.fill("Add bananas for the post-run breakfast");
    await page.getByRole("button", { name: "Send" }).click();
    const shoppingReview = page.getByRole("article", { name: "Shopping list proposal" });
    await expect(shoppingReview.getByText("Add Bananas to Shopping — 6 · Fruit", { exact: true })).toBeVisible();
    await expect(shoppingReview.getByText("Visible to your family", { exact: true })).toBeVisible();
    await expect(shoppingReview.getByRole("button", { name: "Confirm" })).toBeVisible();
    await expect(shoppingReview.getByRole("button", { name: "Edit" })).toBeVisible();
    await expect(shoppingReview.getByRole("button", { name: "Discard" })).toBeVisible();

    await expect(page.locator("body")).not.toContainText(forbiddenCoachCopy);
    await expectNoOverflow(page);
    await page.locator(".fitness-wave5__messages-end").scrollIntoViewIfNeeded();
    await screenshot(page, testInfo, `fitness-wave5-proposals-${viewport.name}.png`, false);
    expect(pageErrors).toEqual([]);
  });
}
