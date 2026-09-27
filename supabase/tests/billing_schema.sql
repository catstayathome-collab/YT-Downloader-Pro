begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);

select has_table('private', 'billing_orders', 'private billing orders exist');
select has_table('private', 'subscriptions', 'private subscriptions exist');
select has_table('private', 'subscription_events', 'private subscription events exist');

select has_index('private', 'billing_orders', 'billing_orders_pkey', 'orders have a primary key');
select has_index(
  'private', 'subscriptions', 'subscriptions_provider_provider_order_id_key',
  'provider order identifies one subscription'
);
select has_index(
  'private', 'subscription_events', 'subscription_events_provider_provider_event_key_key',
  'provider event key is unique'
);
select has_index(
  'private', 'subscriptions', 'one_current_subscription_per_user',
  'one account has at most one current subscription'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'private.subscription_events'::regclass
      and confrelid = 'private.subscriptions'::regclass
      and contype = 'f'
  ),
  'an event references a real subscription'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.billing_orders'::regclass),
  'billing orders enable RLS'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.subscriptions'::regclass),
  'subscriptions enable RLS'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'private.subscription_events'::regclass),
  'subscription events enable RLS'
);

select ok(
  not has_table_privilege('anon', 'private.billing_orders', 'SELECT')
    and not has_table_privilege('anon', 'private.subscriptions', 'SELECT')
    and not has_table_privilege('anon', 'private.subscription_events', 'SELECT'),
  'anonymous clients cannot read private billing data'
);
select ok(
  not has_table_privilege('authenticated', 'private.billing_orders', 'SELECT')
    and not has_table_privilege('authenticated', 'private.subscriptions', 'SELECT')
    and not has_table_privilege('authenticated', 'private.subscription_events', 'SELECT'),
  'authenticated clients cannot read private billing data'
);

insert into auth.users (id, aud, role, email)
values
  ('10000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'billing-test-1@example.invalid'),
  ('10000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'billing-test-2@example.invalid');
insert into private.billing_orders (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
values ('ecpay', 'immutable-order', '10000000-0000-0000-0000-000000000001', 'TWD', 8000);

select throws_ok(
  $$update private.billing_orders set user_id = '10000000-0000-0000-0000-000000000002' where provider_order_id = 'immutable-order'$$,
  '23514', 'billing order identity is immutable', 'an order cannot change owners'
);
select throws_ok(
  $$update private.billing_orders set expected_amount_minor = 9000 where provider_order_id = 'immutable-order'$$,
  '23514', 'billing order identity is immutable', 'an order cannot change amount'
);
select throws_ok(
  $$update private.billing_orders set expected_currency = 'USD' where provider_order_id = 'immutable-order'$$,
  '23514', 'billing order identity is immutable', 'an order cannot change currency'
);
select throws_ok(
  $$update private.billing_orders set provider_order_id = 'changed-order' where provider_order_id = 'immutable-order'$$,
  '23514', 'billing order identity is immutable', 'an order cannot change its identifier'
);
select throws_ok(
  $$update private.billing_orders set provider = 'other' where provider_order_id = 'immutable-order'$$,
  '23514', 'billing order identity is immutable', 'an order cannot change provider'
);

set local role anon;
select throws_ok('select * from private.billing_orders', '42501', null, 'anon order reads are denied');
select throws_ok('select * from private.subscriptions', '42501', null, 'anon subscription reads are denied');
select throws_ok('select * from private.subscription_events', '42501', null, 'anon event reads are denied');
reset role;

set local role authenticated;
select throws_ok('select * from private.billing_orders', '42501', null, 'authenticated order reads are denied');
select throws_ok('select * from private.subscriptions', '42501', null, 'authenticated subscription reads are denied');
select throws_ok('select * from private.subscription_events', '42501', null, 'authenticated event reads are denied');
reset role;

select * from finish();
rollback;
