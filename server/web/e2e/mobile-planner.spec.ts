import { expect, test, type Page, type TestInfo } from "@playwright/test";

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("the phone planner presents the whole week vertically", async ({ page }, testInfo: TestInfo) => {
  test.skip(testInfo.project.name !== "mobile", "This check targets the phone layout.");
  const fixture = await page.evaluate(() => {
    const monday = new Date();
    const day = monday.getDay() || 7;
    monday.setDate(monday.getDate() - day + 1);
    monday.setHours(15, 0, 0, 0);
    const tripStart = new Date(monday);
    tripStart.setHours(22, 0, 0, 0);
    const tripEnd = new Date(tripStart);
    tripEnd.setDate(tripEnd.getDate() + 2);
    tripEnd.setHours(2, 0, 0, 0);
    const localDate = `${monday.getFullYear()}-${String(monday.getMonth() + 1).padStart(2, "0")}-${String(monday.getDate()).padStart(2, "0")}`;
    return {
      date: localDate,
      year: monday.getFullYear(),
      footballStart: monday.toISOString(),
      footballEnd: new Date(monday.getTime() + 60 * 60 * 1_000).toISOString(),
      tripStart: tripStart.toISOString(),
      tripEnd: tripEnd.toISOString(),
    };
  });

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    } else if (path === "/api/family/members") {
      body = [
        { id: "dom", name: "Alex", member_type: "user" },
        { id: "max", name: "Child One", member_type: "child" },
      ];
    } else if (path.startsWith("/api/calendar/?")) {
      body = [
        {
          id: "football",
          title: "Football",
          start_time: fixture.footballStart,
          end_time: fixture.footballEnd,
          all_day: false,
          assigned_to: "max",
        },
        {
          id: "family-trip",
          title: "Family trip",
          start_time: fixture.tripStart,
          end_time: fixture.tripEnd,
          all_day: false,
          assigned_to: "dom",
        },
      ];
    } else if (path.startsWith("/api/routines/active?")) {
      body = [{ routine_item_id: "school", person_id: "max", person_name: "Child One", name: "School", color: "#22b8cf", date: fixture.date }];
    } else if (path.startsWith("/api/meals/plan?")) {
      body = [{ id: "dinner", date: fixture.date, meal_type: "dinner", meal_name: "Pasta" }];
    } else if (path === "/api/routines/terms") {
      body = [{ id: "term", person_id: "max", label: "Autumn term", start_date: `${fixture.year}-09-03`, end_date: `${fixture.year}-12-18` }];
    } else if (path.startsWith("/api/routines/holidays?")) {
      body = [{ id: "inset", person_id: "max", date: `${fixture.year}-10-23`, label: "Inset day" }];
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=planner");
  await expect(page.getByRole("region", { name: "Family calendar" })).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Calendar view" })).toHaveValue("week");
  const days = page.locator(".week-day");
  await expect(days).toHaveCount(7);

  const first = await days.nth(0).boundingBox();
  const second = await days.nth(1).boundingBox();
  expect(first).not.toBeNull();
  expect(second).not.toBeNull();
  expect(Math.abs((first?.x ?? 0) - (second?.x ?? 0))).toBeLessThanOrEqual(1);
  expect(second?.y ?? 0).toBeGreaterThanOrEqual((first?.y ?? 0) + (first?.height ?? 0) - 1);
  await expect(page.getByRole("button", { name: "Football" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Family trip/ })).toHaveCount(3);
  await expect(days.nth(0)).toContainText("22:00");
  await expect(days.nth(1)).toContainText("Continues");
  await expect(days.nth(2)).toContainText("Until 02:00");
  await expect(page.getByText("School", { exact: true })).toBeVisible();
  await expect(page.getByText("Pasta", { exact: true })).toBeVisible();

  const undersized = await page.locator(".planner-header-actions button:visible, .planner-toolbar button:visible, .planner-mobile-select select:visible, .planner-people-filter button:visible, .planner-display-trigger:visible, .week-day button:visible").evaluateAll((elements) => elements.map((element) => {
    const box = element.getBoundingClientRect();
    return { label: element.getAttribute("aria-label") || element.textContent?.trim(), width: Math.round(box.width), height: Math.round(box.height) };
  }).filter(({ width, height }) => width < 44 || height < 44));
  expect(undersized).toEqual([]);
  await expectNoDocumentOverflow(page);

  const actionRail = page.locator(".app-action-rail:visible");
  await actionRail.getByRole("button", { name: "Add directly", exact: true }).click();
  const addHub = page.getByRole("dialog", { name: "Add to HausKlar" });
  await addHub.getByRole("button", { name: /Event/ }).click();
  const editor = page.getByRole("dialog", { name: "Add to the plan" });
  await expect(editor.getByLabel("Title")).toBeVisible();
  await editor.getByRole("button", { name: "Close" }).click();
  await page.screenshot({ path: testInfo.outputPath("planner-week.png"), fullPage: false });

  await page.getByRole("combobox", { name: "Calendar view" }).selectOption("year");
  await expect(page.getByLabel(`Family year overview for ${fixture.year}`)).toBeVisible();
  await expect(page.getByRole("img", { name: /Child One, October: Autumn term, Inset day/ })).toBeVisible();
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("planner-year.png"), fullPage: false });
});
