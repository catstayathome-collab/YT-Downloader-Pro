begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(10);

select has_table('private', 'billing_operations', 'durable billing operations exist');
select ok((select relrowsecurity from pg_class where oid = 'private.billing_operations'::regclass), 'operations enable RLS');

insert into auth.users (id, aud, role) values
  ('30000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated'),
  ('30000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated');
insert into private.billing_orders (provider, provider_order_id, user_id, expected_currency, expected_amount_minor)
values ('ecpay', 'operation-test', '30000000-0000-0000-0000-000000000001', 'TWD', 8000);
insert into private.billing_operations
  (operation_id, user_id, request_id, provider_order_id, kind, created_at, updated_at)
values ('40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001', 'operation-test', 'checkout', now(), now());

select throws_ok($$insert into private.billing_operations
  (operation_id, user_id, request_id, provider_order_id, kind, created_at, updated_at)
  values (gen_random_uuid(), '30000000-0000-0000-0000-000000000001',
    '50000000-0000-0000-0000-000000000001', 'operation-test', 'cancel', now(), now())$$,
  '23505', null, 'request keys are unique per account');
select throws_ok($$insert into private.billing_operations
  (operation_id, user_id, request_id, provider_order_id, kind, created_at, updated_at)
  values (gen_random_uuid(), '30000000-0000-0000-0000-000000000001',
    gen_random_uuid(), 'operation-test', 'checkout', now(), now())$$,
  '23505', null, 'an order has only one operation of each kind');
select throws_ok($$insert into private.billing_operations
  (operation_id, user_id, request_id, provider_order_id, kind, created_at, updated_at)
  values (gen_random_uuid(), '30000000-0000-0000-0000-000000000002',
    gen_random_uuid(), 'operation-test', 'cancel', now(), now())$$,
  '23503', null, 'operation owner must match order owner');
select throws_ok($$update private.billing_operations set environment = 'production'$$,
  '23514', null, 'production operations are not supported');

set local role anon;
select throws_ok('select * from private.billing_operations', '42501', null, 'anon reads denied');
select throws_ok('delete from private.billing_operations', '42501', null, 'anon writes denied');
reset role;
set local role authenticated;
select throws_ok('select * from private.billing_operations', '42501', null, 'client reads denied');
select throws_ok('delete from private.billing_operations', '42501', null, 'client writes denied');
reset role;
select * from finish();
rollback;
