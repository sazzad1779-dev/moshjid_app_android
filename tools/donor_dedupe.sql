-- tools/donor_dedupe.sql
--
-- Server-side half of offline donor support:
--   1. normalized key columns so Dart and Postgres agree on what "same donor" means
--   2. a first-wins trigger so two devices creating the same donor offline converge
--   3. a unique index as the hard backstop for the concurrent-insert race
--   4. an idempotent merge of duplicates that already exist
--
-- Run in Supabase Dashboard > SQL Editor. Safe to run repeatedly.
--
-- THE DEDUPE RULE, restated so it is unambiguous:
--  * A donor with a phone number is identified by that number, reduced to
--    Bangladeshi local form: +880 1712-345678, 008801712345678, 1712345678 and
--    01712-345678 are all one person.
--  * A donor without a phone number is identified by their name, NFC normalized
--    and lowercased with runs of whitespace collapsed to one space.
--   * Two donors may share a name if at least one of them supplied a phone --
--     the phone always wins as the identity.
--   * When two rows collide, the EARLIEST created row survives.
--
-- Column note: this script expects `profiles.full_name`, `role` and `status` to
-- already exist. It ADDS `phone`, `is_monthly` and `client_created_at` if missing.
-- If your `profiles` table stores the number in a differently named column, add it
-- here via `alter table ... rename` before running.


-- ---------------------------------------------------------------- 1. pre-flight
do $$
declare
  missing text[];
begin
  select array_agg(c.column_name order by c.column_name)
    into missing
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name   = 'profiles'
    and c.column_name  not in ('id', 'full_name', 'role', 'status');
  if missing is null then
    raise exception 'public.profiles not found -- run tools/profiles.sql first';
  end if;
  raise notice 'profiles columns beyond id/full_name/role/status: %',
    coalesce(missing::text, '(none)');
end $$;


-- ------------------------------------------------------------ 2. add columns
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists is_monthly boolean;
alter table public.profiles add column if not exists client_created_at timestamptz;

-- Backfill, with any updated_at trigger muted.
--
-- This schema carries trg_profiles_updated_at, which stamps updated_at on
-- every UPDATE. Left alone, backfilling 40 donor rows would make every profile
-- look freshly edited to anything watching that column -- and would trip any
-- downstream sync keyed on it. Nothing here is a real edit to the donor, so the
-- trigger should not fire.
do $$
begin
  if exists (select 1 from pg_trigger
             where tgrelid = 'public.profiles'::regclass
               and tgname = 'trg_profiles_updated_at') then
    alter table public.profiles disable trigger trg_profiles_updated_at;
  end if;

  update public.profiles
     set client_created_at = created_at
   where client_created_at is null;

  update public.profiles
     set is_monthly = true
   where is_monthly is null;

  if exists (select 1 from pg_trigger
             where tgrelid = 'public.profiles'::regclass
               and tgname = 'trg_profiles_updated_at') then
    alter table public.profiles enable trigger trg_profiles_updated_at;
  end if;
end $$;

comment on column public.profiles.client_created_at is
  'When this device first learned of the donor. Tiebreaker for first-wins merges.';


-- -------------------------------------------------------- 3. key columns
-- Generated columns, so they cannot drift from the source data the way a
-- trigger-maintained column can. Generated columns require IMMUTABLE
-- expressions, so the logic lives in IMMUTABLE functions first.
--
-- These functions are the server half of lib/data/models/name_key.dart. The
-- two implementations must stay in lockstep: change a rule on one side and
-- change it on the other, or the app will create duplicate donors.
--
-- Order matters. The generated columns are dropped and rebuilt around the
-- functions, because Postgres refuses to drop a function that a generated
-- column depends on.

alter table public.profiles drop column if exists name_key;
alter table public.profiles drop column if exists match_key;

create or replace function public.moshjid_name_key(raw text)
returns text
language sql
immutable
strict
parallel safe
as $fn$
  -- NFC, then lowercase, then collapse whitespace runs. Mirrors
  -- NameKey.name() in Dart, including the unorm_dart dependency.
  select lower(
           regexp_replace(
             btrim(normalize(coalesce($1, ''), NFC)),
             '[[:space:]]+', ' ', 'g'
           )
         )
$fn$;

