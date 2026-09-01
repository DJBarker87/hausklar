import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";

const email = process.env.E2E_EMAIL;
const password = process.env.E2E_PASSWORD;

test.skip(!email || !password, "E2E_EMAIL and E2E_PASSWORD are required for live production checks.");

async function signIn(page: Page) {
  await page.goto("/");
  const emailField = page.getByLabel("Email");
  const calendarTab = page.locator('nav[aria-label="Main navigation"]:visible').getByRole("button", { name: "Calendar", exact: true });
  await expect(emailField.or(calendarTab)).toBeVisible({ timeout: 15_000 });
  if (await emailField.isVisible()) {
    await emailField.fill(email!);
    await page.getByLabel("Password", { exact: true }).fill(password!);
    await page.getByRole("button", { name: "Sign in" }).click();
  }
  await expect(calendarTab).toBeVisible({ timeout: 15_000 });
}

async function expectNoDocumentOverflow(page: Page) {
  const overflow = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body.scrollWidth,
  }));
  expect(overflow.document, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
  expect(overflow.body, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport + 1);
}

async function expectMinimumTouchSize(locator: Locator) {
  await expect(locator.first()).toBeVisible({ timeout: 15_000 });
  expect(await locator.count()).toBeGreaterThan(0);
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

async function openTab(page: Page, label: string) {
  await page.locator('nav[aria-label="Main navigation"]:visible').getByRole("button", { name: label, exact: true }).click();
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0, { timeout: 15_000 });
  await expectNoDocumentOverflow(page);
}

async function expectActionDoorwayClear(page: Page) {
  const mobileRail = page.locator(".app-action-rail--mobile:visible");
  const sidebarRail = page.locator(".app-action-rail--sidebar:visible");
  const rail = (await mobileRail.count()) ? mobileRail : sidebarRail;
  const launcher = rail.getByRole("button", { name: "Add or ask Bismarck", exact: true });
  await expect(launcher).toBeVisible();
  await launcher.click();
  const layer = rail.getByRole("dialog", { name: "Quick actions" });
  const add = layer.getByRole("button", { name: "Add", exact: true });
  const bismarck = layer.getByRole("button", { name: "Bismarck", exact: true });
  await expect(add).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(bismarck).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(launcher).toBeFocused();

  if (await mobileRail.count()) {
    await expectMinimumTouchSize(launcher);
    const geometry = await page.evaluate(() => {
      const actionRail = document.querySelector<HTMLElement>(".app-action-rail--mobile");
      const navigation = document.querySelector<HTMLElement>(".mobile-nav");
      const content = document.querySelector<HTMLElement>(".app-content");
      if (!actionRail || !navigation || !content) return null;
      const railBox = actionRail.getBoundingClientRect();
      const navigationBox = navigation.getBoundingClientRect();
      return {
        railBottom: Math.round(railBox.bottom),
        navigationTop: Math.round(navigationBox.top),
        contentPaddingBottom: Math.round(Number.parseFloat(getComputedStyle(content).paddingBottom)),
        reservedHeight: Math.round(railBox.height + navigationBox.height),
      };
    });
    expect(geometry).not.toBeNull();
    expect(geometry!.railBottom).toBeLessThanOrEqual(geometry!.navigationTop + 1);
    expect(geometry!.contentPaddingBottom).toBeGreaterThanOrEqual(geometry!.reservedHeight - 4);
  } else {
    const separated = await page.evaluate(() => {
      const railBox = document.querySelector<HTMLElement>(".app-action-rail--sidebar")?.getBoundingClientRect();
      const contentBox = document.querySelector<HTMLElement>(".app-content")?.getBoundingClientRect();
      return railBox && contentBox ? railBox.right <= contentBox.left : false;
    });
    expect(separated).toBe(true);
  }
}

