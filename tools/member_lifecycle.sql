-- tools/member_lifecycle.sql
--
-- Lets the collection device EDIT a donor and SOFT-DELETE one.
--
-- WHY NOT A REAL DELETE
-- `transactions.member_id` is declared
--   FOREIGN KEY (member_id) REFERENCES profiles(id) ON DELETE SET NULL
-- so removing a profile row silently nulls member_id on every transaction that
-- person ever paid for. For donation records that destroys attribution, so
-- "delete" means hide-and-keep instead. The row survives, the FK stays intact,
-- and the payment history still names who it belongs to.
--
-- There is also no DELETE policy on `profiles` for a collector, so a hard delete
-- was never available to this device anyway.
--
-- EDITING NEEDS NOTHING SERVER-SIDE
-- The upsert in SyncService.pushProfiles is INSERT ... ON CONFLICT (id) DO
-- UPDATE, and `profiles_update_collector_donor` (added by
-- tools/collector_donor_write.sql) already permits that for role='member'.
-- Edits sync with no migration; only the delete flag is new.
--
-- RECLAIMING A DELETED DONOR
-- `ux_profiles_match_key` is UNIQUE and ignores is_deleted, so a soft-deleted
-- donor still reserves their identity. That is deliberate: re-adding the same
-- person resurrects the same row rather than forking a duplicate. The device
-- sends is_deleted=false on that push, which clears the flag.
--
-- Safe to run repeatedly.

alter table public.profiles
  add column if not exists is_deleted boolean not null default false;

comment on column public.profiles.is_deleted is
  'Soft delete. Row is retained so transactions.member_id keeps resolving to this donor.';

-- Index the live roster filter. Partial, because soft-deleted rows are rare.
create index if not exists ix_profiles_live
  on public.profiles (match_key)
  where is_deleted = false;