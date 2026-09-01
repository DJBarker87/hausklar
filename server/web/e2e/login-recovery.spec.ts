import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";

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

test("password recovery is usable and recoverable at 375px", async ({ page }, testInfo: TestInfo) => {
  test.skip(testInfo.project.name !== "mobile", "This check targets the phone layout.");

  await page.route("**/api/auth/web/session", (route) => route.fulfill({
    status: 401,
    contentType: "application/json",
    body: JSON.stringify({ detail: "No active session" }),
  }));
  await page.route("**/api/auth/web/refresh", (route) => route.fulfill({ status: 401 }));

  let resetAttempts = 0;
  let submittedEmail = "";
  await page.route("**/api/auth/forgot-password", async (route) => {
    resetAttempts += 1;
    submittedEmail = (await route.request().postDataJSON() as { email: string }).email;
    if (resetAttempts === 1) {
      await route.fulfill({
        status: 503,
        contentType: "application/json",
        body: JSON.stringify({ detail: "Reset email is temporarily unavailable." }),
      });
      return;
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ message: "If that email is registered, reset instructions have been sent." }),
    });
  });

  await page.goto("/");
  await expect(page.getByRole("heading", { name: "HausKlar" })).toBeVisible();
  await page.getByLabel("Email").fill("kat@example.invalid");
  await page.getByRole("button", { name: "Forgot password?" }).click();

  const email = page.getByLabel("Email");
  await expect(email).toHaveValue("kat@example.invalid");
  await page.getByRole("button", { name: "Send reset link" }).click();
  await expect(page.getByRole("alert")).toHaveText("Reset email is temporarily unavailable.");
  await expect(email).toBeFocused();
  await expect(email).toHaveValue("kat@example.invalid");
  await page.screenshot({ path: testInfo.outputPath("password-reset-retry.png"), fullPage: false });

  await page.getByRole("button", { name: "Send reset link" }).click();
  await expect(page.getByRole("heading", { name: "Check your inbox" })).toBeVisible();
  expect(resetAttempts).toBe(2);
  expect(submittedEmail).toBe("kat@example.invalid");
  await expectNoDocumentOverflow(page);
  await expectMinimumTouchSize(page.locator("button:visible, input:visible, a:visible"));
  await page.screenshot({ path: testInfo.outputPath("password-reset-sent.png"), fullPage: false });
});
