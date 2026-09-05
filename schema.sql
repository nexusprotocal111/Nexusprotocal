-- ============================================================================
-- PRODUCTION-READY POSTGRESQL DATABASE SCHEMA: MLM ROI PLATFORM
-- Architecture: High-Concurrency, Double-Entry Capable, ltree Hierarchy
-- Target Database: PostgreSQL 14+
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. EXTENSIONS & INITIAL SETUP
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "ltree";

-- ----------------------------------------------------------------------------
-- 2. CUSTOM ENUMS & DOMAINS
-- ----------------------------------------------------------------------------
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_status') THEN
        CREATE TYPE user_status AS ENUM ('active', 'inactive', 'suspended', 'banned');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'crypto_network') THEN
        CREATE TYPE crypto_network AS ENUM ('BEP20', 'TRC20', 'ERC20', 'POLYGON');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'deposit_status') THEN
        CREATE TYPE deposit_status AS ENUM ('pending', 'approved', 'rejected', 'expired');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'withdrawal_status') THEN
        CREATE TYPE withdrawal_status AS ENUM ('pending', 'processing', 'approved', 'rejected', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'bonus_type') THEN
        CREATE TYPE bonus_type AS ENUM (
            'daily_roi',              -- Daily Tier ROI (1.1% to 3.0%)
            'team_bonus',             -- Direct & Multi-level downline commission
            'level_upgrade_bonus',    -- Milestone reward on achieving higher tier
            'monthly_rank_bonus'      -- Monthly leadership performance pool
        );
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ledger_entry_type') THEN
        CREATE TYPE ledger_entry_type AS ENUM ('credit', 'debit');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ledger_category') THEN
        CREATE TYPE ledger_category AS ENUM (
            'deposit',
            'withdrawal',
            'withdrawal_fee',
            'daily_roi',
            'team_bonus',
            'level_upgrade_bonus',
            'monthly_rank_bonus',
            'admin_adjustment'
        );
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 3. ADMINISTRATIVE USERS TABLE
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admins (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(30) NOT NULL DEFAULT 'finance_manager' CHECK (role IN ('superadmin', 'admin', 'finance_manager', 'support')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 4. LEVEL / TIER CONFIGURATION (7 TIERS)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS level_tiers (
    tier_id INT PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE,
    daily_roi_rate NUMERIC(6, 4) NOT NULL CHECK (daily_roi_rate >= 0), -- e.g., 0.0110 for 1.1%
    min_deposit NUMERIC(20, 8) NOT NULL CHECK (min_deposit >= 0),
    max_deposit NUMERIC(20, 8) NOT NULL CHECK (max_deposit >= min_deposit),
    min_active_directs INT NOT NULL DEFAULT 0 CHECK (min_active_directs >= 0),
    min_team_volume NUMERIC(20, 8) NOT NULL DEFAULT 0 CHECK (min_team_volume >= 0),
    level_upgrade_reward NUMERIC(20, 8) NOT NULL DEFAULT 0 CHECK (level_upgrade_reward >= 0),
    monthly_rank_reward NUMERIC(20, 8) NOT NULL DEFAULT 0 CHECK (monthly_rank_reward >= 0),
    max_roi_cap_multiplier NUMERIC(4, 2) NOT NULL DEFAULT 3.00, -- 3x (300%) Max Returns Cap
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed Default 7 Tiers (1.1%, 1.3%, 1.5%, 1.7%, 2.1%, 2.5%, 3.0%)
INSERT INTO level_tiers (tier_id, name, daily_roi_rate, min_deposit, max_deposit, min_active_directs, min_team_volume, level_upgrade_reward, monthly_rank_reward, max_roi_cap_multiplier)
VALUES
    (1, 'Level 1 - Starter',     0.0110, 50.00000000,    499.00000000,   0,  0.00000000,      0.00000000,    0.00000000,    3.00),
    (2, 'Level 2 - Executive',   0.0130, 500.00000000,   1999.00000000,  2,  2500.00000000,   25.00000000,   50.00000000,   3.00),
    (3, 'Level 3 - Pioneer',     0.0150, 2000.00000000,  4999.00000000,  4,  10000.00000000,  100.00000000,  200.00000000,  3.00),
    (4, 'Level 4 - Leader',      0.0170, 5000.00000000,  9999.00000000,  6,  30000.00000000,  300.00000000,  500.00000000,  3.00),
    (5, 'Level 5 - Director',    0.0210, 10000.00000000, 24999.00000000, 8,  75000.00000000,  750.00000000,  1200.00000000, 3.00),
    (6, 'Level 6 - Ambassador',  0.0250, 25000.00000000, 49999.00000000, 10, 200000.00000000, 2000.00000000, 3000.00000000, 3.00),
    (7, 'Level 7 - Crown Elite', 0.0300, 50000.00000000, 1000000.00000000, 15, 500000.00000000, 5000.00000000, 10000.00000000, 3.00)
ON CONFLICT (tier_id) DO UPDATE SET
    daily_roi_rate = EXCLUDED.daily_roi_rate,
    min_deposit = EXCLUDED.min_deposit,
    max_deposit = EXCLUDED.max_deposit,
    min_active_directs = EXCLUDED.min_active_directs,
    min_team_volume = EXCLUDED.min_team_volume;

-- ----------------------------------------------------------------------------
-- 5. USERS TABLE (Hierarchical Tree with ltree, Eligibility Tracking)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    phone VARCHAR(30),
    password_hash VARCHAR(255) NOT NULL,
    security_pin_hash VARCHAR(255),
    referral_code VARCHAR(20) NOT NULL UNIQUE,
    
    -- Referral Hierarchy
    parent_id UUID REFERENCES users(id) ON DELETE SET NULL,
    tree_path LTREE NOT NULL,
    tree_depth INT NOT NULL DEFAULT 1 CHECK (tree_depth >= 1),
    
    -- Current Status & Tier
    current_tier_id INT NOT NULL REFERENCES level_tiers(tier_id) DEFAULT 1,
    status user_status NOT NULL DEFAULT 'active',
    
    -- Real-Time Eligibility & Network Counters
    active_direct_referrals_count INT NOT NULL DEFAULT 0 CHECK (active_direct_referrals_count >= 0),
    total_indirect_downline_count INT NOT NULL DEFAULT 0 CHECK (total_indirect_downline_count >= 0),
    total_direct_volume NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_direct_volume >= 0),
    total_team_volume NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_team_volume >= 0),
    
    -- Financial Aggregations & Investment State
    active_investment_amount NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (active_investment_amount >= 0),
    total_deposited_amount NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_deposited_amount >= 0),
    total_roi_earned NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_roi_earned >= 0),
    total_bonuses_earned NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_bonuses_earned >= 0),
    total_withdrawn_amount NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (total_withdrawn_amount >= 0),
    
    -- System Audit & Tracking
    last_login_at TIMESTAMPTZ,
    last_roi_calculated_at DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 6. USER WALLETS / BALANCES (Segregated & Auditable)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wallets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    main_balance NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (main_balance >= 0),
    roi_balance NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (roi_balance >= 0),
    bonus_balance NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (bonus_balance >= 0),
    locked_deposit_balance NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (locked_deposit_balance >= 0),
    total_withdrawable_balance NUMERIC(20, 8) GENERATED ALWAYS AS (main_balance + roi_balance + bonus_balance) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 7. DEPOSITS TABLE (USDT BEP20 & TRC20, Lifecycle & ROI Cap Tracking)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS deposits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    currency VARCHAR(10) NOT NULL DEFAULT 'USDT',
    network crypto_network NOT NULL,
    deposit_address VARCHAR(120) NOT NULL,
    tx_hash VARCHAR(150) UNIQUE,
    status deposit_status NOT NULL DEFAULT 'pending',
    
    -- Auditing & Admin Verification
    admin_id UUID REFERENCES admins(id) ON DELETE SET NULL,
    admin_notes TEXT,
    
    -- Tier & ROI Contract Parameters
    tier_id INT REFERENCES level_tiers(tier_id),
    daily_roi_rate NUMERIC(6, 4) NOT NULL, -- Fixed at approval time
    max_cap_multiplier NUMERIC(4, 2) NOT NULL DEFAULT 3.00,
    max_cap_amount NUMERIC(20, 8) NOT NULL, -- amount * max_cap_multiplier
    accumulated_roi_paid NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000 CHECK (accumulated_roi_paid >= 0),
    
    -- ROI Status Flags
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    is_capped BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Timestamps
    approved_at TIMESTAMPTZ,
    rejected_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 8. WITHDRAWALS TABLE (Levy / Fee Deduction, Status, Blockchain Dispatch)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS withdrawals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    gross_amount NUMERIC(20, 8) NOT NULL CHECK (gross_amount > 0),
    fee_percentage NUMERIC(6, 4) NOT NULL DEFAULT 0.0500 CHECK (fee_percentage >= 0 AND fee_percentage <= 1.0000), -- 5% Default Fee
    fee_deducted NUMERIC(20, 8) NOT NULL CHECK (fee_deducted >= 0),
    net_amount NUMERIC(20, 8) NOT NULL CHECK (net_amount > 0),
    
    wallet_address VARCHAR(120) NOT NULL,
    network crypto_network NOT NULL,
    status withdrawal_status NOT NULL DEFAULT 'pending',
    tx_hash VARCHAR(150) UNIQUE,
    
    -- Auditing
    admin_id UUID REFERENCES admins(id) ON DELETE SET NULL,
    rejection_reason TEXT,
    
    -- Timestamps
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Consistency Constraint
    CONSTRAINT chk_net_amount_arithmetic CHECK (net_amount = (gross_amount - fee_deducted))
);

