import { expect, test, type Page } from "@playwright/test";

function localDay(offset: number): string {
  const value = new Date();
  value.setDate(value.getDate() + offset);
  return [
    value.getFullYear(),
    String(value.getMonth() + 1).padStart(2, "0"),
    String(value.getDate()).padStart(2, "0"),
  ].join("-");
}

function daySummary(date: string, familyStart: string, familyEnd: string, weights = false) {
  return {
    date,
    covered: true,
    family_swimming: [{ start: familyStart, end: familyEnd }],
    lane_swimming: weights ? [{ start: "06:00", end: "09:30" }] : [],
    weights_room: weights ? [{ start: "06:00", end: "12:00" }] : [],
    pool_closed: false,
    weights_room_status: weights ? "open" : "closed",
    weights_relevant: true,
  };
}

async function mockFacilities(page: Page) {
  const today = localDay(0);
  const tomorrow = localDay(1);
  let preferences = {
    show_family_swimming: false,
    show_personal_facilities: false,
  };

  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = {
        id: "dom", name: "Alex", email: "demo-person-39@example.invalid",
        role: "admin", priority: 5, family_id: "family",
      };
    } else if (path === "/api/family/members") {
      body = [
        { id: "dom", name: "Alex", member_type: "user" },
        { id: "kat", name: "Morgan", member_type: "user" },
      ];
    } else if (path === "/api/briefing/dashboard") {
      body = {
        generated_at: new Date().toISOString(), date: today,
        events: [], tasks: [], naps: [], illnesses: [], illness_readings: {},
        routines: [], meals: [], dog: null, memories: [], insights: [],
        prep_suggestions: [], medicine: [], birthdays: [], weather: null,
        finance_action: null, unavailable: [],
        coordination: {
          target_date: tomorrow, visible: true, acknowledged: false,
          events: [], tasks: [], load_prompt: null,
        },
        facility_quick_fact: {
          provider: "Example School College",
          source_title: "Summer staff timetable",
          source_document_id: "document-1",
          current_from: today,
          current_to: localDay(60),
          update_due: false,
          today: daySummary(today, "12:00", "17:00"),
          tomorrow: daySummary(tomorrow, "15:00", "17:00", true),
        },
      };
    } else if (path === "/api/facilities/calendar-preferences") {
      if (request.method() === "PATCH") {
        preferences = request.postDataJSON() as typeof preferences;
      }
      body = preferences;
    } else if (path === "/api/facilities/calendar-layer") {
      body = [
        ...(preferences.show_family_swimming ? [{
          id: "family-swim", layer_kind: "family_swimming",
          display_title: "Family swimming",
          start_time: `${today}T15:00:00+01:00`,
          end_time: `${today}T17:00:00+01:00`,
          owner_user_id: null, source_document_id: "document-1",
          source_title: "Summer staff timetable", location: "Example School Athens pool",
          read_only: true,
        }] : []),
        ...(preferences.show_personal_facilities ? [{
          id: "weights", layer_kind: "weights_room",
          display_title: "Weights room",
          start_time: `${today}T06:00:00+01:00`,
          end_time: `${today}T12:00:00+01:00`,
          owner_user_id: "dom", source_document_id: "document-1",
          source_title: "Summer staff timetable", location: "Example School weights room",
          read_only: true,
        }] : []),
      ];
    } else if (path === "/api/facilities/example_school/preview") {
      body = {
        filename: "Summer timetable.docx", title: "Summer timetable",
        sha256: "a".repeat(64), valid_from: today, valid_to: localDay(60),
        counts: {
          days: 61, family_swimming_sessions: 48, lane_swimming_sessions: 42,
          weights_room_open_days: 45, pool_closed_days: 4,
          weights_room_closed_days: 16,
        },
        changes: { added_days: 61, changed_days: 0, removed_days: 0 },
        sample_days: [daySummary(today, "12:00", "17:00")],
        issues: [], already_imported: false, can_confirm: true,
      };
    } else if (path === "/api/facilities/example_school/import") {
      body = {
        version_id: "version-1", document_id: "document-1", imported: true,
        preview: {},
      };
    }
    await route.fulfill({
      status: path === "/api/facilities/example_school/import" ? 201 : 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });
}

async function expectNoOverflow(page: Page) {
  const widths = await page.evaluate(() => ({
    viewport: innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(widths.document, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
  expect(widths.body, JSON.stringify(widths)).toBeLessThanOrEqual(widths.viewport + 1);
}

test("Example School times stay quick on Today and reviewable in Calendar", async ({ page }) => {
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await mockFacilities(page);

  await page.goto("/?view=today&tomorrow=1");
  await expect(page.getByRole("heading", { name: "Tomorrow, sorted" })).toBeVisible();
  const moreToday = page.getByRole("button", { name: /More today/ });
  if (await moreToday.count()) await moreToday.click();
  const quickFact = page.getByRole("button", {
    name: "See Example School swimming and weights times for today and tomorrow",
  });
  await expect(quickFact).toContainText("Family swim 12:00–17:00");
  await expect(page.getByText("Family swim 15:00–17:00", { exact: true })).toBeVisible();
  await expect(page.getByText("Weights 06:00–12:00", { exact: true })).toBeVisible();
  await quickFact.click();
  const times = page.getByRole("dialog", { name: "Example School swimming & weights" });
  await expect(times.getByText("Lane swimming", { exact: true })).toBeVisible();
  await expect(times.getByText("06:00–09:30", { exact: true })).toBeVisible();
  await times.getByRole("button", { name: "Close" }).click();
  await expectNoOverflow(page);

  await page.goto("/?view=planner");
  await expect(page.getByRole("region", { name: "Family calendar" })).toBeVisible();
  await page.getByRole("button", { name: "Choose calendars" }).click();
  const calendars = page.getByRole("dialog", { name: "Calendars" });
  await calendars.getByRole("button", { name: "Family swimming" }).click();
  await expect(calendars.getByRole("button", { name: "Family swimming" }))
    .toHaveAttribute("aria-pressed", "true");
  await calendars.getByRole("button", { name: "My Example School facilities" }).click();
  await expect(calendars.getByRole("button", { name: "My Example School facilities" }))
    .toHaveAttribute("aria-pressed", "true");

  const fileInput = page.getByLabel("Choose Example School timetable file");
  await fileInput.setInputFiles({
    name: "Summer timetable.docx",
    mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    buffer: Buffer.from("mock Word file"),
  });
  const review = page.getByRole("dialog", { name: "Update Example School timetable" });
  await expect(review.getByRole("heading", { name: "Spot check" })).toBeVisible();
  await expect(review).toContainText("Family swimming is shared");
  await review.getByRole("button", { name: "Use this timetable" }).click();
  await expect(page.getByText("Example School swimming and weights times updated.")).toBeVisible();
  await expect(page.locator(".event-item").filter({ hasText: "Family swimming" })).toBeVisible();
  await expect(page.locator(".event-item").filter({ hasText: "Weights room" })).toBeVisible();
  await expectNoOverflow(page);
  expect(pageErrors).toEqual([]);
});
