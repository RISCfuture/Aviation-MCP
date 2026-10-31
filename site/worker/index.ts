const noStore = { "Cache-Control": "no-store" };
const originHeaders = ["Via", "Fly-Request-Id"];
/** Matches the static assets' HSTS header in public/_headers. */
const transportSecurity = "max-age=31536000; includeSubDomains";

/** Signs the edge-observed client address, which the origin requires and meters per client. */
export async function signedHeaders(
  request: Request,
  secret: string,
  now = Date.now(),
): Promise<Headers> {
  const headers = new Headers(request.headers);
  for (const name of [
    "X-Aviation-Client-IP",
    "X-Aviation-Client-Time",
    "X-Aviation-Client-Signature",
  ])
    headers.delete(name);
  const ip = request.headers.get("CF-Connecting-IP");
  if (!ip || !/^[a-f\d:.]{1,45}$/i.test(ip))
    throw new Error("Missing edge client address");
  const timestamp = String(Math.floor(now / 1000));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}\n${ip}`),
  );
  headers.set("X-Aviation-Client-IP", ip);
  headers.set("X-Aviation-Client-Time", timestamp);
  headers.set(
    "X-Aviation-Client-Signature",
    btoa(String.fromCharCode(...new Uint8Array(signature))),
  );
  headers.delete("Host");
  return headers;
}

/** Answers requests the edge can settle without waking the Fly origin. */
function edgeResponse(request: Request, url: URL): Response | undefined {
  if (url.pathname === "/health")
    return Response.json({ status: "ok" }, { headers: noStore });
  if (url.protocol !== "https:")
    return Response.json(
      { error: "https_required", endpoint: `https://${url.host}/mcp` },
      { status: 403, headers: noStore },
    );
  if (request.method !== "POST")
    return new Response(null, {
      status: 405,
      headers: { ...noStore, Allow: "POST" },
    });
  return undefined;
}

/** Streams one MCP POST to the fixed Fly origin with a signed client address. */
async function proxy(request: Request, url: URL, env: Env): Promise<Response> {
  if (!env.EDGE_PROXY_SECRET || env.EDGE_PROXY_SECRET.length < 32) {
    return Response.json(
      { error: "proxy_unavailable" },
      { status: 503, headers: { ...noStore, "Retry-After": "60" } },
    );
  }
  const target = new URL(env.MCP_ORIGIN);
  target.pathname = url.pathname;
  target.search = url.search;
  try {
    const headers = await signedHeaders(request, env.EDGE_PROXY_SECRET);
    const upstream = new Request(new Request(target, request), {
      headers,
      redirect: "manual",
      signal: request.signal,
    });
    const result = await fetch(upstream, { cache: "no-store" });
    const response = new Response(result.body, result);
    response.headers.set("Cache-Control", "no-store");
    for (const name of originHeaders) response.headers.delete(name);
    return response;
  } catch {
    return Response.json(
      { error: "upstream_unavailable" },
      { status: 502, headers: { ...noStore, "Retry-After": "5" } },
    );
  }
}

/** Serves static site assets, answers health checks, and streams MCP traffic to Fly. */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/mcp" && url.pathname !== "/health")
      return env.ASSETS.fetch(request);
    const response =
      edgeResponse(request, url) ?? (await proxy(request, url, env));
    if (url.protocol === "https:")
      response.headers.set("Strict-Transport-Security", transportSecurity);
    return response;
  },
} satisfies ExportedHandler<Env>;
