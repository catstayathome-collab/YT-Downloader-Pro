create schema if not exists private;

revoke all on schema private from anon, authenticated;

create table private.account_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text null check (display_name is null or char_length(display_name) between 1 and 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.entitlement_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null check (plan in ('free', 'pro')),
  status text not null check (status in ('none', 'active', 'suspended')),
  features text[] not null default '{}',
  max_video_height integer null check (max_video_height is null or max_video_height > 0),
  valid_from timestamptz not null,
  valid_until timestamptz null check (valid_until is null or valid_until > valid_from),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);

create table private.entitlement_audit_events (
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (
    event_type in ('grant_created', 'grant_updated', 'grant_suspended', 'grant_revoked')
  ),
  previous_revision bigint null check (previous_revision is null or previous_revision > 0),
  next_revision bigint null check (next_revision is null or next_revision > 0),
  actor_class text not null check (actor_class in ('system', 'operator', 'webhook', 'migration')),
  occurred_at timestamptz not null default now(),
  reason_code varchar(64) not null check (reason_code ~ '^[a-z0-9._-]{1,64}$'),
  check (previous_revision is not null or next_revision is not null)
);

alter table private.account_profiles enable row level security;
alter table private.entitlement_grants enable row level security;
alter table private.entitlement_audit_events enable row level security;

revoke all on all tables in schema private from anon, authenticated;
