import { expect, test } from "@playwright/test";

test("shows the endpoint up front, tool questions before setup, and copies both", async ({
  page,
  context,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  const activeLink = page
    .getByRole("navigation", { name: "Main navigation" })
    .locator('a[aria-current="location"]');
  await expect(activeLink).toHaveText("About");
  await page
    .getByRole("region", { name: /^What is/ })
    .getByRole("button", { name: "Copy URL" })
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe("https://aviation-mcp.org/mcp");
  await page.getByRole("link", { name: "Explore the tools" }).click();
  await expect(activeLink).toHaveText("Tools");
  await expect(page.locator("#question-terrain")).toContainText(
    "Truckee (KTRK) to Mammoth Yosemite (KMMH)",
  );
  await page.getByRole("button", { name: "Copy question: Terrain" }).click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toContain("Truckee (KTRK) to Mammoth Yosemite (KMMH)");
  await page
    .getByRole("link", { name: "Connect the server", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Connect the server" }),
  ).toBeVisible();
  await expect(activeLink).toHaveText("Connect");
  await page
    .getByRole("region", { name: "Connect the server" })
    .getByRole("button", { name: "Copy URL" })
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe("https://aviation-mcp.org/mcp");
  await expect(
    page.getByRole("link", { name: "OpenAI setup guide" }),
  ).toHaveAttribute("href", /help.openai.com/);
  await expect(
    page.getByRole("link", { name: "Claude setup guide" }),
  ).toHaveAttribute("href", /support.claude.com/);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
  await page
    .getByRole("heading", { name: "Terrain", exact: true })
    .evaluate((heading) =>
      heading.scrollIntoView({ behavior: "instant", block: "start" }),
    );
  await expect(activeLink).toHaveText("Tools");
  await page.getByRole("link", { name: "Aviation MCP home" }).click();
  await expect(activeLink).toHaveText("About");
});

test("keeps core copy and setup usable without JavaScript", async ({
  browser,
  viewport,
}) => {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    viewport,
  });
  const page = await context.newPage();
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "What isAviation MCP?",
  );
  await expect(page.locator("#endpoint-url")).toHaveText(
    "https://aviation-mcp.org/mcp",
  );
  await expect(page.locator(".tool-question blockquote")).toHaveCount(11);
  await expect(page.locator("#question-terrain")).toContainText(
    "highest terrain",
  );
  expect(
    await page
      .locator("main > section")
      .evaluateAll((sections) => sections.map((section) => section.id)),
  ).toEqual(["about", "tools", "connect"]);
  const legalLinks = page
    .getByRole("navigation", { name: "Legal and support" })
    .getByRole("link");
  await expect(legalLinks).toHaveText(["Support", "Privacy", "Terms"]);
  for (const link of await legalLinks.all()) await expect(link).toBeVisible();
  await context.close();
});
