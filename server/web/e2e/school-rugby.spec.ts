import { expect, test } from "@playwright/test";

test("an Example School rugby fixture stays obvious and editable at every planner width", async ({ page }) => {
  const times = await page.evaluate(() => {
    const fixture = new Date();
    const day = fixture.getDay() || 7;
    fixture.setDate(fixture.getDate() - day + 1);
    fixture.setHours(13, 0, 0, 0);
    const end = new Date(fixture);
    end.setHours(19, 0, 0, 0);
    return { start: fixture.toISOString(), end: end.toISOString() };
  });

  const homeFixture = {
    id: "rugby-fixture",
    title: "HOME — Colts C rugby v Dulwich College",
    start_time: times.start,
    end_time: times.end,
    all_day: false,
    location: "HOME",
    family_member_ids: ["dom"],
    affected_member_ids: ["kat"],
    assigned_to: "dom",
    event_type: "rugby_fixture",
    source_name: "Example School Colts C rugby",
    source_color: "#2563EB",
    rugby_venue: "home",
    rugby_venue_overridden: false,
    read_only: true,
  };
  const awayFixture = {
    ...homeFixture,
    title: "AWAY — Colts C rugby v Dulwich College",
    location: "AWAY",
    source_color: "#DC2626",
    rugby_venue: "away",
    rugby_venue_overridden: true,
  };
  let fixture = homeFixture;
  let venueRequest: unknown = null;

  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = { id: "dom", name: "Alex", email: "dom@example.invalid", role: "admin", priority: 5, family_id: "family-1" };
    } else if (path === "/api/family/members") {
      body = [
        { id: "dom", name: "Alex", member_type: "user" },
        { id: "kat", name: "Morgan", member_type: "user" },
      ];
    } else if (url.pathname === "/api/calendar/rugby/fixtures/rugby-fixture/venue") {
      venueRequest = route.request().postDataJSON();
      fixture = awayFixture;
      body = fixture;
    } else if (path.startsWith("/api/calendar/?")) {
      body = [fixture];
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });

  await page.goto("/?view=planner");
  const calendarButton = page.getByRole("button", { name: /HOME — Colts C rugby/ }).first();
  await expect(calendarButton).toBeVisible();
  await calendarButton.click();

  const homeDialog = page.getByRole("dialog", { name: homeFixture.title });
  await expect(homeDialog).toContainText("Home fixture");
  await expect(homeDialog).toContainText("Reserved in the planner from 1:00 to 7:00 pm.");
  await expect(homeDialog.getByText("Alex", { exact: true })).toBeVisible();
  await expect(homeDialog.getByText("Morgan", { exact: true })).toBeVisible();
  await expect(homeDialog.getByRole("button", { name: "Edit" })).toHaveCount(0);

  const switchButton = homeDialog.getByRole("button", { name: "Mark as AWAY" });
  const switchBox = await switchButton.boundingBox();
  expect(switchBox?.height ?? 0).toBeGreaterThanOrEqual(40);
  await switchButton.click();
  await expect.poll(() => venueRequest).toEqual({ venue: "away" });

  const awayDialog = page.getByRole("dialog", { name: awayFixture.title });
  await expect(awayDialog).toContainText("Away fixture — travel blocked out");
  await expect(awayDialog.getByRole("button", { name: "Mark as HOME" })).toBeVisible();
  await expect(awayDialog.locator(".rugby-venue-label")).toHaveCSS("background-color", "rgb(220, 38, 38)");

  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
});