-- ----------------------------------------------------------------------------
-- 9. BONUSES TABLE (Daily ROI, Team Bonus, Level Upgrade, Monthly Rank)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bonuses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, -- Beneficiary
    source_user_id UUID REFERENCES users(id) ON DELETE SET NULL,  -- Downline user who triggered the bonus
    deposit_id UUID REFERENCES deposits(id) ON DELETE SET NULL,   -- Specific deposit (for daily ROI)
    
    bonus_type bonus_type NOT NULL,
    generation_level INT CHECK (generation_level >= 1 AND generation_level <= 7), -- Generation depth 1-7
    
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    calculation_basis_amount NUMERIC(20, 8) CHECK (calculation_basis_amount >= 0),
    percentage_applied NUMERIC(6, 4),
    
    calculation_date DATE NOT NULL, -- Date bonus was generated (idempotency key part)
    status VARCHAR(20) NOT NULL DEFAULT 'credited' CHECK (status IN ('pending', 'credited', 'capped', 'cancelled')),
    capped_amount_deducted NUMERIC(20, 8) NOT NULL DEFAULT 0.00000000,
    
    remarks TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- 10. FINANCIAL LEDGER (Double-Entry Audit Trail for Immutable Accounting)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS financial_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    entry_type ledger_entry_type NOT NULL,
    category ledger_category NOT NULL,
    amount NUMERIC(20, 8) NOT NULL CHECK (amount > 0),
    balance_before NUMERIC(20, 8) NOT NULL,
    balance_after NUMERIC(20, 8) NOT NULL,
    reference_id UUID, -- References deposit_id, withdrawal_id, or bonus_id
    reference_table VARCHAR(50),
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 11. INDEXES FOR PERFORMANCE & TREE TRAVERSAL
-- ============================================================================

