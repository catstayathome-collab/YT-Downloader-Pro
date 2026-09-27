create function private.enforce_billing_order_identity()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if row(new.provider, new.provider_order_id, new.user_id,
         new.expected_currency, new.expected_amount_minor)
     is distinct from
     row(old.provider, old.provider_order_id, old.user_id,
         old.expected_currency, old.expected_amount_minor) then
    raise exception using
      errcode = '23514',
      message = 'billing order identity is immutable';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_billing_order_identity() from public, anon, authenticated;

create trigger billing_order_identity_immutable
before update on private.billing_orders
for each row execute function private.enforce_billing_order_identity();
