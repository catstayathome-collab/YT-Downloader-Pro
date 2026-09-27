alter table private.billing_orders add constraint billing_order_owner_identity
  unique (provider, provider_order_id, user_id);

create table private.billing_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  provider text not null default 'ecpay' check (provider = 'ecpay'),
  provider_order_id varchar(20) not null,
  environment text not null default 'mock' check (environment = 'mock'),
  kind text not null check (kind in ('checkout', 'cancel')),
  state text not null default 'pending' check (state in ('pending', 'succeeded', 'unknown')),
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (user_id, request_id),
  unique (provider, provider_order_id, kind),
  foreign key (provider, provider_order_id, user_id)
    references private.billing_orders(provider, provider_order_id, user_id) on delete restrict
);
alter table private.billing_operations enable row level security;
revoke all on private.billing_operations from anon, authenticated;