test("mirrored family workflow is usable at each supported width", async ({ page }, testInfo: TestInfo) => {
  const serverErrors: string[] = [];
  const pageErrors: string[] = [];
  page.on("response", (response) => { if (response.status() >= 500) serverErrors.push(`${response.status()} ${response.url()}`); });
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await signIn(page);
  await expect(page.getByRole("region", { name: "Today at a glance" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Up next" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "To do" })).toBeVisible();
  await expectActionDoorwayClear(page);
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("today.png"), fullPage: false });

  await openTab(page, "Calendar");
  await expect(page.getByRole("region", { name: "Family calendar" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Week" })).toHaveAttribute("aria-pressed", "true");
  const actionRail = page.locator(".app-action-rail:visible");
  const launcher = actionRail.getByRole("button", { name: "Add or ask Bismarck", exact: true });
  await launcher.click();
  await actionRail.getByRole("dialog", { name: "Quick actions" }).getByRole("button", { name: "Add", exact: true }).click();
  const addHub = page.getByRole("dialog", { name: "Add to HausKlar" });
  await expect(addHub.getByRole("button", { name: /Event/ })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(launcher).toBeFocused();
  await launcher.click();
  await actionRail.getByRole("dialog", { name: "Quick actions" }).getByRole("button", { name: "Add", exact: true }).click();
  await expect(addHub.getByRole("button", { name: /Event/ })).toBeVisible();
  await addHub.getByRole("button", { name: /Event/ }).click();
  const eventEditor = page.getByRole("dialog", { name: "Add to the plan" });
  await expect(eventEditor.getByLabel("Title")).toBeVisible();
  await expect(eventEditor.getByRole("group", { name: "Who is going?" })).toBeVisible();
  await expect(eventEditor.getByLabel("Everyone")).toBeVisible();
  await eventEditor.getByRole("button", { name: "Close" }).click();
  if (testInfo.project.name === "mobile") {
    await expectMinimumTouchSize(page.locator(".mobile-nav button:visible, .planner-header-actions button:visible, .planner-toolbar button:visible, .planner-people-filter button:visible, .planner-display-trigger:visible"));
  }

  await openTab(page, "Family");
  await expect(page.getByRole("region", { name: "Everyone" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Star Charts/ })).toBeVisible();
  await expect(page.getByRole("button", { name: /Letters & documents/ })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("family.png"), fullPage: false });

  await page.getByRole("button", { name: /Star Charts/ }).click();
  await expect(page.getByRole("heading", { name: "Star Charts", exact: true })).toBeVisible();
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0, { timeout: 15_000 });
  await expect(page.getByText("Owed", { exact: true })).toBeVisible();
  await expect(page.getByRole("group", { name: "Choose child" })).toBeVisible({ timeout: 15_000 });
  await page.screenshot({ path: testInfo.outputPath("star-charts.png"), fullPage: false });
  if (testInfo.project.name === "mobile") {
    await expectMinimumTouchSize(page.locator(".child-filter button:visible, .interactive-star-grid button:visible"));
  }
  await page.locator(".nested-back").click();
  await page.getByRole("button", { name: "Illness", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Illness", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: /illness mode/i })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("illness.png"), fullPage: false });

  await openTab(page, "Family");
  await page.getByRole("button", { name: /Letters & documents/ }).click();
  await expect(page.getByRole("heading", { name: "Documents" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Family documents" })).toBeVisible();
  await page.getByRole("button", { name: "Add document" }).click();
  const capture = page.getByRole("dialog", { name: "Add" });
  await expect(capture.getByRole("button", { name: "Letter or file", exact: true })).toHaveAttribute("aria-pressed", "true");
  await capture.getByRole("button", { name: "Close" }).click();
  if (testInfo.project.name === "mobile") {
    await expectMinimumTouchSize(page.locator(".document-toolbar button:visible, .filter-chips button:visible, .documents-page > .page-header .button:visible"));
  }

  await openTab(page, "Lists");
  await expect(page.getByRole("button", { name: /Meals & Shopping/ })).toBeVisible();
  await page.locator(".ios-list-row").filter({ hasText: "Tasks" }).click();
  await expect(page.getByRole("heading", { name: "Tasks", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Open tasks" })).toBeVisible();
  await page.getByRole("button", { name: "New task" }).click();
  const taskEditor = page.getByRole("dialog", { name: "New task" });
  await expect(taskEditor.getByLabel("Title")).toBeVisible();
  await expect(taskEditor.getByLabel("Due date")).toBeVisible();
  await taskEditor.getByRole("button", { name: "Close" }).click();
  if (testInfo.project.name === "mobile") {
    await expectMinimumTouchSize(page.locator(".task-primary-filters button:visible, .task-category-filter button:visible, .task-check:visible"));
  }
  await page.locator(".nested-back").click();
  await page.getByRole("button", { name: /Meals & Shopping/ }).click();
  await expect(page.getByRole("heading", { name: "Meals", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Plan", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Plan", exact: true }).click();
  await expect(page.getByRole("region", { name: "Weekly meal plan" })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("meals.png"), fullPage: false });

  await openTab(page, "House");
  await expect(page.locator(".home-page")).toBeVisible();
  await expect(page.locator(".home-page [aria-busy=\"true\"]")).toHaveCount(0, { timeout: 15_000 });

  await page.getByRole("button", { name: "Settings and profile" }).click();
  await expect(page.getByRole("dialog", { name: "Settings & profile" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Change password" })).toBeVisible();
  await page.getByRole("button", { name: "Close" }).click();

  const globalActions = page.locator(".app-action-rail:visible");
  const globalLauncher = globalActions.getByRole("button", { name: "Add or ask Bismarck", exact: true });
  await globalLauncher.click();
  await globalActions.getByRole("dialog", { name: "Quick actions" }).getByRole("button", { name: "Bismarck", exact: true }).click();
  const bismarck = page.getByRole("dialog", { name: "Bismarck" });
  await expect(bismarck).toBeVisible();
  const consentHeading = bismarck.getByRole("heading", { name: "Allow Bismarck to use OpenAI?" });
  const assistantLabel = bismarck.getByText("Private family assistant");
  await expect(consentHeading.or(assistantLabel)).toBeVisible();
  if (await consentHeading.isVisible()) {
    await expect(bismarck.getByText("Uses OpenAI with your permission")).toBeVisible();
    await expect(bismarck.getByRole("button", { name: "Not now" })).toBeVisible();
    await expect(bismarck.getByRole("button", { name: "Allow and continue" })).toBeVisible();
  }
  await expect.poll(() => bismarck.evaluate((element) => getComputedStyle(element).opacity)).toBe("1");
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("bismarck.png"), fullPage: false });
  await bismarck.getByRole("button", { name: "Close Bismarck" }).click();
  await expect(globalLauncher).toBeFocused();

  expect(serverErrors).toEqual([]);
  expect(pageErrors).toEqual([]);
});

test("tomorrow check stays calm and touchable at each supported width", async ({ page }, testInfo: TestInfo) => {
  await signIn(page);
  await page.goto("/?view=today&tomorrow=1");
  const card = page.locator(".tomorrow-card");
  await expect(page.getByRole("heading", { name: "Tomorrow, sorted" })).toBeVisible({ timeout: 15_000 });
  await expect(card.getByRole("button", { name: "Looks right" })).toBeVisible();
  await expect(card.getByRole("button", { name: "Fix something" })).toBeVisible();
  await expectMinimumTouchSize(card.getByRole("button"));
  await expectNoDocumentOverflow(page);
  await page.screenshot({ path: testInfo.outputPath("tomorrow-sorted.png"), fullPage: false });
});
