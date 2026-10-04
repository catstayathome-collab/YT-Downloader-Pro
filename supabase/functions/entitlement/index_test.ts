import { createRuntimeHandler } from "./index.ts";

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) throw new Error(`${String(actual)} != ${String(expected)}`);
}

Deno.test("missing runtime configuration returns a bounded service response", async () => {
  const handler = await createRuntimeHandler({});
  const response = await handler(new Request("https://example.invalid", { method: "POST" }));
  const text = await response.text();

  assertEquals(response.status, 503);
  assert(text.includes("service_unavailable"), "bounded code must be present");
  assert(!text.includes("SUPABASE"), "secret names must be absent");
  assert(!text.includes("PRIVATE_KEY"), "key names must be absent");
  assertEquals(response.headers.get("Cache-Control"), "no-store");
});
