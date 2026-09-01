import { expect, test, type Page } from "@playwright/test";

function localToday(): string {
  const value = new Date();
  return [value.getFullYear(), String(value.getMonth() + 1).padStart(2, "0"), String(value.getDate()).padStart(2, "0")].join("-");
}

const user = {
  id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin",
  priority: 5, family_id: "family",
};

const dashboard = {
  generated_at: new Date().toISOString(), date: localToday(),
  events: [], tasks: [], naps: [], illnesses: [], illness_readings: {}, routines: [], meals: [],
  dog: null, coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [],
  birthdays: [], weather: null, family_members: [], unavailable: [],
};

async function mockApp(page: Page, shoppingCreates: Array<Record<string, unknown>> = []) {
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    let body: unknown = [];
    if (url.pathname.endsWith("/auth/web/session")) body = user;
    else if (url.pathname.endsWith("/briefing/dashboard")) body = dashboard;
    else if (url.pathname.endsWith("/meals/shopping") && route.request().method() === "POST") {
      const payload = route.request().postDataJSON() as Record<string, unknown>;
      shoppingCreates.push(payload);
      body = {
        ...payload, checked: false,
        created_at: "2026-07-13T08:00:00Z", updated_at: "2026-07-13T08:00:00Z",
      };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
}

test("browser Back restores the previous HausKlar screen", async ({ page }) => {
  await mockApp(page);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();

  const navigation = page.locator('nav[aria-label="Main navigation"]:visible');
  await navigation.getByRole("button", { name: "Calendar", exact: true }).click();
  await expect(page.getByRole("region", { name: "Family calendar" })).toBeVisible();
  await navigation.getByRole("button", { name: "Lists", exact: true }).click();
  await expect(page.locator(".lists-page")).toBeVisible();

  await page.goBack();
  await expect(page.getByRole("region", { name: "Family calendar" })).toBeVisible();
  await expect(navigation.getByRole("button", { name: "Calendar", exact: true })).toHaveAttribute("aria-current", "page");
  await page.goBack();
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();
  await expect(navigation.getByRole("button", { name: "Today", exact: true })).toHaveAttribute("aria-current", "page");
});

test("an offline shopping item is retained and replayed once on reconnect", async ({ page, context }) => {
  const shoppingCreates: Array<Record<string, unknown>> = [];
  await mockApp(page, shoppingCreates);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();

  const rail = page.locator(".app-action-rail:visible");
  await rail.getByRole("button", { name: "Add directly", exact: true }).click();
  await page.getByRole("dialog", { name: "Add to HausKlar" }).getByRole("button", { name: /Shopping item/ }).click();
  const dialog = page.getByRole("dialog", { name: "Add to shopping list" });
  await expect(dialog).toBeVisible();

  await context.setOffline(true);
  await dialog.getByLabel("Item").fill("Oat milk");
  await dialog.getByLabel("Quantity (optional)").fill("2 cartons");
  await dialog.getByRole("button", { name: "Add item" }).click();

  await expect(page.getByText(/1 change is safely waiting to sync/)).toBeVisible();
  await expect(page.getByText(/Saved offline/)).toBeVisible();
  expect(shoppingCreates).toHaveLength(0);

  await context.setOffline(false);
  await expect.poll(() => shoppingCreates.length).toBe(1);
  await expect(page.getByText(/1 offline change synced/)).toBeVisible();
  await expect(page.locator(".offline-banner")).toHaveCount(0);
  expect(shoppingCreates[0]).toMatchObject({ name: "Oat milk", quantity: "2 cartons" });
  expect(shoppingCreates[0]?.id).toEqual(shoppingCreates[0]?.client_id);
});
