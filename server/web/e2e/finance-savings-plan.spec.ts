import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";

const email = process.env.E2E_EMAIL;
const password = process.env.E2E_PASSWORD;
const allowWrites = process.env.E2E_ALLOW_WRITES === "1";

test.skip(!email || !password, "E2E_EMAIL and E2E_PASSWORD are required for Finance checks.");

async function signIn(page: Page) {
  await page.goto("/");
  const emailField = page.getByLabel("Email");
  const mainNavigation = page.locator('nav[aria-label="Main navigation"]:visible');
  await expect(emailField.or(mainNavigation)).toBeVisible({ timeout: 15_000 });
  if (await emailField.isVisible()) {
    await emailField.fill(email!);
    await page.getByLabel("Password", { exact: true }).fill(password!);
    await page.getByRole("button", { name: "Sign in" }).click();
  }
  await expect(mainNavigation).toBeVisible({ timeout: 15_000 });
}

async function openFinance(page: Page) {
  const mainNavigation = page.locator('nav[aria-label="Main navigation"]:visible');
  const financeButton = mainNavigation.getByRole("button", { name: "Finance", exact: true });
  if (await financeButton.isVisible()) {
    await financeButton.click();
  } else {
    await mainNavigation.getByRole("button", { name: "More", exact: true }).click();
    await page.getByRole("dialog", { name: "More HausKlar" }).getByRole("button", { name: /Finance/ }).click();
  }
  await expect(page.getByRole("heading", { name: "Savings plan", exact: true })).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0, { timeout: 15_000 });
}

async function expectNoDocumentOverflow(page: Page) {
  const width = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(width.document, JSON.stringify(width)).toBeLessThanOrEqual(width.viewport + 1);
  expect(width.body, JSON.stringify(width)).toBeLessThanOrEqual(width.viewport + 1);
}

async function expectMinimumTouchSize(locator: Locator) {
  const undersized = await locator.evaluateAll((elements) => elements.map((element) => {
    const box = element.getBoundingClientRect();
    return {
      label: element.getAttribute("aria-label") || element.textContent?.trim() || element.id,
      width: Math.round(box.width),
      height: Math.round(box.height),
    };
  }).filter(({ width, height }) => width < 44 || height < 44));
  expect(undersized).toEqual([]);
}

async function setFinanceDetailMode(page: Page, mode: "simple" | "full") {
  const desktopControl = page.getByRole("button", {
    name: mode === "simple" ? "Simple" : "Full",
    exact: true,
  });
  if (await desktopControl.isVisible()) {
    if (await desktopControl.getAttribute("aria-pressed") !== "true") await desktopControl.click();
    return;
  }

  const mobileControl = page.locator(".finance-mobile-detail-toggle");
  const action = (await mobileControl.textContent())?.trim();
  if ((mode === "simple" && action === "Simple view") || (mode === "full" && action === "Full details")) {
    await mobileControl.click();
  }
}

test("Savings plan works with one goal and this month's position", async ({ page }, testInfo: TestInfo) => {
  const serverErrors: string[] = [];
  const pageErrors: string[] = [];
  page.on("response", (response) => {
    if (response.status() >= 500) serverErrors.push(`${response.status()} ${response.url()}`);
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await signIn(page);
  await openFinance(page);
  await setFinanceDetailMode(page, "simple");

  await expect(page.getByRole("heading", { name: "Your savings goals" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "This month" })).toBeVisible();
  const holidayGoal = page.getByRole("listitem").filter({ hasText: "Synthetic public demo record 16" });
  await expect(holidayGoal).toBeVisible();
  await expect(holidayGoal.getByText("Required each month").locator("..")).toContainText("£250.00");
  await expect(page.getByText("The same money is never shown as funding two goals.")).toBeVisible();
  await expect(page.getByText(/CANNOT_MODEL|cannot model|not enough data/i)).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Check a planned purchase" })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Money outlook" })).toHaveCount(0);
  await expectNoDocumentOverflow(page);

  if (testInfo.project.name === "mobile") {
    await expectMinimumTouchSize(page.locator(".finance-goal-overview-card button:visible"));
    await expectMinimumTouchSize(page.locator(".finance-subnav button:visible"));
  }

  await page.screenshot({ path: testInfo.outputPath("savings-plan-light.png"), fullPage: true });
  await page.locator('button[aria-label="Use dark appearance"]').evaluate((button: HTMLButtonElement) => button.click());
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.screenshot({ path: testInfo.outputPath("savings-plan-dark.png"), fullPage: true });

  await setFinanceDetailMode(page, "full");
  await expect(page.getByRole("heading", { name: "Check a planned purchase" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Money outlook" })).toBeVisible();

  await page.locator('button[aria-label="Use light appearance"]').evaluate((button: HTMLButtonElement) => button.click());
  await page.locator(".finance-section-nav").getByRole("button", { name: "Explore", exact: true }).click();
  const netWorth = page.locator(".finance-net-worth-history");
  await expect(netWorth).toBeVisible({ timeout: 15_000 });
  await expect(netWorth.locator("svg.finance-net-worth-chart")).toBeVisible();
  await expect(netWorth.getByText("Contributions and withdrawals are separate from market movement.")).toBeVisible();
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("net-worth.png"), fullPage: true });

  expect(serverErrors).toEqual([]);
  expect(pageErrors).toEqual([]);
});

test("an optional second savings goal can coexist with the first", async ({ page }, testInfo: TestInfo) => {
  test.skip(!allowWrites, "E2E_ALLOW_WRITES=1 is required for the temporary create-and-clean-up check.");

  await signIn(page);
  await openFinance(page);
  await setFinanceDetailMode(page, "simple");

  const goalName = `Optional second goal (${testInfo.project.name})`;
  const deadline = new Date();
  deadline.setUTCFullYear(deadline.getUTCFullYear() + 1);
  const deadlineValue = deadline.toISOString().slice(0, 10);
  let createdGoalID = "";

  try {
    await page.getByText("Savings goal and three plans", { exact: true }).click();
    await page.getByRole("button", { name: "New savings goal", exact: true }).click();
    await page.getByLabel("What are you saving for?").fill(goalName);
    await page.getByLabel("Target amount").fill("600");
    await page.getByLabel("Target date").fill(deadlineValue);

    const createResponsePromise = page.waitForResponse((response) => (
      response.request().method() === "POST"
      && new URL(response.url()).pathname === "/api/finance/goals"
    ));
    await page.getByRole("button", { name: "Save goal", exact: true }).click();
    const createResponse = await createResponsePromise;
    expect(createResponse.status()).toBe(201);
    const created = await createResponse.json() as { id: string };
    createdGoalID = created.id;

    const goals = page.getByRole("list").filter({ has: page.locator(".finance-goal-overview-card") });
    await expect(goals.getByRole("listitem").filter({ hasText: "Synthetic public demo record 16" })).toBeVisible();
    await expect(goals.getByRole("listitem").filter({ hasText: goalName })).toContainText("Not chosen yet");
    await expect(page.getByText("The same money is never shown as funding two goals.")).toBeVisible();
  } finally {
    if (createdGoalID) {
      const cleanupStatus = await page.evaluate(async (goalID) => {
        const response = await fetch(`/api/finance/goals/${encodeURIComponent(goalID)}`, {
          method: "DELETE",
          credentials: "same-origin",
        });
        return response.status;
      }, createdGoalID);
      expect(cleanupStatus).toBe(204);
    }
  }
});
