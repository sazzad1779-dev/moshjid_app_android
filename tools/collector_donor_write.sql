-- tools/collector_donor_write.sql
--
-- Lets a collection device CREATE and UPDATE donors.
--
-- WHY THIS IS NEEDED
-- tools/donor_roster_read.sql added a SELECT policy, so the device can read the
-- roster. It never added the write side, and `profiles` has no INSERT policy for
-- anyone except an admin:
--
--   profiles_admin_write  ALL  using (is_admin())
--   profiles_admin_update UPDATE using (is_admin())
--   profiles_self_update  UPDATE using (id = auth.uid())
--
-- The device signs in as a *collector*, and is_admin() requires
-- role IN ('admin','super_admin'), so none of those policies apply and every
-- donor insert is rejected. SyncService.pushProfiles upserts into `profiles`,
-- hits the RLS rejection, and its catch block has no error branch -- so the
-- donor simply stays "waiting to sync" with nothing reported anywhere. Reads
-- look perfect the whole time, which is what makes this so confusing.
--
-- SCOPE, deliberately narrow
-- Both policies are restricted to `role = 'member'`, so a collector can create
-- and edit donors but cannot touch operator profiles (admin/collector/super_admin)
-- and cannot promote anyone to a privileged role: the WITH CHECK re-asserts the
-- same restriction on the new row, so an upsert cannot smuggle a role change.
-- This grants data entry, not authority.
--
-- Safe to run repeatedly.

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename   = 'profiles'
      and policyname  = 'profiles_insert_collector_donor'
  ) then
    create policy profiles_insert_collector_donor
      on public.profiles
      for insert
      to authenticated
      with check (is_collector() and role = 'member');
    raise notice 'created policy profiles_insert_collector_donor';
  else
    raise notice 'policy profiles_insert_collector_donor already exists';
  end if;

  -- Required as well as the insert policy: PostgREST upsert sends
  -- INSERT ... ON CONFLICT (id) DO UPDATE, and the DO UPDATE branch is
  -- governed by UPDATE policies. Without this, a donor that already exists
  -- server-side still fails to upload.
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename   = 'profiles'
      and policyname  = 'profiles_update_collector_donor'
  ) then
    create policy profiles_update_collector_donor
      on public.profiles
      for update
      to authenticated
      using (is_collector() and role = 'member')
      with check (is_collector() and role = 'member');
    raise notice 'created policy profiles_update_collector_donor';
  else
    raise notice 'policy profiles_update_collector_donor already exists';
  end if;
end $$;