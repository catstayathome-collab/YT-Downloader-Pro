import type { EntitlementClaimsInput } from "./contract.ts";

export type EntitlementPayload =
  & Readonly<{
    iss: string;
    aud: string;
    sub: string;
    iat: number;
    nbf: number;
    exp: number;
    jti: string;
  }>
  & EntitlementClaimsInput;

export async function signEntitlement(
  payload: EntitlementPayload,
  privateKey: CryptoKey,
  keyID: string,
): Promise<string> {
  guardSigningInputs(privateKey, keyID);

  const header = { alg: "ES256", kid: keyID, typ: "JWT" } as const;
  const encodedHeader = base64URLEncode(new TextEncoder().encode(JSON.stringify(header)));
  const encodedPayload = base64URLEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);

  let signature: ArrayBuffer;
  try {
    signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      privateKey,
      signingInput,
    );
  } catch {
    throw new Error("jwsSigningFailed");
  }

  const rawSignature = new Uint8Array(signature);
  if (rawSignature.byteLength !== 64) {
    throw new Error("jwsSigningFailed");
  }
  return `${encodedHeader}.${encodedPayload}.${base64URLEncode(rawSignature)}`;
}

export function base64URLEncode(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function guardSigningInputs(privateKey: CryptoKey, keyID: string): void {
  const algorithm = privateKey.algorithm as EcKeyAlgorithm;
  if (
    privateKey.type !== "private" ||
    algorithm.name !== "ECDSA" ||
    algorithm.namedCurve !== "P-256" ||
    !privateKey.usages.includes("sign") ||
    !/^[A-Za-z0-9._-]{1,64}$/.test(keyID)
  ) {
    throw new Error("jwsSigningFailed");
  }
}