-- Users Tree & Hierarchy Indexes
CREATE INDEX IF NOT EXISTS idx_users_parent_id ON users(parent_id);
CREATE INDEX IF NOT EXISTS idx_users_tree_path_gist ON users USING GIST (tree_path);
CREATE INDEX IF NOT EXISTS idx_users_tree_path_btree ON users USING BTREE (tree_path);
CREATE INDEX IF NOT EXISTS idx_users_referral_code ON users(referral_code);
CREATE INDEX IF NOT EXISTS idx_users_tier_status ON users(current_tier_id, status);
CREATE INDEX IF NOT EXISTS idx_users_active_directs ON users(active_direct_referrals_count);

-- Deposits Indexes
CREATE INDEX IF NOT EXISTS idx_deposits_user_status ON deposits(user_id, status);
CREATE INDEX IF NOT EXISTS idx_deposits_status_created ON deposits(status, created_at);
CREATE INDEX IF NOT EXISTS idx_deposits_active_roi ON deposits(is_active, is_capped) WHERE is_active = TRUE AND is_capped = FALSE;
CREATE INDEX IF NOT EXISTS idx_deposits_tx_hash ON deposits(tx_hash) WHERE tx_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_deposits_admin ON deposits(admin_id);

-- Withdrawals Indexes
CREATE INDEX IF NOT EXISTS idx_withdrawals_user_status ON withdrawals(user_id, status);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status_created ON withdrawals(status, created_at);
CREATE INDEX IF NOT EXISTS idx_withdrawals_tx_hash ON withdrawals(tx_hash) WHERE tx_hash IS NOT NULL;

