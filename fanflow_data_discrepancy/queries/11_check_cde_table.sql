-- Step 11: Check if the 599 missing events exist in the CDE analytics table
-- per the recover-tier-points runbook (page 2384461902), this is a downstream loyalty analytics table
-- Schema is different (lowercase short names): loyactid, loytranid, ts, status

-- First, confirm the table exists and check sample columns
DESCRIBE TABLE CDE.CDE_CORE.FF_LOYALTY_TRANSACTION_SUCCESSFUL_ACCOUNT;
