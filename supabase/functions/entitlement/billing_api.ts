export type BillingCommand =
  | Readonly<{ kind: "status" }>
  | Readonly<{ kind: "checkout"; requestID: string }>
  | Readonly<{ kind: "cancel"; requestID: string; orderID: string }>;

export type BillingAPIResult = Readonly<{ status: number; body: Record<string, unknown> }>;
export type BillingAPIDependencies = Readonly<{
  verifyAccessToken(token: string): Promise<string>;
  execute(userID: string, command: BillingCommand): Promise<BillingAPIResult>;
}>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ORDER = /^[A-Za-z0-9_-]{1,20}$/;
const MAX_BYTES = 1024;

export function createBillingAPI(dependencies: BillingAPIDependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return error(405, "method_not_allowed", { Allow: "POST" });
    const url = new URL(request.url);
    const route = url.pathname;
    if (!["/billing/status", "/billing/checkout", "/billing/cancel"].includes(route)) {
      return error(404, "not_found");
    }
    if (
      url.search ||
      request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json"
    ) return error(400, "invalid_request");
    const command = parseCommand(route, await readBody(request));
    if (!command) return error(400, "invalid_request");
    const token = request.headers.get("Authorization")?.match(/^Bearer ([^\s,]{1,4096})$/)?.[1];
    if (!token) return error(401, "unauthorized");
    let userID: string;
    try {
      userID = await dependencies.verifyAccessToken(token);
      if (!UUID.test(userID)) return error(401, "unauthorized");
    } catch {
      return error(401, "unauthorized");
    }
    try {
      const result = await dependencies.execute(userID.toLowerCase(), command);
      return response(result.status, result.body);
    } catch {
      return error(503, "service_unavailable");
    }
  };
}

function parseCommand(route: string, value: unknown): BillingCommand | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (body.schema !== 1) return null;
  const keys = Object.keys(body).sort().join(",");
  if (route === "/billing/status") return keys === "schema" ? { kind: "status" } : null;
  if (typeof body.requestID !== "string" || !UUID.test(body.requestID)) return null;
  const requestID = body.requestID.toLowerCase();
  if (route === "/billing/checkout" && keys === "requestID,schema") {
    return { kind: "checkout", requestID };
  }
  if (
    route === "/billing/cancel" && keys === "orderID,requestID,schema" &&
    typeof body.orderID === "string" && ORDER.test(body.orderID)
  ) return { kind: "cancel", requestID, orderID: body.orderID };
  return null;
}

async function readBody(request: Request): Promise<unknown> {
  const length = request.headers.get("Content-Length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > MAX_BYTES)) return null;
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.byteLength;
      if (size > MAX_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(part.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
}

function error(status: number, code: string, headers: HeadersInit = {}) {
  return response(status, { code }, headers);
}
function response(status: number, body: Record<string, unknown>, extra: HeadersInit = {}) {
  const headers = new Headers(extra);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(JSON.stringify(body), { status, headers });
}
