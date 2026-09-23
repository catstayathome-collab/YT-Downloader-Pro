from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "202609230001_account_entitlements.sql"


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


if __name__ == "__main__":
    unittest.main()
