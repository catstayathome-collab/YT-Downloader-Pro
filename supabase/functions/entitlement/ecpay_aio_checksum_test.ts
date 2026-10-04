import { computeAioMac, verifyAioMac } from "./ecpay_aio_checksum.ts";

function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) throw new Error(`Expected ${expected}, received ${actual}`);
}
const credentials = { hashKey: "local-key", hashIV: "local-iv" };
const params = { b: "two words", A: "hello" };
const expected = "8D71D4289DA563AD2FF7536F51B257387B2120AA56BD893996062414F5D25506";

Deno.test("independent local vector matches", async () => {
  equal(await computeAioMac(params, credentials), expected);
  equal(await verifyAioMac({ ...params, CheckMacValue: expected }, credentials), true);
});
Deno.test("field order is irrelevant and checksum itself is excluded", async () => {
  equal(
    await computeAioMac({ A: "hello", b: "two words", CheckMacValue: "ignored" }, credentials),
    expected,
  );
});
Deno.test("unicode and reserved punctuation match independent encoding", async () => {
  equal(
    await computeAioMac({ Message: "繁體字幕 !*()~' +%&=", z: "" }, credentials),
    "35F08F3EFB8792B3F602531B71115E7A3E70B2CC7728097FEFC5C933F7361759",
  );
});
Deno.test("tampered value field and credentials fail", async () => {
  for (
    const fields of [
      { ...params, b: "three words" },
      { A: "hello", c: "two words" },
      { ...params, unknown: "signed too" },
    ] as Record<string, string>[]
  ) equal(await verifyAioMac({ ...fields, CheckMacValue: expected }, credentials), false);
  equal(
    await verifyAioMac({ ...params, CheckMacValue: expected }, {
      ...credentials,
      hashKey: "wrong",
    }),
    false,
  );
});
Deno.test("missing and malformed checksums fail closed", async () => {
  equal(await verifyAioMac(params, credentials), false);
  for (const mac of ["", "0".repeat(32), "G".repeat(64), expected + " ", "0".repeat(64)]) {
    equal(await verifyAioMac({ ...params, CheckMacValue: mac }, credentials), false);
  }
});

// Official source stays outside version control because redistribution is restricted.
const variable = "YTDP_AIO_VECTOR_FILE";
const permission = await Deno.permissions.query({ name: "env", variable });
const path = permission.state === "granted" ? Deno.env.get(variable) : undefined;
if (permission.state === "granted" && !path) throw new Error("official vector file required");
Deno.test({
  name: "pinned official SHA256 AIO vectors match",
  ignore: path === undefined,
  async fn() {
    const bytes = await Deno.readFile(path!);
    const digest = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
      (value) => value.toString(16).padStart(2, "0"),
    ).join("");
    equal(digest, "19500d60f3db8da3a9c31760e48b2102b233e4e8a9a5a594edd680deb8358301");
    const source = JSON.parse(new TextDecoder().decode(bytes));
    let count = 0;
    for (const vector of source.vectors) {
      if (vector.method !== "SHA256" || vector.formula) continue;
      const keys = { hashKey: vector.hashKey, hashIV: vector.hashIV };
      equal(await computeAioMac(vector.params, keys), vector.expected);
      equal(await verifyAioMac({ ...vector.params, CheckMacValue: vector.expected }, keys), true);
      count++;
    }
    equal(count, 5);
  },
});
