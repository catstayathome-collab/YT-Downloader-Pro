create table private.billing_orders (
  provider text not null check (provider in ('ecpay')),
  provider_order_id varchar(20) not null,
  user_id uuid not null references auth.users(id) on delete restrict,
  expected_currency char(3) not null check (expected_currency = 'TWD'),
  expected_amount_minor bigint not null check (expected_amount_minor > 0),
  created_at timestamptz not null default now(),
  primary key (provider, provider_order_id),
  check (char_length(provider_order_id) between 1 and 20)
);

alter table private.billing_orders enable row level security;
revoke all on private.billing_orders from anon, authenticated;
