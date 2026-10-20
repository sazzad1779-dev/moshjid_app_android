-- Create the operator profiles referenced by transactions.entered_by.
-- Run in Supabase Dashboard > SQL Editor. Safe to run repeatedly.
-- entered_by is NOT NULL, so these must exist before importing.

insert into profiles (id, full_name, role, status)
select gen_random_uuid(), 'Sazzad', 'collector', 'active'
where not exists (
  select 1 from profiles where lower(full_name) = lower('Sazzad')
);

insert into profiles (id, full_name, role, status)
select gen_random_uuid(), 'Kamal', 'collector', 'active'
where not exists (
  select 1 from profiles where lower(full_name) = lower('Kamal')
);

