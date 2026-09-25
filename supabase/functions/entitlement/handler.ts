import { deriveEntitlement, type GrantRow } from "./contract.ts";
import type { EntitlementPayload } from "./jws.ts";

export type { EntitlementPayload } from "./jws.ts";

export type EntitlementDependencies = Readonly<{
  issuer: string;
  audience: string;
  verifyAccessToken(token: string): Promise<string>;
  loadGrant(userID: string): Promise<GrantRow | null>;
  sign(payload: EntitlementPayload): Promise<string>;
  now(): Date;
  randomUUID(): string;
}>;

type ErrorCode =
  | "method_not_allowed"
  | "invalid_request"
  | "unauthorized"
  | "service_unavailable";

const MAXIMUM_REQUEST_BYTES = 1_024;

export function createEntitlementHandler(
  dependencies: EntitlementDependencies,
): (request: Request) => Promise<Response> {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return errorResponse(dependencies, 405, "method_not_allowed", { Allow: "POST" });
    }
    if (!isJSONRequest(request)) {
      return errorResponse(dependencies, 400, "invalid_request");
    }

    const body = await readRequestBody(request);
    if (!body) {
      return errorResponse(dependencies, 400, "invalid_request");
    }

    const accessToken = bearerToken(request.headers.get("Authorization"));
    if (!accessToken) {
      return errorResponse(dependencies, 401, "unauthorized");
    }

    let verifiedUserID: string;
    try {
      verifiedUserID = await dependencies.verifyAccessToken(accessToken);
    } catch {
      return errorResponse(dependencies, 401, "unauthorized");
    }
    if (!verifiedUserID || verifiedUserID !== verifiedUserID.trim()) {
      return errorResponse(dependencies, 401, "unauthorized");
    }

    try {
      const now = dependencies.now();
      const nowSeconds = Math.floor(now.getTime() / 1_000);
      if (!Number.isSafeInteger(nowSeconds)) throw new Error("invalidClock");
      const grant = await dependencies.loadGrant(verifiedUserID);
      const derived = deriveEntitlement(grant?.user_id === verifiedUserID ? grant : null, now);
      const payload: EntitlementPayload = {
        iss: dependencies.issuer,
        aud: dependencies.audience,
        sub: verifiedUserID,
        iat: nowSeconds,
        nbf: nowSeconds - 30,
        exp: nowSeconds + 86_400,
        jti: dependencies.randomUUID(),
        ...derived,
      };
      const token = await dependencies.sign(payload);
      if (!token) throw new Error("emptyToken");
      return jsonResponse(200, { token });
    } catch {
      return errorResponse(dependencies, 503, "service_unavailable");
    }
  };
}

function isJSONRequest(request: Request): boolean {
  const contentType = request.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json") return false;

  const declaredLength = request.headers.get("Content-Length");
  if (declaredLength !== null) {
    const value = Number(declaredLength);
    if (!Number.isSafeInteger(value) || value < 0 || value > MAXIMUM_REQUEST_BYTES) return false;
  }
  return true;
}

async function readRequestBody(request: Request): Promise<{ schema: 1; platform: "macos" } | null> {
  try {
    const text = await request.text();
    if (new TextEncoder().encode(text).byteLength > MAXIMUM_REQUEST_BYTES) return null;
    const value: unknown = JSON.parse(text);
    if (!isRecord(value)) return null;
    const keys = Object.keys(value).sort();
    if (keys.length !== 2 || keys[0] !== "platform" || keys[1] !== "schema") return null;
    if (value.schema !== 1 || value.platform !== "macos") return null;
    return { schema: 1, platform: "macos" };
  } catch {
    return null;
  }
}

function bearerToken(value: string | null): string | null {
  const match = value?.match(/^Bearer ([^\s,]+)$/);
  return match?.[1] ?? null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorResponse(
  dependencies: EntitlementDependencies,
  status: number,
  code: ErrorCode,
  extraHeaders: HeadersInit = {},
): Response {
  let requestID = "request-unavailable";
  try {
    requestID = dependencies.randomUUID();
  } catch {
    // Keep the response bounded even when the injected ID source is unavailable.
  }
  return jsonResponse(status, { code, requestID }, extraHeaders);
}

function jsonResponse(status: number, value: unknown, extraHeaders: HeadersInit = {}): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(JSON.stringify(value), { status, headers });
}
