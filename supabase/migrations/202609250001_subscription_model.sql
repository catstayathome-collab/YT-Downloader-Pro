create table private.subscriptions (
  subscription_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  provider text not null check (provider in ('ecpay')),
  provider_order_id varchar(20) not null,
  is_current boolean not null default true,
  status text not null check (status in ('active', 'cancelled', 'payment_failed', 'refunded', 'revoked')),
  paid_from timestamptz not null,
  paid_through timestamptz not null,
  cancel_confirmed_at timestamptz null,
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_order_id),
  check (char_length(provider_order_id) between 1 and 20),
  check (paid_through > paid_from),
  check (status <> 'cancelled' or cancel_confirmed_at is not null),
  check (cancel_confirmed_at is null or status in ('cancelled', 'refunded', 'revoked'))
);

create unique index one_current_subscription_per_user
  on private.subscriptions (user_id) where is_current;

create table private.subscription_events (
  event_id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references private.subscriptions(subscription_id) on delete restrict,
  provider text not null check (provider in ('ecpay')),
  provider_event_key varchar(128) not null,
  event_kind text not null check (
    event_kind in (
      'payment_succeeded', 'payment_failed', 'cancellation_confirmed',
      'refund_confirmed', 'revocation_confirmed'
    )
  ),
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  unique (provider, provider_event_key),
  check (char_length(provider_event_key) between 1 and 128)
);

alter table private.subscriptions enable row level security;
alter table private.subscription_events enable row level security;

revoke all on private.subscriptions, private.subscription_events from anon, authenticated;
