import { afterEach, expect, test, vi } from "vitest";
import worker, { signedHeaders } from "./index";

const secret = "terrain-proxy-test-secret-32-bytes";
const assetFetch = vi.fn(async () => new Response("website"));
const env: Env = {
  MCP_ORIGIN: "https://aviation-mcp-server.fly.dev",
  EDGE_PROXY_SECRET: secret,
  ASSETS: {
    fetch: assetFetch,
    connect: () => {
      throw new Error("Unexpected socket connection");
    },
  },
};
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  assetFetch.mockClear();
});

test("replaces forged client assertions with a signature compatible with Swift", async () => {
  const request = new Request("https://aviation-mcp.org/mcp", {
    headers: {
      "CF-Connecting-IP": "192.0.2.1",
      "X-Aviation-Client-IP": "203.0.113.1",
      "X-Aviation-Client-Signature": "forged",
    },
  });
  const headers = await signedHeaders(request, secret, 1800000000000);
  expect(headers.get("X-Aviation-Client-IP")).toBe("192.0.2.1");
  expect(headers.get("X-Aviation-Client-Signature")).toBe(
    "uLwsO1Ljka1wmuEc48hVEmpqDsxER7Yw67qSYGgsfss=",
  );
});

test("streams MCP bodies and preserves status, protocol headers, and retry information", async () => {
  const upstream = vi.fn(async (request: Request) => {
    expect(request.url).toBe(
      "https://aviation-mcp-server.fly.dev/mcp?client=claude",
    );
    expect(request.method).toBe("POST");
    expect(request.redirect).toBe("manual");
    expect(request.headers.get("Origin")).toBe("https://aviation-mcp.org");
    expect(request.headers.get("MCP-Protocol-Version")).toBe("2025-11-25");
    expect(await request.json()).toEqual({
      jsonrpc: "2.0",
      id: 7,
      method: "tools/list",
    });
    return new Response("rate limited", {
      status: 429,
      headers: {
        "Retry-After": "4",
        Via: "1.1 fly.io",
        "Fly-Request-Id": "01M68M1B-sjc",
      },
    });
  });
  vi.stubGlobal("fetch", upstream);
  const request = new Request("https://aviation-mcp.org/mcp?client=claude", {
    method: "POST",
    headers: {
      "CF-Connecting-IP": "192.0.2.1",
      Origin: "https://aviation-mcp.org",
      "MCP-Protocol-Version": "2025-11-25",
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 7, method: "tools/list" }),
  });
  const response = await worker.fetch(request, env);
  expect(response.status).toBe(429);
  expect(response.headers.get("Retry-After")).toBe("4");
  expect(response.headers.get("Cache-Control")).toBe("no-store");
  expect(response.headers.get("Via")).toBeNull();
  expect(response.headers.get("Fly-Request-Id")).toBeNull();
  expect(response.headers.get("Strict-Transport-Security")).toBe(
    "max-age=31536000; includeSubDomains",
  );
  expect(await response.text()).toBe("rate limited");
  expect(upstream).toHaveBeenCalledOnce();
  expect(assetFetch).not.toHaveBeenCalled();
});

test("keeps site and operational requests off the Fly origin", async () => {
  const upstream = vi.fn();
  vi.stubGlobal("fetch", upstream);
  const paths = ["/", "/assets/site.js", "/mcp/unknown", "/ready", "/metrics"];
  for (const path of paths) {
    const response = await worker.fetch(
      new Request(`https://aviation-mcp.org${path}`),
      env,
    );
    expect(await response.text()).toBe("website");
  }
  expect(upstream).not.toHaveBeenCalled();
  expect(assetFetch).toHaveBeenCalledTimes(paths.length);
});

test("answers health checks, non-POST methods and plain HTTP at the edge", async () => {
  const upstream = vi.fn();
  vi.stubGlobal("fetch", upstream);
  const health = await worker.fetch(
    new Request("https://aviation-mcp.org/health"),
    env,
  );
  expect(health.status).toBe(200);
  expect(health.headers.get("Strict-Transport-Security")).toBe(
    "max-age=31536000; includeSubDomains",
  );
  expect(await health.json()).toEqual({ status: "ok" });
  for (const method of ["GET", "HEAD", "OPTIONS", "DELETE"]) {
    const response = await worker.fetch(
      new Request("https://aviation-mcp.org/mcp", { method }),
      env,
    );
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
  }
  const insecure = await worker.fetch(
    new Request("http://aviation-mcp.org/mcp", { method: "POST", body: "{}" }),
    env,
  );
  expect(insecure.status).toBe(403);
  expect(insecure.headers.get("Strict-Transport-Security")).toBeNull();
  expect(await insecure.json()).toMatchObject({ error: "https_required" });
  expect(upstream).not.toHaveBeenCalled();
  expect(assetFetch).not.toHaveBeenCalled();
});

test("fails closed when signing configuration is missing and reports upstream outages", async () => {
  const request = new Request("https://aviation-mcp.org/mcp", {
    method: "POST",
    headers: { "CF-Connecting-IP": "192.0.2.1" },
  });
  const upstream = vi.fn().mockRejectedValue(new Error("offline"));
  vi.stubGlobal("fetch", upstream);
  expect(
    (await worker.fetch(request, { ...env, EDGE_PROXY_SECRET: "" })).status,
  ).toBe(503);
  expect(upstream).not.toHaveBeenCalled();
  expect((await worker.fetch(request, env)).status).toBe(502);
});
