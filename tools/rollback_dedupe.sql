-- tools/rollback_dedupe.sql
--
-- Removes everything tools/donor_dedupe.sql adds, restoring `profiles` to the
-- schema it had before that script was ever run.
--
-- Only run this if donor_dedupe.sql was applied by mistake. To install the
-- donor dedupe properly, just run donor_dedupe.sql -- it is idempotent.
--
-- Safe to run repeatedly. Additive columns are dropped only when they are
-- empty of real data; if either holds something written since, this aborts
-- rather than destroying it.

begin;

-- Generated columns must go before the functions that define them.
alter table public.profiles drop column if exists match_key;
alter table public.profiles drop column if exists name_key;

do $$
declare n int;
begin
  select count(*) into n from public.profiles where is_monthly is false;
  if n > 0 then
    raise exception 'ABORT: % profile(s) have is_monthly = false; dropping the column would lose that', n;
  end if;

  select count(*) into n from public.profiles
  where client_created_at is not null
    and (created_at is null or client_created_at <> created_at);
  if n > 0 then
    raise exception 'ABORT: % profile(s) have client_created_at differing from created_at; dropping would lose that', n;
  end if;
end $$;

alter table public.profiles drop column if exists is_monthly;
alter table public.profiles drop column if exists client_created_at;

drop trigger if exists trg_profiles_first_wins on public.profiles;
drop function if exists public.profiles_first_wins();
drop function if exists public.moshjid_match_key(text, text);
drop function if exists public.moshjid_phone_key(text);
drop function if exists public.moshjid_name_key(text);

drop index if exists public.ux_profiles_match_key;
drop index if exists public.ix_profiles_name_key;
drop index if exists public.ix_profiles_role;

commit;

\echo ''
\echo 'remaining donor columns (expect 0 rows):'
select column_name from information_schema.columns
where table_name = 'profiles'
  and column_name in ('name_key', 'match_key', 'is_monthly', 'client_created_at');

\echo 'remaining donor functions (expect 0 rows):'
select proname from pg_proc
where proname in ('moshjid_name_key', 'moshjid_phone_key',
                  'moshjid_match_key', 'profiles_first_wins');

\echo 'remaining donor indexes/trigger (expect 0 rows):'
select indexname from pg_indexes
where indexname in ('ux_profiles_match_key', 'ix_profiles_name_key', 'ix_profiles_role')
union all
select tgname from pg_trigger where tgname = 'trg_profiles_first_wins';