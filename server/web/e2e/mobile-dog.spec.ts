import { expect, test, type Page, type TestInfo } from "@playwright/test";

function localToday(): string {
  const value = new Date();
  return [value.getFullYear(), String(value.getMonth() + 1).padStart(2, "0"), String(value.getDate()).padStart(2, "0")].join("-");
}

const profile = {
  id: "profile-1",
  name: "Mabel",
  date_of_birth: "2020-03-01",
  breed: "Labrador",
  microchip_number: "981000000000001",
  insurance_provider: "ManyPets",
  insurance_policy_number: "POL-123",
  vet_name: "Village Vets",
  vet_phone: "+00000000003",
  allergies: "Chicken",
  medicine_notes: "Tablet with food",
  breakfast_window_start: "07:30",
  breakfast_window_end: "08:30",
  walk_window_start: "10:00",
  walk_window_end: "12:00",
  dinner_window_start: "17:30",
  dinner_window_end: "19:00",
};

function status(overrides: Record<string, unknown> = {}) {
  return {
    walked_today: false,
    fed_breakfast_today: true,
    fed_dinner_today: false,
    last_walk: null,
    last_feed_breakfast: {
      id: "breakfast-1", activity_type: "feed_breakfast", started_at: "2026-08-09T07:45:00Z",
      ended_at: null, notes: null, is_active: false, done_by: "kat",
    },
    last_feed_dinner: null,
    active_walk: null,
    dog_name: "Mabel",
    walk_state: "due",
    breakfast_state: "done",
    dinner_state: "upcoming",
    ...overrides,
  };
}

async function expectNoOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("dog care stays quick while the full pet record is available at every supported width", async ({ page }, testInfo: TestInfo) => {
  let currentStatus = status();
  const activeWalk = {
    id: "walk-live", activity_type: "walk", started_at: new Date(Date.now() - 65_000).toISOString(),
    ended_at: null, notes: null, is_active: true, done_by: "dom",
  };

  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    else if (path === "/api/family/members") body = [{ id: "dom", name: "Alex", member_type: "user" }, { id: "kat", name: "Morgan", member_type: "user" }];
    else if (path === "/api/children/") body = [];
    else if (path.startsWith("/api/dog/status?")) body = currentStatus;
    else if (path === "/api/dog/profile") body = profile;
    else if (path.startsWith("/api/dog/activities?")) body = [];
    else if (path.startsWith("/api/dog/weights?")) body = [{ id: "weight-1", measured_on: "2026-07-01", weight_kg: 22.4, notes: "Vet scales" }];
    else if (path.startsWith("/api/dog/vaccinations?")) body = [{ id: "vaccine-1", vaccine_name: "Leptospirosis", given_on: "2026-06-01", next_due_on: "2027-06-01", notes: null }];
    else if (path === "/api/dog/documents") body = [{ id: "link-1", document_id: "document-1", role: "insurance", title: "Pet insurance", original_filename: "policy.pdf", media_type: "application/pdf", file_size: 12_000, download_url: "/api/documents/document-1/content" }];
    else if (path === "/api/dog/activities" && request.method() === "POST") {
      currentStatus = status({ active_walk: activeWalk });
      body = activeWalk;
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=family&section=dog");
  await expect(page.getByRole("heading", { name: "Mabel" })).toBeVisible();
  const walk = page.getByRole("button", { name: /Walk due now/ });
  await expect(walk).toContainText("10:00–12:00");
  await expect(page.getByRole("button", { name: /Breakfast done/ })).toBeVisible();
  await walk.click();
  await expect(page.getByRole("button", { name: /Walking now/ })).toContainText(/1:0\d/);

  await page.getByText("Pet record", { exact: true }).click();
  await expect(page.getByText("981000000000001")).toBeVisible();
  await expect(page.getByText("22.4 kg")).toBeVisible();
  await expect(page.getByText("Leptospirosis")).toBeVisible();
  await expect(page.getByText("Pet insurance")).toBeVisible();
  await page.getByRole("region", { name: "Important details" }).getByRole("button", { name: "Edit" }).click();
  const editor = page.getByRole("dialog", { name: "Edit Mabel's pet record" });
  await expect(editor.getByLabel("Microchip number (optional)")).toHaveValue("981000000000001");
  await expect(editor.getByLabel("From").nth(1)).toHaveValue("10:00");
  await editor.getByRole("button", { name: "Close" }).click();

  if (testInfo.project.name === "mobile") {
    const undersized = await page.locator(".dog-care__status:visible, .dog-care__hero .button:visible, .dog-care__record-book > summary:visible, .dog-care__subsection .button:visible").evaluateAll((elements) => elements.map((element) => {
      const box = element.getBoundingClientRect();
      return { label: element.textContent?.trim(), width: Math.round(box.width), height: Math.round(box.height) };
    }).filter(({ width, height }) => width < 44 || height < 44));
    expect(undersized).toEqual([]);
  }
  await expectNoOverflow(page);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: testInfo.outputPath("dog-care.png"), fullPage: false });
});

test("Today keeps dog care in Family even when it needs attention", async ({ page }, testInfo: TestInfo) => {
  let todayDog = status({ walk_state: "overdue", dinner_state: "due" });
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    else if (path === "/api/family/members") body = [{ id: "dom", name: "Alex", member_type: "user" }];
    else if (path.startsWith("/api/briefing/dashboard?")) body = {
      generated_at: new Date().toISOString(), date: localToday(),
      events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: todayDog,
      coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [], birthdays: [],
      homework: [], weather: null, finance_action: null, facility_quick_fact: null, unavailable: [],
    };
    else if (path === "/api/fitness/today-card") body = null;
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=today");
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();
  await expect(page.getByText("Mabel", { exact: false })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "At home" })).toHaveCount(0);
  await expectNoOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("today-without-dog-admin.png"), fullPage: false });

  todayDog = status({ walked_today: true, walk_state: "done", breakfast_state: "done", dinner_state: "upcoming" });
  await page.reload();
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();
  await expect(page.getByText("Mabel", { exact: false })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "At home" })).toHaveCount(0);
});
