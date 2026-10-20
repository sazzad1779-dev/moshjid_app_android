-- tools/donor_edit_permission.sql
--
-- Lets a collection device EDIT and SOFT-DELETE a donor.
--
-- WHY THIS IS NEEDED
-- `profiles` carries a BEFORE UPDATE trigger, enforce_profile_protected_columns,
-- whose central rule is:
--
--   IF OLD.id IS DISTINCT FROM auth.uid() THEN
--     RAISE EXCEPTION 'not authorized to update this profile'
--
-- i.e. a user may only update the row that is their own profile. That is the
-- right rule for operator accounts, but a donor row's id is a uuid this device
-- minted offline (see LocalDb.ensureProfile) -- it is never the signed-in
-- collector's auth.uid(). So the collector can INSERT donors but can never
-- UPDATE one, and editing a member's name or phone fails with 42501.
--
-- The device reports this honestly rather than silently, but the feature still
-- cannot work until the rule permits it.
--
-- SCOPE, deliberately narrow
-- The exemption is added to the existing-trRow test, not as a bypass of it:
--
--   * only rows whose role is 'member' on BOTH sides -- no operator row, and a
--     collector cannot rewrite a donor into an operator;
--   * only for a caller is_collector() already accepts;
--   * placed AFTER the protected-column loop below, so role, status,
--     approval_status, collector_id, auth_user_id and the rest still cannot be
--     changed by anyone but an admin. That is what stops this from becoming
--     privilege escalation;
--   * id stability is still enforced.
--
-- What a collector CAN then change on a donor: full_name, phone, is_monthly and
-- is_deleted. Nothing else.
--
-- Safe to run repeatedly.

create or replace function public.enforce_profile_protected_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  old_j jsonb := to_jsonb(OLD);
  new_j jsonb := to_jsonb(NEW);
  protected text[] := ARRAY[
    'role', 'status', 'approval_status',
    'collector_id', 'area_id', 'auth_user_id',
    'decision_by', 'decision_at', 'rejected_reason',
    'approved_by', 'approved_at'
  ];
  key text;
BEGIN
  -- Admins bypass the column check (see header).
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- Server-internal writes (e.g. unclaimed-profile adoption inside
  -- handle_new_auth_user()) execute within a trigger/function with no
  -- end-user JWT, so auth.uid() is NULL there. Plain client statements
  -- always run at trigger depth 0, hence this exempts internal paths
  -- only -- never a direct client UPDATE (which also still faces RLS).
  IF auth.uid() IS NULL AND pg_trigger_depth() > 0 THEN
    RETURN NEW;
  END IF;

  -- Own row: protected keys must be unchanged (missing keys = equal).
  -- Checked before the row-ownership rule below so that allowing donor edits
  -- cannot become a way to rewrite role or status.
  FOREACH key IN ARRAY protected LOOP
    IF (old_j -> key) IS DISTINCT FROM (new_j -> key) THEN
      RAISE EXCEPTION 'not authorized to change %', key
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  -- Primary-key / identity stability.
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'not authorized to change id'
      USING ERRCODE = '42501';
  END IF;

  -- Non-admins may touch only their own row -- except a donor row, which a
  -- collection device legitimately has to edit and soft-delete. Donor ids are
  -- minted offline so they never equal auth.uid(). Both sides must already be
  -- 'member', and the protected columns above have already been locked down, so
  -- this cannot be used to reach an operator row or to escalate a role.
  IF OLD.id IS DISTINCT FROM auth.uid() THEN
    IF NOT (public.is_collector()
            AND OLD.role = 'member'
            AND NEW.role = 'member') THEN
      RAISE EXCEPTION 'not authorized to update this profile'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END
$$;