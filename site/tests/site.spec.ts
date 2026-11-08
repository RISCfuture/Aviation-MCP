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

test("documents each aircraft in keyboard-operable tabs on an unlisted page", async ({
  page,
  context,
  request,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/performance/");
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute(
    "content",
    "noindex",
  );
  const tabs = page.getByRole("tablist", { name: "Aircraft" });
  const sf50 = tabs.getByRole("tab", { name: "Cirrus SF50" });
  const sr22 = tabs.getByRole("tab", { name: "Cirrus SR22" });
  await expect(sf50).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tabpanel")).toHaveCount(1);
  await expect(page.getByRole("tabpanel")).toContainText("g2_updated_thrust");

  await sf50.focus();
  await page.keyboard.press("ArrowRight");
  await expect(sr22).toBeFocused();
  await expect(sr22).toHaveAttribute("aria-selected", "true");
  await expect(page).toHaveURL(/#sr22$/);
  const panel = page.getByRole("tabpanel", { name: "Cirrus SR22" });
  await expect(panel).toContainText("hartzell_propeller");
  await expect(page.locator("#sf50")).toBeHidden();
  await panel
    .getByRole("button", { name: "Copy question: SR22 takeoff", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toContain("Boulder (KBDU)");
  await sr22.focus();
  await page.keyboard.press("Home");
  await expect(sf50).toHaveAttribute("aria-selected", "true");
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);

  await page.goto("/performance/#sr22");
  await expect(sr22).toHaveAttribute("aria-selected", "true");

  await page.goto("/");
  await expect(page.locator('a[href*="performance"]')).toHaveCount(0);
  const sitemap = await (await request.get("/sitemap.xml")).text();
  expect(sitemap).not.toContain("performance");
});

test("shows every aircraft's tools and questions without JavaScript", async ({
  browser,
  viewport,
}) => {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    viewport,
  });
  const page = await context.newPage();
  await page.goto("/performance/");
  await expect(page.locator("#sf50")).toBeVisible();
  await expect(page.locator("#sr22")).toBeVisible();
  await expect(page.locator(".tool-question blockquote")).toHaveCount(8);
  await expect(
    page.getByRole("navigation", { name: "Aircraft" }).getByRole("link"),
  ).toHaveText(["Cirrus SF50", "Cirrus SR22"]);
  await context.close();
});
