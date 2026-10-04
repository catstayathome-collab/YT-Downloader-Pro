type Credentials = Readonly<{ hashKey: string; hashIV: string }>;

function canonicalEncode(value: string): string {
  // AIO uses form-style spaces, encoded apostrophes/tilde, then lowercase.
  return encodeURIComponent(value).replace(
    /['~]/g,
    (character) => `%${character.charCodeAt(0).toString(16)}`,
  ).replace(/%20/g, "+").toLowerCase();
}

export async function computeAioMac(
  fields: Readonly<Record<string, string>>,
  credentials: Credentials,
): Promise<string> {
  const keys = Object.keys(fields).filter((key) => key !== "CheckMacValue").sort((a, b) => {
    const left = a.toLowerCase();
    const right = b.toLowerCase();
    return left < right ? -1 : left > right ? 1 : 0;
  });
  const components = [
    `HashKey=${credentials.hashKey}`,
    ...keys.map((key) => `${key}=${fields[key]}`),
    `HashIV=${credentials.hashIV}`,
  ];
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonicalEncode(components.join("&"))),
  );
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0"))
    .join("").toUpperCase();
}

export async function verifyAioMac(
  fields: Readonly<Record<string, string>>,
  credentials: Credentials,
): Promise<boolean> {
  const supplied = fields.CheckMacValue;
  if (typeof supplied !== "string" || !/^[0-9A-F]{64}$/.test(supplied)) return false;
  const expected = await computeAioMac(fields, credentials);
  let difference = 0;
  for (let index = 0; index < 64; index += 2) {
    difference |= Number.parseInt(supplied.slice(index, index + 2), 16) ^
      Number.parseInt(expected.slice(index, index + 2), 16);
  }
  return difference === 0;
}