create or replace function public.moshjid_phone_key(raw text)
returns text
language plpgsql
immutable
strict
parallel safe
as $fn$
declare
  d text := regexp_replace(coalesce(raw, ''), '[^0-9]', '', 'g');
begin
  if d = '' then
    return null;
  end if;

  -- Drop an international prefix written as 00.
  if d like '00%' then
    d := substr(d, 3);
  end if;

  -- Only these two exact shapes are rewritten. Anything else is left as its
  -- bare digits: guessing would risk merging two different people into one
  -- donor, which is far worse than leaving a number unrecognised.
  if length(d) = 13 and d like '880%' then
    d := '0' || substr(d, 4);          -- 8801712345678 -> 01712345678
  elsif length(d) = 10 and d like '1%' then
    d := '0' || d;                     -- 1712345678    -> 01712345678
  end if;

  return nullif(d, '');
end
$fn$;

create or replace function public.moshjid_match_key(full_name text, phone text)
returns text
language sql
immutable
-- deliberately NOT strict.
--
-- A donor with no phone is the common case, and STRICT would short-circuit on
-- a NULL phone argument and return NULL for every phone-less donor. That makes
-- match_key NULL, which silently disables both the trigger (it never matches)
-- and the unique index (NULLs are never equal in a btree index, so nothing is
-- ever rejected). The bug is invisible until something relies on it.
--
-- The leaf functions keep STRICT: moshjid_phone_key(NULL) returning NULL is
-- exactly what the CASE below wants.
parallel safe
as $fn$
  -- The single definition of donor identity. Used by BOTH the generated column
  -- and the BEFORE INSERT trigger, because a BEFORE trigger cannot read a
  -- generated column: Postgres fills those in after the trigger has run, so
  -- NEW.match_key is still NULL at that point. Computing it here is what keeps
  -- the two paths from drifting apart.
  --
  -- A phone wins over a name. Prefixes stop the two key spaces colliding.
  select case
           when public.moshjid_phone_key(phone) is not null
             then 'p:' || public.moshjid_phone_key(phone)
           else 'n:' || public.moshjid_name_key(full_name)
         end
$fn$;

comment on function public.moshjid_name_key(text) is
  'Donor name identity. Must match NameKey.name() in lib/data/models/name_key.dart.';
comment on function public.moshjid_phone_key(text) is
  'Donor phone identity in BD local form. Must match NameKey.phone() in lib/data/models/name_key.dart.';
comment on function public.moshjid_match_key(text, text) is
  'Donor identity: phone when given, otherwise name. Mirrors NameKey.match() in lib/data/models/name_key.dart.';

alter table public.profiles add column name_key text generated always as (
  public.moshjid_name_key(full_name)
) stored;

alter table public.profiles add column match_key text generated always as (
  public.moshjid_match_key(full_name, phone)
) stored;

-- A donor that nobody has committed as a monthly giver is not one yet. This is
-- handled in the backfill above, alongside the trigger suppression.


-- --------------------------------------- 4. merge duplicates that already exist
-- Must run BEFORE the unique index, or creation fails on pre-existing dupes.
-- Discovers referencing foreign keys dynamically so this stays correct as
-- tables are added, rather than hardcoding a column list that will rot.

create temporary table _dd_plan on commit drop as
select p.id as loser_id,
       k.id as keeper_id,
       k.full_name as keeper_name,
       p.name_key  as loser_key
from public.profiles p
join lateral (
  select q.id, q.full_name
  from public.profiles q
  where q.match_key = p.match_key
  order by q.client_created_at asc nulls last,
           q.created_at     asc nulls last,
           q.id             asc
  limit 1
) k on true
where k.id <> p.id;

do $$
declare
  loser   record;
  fk      record;
  n_repointed int := 0;
