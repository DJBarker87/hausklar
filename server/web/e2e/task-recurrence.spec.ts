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

test("a task can repeat from its due date", async ({ page }) => {
  let created: Record<string, unknown> | null = null;
  let createdTask: Record<string, unknown> | null = null;
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    let body: unknown = [];
    if (url.pathname === "/api/auth/web/session") {
      body = {
        id: "dom",
        name: "Alex",
        email: "demo-person-39@example.invalid",
        role: "admin",
        priority: 5,
        family_id: "family-1",
      };
    } else if (url.pathname === "/api/family/members") {
      body = [{ id: "dom", name: "Alex", member_type: "user" }];
    } else if (url.pathname === "/api/tasks/" && request.method() === "POST") {
      created = request.postDataJSON() as Record<string, unknown>;
      createdTask = {
        ...created,
        completed_at: null,
        created_by: "dom",
        assignees: [],
      };
      body = createdTask;
    } else if (url.pathname === "/api/tasks/") {
      body = createdTask ? [createdTask] : [];
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });

  await page.goto("/?view=tasks");
  await page.getByRole("button", { name: "New task" }).click();
  const editor = page.getByRole("dialog", { name: "New task" });
  await editor.getByLabel("Title").fill("Pay Little Gym");
  await editor.getByLabel("Repeat").selectOption("monthly");

  await expect(editor.getByRole("checkbox", { name: "Add a due date" })).toBeChecked();
  await editor.locator("#task-due-date").fill("2026-09-04");
  await editor.locator("#task-due-time").fill("18:00");
  await expect(editor.getByText("Repeats from the due date.")).toBeVisible();
  await expectNoDocumentOverflow(page);

  await editor.getByRole("button", { name: "Create task" }).click();

  await expect.poll(() => created?.recurrence_rule).toBe("FREQ=MONTHLY");
  expect(String(created?.due_date)).toContain("2026-09-04T18:00:00");
  await expect(page.getByRole("button", { name: "Open task Pay Little Gym" })).toContainText("Every month");
  await expectNoDocumentOverflow(page);
});