-- Bonuses Indexes & Idempotency Constraints
CREATE INDEX IF NOT EXISTS idx_bonuses_user_type_date ON bonuses(user_id, bonus_type, calculation_date);
CREATE INDEX IF NOT EXISTS idx_bonuses_source_user ON bonuses(source_user_id);
CREATE INDEX IF NOT EXISTS idx_bonuses_deposit_id ON bonuses(deposit_id);

-- CRITICAL IDEMPOTENCY: Prevent Duplicate Daily ROI Payouts
CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_daily_roi_idempotency 
ON bonuses (deposit_id, calculation_date, bonus_type) 
WHERE bonus_type = 'daily_roi';

-- CRITICAL IDEMPOTENCY: Prevent Duplicate Monthly Rank Rewards
CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_monthly_rank_idempotency 
ON bonuses (user_id, bonus_type, calculation_date) 
WHERE bonus_type = 'monthly_rank_bonus';

-- Ledger Indexes
CREATE INDEX IF NOT EXISTS idx_ledger_user_created ON financial_ledger(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_reference ON financial_ledger(reference_table, reference_id);

-- ============================================================================
-- 12. DATABASE FUNCTIONS & TRIGGERS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper Function: Clean UUID for ltree path (replace hyphens with underscores)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clean_uuid_for_ltree(p_uuid UUID)
RETURNS VARCHAR AS $$
BEGIN
    RETURN 'u_' || REPLACE(p_uuid::TEXT, '-', '_');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- Trigger 1: Auto-generate Tree Path, Depth, and Wallet on User Registration
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_users_before_insert_path()
RETURNS TRIGGER AS $$
DECLARE
    v_parent_path LTREE;
    v_parent_depth INT;
    v_clean_node VARCHAR;
BEGIN
    v_clean_node := clean_uuid_for_ltree(NEW.id);

    IF NEW.parent_id IS NULL THEN
        -- Root Node
        NEW.tree_path := text2ltree(v_clean_node);
        NEW.tree_depth := 1;
    ELSE
        -- Fetch Parent Path and Depth
        SELECT tree_path, tree_depth INTO v_parent_path, v_parent_depth
        FROM users
        WHERE id = NEW.parent_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parent user with ID % does not exist', NEW.parent_id;
        END IF;

        NEW.tree_path := v_parent_path || text2ltree(v_clean_node);
        NEW.tree_depth := v_parent_depth + 1;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_before_insert_path ON users;
CREATE TRIGGER trg_users_before_insert_path
BEFORE INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION fn_users_before_insert_path();

-- Auto-create Wallet after User creation
CREATE OR REPLACE FUNCTION fn_users_after_insert_wallet()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO wallets (user_id) VALUES (NEW.id);
    
    -- Increment total indirect downline count on all ancestors
    IF NEW.parent_id IS NOT NULL THEN
        -- Direct parent: increment active_direct_referrals_count if active
        UPDATE users 
        SET total_indirect_downline_count = total_indirect_downline_count + 1
        WHERE tree_path @> text2ltree(clean_uuid_for_ltree(NEW.parent_id))
          AND id != NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_after_insert_wallet ON users;
CREATE TRIGGER trg_users_after_insert_wallet
AFTER INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION fn_users_after_insert_wallet();

-- ----------------------------------------------------------------------------
-- Trigger 2: Automatic Network Volume & Eligibility Recalculation on Deposit Approval
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_deposits_after_update_approval()
RETURNS TRIGGER AS $$
DECLARE
    v_user users%ROWTYPE;
    v_tier level_tiers%ROWTYPE;
    v_ancestor_node RECORD;
    v_is_first_active_deposit BOOLEAN;
BEGIN
    -- Execute only when transition occurs from pending -> approved
    IF OLD.status = 'pending' AND NEW.status = 'approved' THEN
        
        -- 1. Fetch user & Tier info
        SELECT * INTO v_user FROM users WHERE id = NEW.user_id;
        SELECT * INTO v_tier FROM level_tiers WHERE tier_id = NEW.tier_id;

        -- 2. Activate Deposit ROI terms
        NEW.is_active := TRUE;
        NEW.max_cap_amount := NEW.amount * v_tier.max_roi_cap_multiplier;
        NEW.daily_roi_rate := v_tier.daily_roi_rate;
        NEW.approved_at := CURRENT_TIMESTAMP;

        -- 3. Check if this is the user's first active deposit (to update parent direct active count)
        SELECT (COUNT(*) = 0) INTO v_is_first_active_deposit 
        FROM deposits 
        WHERE user_id = NEW.user_id AND status = 'approved' AND id != NEW.id;

        -- 4. Update User's Active Investment and Deposited Balance
        UPDATE users
        SET active_investment_amount = active_investment_amount + NEW.amount,
            total_deposited_amount = total_deposited_amount + NEW.amount,
            current_tier_id = GREATEST(current_tier_id, NEW.tier_id),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = NEW.user_id;

        -- 5. If first active deposit, increment parent's active_direct_referrals_count
        IF v_is_first_active_deposit AND v_user.parent_id IS NOT NULL THEN
            UPDATE users
            SET active_direct_referrals_count = active_direct_referrals_count + 1,
                total_direct_volume = total_direct_volume + NEW.amount,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = v_user.parent_id;
        ELSIF v_user.parent_id IS NOT NULL THEN
            UPDATE users
            SET total_direct_volume = total_direct_volume + NEW.amount,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = v_user.parent_id;
        END IF;

        -- 6. Propagate Team Volume to all upline ancestors using ltree @>
        UPDATE users
        SET total_team_volume = total_team_volume + NEW.amount,
            updated_at = CURRENT_TIMESTAMP
        WHERE tree_path @> text2ltree(clean_uuid_for_ltree(v_user.id))
          AND id != NEW.user_id;

        -- 7. Add funds to locked deposit wallet
        UPDATE wallets
        SET locked_deposit_balance = locked_deposit_balance + NEW.amount,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = NEW.user_id;

        -- 8. Write Immutable Financial Ledger Record
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
            NEW.user_id,
            w.id,
            'credit',
            'deposit',
            NEW.amount,
            w.locked_deposit_balance - NEW.amount,
            w.locked_deposit_balance,
            NEW.id,
            'deposits',
            'Approved USDT deposit on ' || NEW.network::TEXT
        FROM wallets w
        WHERE w.user_id = NEW.user_id;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_deposits_after_update_approval ON deposits;
CREATE TRIGGER trg_deposits_after_update_approval
BEFORE UPDATE ON deposits
FOR EACH ROW
EXECUTE FUNCTION fn_deposits_after_update_approval();

-- ============================================================================
-- 13. STORED PROCEDURES: CRON / BATCH ROI & TEAM BONUS DISTRIBUTION
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SP 1: High-Performance Batch Daily ROI Distribution with Cap Protection
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_distribute_daily_roi(p_calculation_date DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_processed_count INT := 0;
    v_total_roi_amount NUMERIC(20, 8) := 0;
BEGIN
    -- Temporary staging table for batch calculations
    CREATE TEMP TABLE tmp_daily_roi_batch ON COMMIT DROP AS
    SELECT 
        d.id AS deposit_id,
        d.user_id,
        d.amount AS deposit_amount,
        d.daily_roi_rate,
        d.max_cap_amount,
        d.accumulated_roi_paid,
        -- Calculate proposed ROI
        ROUND((d.amount * d.daily_roi_rate), 8) AS raw_roi_amount,
        -- Check Remaining Room under Cap
        (d.max_cap_amount - d.accumulated_roi_paid) AS remaining_cap,
        -- Final Payable ROI bounded by Cap
        LEAST(
            ROUND((d.amount * d.daily_roi_rate), 8),
            GREATEST(0, d.max_cap_amount - d.accumulated_roi_paid)
        ) AS payable_roi_amount,
        CASE 
            WHEN (d.accumulated_roi_paid + ROUND((d.amount * d.daily_roi_rate), 8)) >= d.max_cap_amount 
            THEN TRUE 
            ELSE FALSE 
        END AS will_be_capped
    FROM deposits d
    JOIN users u ON u.id = d.user_id
    WHERE d.status = 'approved'
      AND d.is_active = TRUE
      AND d.is_capped = FALSE
      AND u.status = 'active'
      -- Avoid re-running for the same date (Idempotency check)
      AND NOT EXISTS (
          SELECT 1 FROM bonuses b 
          WHERE b.deposit_id = d.id 
            AND b.calculation_date = p_calculation_date 
            AND b.bonus_type = 'daily_roi'
      );

    -- 1. Insert into Bonuses Table
    INSERT INTO bonuses (
        user_id,
        deposit_id,
        bonus_type,
        amount,
        calculation_basis_amount,
        percentage_applied,
        calculation_date,
        status,
        capped_amount_deducted,
        remarks
    )
    SELECT 
        user_id,
        deposit_id,
        'daily_roi',
        payable_roi_amount,
        deposit_amount,
        daily_roi_rate,
        p_calculation_date,
        CASE WHEN will_be_capped THEN 'capped' ELSE 'credited' END,
        (raw_roi_amount - payable_roi_amount),
        'Daily ROI of ' || (daily_roi_rate * 100)::TEXT || '% for date ' || p_calculation_date::TEXT
    FROM tmp_daily_roi_batch
    WHERE payable_roi_amount > 0;

    -- 2. Update Deposit Cap Tracking & Flags
    UPDATE deposits d
    SET 
        accumulated_roi_paid = d.accumulated_roi_paid + t.payable_roi_amount,
        is_capped = t.will_be_capped,
        is_active = CASE WHEN t.will_be_capped THEN FALSE ELSE TRUE END,
        updated_at = CURRENT_TIMESTAMP
    FROM tmp_daily_roi_batch t
    WHERE d.id = t.deposit_id;

    -- 3. Credit ROI Balances in Wallets
    UPDATE wallets w
    SET 
        roi_balance = w.roi_balance + sub.total_roi,
        updated_at = CURRENT_TIMESTAMP
    FROM (
        SELECT user_id, SUM(payable_roi_amount) AS total_roi
        FROM tmp_daily_roi_batch
        WHERE payable_roi_amount > 0
        GROUP BY user_id
    ) sub
    WHERE w.user_id = sub.user_id;

    -- 4. Update User Aggregate Tracking
    UPDATE users u
    SET 
        total_roi_earned = u.total_roi_earned + sub.total_roi,
        last_roi_calculated_at = p_calculation_date,
        updated_at = CURRENT_TIMESTAMP
    FROM (
        SELECT user_id, SUM(payable_roi_amount) AS total_roi
        FROM tmp_daily_roi_batch
        WHERE payable_roi_amount > 0
        GROUP BY user_id
    ) sub
    WHERE u.id = sub.user_id;

    -- Log Execution
    SELECT COUNT(*), COALESCE(SUM(payable_roi_amount), 0)
    INTO v_processed_count, v_total_roi_amount
    FROM tmp_daily_roi_batch;

    RAISE NOTICE 'Daily ROI Distribution Completed for %: % deposits processed, % USDT total paid.', 
                 p_calculation_date, v_processed_count, v_total_roi_amount;
END;
$$;

-- ----------------------------------------------------------------------------
-- SP 2: Dynamic 7-Generation Team Commission Distribution
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_distribute_team_bonus(p_calculation_date DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Commission percentage per generation depth (Gen 1 to 7)
    -- Level 1: 10%, L2: 5%, L3: 3%, L4: 2%, L5: 1%, L6: 1%, L7: 0.5%
    c_gen_rates CONSTANT NUMERIC[] := ARRAY[0.1000, 0.0500, 0.0300, 0.0200, 0.0100, 0.0100, 0.0050];
    v_depth INT;
BEGIN
    -- Iterate through 7 generations
    FOR v_depth IN 1..7 LOOP
        
        -- Insert generation bonuses
        INSERT INTO bonuses (
            user_id,
            source_user_id,
            deposit_id,
            bonus_type,
            generation_level,
            amount,
            calculation_basis_amount,
            percentage_applied,
            calculation_date,
            status,
            remarks
        )
        SELECT 
            ancestor.id AS user_id,
            b.user_id AS source_user_id,
            b.deposit_id,
            'team_bonus',
            v_depth,
            ROUND(b.amount * c_gen_rates[v_depth], 8) AS bonus_amount,
            b.amount AS calculation_basis_amount,
            c_gen_rates[v_depth],
            p_calculation_date,
            'credited',
            'Gen ' || v_depth || ' Team Bonus (' || (c_gen_rates[v_depth] * 100)::TEXT || '%) from ' || src.username
        FROM bonuses b
        JOIN users src ON src.id = b.user_id
        -- Ancestor is at exact generation distance v_depth
        JOIN users ancestor ON ancestor.tree_path @> src.tree_path 
                            AND (src.tree_depth - ancestor.tree_depth) = v_depth
        -- Ancestor Eligibility Check: Active and sufficient active direct referrals to unlock depth
        JOIN level_tiers lt ON lt.tier_id = ancestor.current_tier_id
        WHERE b.bonus_type = 'daily_roi'
          AND b.calculation_date = p_calculation_date
          AND ancestor.status = 'active'
          AND ancestor.active_direct_referrals_count >= v_depth -- Unlocking rule: N active directs unlocks N generation depths
          AND NOT EXISTS (
              SELECT 1 FROM bonuses eb
              WHERE eb.user_id = ancestor.id
                AND eb.source_user_id = src.id
                AND eb.deposit_id = b.deposit_id
                AND eb.bonus_type = 'team_bonus'
                AND eb.calculation_date = p_calculation_date
          );

    END LOOP;

    -- Credit all generated team bonuses to wallets
    UPDATE wallets w
    SET 
        bonus_balance = w.bonus_balance + sub.total_bonus,
        updated_at = CURRENT_TIMESTAMP
    FROM (
        SELECT user_id, SUM(amount) AS total_bonus
        FROM bonuses
        WHERE bonus_type = 'team_bonus'
          AND calculation_date = p_calculation_date
        GROUP BY user_id
    ) sub
    WHERE w.user_id = sub.user_id;

    -- Update User aggregates
    UPDATE users u
    SET 
        total_bonuses_earned = u.total_bonuses_earned + sub.total_bonus,
        updated_at = CURRENT_TIMESTAMP
    FROM (
        SELECT user_id, SUM(amount) AS total_bonus
        FROM bonuses
        WHERE bonus_type = 'team_bonus'
          AND calculation_date = p_calculation_date
        GROUP BY user_id
    ) sub
    WHERE u.id = sub.user_id;

    RAISE NOTICE 'Team Bonus Distribution Completed for %', p_calculation_date;
END;
$$;

-- ============================================================================
-- 14. HELPER VIEWS FOR DASHBOARDS & AUDITING
-- ============================================================================

-- View: User Downline Performance & Tree Depth Metrics
CREATE OR REPLACE VIEW v_user_network_summary AS
SELECT 
    u.id AS user_id,
    u.username,
    u.referral_code,
    u.tree_depth,
    lt.name AS tier_name,
    lt.daily_roi_rate,
    u.active_direct_referrals_count,
    u.total_indirect_downline_count,
    u.active_investment_amount,
    u.total_direct_volume,
    u.total_team_volume,
    w.main_balance,
    w.roi_balance,
    w.bonus_balance,
    w.total_withdrawable_balance,
    u.status
FROM users u
JOIN level_tiers lt ON lt.tier_id = u.current_tier_id
JOIN wallets w ON w.user_id = u.id;

-- View: Admin Pending Approval Queue for Deposits & Withdrawals
CREATE OR REPLACE VIEW v_pending_transactions_queue AS
SELECT 
    'deposit' AS transaction_type,
    d.id AS transaction_id,
    d.user_id,
    u.username,
    d.amount,
    0.00000000 AS fee,
    d.amount AS net_amount,
    d.network,
    d.deposit_address AS destination_or_source_address,
    d.tx_hash,
    d.status::TEXT AS status,
    d.created_at
FROM deposits d
JOIN users u ON u.id = d.user_id
WHERE d.status = 'pending'

UNION ALL

SELECT 
    'withdrawal' AS transaction_type,
    w.id AS transaction_id,
    w.user_id,
    u.username,
    w.gross_amount AS amount,
    w.fee_deducted AS fee,
    w.net_amount,
    w.network,
    w.wallet_address AS destination_or_source_address,
    w.tx_hash,
    w.status::TEXT AS status,
    w.created_at
FROM withdrawals w
JOIN users u ON u.id = w.user_id
WHERE w.status = 'pending'
ORDER BY created_at ASC;
