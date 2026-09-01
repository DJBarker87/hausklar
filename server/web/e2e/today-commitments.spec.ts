import { expect, test, type Page, type TestInfo } from "@playwright/test";

function localDateValue(value = new Date()): string {
  return [
    value.getFullYear(),
    String(value.getMonth() + 1).padStart(2, "0"),
    String(value.getDate()).padStart(2, "0"),
  ].join("-");
}

function offsetDateValue(days: number): string {
  const value = new Date();
  value.setDate(value.getDate() + days);
  return localDateValue(value);
}

const commitment = {
  id: "commitment-school-1",
  kind: "school",
  visibility: "family",
  owner_user_id: "kat",
  title: "Bring trainers for sports day",
  summary: "Sports day is next week and trainers need to go in the school bag.",
  status: "draft",
  revision: 1,
  sources: [{
    id: "source-school-1",
    kind: "manual",
    document_id: null,
    label: "School message",
    provider_reference: null,
    source_url: null,
    observed_at: null,
  }],
  plan: {
    events: [{
      id: "event-school-1",
      title: "Sports day",
      description: null,
      start_time: offsetDateValue(1),
      end_time: null,
      all_day: true,
      location: "School field",
      person_ids: ["child-1"],
      affected_adult_ids: ["kat", "dom"],
      assigned_to: null,
      event_type: "school",
      document_ids: [],
    }],
    tasks: [{
      id: "task-school-1",
      title: "Pack trainers",
      description: null,
      due_date: localDateValue(),
      actionable_from: null,
      assigned_to: "kat",
      priority: 2,
      document_id: null,
    }],
    preparations: [],
    external_action: null,
  },
  review_issues: [],
  external_action_status: "not_required",
  external_action_outcome: null,
  external_action_completed_at: null,
  group_key: null,
  interpretation_processor: "typed",
  supersedes_id: null,
  change_summary: [],
  confirmed_at: null,
  declined_at: null,
  results: [],
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
};

async function mockToday(page: Page) {
  const today = localDateValue();
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    let body: unknown = [];

    if (path === "/api/auth/web/session") {
      body = { id: "kat", name: "Morgan", email: "demo-person-40@example.invalid", role: "user", priority: 10, family_id: "family" };
    } else if (path === "/api/auth/onboarding") {
      body = {
        family_name: "Example family",
        people_count: 5,
        adult_count: 2,
        child_count: 3,
        calendar_commitment_count: 1,
        reminders_configured: true,
        selected_modules: [],
        dismissed: true,
        completed: true,
        should_show: false,
        first_success: true,
      };
    } else if (path === "/api/fitness/workspace") {
      body = { enabled: false, pinned: false, show_nutrition_today: false };
    } else if (path === "/api/family/members") {
      body = [
        { id: "kat", name: "Morgan", member_type: "user" },
        { id: "dom", name: "Alex", member_type: "user" },
        { id: "child-1", name: "Child", member_type: "child" },
      ];
    } else if (path === "/api/briefing/dashboard") {
      body = {
        generated_at: new Date().toISOString(),
        date: today,
        events: [],
        tasks: [],
        naps: [],
        illnesses: [],
        routines: [],
        coordination: null,
        memories: [],
        insights: [],
        prep_suggestions: [],
        medicine: [],
        birthdays: [],
        weather: null,
        finance_action: null,
        facility_quick_fact: null,
        homework: [],
        presents: [],
        unavailable: [],
      };
    } else if (path === "/api/commitments/" || path === `/api/commitments/${commitment.id}`) {
      body = path.endsWith(commitment.id) ? commitment : [commitment];
    } else if (path === "/api/fitness/vi-schedule") {
      body = {
        relevant: true,
        provider: "vi_training",
        source_title: "Vi Training Example School",
        source_url: "https://www.vitraininggym.co.uk/class-schedule/",
        unavailable_reason: null,
        days: [{
          date: today,
          covered: true,
          classes: [{
            start: "18:00",
            end: "19:00",
            label: "Mobility flow",
            classification: "mobility",
            booking_url: "https://book.vi.example/class-1",
          }],
        }],
      };
    }

    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });
}

async function expectNoHorizontalOverflow(page: Page) {
  const geometry = await page.evaluate(() => {
    const dialog = document.querySelector<HTMLElement>("[role='dialog']");
    const box = dialog?.getBoundingClientRect();
    return {
      viewport: window.innerWidth,
      document: document.documentElement.scrollWidth,
      body: document.body.scrollWidth,
      dialogLeft: box?.left ?? null,
      dialogRight: box?.right ?? null,
      dialogScrollWidth: dialog?.scrollWidth ?? null,
      dialogClientWidth: dialog?.clientWidth ?? null,
    };
  });
  expect(geometry.document, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.viewport + 1);
  expect(geometry.body, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.viewport + 1);
  if (geometry.dialogLeft != null && geometry.dialogRight != null) {
    expect(geometry.dialogLeft, JSON.stringify(geometry)).toBeGreaterThanOrEqual(-1);
    expect(geometry.dialogRight, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.viewport + 1);
    expect(geometry.dialogScrollWidth!, JSON.stringify(geometry)).toBeLessThanOrEqual(geometry.dialogClientWidth! + 1);
  }
}

test("Morgan can hand off a Vi booking and open the most urgent plan from Today", async ({ page }, testInfo: TestInfo) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockToday(page);
  await page.emulateMedia({
    colorScheme: testInfo.project.name === "desktop" ? "dark" : "light",
    reducedMotion: testInfo.project.name === "tablet" ? "reduce" : "no-preference",
  });
  await page.addInitScript(() => localStorage.removeItem("hausklar-theme"));

  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();
  const plans = page.getByRole("button", { name: /Plans to sort/ });
  await expect(plans).toContainText("1 plan waiting");
  await expect(plans).toContainText("Bring trainers for sports day");

  const moreToday = page.getByRole("button", { name: /More today/ });
  if (await moreToday.isVisible() && await moreToday.getAttribute("aria-expanded") === "false") {
    await moreToday.click();
  }
  const viCard = page.getByRole("region", { name: "Classes today" });
  await expect(viCard).toBeVisible();
  await expect(viCard.getByRole("link", { name: "Book in Vi" })).toHaveAttribute("href", "https://book.vi.example/class-1");
  await expect(viCard.getByRole("button", { name: "Booked" })).toBeVisible();
  await expectNoHorizontalOverflow(page);

  if (testInfo.project.name === "desktop") {
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  }
  if (testInfo.project.name === "tablet") {
    expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);
  }

  await plans.click();
  const hub = page.getByRole("dialog", { name: "Plans to sort" });
  await expect(hub).toBeVisible();
  await expect(hub.getByRole("region", { name: "Plan basics" }).getByRole("textbox", { name: "Title" })).toHaveValue("Bring trainers for sports day");
  await expectNoHorizontalOverflow(page);
  expect(pageErrors).toEqual([]);
});
