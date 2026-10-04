import { type EntitlementPayload, signEntitlement } from "./jws.ts";

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = "values differ"): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

function decodeBase64URL(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function decodeJSON(value: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(decodeBase64URL(value)));
}

async function generateEphemeralTestKeyPair(): Promise<CryptoKeyPair> {
  return await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
}

function fixedPayload(): EntitlementPayload {
  return {
    iss: "https://accounts.ytdownloaderpro.example/staging",
    aud: "com.tachouweng.ytdownloaderpro2",
    sub: "11111111-1111-1111-1111-111111111111",
    iat: 1_790_208_000,
    nbf: 1_790_207_970,
    exp: 1_790_294_400,
    jti: "22222222-2222-2222-2222-222222222222",
    schema: 1,
    plan: "pro",
    features: ["download.single", "video.hd"],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: 7,
  };
}

Deno.test("signer emits an exact ES256 compact JWS that verifies", async () => {
  const keyPair = await generateEphemeralTestKeyPair();
  const token = await signEntitlement(
    fixedPayload(),
    keyPair.privateKey,
    "test-es256-2026-09",
  );
  const segments: string[] = token.split(".");
  assertEquals(segments.length, 3);
  const [header, payload, signature] = segments;

  assertEquals(decodeJSON(header), {
    alg: "ES256",
    kid: "test-es256-2026-09",
    typ: "JWT",
  });
  assertEquals(decodeJSON(payload), fixedPayload());
  assertEquals(decodeBase64URL(signature).byteLength, 64);
  assert(
    !segments.some((segment: string) => segment.includes("=")),
    "compact JWS must be unpadded",
  );

  const signatureBytes = decodeBase64URL(signature);
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    keyPair.publicKey,
    signatureBytes.buffer as ArrayBuffer,
    new TextEncoder().encode(`${header}.${payload}`),
  );
  assert(verified, "signature must verify against the matching public key");
  const decodedPayload = decodeJSON(payload);
  assertEquals(Number(decodedPayload.exp) - Number(decodedPayload.iat), 86_400);
});

Deno.test("signer rejects an empty key id and non-signing key", async () => {
  const keyPair = await generateEphemeralTestKeyPair();
  await assertRejects(() => signEntitlement(fixedPayload(), keyPair.privateKey, ""));
  await assertRejects(() => signEntitlement(fixedPayload(), keyPair.publicKey, "test-key"));
});

Deno.test("committed public fixture verifies the exact cross-runtime entitlement", async () => {
  const fixtureTokenURL = new URL(
    "../../../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-valid-es256.jws",
    import.meta.url,
  );
  const denoPublicKeyURL = new URL(
    "./test-fixtures/es256-public-key.x963",
    import.meta.url,
  );
  const swiftPublicKeyURL = new URL(
    "../../../swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/entitlement-es256-public-key.x963",
    import.meta.url,
  );
  const token = (await Deno.readTextFile(fixtureTokenURL)).trim();
  const denoPublicKey = await Deno.readFile(denoPublicKeyURL);
  const swiftPublicKey = await Deno.readFile(swiftPublicKeyURL);
  assertEquals([...denoPublicKey], [...swiftPublicKey]);
  assertEquals(denoPublicKey.byteLength, 65);

  const publicKey = await crypto.subtle.importKey(
    "raw",
    denoPublicKey.buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const [header, payload, signature] = token.split(".");
  const signatureBytes = decodeBase64URL(signature);
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      signatureBytes.buffer as ArrayBuffer,
      new TextEncoder().encode(`${header}.${payload}`),
    ),
    "committed fixture signature must verify",
  );
  assertEquals(decodeJSON(header), {
    alg: "ES256",
    kid: "test-es256-2026-09",
    typ: "JWT",
  });
  assertEquals(decodeJSON(payload), {
    iss: "https://accounts.ytdownloaderpro.example/staging",
    aud: "com.tachouweng.ytdownloaderpro2",
    sub: "11111111-1111-1111-1111-111111111111",
    iat: 1_790_208_000,
    nbf: 1_790_207_970,
    exp: 1_790_294_400,
    jti: "22222222-2222-2222-2222-222222222222",
    schema: 1,
    plan: "pro",
    features: [
      "download.single",
      "video.standard",
      "video.hd",
      "video.uhd",
      "audio.mp3",
      "queue.batch",
      "playlist.expand",
      "subtitle.basic",
      "subtitle.advanced",
      "format.presets",
      "recovery.manual",
      "recovery.full",
      "history.local",
      "history.sync",
      "support.standard",
      "support.priority",
    ],
    maxVideoHeight: null,
    subscriptionState: "active",
    grantRevision: 7,
  });
  assert(!token.includes("PRIVATE"), "fixture must contain no private-key marker");
});

async function assertRejects(operation: () => Promise<unknown>): Promise<void> {
  try {
    await operation();
    throw new Error("expected operation to reject");
  } catch (error) {
    assert(error instanceof Error, "rejection must be an Error");
    assert(!error.message.includes("PRIVATE"), "error must not include key material");
  }
}
