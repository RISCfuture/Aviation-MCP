const servicePaths = new Set(["/mcp", "/health", "/ready", "/metrics"]);

/** Authenticates the edge-observed client address for the origin's shared rate limiter. */
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

/** Serves static site assets and streams MCP traffic to the fixed Fly origin. */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!servicePaths.has(url.pathname)) return env.ASSETS.fetch(request);
    if (!env.EDGE_PROXY_SECRET || env.EDGE_PROXY_SECRET.length < 32) {
      return Response.json(
        { error: "proxy_unavailable" },
        {
          status: 503,
          headers: { "Retry-After": "60", "Cache-Control": "no-store" },
        },
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
      return response;
    } catch {
      return Response.json(
        { error: "upstream_unavailable" },
        {
          status: 502,
          headers: { "Retry-After": "5", "Cache-Control": "no-store" },
        },
      );
    }
  },
} satisfies ExportedHandler<Env>;
