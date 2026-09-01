import { expect, test, type Page } from "@playwright/test";

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

test("future council collections stay visible and clearly managed", async ({ page }) => {
  const taskRequests: string[] = [];
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname + url.search;
    let body: unknown = [];
    if (path === "/api/auth/web/session") {
      body = {
        id: "kat",
        name: "Morgan",
        email: "kat@example.invalid",
        role: "user",
        priority: 10,
        family_id: "family-1",
      };
    } else if (path === "/api/family/members") {
      body = [
        { id: "dom", name: "Alex", member_type: "user" },
        { id: "kat", name: "Morgan", member_type: "user" },
      ];
    } else if (path.startsWith("/api/tasks/?")) {
      taskRequests.push(path);
      body = [{
        id: "managed-bins",
        title: "Bins",
        description: "blue,black",
        assigned_to: "dom",
        due_date: "2026-07-16",
        completed_at: null,
        category: "bins",
        recurrence_rule: null,
        priority: 2,
        actionable_from: "2026-07-15T17:00:00Z",
        created_by: "bin-scraper",
        assignees: [{
          id: "bins-dom",
          assignee_id: "dom",
          assignee_name: "Alex",
          assignee_type: "user",
          completed_at: null,
        }],
      }];
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });

  await page.goto("/?view=tasks");
  await expect(page.getByRole("heading", { name: "Tasks", exact: true })).toBeVisible();
  await page.getByRole("button", { name: /^Filters,/ }).click();
  const filters = page.getByRole("dialog", { name: "Filter tasks" });
  await filters.getByLabel("Category").selectOption("bins");
  await filters.getByRole("button", { name: "Done" }).click();

  await expect.poll(() => taskRequests.at(-1) ?? "").toContain("order=attention");
  expect(taskRequests.at(-1)).not.toContain("category=");
  expect(taskRequests.at(-1)).not.toContain("actionable=");
  await expect(page.getByRole("button", { name: /Filters, Mine · Bins/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Open task Bins" })).toBeVisible();
  await expect(page.getByText("Recycling, refuse", { exact: true })).toBeVisible();
  await expect(page.getByText("Thu 16 Jul", { exact: true })).toBeVisible();
  await expectNoDocumentOverflow(page);

  await page.getByRole("button", { name: "Open task Bins" }).click();
  const detail = page.getByRole("dialog", { name: "Bins" });
  await expect(detail.getByText("Managed from the council schedule.")).toBeVisible();
  await expect(detail.getByRole("button", { name: "Complete task" })).toBeVisible();
  await expect(detail.getByRole("button", { name: "Edit" })).toHaveCount(0);
  await expect(detail.getByRole("button", { name: "Delete" })).toHaveCount(0);
});
