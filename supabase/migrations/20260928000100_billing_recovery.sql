alter table private.billing_operations add constraint billing_operation_owner_identity unique(operation_id,user_id);
alter table private.subscription_events add column facts_digest text
  check (facts_digest is null or facts_digest ~ '^[0-9a-f]{64}$');
create table private.billing_recovery_audit (
  audit_id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  user_id uuid not null,
  evidence_digest text not null check (evidence_digest ~ '^[0-9a-f]{64}$'),
  state_digest text not null check (state_digest ~ '^[0-9a-f]{64}$'),
  observed_at timestamptz not null,
  result text not null check (result in ('applied','duplicate','needs_review')),
  reason text not null check (reason in ('payment','checkout','cancellation','duplicate','unavailable','not_found','invalid_evidence','incomplete_history','conflicting_facts','missing_period','missing_cancel_time','policy_conflict','still_active','stale_snapshot')),
  foreign key(operation_id,user_id) references private.billing_operations(operation_id,user_id) on delete restrict,
  unique(operation_id,evidence_digest,state_digest)
);
alter table private.billing_recovery_audit enable row level security;
revoke all on private.billing_recovery_audit from public,anon,authenticated;
