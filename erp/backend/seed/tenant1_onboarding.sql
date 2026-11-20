-- =====================================================================
-- iSmile ERP  -  tenant #1 onboarding seed (step C0 of 06 section 5; run ONCE by the owner, after E100 + E110)
-- E100 already seeds the tenant row (code ismile). This adds its settings / permission matrix (idempotent) and the
-- pending OWNER invitation for the email given below. Branches and the other members are typed in the admin screen.
-- No real email is stored in this repository: it is passed at run time.
--   psql:              psql -v owner_email='owner@example.com' -f erp/backend/seed/tenant1_onboarding.sql
--   Supabase editor:   select erp.tenant_onboard('ismile', 'iSmile', 'owner@example.com',
--                        (select id from auth.users where email = 'owner@example.com'));
--   The 4th argument (review F1, F1-04) binds the owner to its EXISTING login at once (no window in which another
--   login could claim the owner invitation). It is null when the email has no login yet: then invite the same email
--   in Supabase (Authentication > Users > Invite user), open erp.html and sign in at once; the first sign-in binds.
-- Check: select email, role, auth_user_id is not null as bound from erp.members;
-- Re-runnable: a second run changes nothing once the tenant has an active owner.
-- =====================================================================
\if :{?owner_email}
select erp.tenant_onboard('ismile', 'iSmile', :'owner_email');
\else
\echo 'usage: psql -v owner_email=owner@example.com -f erp/backend/seed/tenant1_onboarding.sql'
\endif
