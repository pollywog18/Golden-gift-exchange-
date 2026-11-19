-- Golden Gift Exchange: one permanent draw per Supabase project.
create extension if not exists pgcrypto;

create table if not exists public.organizers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.exchange (
  id integer primary key check (id = 1),
  title text not null,
  budget text,
  exchange_date date,
  locked_at timestamptz not null default now()
);

create table if not exists public.participants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_key text not null unique,
  pin_hash text not null unique,
  redeemed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.assignments (
  participant_id uuid primary key references public.participants(id),
  recipient_id uuid not null unique references public.participants(id),
  constraint no_self_assignment check (participant_id <> recipient_id)
);

alter table public.organizers enable row level security;
alter table public.exchange enable row level security;
alter table public.participants enable row level security;
alter table public.assignments enable row level security;

-- No browser role may read or mutate draw data directly.
revoke all on public.organizers, public.exchange, public.participants, public.assignments from anon, authenticated;
grant usage on schema public to service_role;

create or replace function public.commit_gift_draw(
  p_title text, p_budget text, p_exchange_date date,
  p_people jsonb, p_assignments jsonb
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  if jsonb_typeof(p_people) <> 'array' or jsonb_typeof(p_assignments) <> 'array' then
    raise exception 'Invalid draw payload';
  end if;
  v_count := jsonb_array_length(p_people);
  if v_count < 2 or jsonb_array_length(p_assignments) <> v_count then
    raise exception 'At least two participants and matching assignments are required';
  end if;

  -- The singleton primary key makes the draw permanently one-time, including concurrent requests.
  insert into public.exchange(id,title,budget,exchange_date)
  values (1, left(coalesce(p_title,'Golden Gift Exchange'),100), nullif(left(p_budget,100),''),
          p_exchange_date);

  insert into public.participants(id,name,name_key,pin_hash)
  select (x->>'id')::uuid, left(x->>'name',80), lower(trim(x->>'name')), x->>'pin_hash'
  from jsonb_array_elements(p_people) x;

  insert into public.assignments(participant_id,recipient_id)
  select (x->>'participant_id')::uuid, (x->>'recipient_id')::uuid
  from jsonb_array_elements(p_assignments) x;

  return jsonb_build_object('locked',true,'participants',v_count);
end;
$$;

create or replace function public.redeem_gift_pin(p_name text, p_pin_hash text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_person public.participants%rowtype;
  v_recipient text;
  v_exchange public.exchange%rowtype;
begin
  -- Atomic consume: only the first correct name+PIN request can proceed.
  update public.participants
    set redeemed_at = now()
    where name_key = lower(trim(p_name))
      and pin_hash = p_pin_hash
      and redeemed_at is null
    returning * into v_person;

  if not found then
    raise exception 'Invalid details or this one-time reveal has already been used';
  end if;

  select p.name into v_recipient
    from public.assignments a
    join public.participants p on p.id = a.recipient_id
    where a.participant_id = v_person.id;

  select * into v_exchange from public.exchange where id = 1;
  if v_recipient is null then raise exception 'Assignment unavailable'; end if;

  return jsonb_build_object(
    'recipient',v_recipient,'title',v_exchange.title,
    'budget',v_exchange.budget,'exchange_date',v_exchange.exchange_date
  );
end;
$$;

revoke all on function public.commit_gift_draw(text,text,date,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.redeem_gift_pin(text,text) from public, anon, authenticated;
grant execute on function public.commit_gift_draw(text,text,date,jsonb,jsonb) to service_role;
grant execute on function public.redeem_gift_pin(text,text) to service_role;
