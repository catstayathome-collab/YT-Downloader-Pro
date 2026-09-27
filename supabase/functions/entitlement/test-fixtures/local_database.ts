import postgres from "postgres";

const variable = "YTDP_LOCAL_BILLING_DATABASE_URL";
const permission = await Deno.permissions.query({ name: "env", variable });
const value = permission.state === "granted" ? Deno.env.get(variable) : undefined;
if (permission.state === "granted" && !value) {
  throw new Error("local billing database URL required");
}
if (value) {
  const url = new URL(value);
  if (
    !["postgres:", "postgresql:"].includes(url.protocol) ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
  ) throw new Error("loopback PostgreSQL required");
}

export function databaseTest(name: string, work: (url: string) => Promise<void>) {
  Deno.test({ name, ignore: value === undefined, fn: () => work(value!) });
}

export async function withAccount(
  url: string,
  work: (sql: postgres.Sql, userID: string) => Promise<void>,
) {
  const sql = postgres(url, { prepare: false, max: 2 });
  const userID = crypto.randomUUID();
  try {
    await sql`insert into auth.users (id, aud, role) values (${userID}, 'authenticated', 'authenticated')`;
    await work(sql, userID);
  } finally {
    try {
      await sql`delete from private.billing_recovery_audit where user_id = ${userID}`;
      await sql`delete from private.billing_operations where user_id = ${userID}`;
      await sql`delete from private.subscription_events where subscription_id in
        (select subscription_id from private.subscriptions where user_id = ${userID})`;
      await sql`delete from private.subscriptions where user_id = ${userID}`;
      await sql`delete from private.billing_orders where user_id = ${userID}`;
      await sql`delete from auth.users where id = ${userID}`;
    } finally {
      await sql.end();
    }
  }
}
