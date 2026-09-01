import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page, type TestInfo } from "@playwright/test";

const email = process.env.E2E_EMAIL;
const password = process.env.E2E_PASSWORD;

test.skip(
  !email || !password,
  "E2E_EMAIL and E2E_PASSWORD are required for live Fitness checks.",
);

async function signIn(page: Page) {
  await page.goto("/");
  const emailField = page.getByLabel("Email");
  const fitnessTab = page
    .locator('nav[aria-label="Main navigation"]:visible')
    .getByRole("button", { name: "Fitness", exact: true });
  await expect(emailField.or(fitnessTab)).toBeVisible({ timeout: 15_000 });
  if (await emailField.isVisible()) {
    await emailField.fill(email!);
    await page.getByLabel("Password", { exact: true }).fill(password!);
    await page.getByRole("button", { name: "Sign in" }).click();
  }
  await expect(fitnessTab).toBeVisible({ timeout: 15_000 });
  await fitnessTab.click();
  await expect(page.getByRole("heading", { name: "Review", exact: true })).toBeVisible({
    timeout: 15_000,
  });
}

async function expectNoOverflow(page: Page) {
  const geometry = await page.evaluate(() => ({
    viewport: innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(geometry.document, JSON.stringify(geometry)).toBeLessThanOrEqual(
    geometry.viewport + 1,
  );
  expect(geometry.body, JSON.stringify(geometry)).toBeLessThanOrEqual(
    geometry.viewport + 1,
  );
}

test("deployed Fitness is usable across its everyday destinations", async ({ page }, testInfo: TestInfo) => {
  test.setTimeout(120_000);
  const pageErrors: string[] = [];
  const serverErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("response", (response) => {
    if (response.status() >= 500) serverErrors.push(`${response.status()} ${response.url()}`);
  });

  await signIn(page);
  const navigation = page.getByRole("navigation", { name: "Fitness sections" });
  await expect(navigation.getByRole("button")).toHaveCount(4);
  expect(await navigation.getByRole("button").allTextContents()).toEqual([
    "Review",
    "Food",
    "Train",
    "More",
  ]);

  for (const destination of [
    { tab: "Review", heading: "Review" },
    { tab: "Food", heading: "Log" },
    { tab: "Train", heading: "Sessions" },
    { tab: "More", heading: "More" },
  ] as const) {
    await navigation.getByRole("button", { name: destination.tab, exact: true }).click();
    await expect(page.getByRole("heading", { name: destination.heading, exact: true })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.locator(".fitness-module [aria-busy='true']")).toHaveCount(0, {
      timeout: 15_000,
    });
    await expectNoOverflow(page);
    const results = await new AxeBuilder({ page })
      .include(".fitness-module")
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze();
    expect(
      results.violations.map(({ id, impact, nodes }) => ({
        id,
        impact,
        targets: nodes.map((node) => node.target),
      })),
    ).toEqual([]);
    await page.screenshot({
      path: testInfo.outputPath(`fitness-${destination.tab.toLowerCase()}.png`),
      fullPage: false,
    });
  }

  await expect(page.locator(".fitness-module")).not.toContainText(
    /provider|model|evidence id|validation trace|sync queue|stale data/i,
  );
  expect(serverErrors).toEqual([]);
  expect(pageErrors).toEqual([]);
});
