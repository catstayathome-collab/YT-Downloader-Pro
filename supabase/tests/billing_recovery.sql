begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(12);
select has_table('private','billing_recovery_audit','private audit exists');
select ok((select relrowsecurity from pg_class where oid='private.billing_recovery_audit'::regclass),'audit RLS enabled');
select has_column('private','subscription_events','facts_digest','event facts digest exists');
insert into auth.users(id) values ('60000000-0000-0000-0000-000000000001'),('60000000-0000-0000-0000-000000000002');
insert into private.billing_orders(provider,provider_order_id,user_id,expected_currency,expected_amount_minor)
values('ecpay','recovery-test','60000000-0000-0000-0000-000000000001','TWD',8000);
insert into private.billing_operations(operation_id,user_id,request_id,provider_order_id,kind,created_at,updated_at)
values('70000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001',gen_random_uuid(),'recovery-test','checkout',now(),now());
insert into private.billing_recovery_audit(operation_id,user_id,evidence_digest,state_digest,observed_at,result,reason)
values('70000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001',repeat('a',64),repeat('b',64),now(),'applied','payment');
select throws_ok($$update private.billing_recovery_audit set user_id='60000000-0000-0000-0000-000000000002'$$,'23503',null,'owner must match operation');
select throws_ok($$update private.billing_recovery_audit set evidence_digest='bad'$$,'23514',null,'digest bounded');
select throws_ok($$update private.billing_recovery_audit set result='raw provider message'$$,'23514',null,'result bounded');
select throws_ok($$update private.billing_recovery_audit set reason='raw provider message'$$,'23514',null,'reason bounded');
select throws_ok($$insert into private.billing_recovery_audit(operation_id,user_id,evidence_digest,state_digest,observed_at,result,reason)
 select operation_id,user_id,evidence_digest,state_digest,now(),'duplicate','duplicate' from private.billing_recovery_audit$$,'23505',null,'same evidence and state unique');
set local role anon;
select throws_ok('select * from private.billing_recovery_audit','42501',null,'anon read denied');
select throws_ok('delete from private.billing_recovery_audit','42501',null,'anon write denied');
reset role;
set local role authenticated;
select throws_ok('select * from private.billing_recovery_audit','42501',null,'client read denied');
select throws_ok('delete from private.billing_recovery_audit','42501',null,'client write denied');
reset role;
select * from finish();
rollback;
