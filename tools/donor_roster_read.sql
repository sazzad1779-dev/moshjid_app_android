-- tools/donor_roster_read.sql
--
-- Lets the collection device read the full donor roster.
--
-- WHY THIS IS NEEDED
-- `profiles` already has these SELECT policies:
--   profiles_select_admin_all          using (is_admin())
--   profiles_select_collector_assigned using (is_collector() AND collector_id = current_profile_id())
--   profiles_select_own                using (auth_user_id = auth.uid())
--
-- The device signs in as an approved collector, so the collector policy is the
-- one that should apply -- but it only exposes profiles whose collector_id
-- equals the caller's own id. Every donor has collector_id NULL (see
-- ASSIGN_COLLECTOR = False in tools/link_donor_profiles.py), so that predicate
-- is never true and the device sees exactly one row: its own profile.
--
-- Measured before this change, as the signed-in device:
--   select * from profiles                    -> 1 row
--   select * from profiles where role=member  -> 0 rows
--
-- The fix is a policy that lets any approved collector read donors, rather
-- than only the ones assigned to them. Nothing existing is modified.
--
-- Safe to run repeatedly.

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename   = 'profiles'
      and policyname  = 'profiles_select_collector_roster'
  ) then
    create policy profiles_select_collector_roster
      on public.profiles
      for select
      to authenticated
      using (is_collector());
    raise notice 'created policy profiles_select_collector_roster';
  else
    raise notice 'policy profiles_select_collector_roster already exists';
  end if;
end $$;

\echo ''
\echo 'policies on public.profiles now:'
select policyname, cmd, roles::text
from pg_policies
where schemaname = 'public' and tablename = 'profiles'
order by policyname;