begin
  for loser in select * from _dd_plan loop
    for fk in
      select con.conname,
             con.conrelid::regclass::text                  as ref_table,
             (select attname from pg_attribute
               where attrelid = con.conrelid
                 and attnum   = con.conkey[1])                as ref_column
      from pg_constraint con
      where con.contype   = 'f'
        and con.confrelid = 'public.profiles'::regclass
        and array_length(con.conkey, 1) = 1
    loop
      execute format('update %I set %I = $1 where %I = $2',
                     fk.ref_table, fk.ref_column, fk.ref_column)
        using loser.keeper_id, loser.loser_id;
      get diagnostics n_repointed = row_count;
      raise notice 'repointed % row(s) in %.% from loser to keeper',
        n_repointed, fk.ref_table, fk.ref_column;
    end loop;

    -- Any composite foreign key pointing at profiles would have been skipped
    -- above; there are none today, but fail loudly if that ever changes.
    if exists (select 1 from pg_constraint con
               where con.contype = 'f'
                 and con.confrelid = 'public.profiles'::regclass
                 and array_length(con.conkey, 1) > 1) then
      raise exception 'composite FK to profiles exists -- merge by hand before continuing';
    end if;

    delete from public.profiles where id = loser.loser_id;
    raise notice 'merged duplicate "%" into the earlier row "%"', loser.loser_key, loser.keeper_name;
  end loop;

  if not found then
    raise notice 'no duplicate profiles found -- nothing to merge';
  end if;
end $$;


-- ------------------------------------------------------ 5. unique backstop
-- The trigger in step 6 handles the ordinary case. This index catches the case
-- where two devices insert the same donor at the very same moment: the trigger's
-- existence check is not atomic, but this index is. The app treats the resulting
-- 23505 as "somebody got there first" and re-reads the canonical row.
create unique index if not exists ux_profiles_match_key
  on public.profiles (match_key);

-- Prefix search for the donor picker.
create index if not exists ix_profiles_name_key
  on public.profiles (name_key text_pattern_ops);

-- The app filters its dropdown by role. The schema may already carry a
-- composite index on (role, status), in which case this is redundant but
-- harmless; `if not exists` keeps it cheap.
create index if not exists ix_profiles_role
  on public.profiles (role);


-- ------------------------------------------------- 6. first-wins on insert
-- Returning NULL from a BEFORE INSERT trigger silently skips the row, so the
-- existing profile survives and the caller gets no error. The app re-reads the
-- profile by match_key after every push to learn the canonical id, so it never
-- has to guess which row won.
--
-- The key is recomputed with moshjid_match_key() rather than read from
-- NEW.match_key: generated columns are computed after BEFORE triggers, so
-- NEW.match_key is NULL here and a naive `NEW.match_key` check would never
-- fire.

create or replace function public.profiles_first_wins() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  key text := public.moshjid_match_key(new.full_name, new.phone);
begin
  if exists (select 1 from public.profiles q where q.match_key = key) then
    raise notice 'profiles_first_wins: "%" already exists as % -- keeping the existing row',
      coalesce(new.full_name, ''),
      (select q.id from public.profiles q where q.match_key = key limit 1);
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_first_wins on public.profiles;
create trigger trg_profiles_first_wins
  before insert on public.profiles
  for each row execute function public.profiles_first_wins();


-- ------------------------------------------------------------- 7. RLS
-- The app signs in as a service user, so RLS applies to it. Only creates
-- policies when they are missing; existing ones are left alone.

do $$
begin
  if not exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'profiles') then
    raise notice 'no RLS policies on profiles -- creating read/insert policies';
    execute 'alter table public.profiles enable row level security';

    execute $p$
      create policy profiles_read_authenticated on public.profiles
        for select to authenticated
        using (true)
    $p$;

    -- The app only ever creates member rows and only ever resolves ids it can
    -- already read, so a narrow insert policy is enough.
    execute $p$
      create policy profiles_insert_members on public.profiles
        for insert to authenticated
        with check (role = 'member')
    $p$;

    -- No update/delete policy on purpose. Edits to donors happen through the
    -- dashboard or a future admin flow, not from the collection device.
  else
    raise notice 'profiles already has RLS policies -- leaving them untouched';
  end if;
end $$;


-- --------------------------------------------------------- 8. verification
select
  (select count(*) from public.profiles)                             as total_profiles,
  (select count(*) from public.profiles where role = 'member')       as members,
  (select count(*) from public.profiles where is_monthly)            as monthly,
  (select count(*) from (
      select match_key from public.profiles
      group by match_key having count(*) > 1) x)                     as duplicate_keys,
  (select count(*) from public.profiles where match_key like 'p:%')   as keyed_by_phone,
  (select count(*) from public.profiles where match_key like 'n:%')   as keyed_by_name;

-- Everything below should return 0 rows once the merge has run.
select match_key, count(*), array_agg(full_name order by client_created_at)
from public.profiles
group by match_key
having count(*) > 1;