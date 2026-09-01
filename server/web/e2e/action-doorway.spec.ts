import { expect, test } from "@playwright/test";

function localToday(): string {
  const value = new Date();
  return [value.getFullYear(), String(value.getMonth() + 1).padStart(2, "0"), String(value.getDate()).padStart(2, "0")].join("-");
}

test.beforeEach(async ({ page }) => {
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    let body: unknown = [];
    if (url.pathname.endsWith("/auth/web/session")) {
      body = { id: "dom", name: "Alex", email: "demo-person-39@example.invalid", role: "admin", priority: 5, family_id: "family" };
    } else if (url.pathname.endsWith("/briefing/dashboard")) {
      body = {
        generated_at: new Date().toISOString(), date: localToday(),
        events: [], tasks: [], naps: [], illnesses: [], illness_readings: {}, routines: [], meals: [],
        dog: null, coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [],
        birthdays: [], weather: null, family_members: [], unavailable: [],
      };
    }
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) });
  });
});

test("the shared action doorway is labelled, keyboard-safe and clear of content", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();

  const mobileRail = page.locator(".app-action-rail--mobile:visible");
  const rail = (await mobileRail.count()) ? mobileRail : page.locator(".app-action-rail--sidebar:visible");
  const capture = rail.getByRole("button", { name: "Tell HausKlar…", exact: true });
  const add = rail.getByRole("button", { name: "Add directly", exact: true });
  await expect(capture).toBeVisible();
  await expect(add).toBeVisible();

  for (const action of [capture, add]) {
    const box = await action.boundingBox();
    expect(box?.width).toBeGreaterThanOrEqual(44);
    expect(box?.height).toBeGreaterThanOrEqual(44);
  }

  await capture.click();
  const captureDialog = page.getByRole("dialog", { name: "Add", exact: true });
  await expect(captureDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(captureDialog).toHaveCount(0);
  await expect(capture).toBeFocused();

  await capture.click();
  await page.locator(".dialog-overlay").click({ position: { x: 4, y: 4 } });
  await expect(captureDialog).toHaveCount(0);

  if (await mobileRail.count()) {
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
        contentPaddingBottom: Number.parseFloat(getComputedStyle(content).paddingBottom),
        reservedHeight: railBox.height + navigationBox.height,
      };
    });
    expect(geometry).not.toBeNull();
    expect(geometry!.railBottom).toBeLessThanOrEqual(geometry!.navigationTop + 1);
    expect(geometry!.contentPaddingBottom).toBeGreaterThanOrEqual(geometry!.reservedHeight - 4);
  }

  await add.click();
  const hub = page.getByRole("dialog", { name: "Add to HausKlar" });
  await expect(hub.getByRole("button", { name: /Shopping item/ })).toBeVisible();
  await expect(hub.getByRole("button", { name: /Record medicine/ })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(add).toBeFocused();
});
