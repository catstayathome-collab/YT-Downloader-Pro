import { verifyAioMac } from "./ecpay_aio_checksum.ts";

type Reason =
  | "method"
  | "content_type"
  | "limits"
  | "encoding"
  | "duplicate"
  | "mac"
  | "merchant"
  | "fields"
  | "body";
export class InvalidAioNotification extends Error {
  constructor(public readonly reason: Reason) {
    super(`Invalid AIO notification: ${reason}`);
  }
}
const verified: unique symbol = Symbol("verified-aio-candidate");
export type CandidatePayment = Readonly<{
  merchantID: string;
  orderID: string;
  authorizationID: string;
  occurredAt: string;
  amountTWD: string;
  outcome: "paid" | "failed";
  simulated: boolean;
}>;
export type VerifiedCandidate = CandidatePayment & { readonly [verified]: true };
const encoder = new TextEncoder();
function fail(reason: Reason): never {
  throw new InvalidAioNotification(reason);
}

async function parse(request: Request): Promise<Record<string, string>> {
  if (request.method !== "POST") fail("method");
  const type = request.headers.get("Content-Type") ?? "";
  if (
    !/^application\/x-www-form-urlencoded(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?\s*$/i.test(
      type,
    )
  ) fail("content_type");
  if (!request.body) fail("body");
  const reader = request.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  let raw = "", size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 65536) fail("limits");
      raw += decoder.decode(value, { stream: true });
    }
    raw += decoder.decode();
  } catch (error) {
    await reader.cancel().catch(() => {});
    if (error instanceof InvalidAioNotification) throw error;
    fail("encoding");
  } finally {
    reader.releaseLock();
  }
  const pairs = raw.split("&");
  if (pairs.length > 128) fail("limits");
  const fields: Record<string, string> = Object.create(null);
  const names = new Set<string>();
  for (const pair of pairs) {
    const equals = pair.indexOf("=");
    if (equals < 1) fail("encoding");
    let name: string, value: string;
    try {
      name = decodeURIComponent(pair.slice(0, equals).replace(/\+/g, " "));
      value = decodeURIComponent(pair.slice(equals + 1).replace(/\+/g, " "));
    } catch {
      fail("encoding");
    }
    if (encoder.encode(name).length > 64 || encoder.encode(value).length > 8192) fail("limits");
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(name)) fail("fields");
    if (names.has(name.toLowerCase())) fail("duplicate");
    names.add(name.toLowerCase());
    fields[name] = value;
  }
  return fields;
}
function integer(value: string | undefined, positive = false): string {
  if (
    value === undefined || !/^(0|[1-9][0-9]*)$/.test(value) ||
    !Number.isSafeInteger(Number(value)) || (positive && Number(value) === 0)
  ) fail("fields");
  return value;
}
function timestamp(value: string | undefined): string {
  if (!value || !/^\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}$/.test(value)) fail("fields");
  const [year, month, day, hour, minute, second] = value.split(/\D/).map(Number);
  if (year < 2000 || year > 9999) fail("fields");
  const local = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  if (
    local.getUTCFullYear() !== year || local.getUTCMonth() !== month - 1 ||
    local.getUTCDate() !== day || local.getUTCHours() !== hour ||
    local.getUTCMinutes() !== minute || local.getUTCSeconds() !== second
  ) fail("fields");
  return new Date(local.getTime() - 8 * 3600000).toISOString();
}

// A verified candidate is not an entitlement or a trusted billing period.
export async function verifyAioNotification(
  request: Request,
  route: "first" | "renewal",
  config: { merchantID: string; hashKey: string; hashIV: string },
): Promise<VerifiedCandidate> {
  try {
    const fields = await parse(request);
    if (!await verifyAioMac(fields, config)) fail("mac");
    if (!/^[0-9]{1,10}$/.test(config.merchantID) || fields.MerchantID !== config.merchantID) {
      fail("merchant");
    }
    if (!/^[A-Za-z0-9]{1,20}$/.test(fields.MerchantTradeNo ?? "")) fail("fields");
    const first = route === "first";
    if (route !== "first" && route !== "renewal") fail("fields");
    const prohibited = first
      ? ["Amount", "Gwsr", "ProcessDate"]
      : ["TradeAmt", "amount", "gwsr", "process_date", "PaymentDate"];
    if (prohibited.some((key) => key in fields)) fail("fields");
    const amountTWD = integer(fields[first ? "amount" : "Amount"], true);
    if (
      first &&
      (integer(fields.TradeAmt, true) !== amountTWD || fields.PaymentType !== "Credit_CreditCard")
    ) fail("fields");
    const flag = fields.SimulatePaid;
    if ((first && flag === undefined) || (flag !== undefined && flag !== "0" && flag !== "1")) {
      fail("fields");
    }
    return Object.freeze({
      merchantID: fields.MerchantID,
      orderID: fields.MerchantTradeNo,
      authorizationID: integer(fields[first ? "gwsr" : "Gwsr"], true),
      occurredAt: timestamp(fields[first ? "process_date" : "ProcessDate"]),
      amountTWD,
      outcome: integer(fields.RtnCode) === "1" ? "paid" : "failed",
      simulated: flag === "1",
      [verified]: true as const,
    });
  } catch (error) {
    if (error instanceof InvalidAioNotification) throw error;
    fail("body");
  }
}
