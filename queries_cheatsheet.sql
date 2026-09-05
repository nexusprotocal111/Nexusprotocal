-- ============================================================================
-- MLM ROI PLATFORM: PRODUCTION QUERY CHEAT SHEET & COMMON OPERATIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. HIERARCHICAL TREE QUERIES (Using PostgreSQL ltree)
-- ----------------------------------------------------------------------------

-- A. Fetch entire downline (all generations) under a specific user
-- Replace ':user_uuid' with actual user UUID
SELECT 
    child.id,
    child.username,
    child.tree_depth - parent.tree_depth AS generation_depth,
    child.current_tier_id,
    child.active_investment_amount,
    child.created_at
FROM users parent
JOIN users child ON child.tree_path <@ parent.tree_path
WHERE parent.id = '00000000-0000-0000-0000-000000000001'
  AND child.id != parent.id
ORDER BY generation_depth ASC, child.created_at DESC;

-- B. Fetch direct referrals only (Generation 1)
SELECT 
    id,
    username,
    email,
    current_tier_id,
    active_investment_amount,
    status,
    created_at
FROM users
WHERE parent_id = '00000000-0000-0000-0000-000000000001'
ORDER BY created_at DESC;

-- C. Fetch all upline ancestors (Sponsor path up to root)
SELECT 
    ancestor.id,
    ancestor.username,
    ancestor.tree_depth,
    ancestor.referral_code
FROM users target
JOIN users ancestor ON target.tree_path <@ ancestor.tree_path
WHERE target.id = '00000000-0000-0000-0000-000000000005'
ORDER BY ancestor.tree_depth ASC;

-- D. Real-time Aggregate Volume & Downline stats under any node
SELECT 
    parent.username,
    COUNT(child.id) AS total_network_members,
    COALESCE(SUM(child.active_investment_amount), 0) AS total_downline_active_investment,
    COALESCE(SUM(child.total_deposited_amount), 0) AS total_downline_deposited_volume
FROM users parent
JOIN users child ON child.tree_path <@ parent.tree_path AND child.id != parent.id
WHERE parent.id = '00000000-0000-0000-0000-000000000001'
GROUP BY parent.username;

-- ----------------------------------------------------------------------------
-- 2. ADMIN TRANSACTION LIFECYCLE OPERATIONS
-- ----------------------------------------------------------------------------

-- A. Approve a Pending Deposit (Triggers volume propagation & wallet locking)
UPDATE deposits
SET 
    status = 'approved',
    admin_id = '11111111-1111-1111-1111-111111111111',
    tx_hash = '0x9b7a3d8e5f2c1b4a6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c',
    admin_notes = 'Verified on BSC Explorer'
WHERE id = '22222222-2222-2222-2222-222222222222'
  AND status = 'pending';

-- B. Process a Withdrawal (Deduct balance, apply fee, record TX Hash)
BEGIN;

-- 1. Lock wallet row for update
SELECT total_withdrawable_balance 
FROM wallets 
WHERE user_id = '00000000-0000-0000-0000-000000000001' 
FOR UPDATE;

-- 2. Update Withdrawal Record
UPDATE withdrawals
SET 
    status = 'approved',
    tx_hash = '0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b',
    admin_id = '11111111-1111-1111-1111-111111111111',
    processed_at = CURRENT_TIMESTAMP
WHERE id = '33333333-3333-3333-3333-333333333333'
  AND status = 'pending';

-- 3. Deduct from ROI / Main balance in wallet
UPDATE wallets
SET 
    roi_balance = roi_balance - 100.00000000,
    updated_at = CURRENT_TIMESTAMP
WHERE user_id = '00000000-0000-0000-0000-000000000001';

-- 4. Record in Financial Ledger
INSERT INTO financial_ledger (
    user_id,
    wallet_id,
    entry_type,
    category,
    amount,
    balance_before,
    balance_after,
    reference_id,
    reference_table,
    description
)
SELECT 
    '00000000-0000-0000-0000-000000000001',
    w.id,
    'debit',
    'withdrawal',
    100.00000000,
    w.roi_balance + 100.00000000,
    w.roi_balance,
    '33333333-3333-3333-3333-333333333333',
    'withdrawals',
    'Processed USDT Withdrawal (TRC20)'
FROM wallets w
WHERE w.user_id = '00000000-0000-0000-0000-000000000001';

COMMIT;

-- ----------------------------------------------------------------------------
-- 3. DAILY CRON EXECUTION (Call Stored Procedures)
-- ----------------------------------------------------------------------------

-- Step 1: Distribute Daily Tier ROI to all eligible active deposits
CALL sp_distribute_daily_roi(CURRENT_DATE);

-- Step 2: Distribute Multi-Tier Team Bonuses to eligible uplines
CALL sp_distribute_team_bonus(CURRENT_DATE);

-- ----------------------------------------------------------------------------
-- 4. AUDITING & RECONCILIATION
-- ----------------------------------------------------------------------------

-- Check Daily ROI Payout totals by Tier
SELECT 
    lt.name AS tier_name,
    COUNT(b.id) AS payouts_count,
    SUM(b.amount) AS total_roi_paid_usdt,
    AVG(b.percentage_applied) * 100 AS roi_percentage
FROM bonuses b
JOIN deposits d ON d.id = b.deposit_id
JOIN level_tiers lt ON lt.tier_id = d.tier_id
WHERE b.bonus_type = 'daily_roi'
  AND b.calculation_date = CURRENT_DATE
GROUP BY lt.tier_id, lt.name
ORDER BY lt.tier_id ASC;
