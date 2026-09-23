import { createClient } from "@supabase/supabase-js";
import type { GrantRow } from "./contract.ts";
import { createEntitlementHandler } from "./handler.ts";
import { signEntitlement } from "./jws.ts";

type RuntimeEnvironment = Readonly<Record<string, string | undefined>>;

type RuntimeConfiguration = Readonly<{
  supabaseURL: string;
  serviceRoleKey: string;
  privateKeyPKCS8: string;
  keyID: string;
  issuer: string;
  audience: string;
}>;

export async function createRuntimeHandler(
  environment: RuntimeEnvironment,
): Promise<(request: Request) => Promise<Response>> {
  const configuration = runtimeConfiguration(environment);
  if (!configuration) return unavailableHandler;

  try {
    const privateKey = await importPrivateKey(configuration.privateKeyPKCS8);
    const client = createClient(configuration.supabaseURL, configuration.serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    return createEntitlementHandler({
      issuer: configuration.issuer,
      audience: configuration.audience,
      now: () => new Date(),
      randomUUID: () => crypto.randomUUID(),
      async verifyAccessToken(token: string): Promise<string> {
        const { data, error } = await client.auth.getUser(token);
        if (error || !data.user?.id) throw new Error("authenticationFailed");
        return data.user.id;
      },
      async loadGrant(userID: string): Promise<GrantRow | null> {
        const { data, error } = await client
          .schema("private")
          .from("entitlement_grants")
          .select(
            "user_id,plan,status,features,max_video_height,valid_from,valid_until,revision",
          )
          .eq("user_id", userID)
          .maybeSingle();
        if (error) throw new Error("grantLookupFailed");
        return data as GrantRow | null;
      },
      sign: (payload) => signEntitlement(payload, privateKey, configuration.keyID),
    });
  } catch {
    return unavailableHandler;
  }
}

function runtimeConfiguration(environment: RuntimeEnvironment): RuntimeConfiguration | null {
  const supabaseURL = environment.SUPABASE_URL;
  const serviceRoleKey = environment.SUPABASE_SERVICE_ROLE_KEY;
  const privateKeyPKCS8 = environment.ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8;
  const keyID = environment.ENTITLEMENT_ES256_KID;
  const issuer = environment.ENTITLEMENT_ISSUER;
  const audience = environment.ENTITLEMENT_AUDIENCE;
  if (
    !isTrustedHTTPSURL(supabaseURL) ||
    !serviceRoleKey ||
    !privateKeyPKCS8 ||
    !keyID ||
    !issuer ||
    !audience ||
    !/^[A-Za-z0-9._-]{1,64}$/.test(keyID)
  ) {
    return null;
  }
  return { supabaseURL, serviceRoleKey, privateKeyPKCS8, keyID, issuer, audience };
}

function isTrustedHTTPSURL(value: string | undefined): value is string {
  if (!value || value !== value.trim()) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" &&
      Boolean(url.hostname) &&
      !url.username &&
      !url.password &&
      !url.port &&
      !url.search &&
      !url.hash &&
      (url.pathname === "/" || url.pathname === "");
  } catch {
    return false;
  }
}

async function importPrivateKey(encoded: string): Promise<CryptoKey> {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error("keyImportFailed");
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
  } catch {
    throw new Error("keyImportFailed");
  }
  try {
    return await crypto.subtle.importKey(
      "pkcs8",
      bytes.buffer as ArrayBuffer,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new Error("keyImportFailed");
  }
}

function unavailableHandler(_request: Request): Promise<Response> {
  return Promise.resolve(
    new Response(
      JSON.stringify({ code: "service_unavailable", requestID: crypto.randomUUID() }),
      {
        status: 503,
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
        },
      },
    ),
  );
}

if (import.meta.main) {
  const handler = await createRuntimeHandler({
    SUPABASE_URL: Deno.env.get("SUPABASE_URL"),
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
    ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8: Deno.env.get(
      "ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8",
    ),
    ENTITLEMENT_ES256_KID: Deno.env.get("ENTITLEMENT_ES256_KID"),
    ENTITLEMENT_ISSUER: Deno.env.get("ENTITLEMENT_ISSUER"),
    ENTITLEMENT_AUDIENCE: Deno.env.get("ENTITLEMENT_AUDIENCE"),
  });
  Deno.serve(handler);
}
