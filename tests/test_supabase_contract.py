from pathlib import Path
import json
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "202609230001_account_entitlements.sql"
SUBSCRIPTION_MIGRATION = ROOT / "supabase" / "migrations" / "202609250001_subscription_model.sql"
DENO_CONFIG = ROOT / "supabase" / "deno.json"
EDGE_INDEX = ROOT / "supabase" / "functions" / "entitlement" / "index.ts"
STAGING_GUIDE = ROOT / "docs" / "swift-2.0" / "SUPABASE_STAGING.md"


class SupabaseContractTests(unittest.TestCase):
    def migration_sql(self) -> str:
        self.assertTrue(MIGRATION.is_file(), f"missing migration: {MIGRATION}")
        return MIGRATION.read_text(encoding="utf-8").lower()

    def test_entitlement_tables_are_private_and_rls_enabled(self):
        sql = self.migration_sql()

        for table in (
            "account_profiles",
            "entitlement_grants",
            "entitlement_audit_events",
        ):
            self.assertIn(f"create table private.{table}", sql)
            self.assertIn(
                f"alter table private.{table} enable row level security",
                sql,
            )

        self.assertNotRegex(
            sql,
            re.compile(
                r"create\s+policy[\s\S]*?on\s+private\.(?:entitlement_grants|entitlement_audit_events)"
                r"[\s\S]*?for\s+(?:insert|update|delete|all)"
            ),
        )

    def test_grant_constraints_are_explicit(self):
        sql = self.migration_sql()

        self.assertIn("check (plan in ('free', 'pro'))", sql)
        self.assertIn("check (status in ('none', 'active', 'suspended'))", sql)
        self.assertIn(
            "check (max_video_height is null or max_video_height > 0)",
            sql,
        )
        self.assertIn(
            "valid_until timestamptz null check (valid_until is null or valid_until > valid_from)",
            sql,
        )
        self.assertIn(
            "revision bigint not null default 1 check (revision > 0)",
            sql,
        )

    def test_private_schema_and_tables_are_not_granted_to_clients(self):
        sql = self.migration_sql()

        self.assertIn("revoke all on schema private from anon, authenticated", sql)
        self.assertIn(
            "revoke all on all tables in schema private from anon, authenticated",
            sql,
        )
        self.assertNotRegex(
            sql,
            re.compile(r"grant[\s\S]*?to\s+(?:anon|authenticated)"),
        )

    def test_audit_events_have_bounded_non_secret_fields(self):
        sql = self.migration_sql()

        self.assertIn("event_id uuid primary key default gen_random_uuid()", sql)
        self.assertIn("previous_revision bigint null", sql)
        self.assertIn("next_revision bigint null", sql)
        self.assertIn("reason_code varchar(64) not null", sql)
        for prohibited in ("token", "email", "media_url", "download_path", "cookie"):
            self.assertNotRegex(sql, rf"\b{prohibited}\b\s+(?:text|varchar|json|jsonb)")

    def test_edge_runtime_uses_exact_pinned_client_and_required_secret_names(self):
        config = json.loads(DENO_CONFIG.read_text(encoding="utf-8"))
        self.assertIn("imports", config)
        self.assertEqual(
            config["imports"]["@supabase/supabase-js"],
            "npm:@supabase/supabase-js@2.117.0",
        )

        source = EDGE_INDEX.read_text(encoding="utf-8")
        for variable in (
            "SUPABASE_URL",
            "SUPABASE_SERVICE_ROLE_KEY",
            "ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8",
            "ENTITLEMENT_ES256_KID",
            "ENTITLEMENT_ISSUER",
            "ENTITLEMENT_AUDIENCE",
        ):
            self.assertRegex(source, rf'get\(\s*"{variable}"\s*,?\s*\)')
        self.assertNotIn("sb_secret_", source)
        self.assertNotIn("BEGIN PRIVATE KEY", source)

    def test_staging_guide_uses_the_exact_runtime_secret_names(self):
        guide = STAGING_GUIDE.read_text(encoding="utf-8")

        for variable in (
            "SUPABASE_URL",
            "SUPABASE_SERVICE_ROLE_KEY",
            "ENTITLEMENT_ES256_PRIVATE_KEY_PKCS8",
            "ENTITLEMENT_ES256_KID",
            "ENTITLEMENT_ISSUER",
            "ENTITLEMENT_AUDIENCE",
        ):
            self.assertIn(f"`{variable}`", guide)

        self.assertNotIn("ENTITLEMENT_SIGNING_PRIVATE_KEY", guide)
        self.assertNotIn("ENTITLEMENT_SIGNING_KID", guide)

        secret_command = guide.split("supabase secrets set", 1)[1].split("```", 1)[0]
        self.assertNotIn("SUPABASE_URL=", secret_command)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY=", secret_command)

    def test_subscription_and_event_ledger_are_private_and_account_owned(self):
        sql = SUBSCRIPTION_MIGRATION.read_text(encoding="utf-8").lower()

        self.assertIn("create table private.subscriptions", sql)
        self.assertIn("user_id uuid not null references auth.users(id) on delete restrict", sql)
        self.assertIn("check (paid_through > paid_from)", sql)
        self.assertIn("check (status in ('active', 'cancelled', 'payment_failed', 'refunded', 'revoked'))", sql)
        self.assertIn("create unique index one_current_subscription_per_user", sql)
        self.assertIn("create table private.subscription_events", sql)
        self.assertIn("unique (provider, provider_event_key)", sql)
        self.assertIn("check (char_length(provider_order_id) between 1 and 20)", sql)
        self.assertIn("check (char_length(provider_event_key) between 1 and 128)", sql)
        for table in ("subscriptions", "subscription_events"):
            self.assertIn(f"alter table private.{table} enable row level security", sql)
        self.assertIn(
            "revoke all on private.subscriptions, private.subscription_events from anon, authenticated",
            sql,
        )
        for prohibited in ("email", "card_number", "cvv", "raw_callback", "access_token"):
            self.assertNotRegex(sql, rf"\b{prohibited}\b\s+(?:text|varchar|json|jsonb)")


if __name__ == "__main__":
    unittest.main()
