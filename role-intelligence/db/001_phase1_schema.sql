-- =============================================================================
-- Role Intelligence Platform — Phase 1 Schema
-- Database: Neon PostgreSQL
-- =============================================================================

-- Enable uuid generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- TABLES
-- =============================================================================

-- companies
-- Supports a tree hierarchy via parent_id. Null parent_id = top of group.
CREATE TABLE IF NOT EXISTS companies (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    parent_id   UUID REFERENCES companies(id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- permission_levels
-- Each company has its own set of levels (1–5 by default, customisable).
CREATE TABLE IF NOT EXISTS permission_levels (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id       UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    level_number     INTEGER NOT NULL CHECK (level_number BETWEEN 1 AND 99),
    level_name       TEXT NOT NULL,
    can_edit_levels  INTEGER[] NOT NULL DEFAULT '{}',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (company_id, level_number)
);

-- users
CREATE TABLE IF NOT EXISTS users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id          UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    full_name           TEXT NOT NULL,
    username            TEXT NOT NULL UNIQUE,
    password_hash       TEXT NOT NULL,  -- bcrypt hash, never plaintext
    permission_level_id UUID NOT NULL REFERENCES permission_levels(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- roles
CREATE TABLE IF NOT EXISTS roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id  UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    created_by  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- role_dimensions
-- Each of the 11 dimensions of a Role Charter, with per-dimension visibility.
CREATE TABLE IF NOT EXISTS role_dimensions (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id            UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    dimension_name     TEXT NOT NULL,
    content            TEXT NOT NULL DEFAULT '',
    visible_from_level INTEGER NOT NULL CHECK (visible_from_level BETWEEN 1 AND 99),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (role_id, dimension_name)
);

-- interviews
CREATE TABLE IF NOT EXISTS interviews (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id        UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    interviewer_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    mode           TEXT NOT NULL CHECK (mode IN ('desired', 'actual')),
    status         TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress', 'completed')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at   TIMESTAMPTZ
);

-- interview_messages
CREATE TABLE IF NOT EXISTS interview_messages (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    interview_id   UUID NOT NULL REFERENCES interviews(id) ON DELETE CASCADE,
    role           TEXT NOT NULL CHECK (role IN ('agent', 'user')),
    content        TEXT NOT NULL,
    dimension_name TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- conversation_history
CREATE TABLE IF NOT EXISTS conversation_history (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role         TEXT NOT NULL CHECK (role IN ('agent', 'user')),
    content      TEXT NOT NULL,
    context_type TEXT NOT NULL CHECK (context_type IN ('interview', 'query')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_companies_parent        ON companies(parent_id);
CREATE INDEX IF NOT EXISTS idx_permission_levels_co    ON permission_levels(company_id);
CREATE INDEX IF NOT EXISTS idx_users_company           ON users(company_id);
CREATE INDEX IF NOT EXISTS idx_users_permission        ON users(permission_level_id);
CREATE INDEX IF NOT EXISTS idx_roles_company           ON roles(company_id);
CREATE INDEX IF NOT EXISTS idx_role_dimensions_role    ON role_dimensions(role_id);
CREATE INDEX IF NOT EXISTS idx_role_dimensions_level   ON role_dimensions(visible_from_level);
CREATE INDEX IF NOT EXISTS idx_interviews_role         ON interviews(role_id);
CREATE INDEX IF NOT EXISTS idx_interviews_interviewer  ON interviews(interviewer_id);
CREATE INDEX IF NOT EXISTS idx_interview_msgs_intview  ON interview_messages(interview_id);
CREATE INDEX IF NOT EXISTS idx_conv_history_user       ON conversation_history(user_id);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
-- The agent connects as the app service role (neondb_owner / a dedicated app user).
-- Before executing any query the agent sets two session-local variables:
--   SET LOCAL app.current_user_id      = '<uuid>';
--   SET LOCAL app.current_level_number = '<integer>';
-- All RLS policies read these variables to enforce access.
-- IMPORTANT: use these inside a BEGIN/COMMIT block so SET LOCAL is honoured
-- even through the connection pooler.

ALTER TABLE companies           ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_levels   ENABLE ROW LEVEL SECURITY;
ALTER TABLE users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles               ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_dimensions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE interviews          ENABLE ROW LEVEL SECURITY;
ALTER TABLE interview_messages  ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_history ENABLE ROW LEVEL SECURITY;

-- Helper: returns current user's UUID from session variable (NULL if not set)
CREATE OR REPLACE FUNCTION app_current_user_id() RETURNS UUID
    LANGUAGE sql STABLE AS $$
        SELECT NULLIF(current_setting('app.current_user_id', true), '')::UUID;
    $$;

-- Helper: returns current user's permission level number (99 = unauthenticated)
CREATE OR REPLACE FUNCTION app_current_level() RETURNS INTEGER
    LANGUAGE sql STABLE AS $$
        SELECT COALESCE(NULLIF(current_setting('app.current_level_number', true), '')::INTEGER, 99);
    $$;

-- Helper: returns the company_id of the current user
CREATE OR REPLACE FUNCTION app_current_company_id() RETURNS UUID
    LANGUAGE sql STABLE AS $$
        SELECT company_id FROM users WHERE id = app_current_user_id();
    $$;

-- Helper: true if company c is the user's company or a descendant of it
CREATE OR REPLACE FUNCTION company_is_visible(c_id UUID) RETURNS BOOLEAN
    LANGUAGE sql STABLE AS $$
        WITH RECURSIVE tree AS (
            SELECT id FROM companies WHERE id = app_current_company_id()
            UNION ALL
            SELECT c.id FROM companies c JOIN tree t ON c.parent_id = t.id
        )
        SELECT EXISTS (SELECT 1 FROM tree WHERE id = c_id);
    $$;

-- --- companies ---
-- Users can see their own company and all companies below them in the tree.
CREATE POLICY companies_select ON companies FOR SELECT
    USING (company_is_visible(id));

CREATE POLICY companies_insert ON companies FOR INSERT
    WITH CHECK (app_current_level() <= 2);   -- Owner / CEO can create companies

CREATE POLICY companies_update ON companies FOR UPDATE
    USING (app_current_level() = 1);         -- Only Owner can update companies

CREATE POLICY companies_delete ON companies FOR DELETE
    USING (app_current_level() = 1);

-- --- permission_levels ---
CREATE POLICY perm_levels_select ON permission_levels FOR SELECT
    USING (company_is_visible(company_id));

CREATE POLICY perm_levels_insert ON permission_levels FOR INSERT
    WITH CHECK (
        company_is_visible(company_id)
        AND app_current_level() <= 3
    );

CREATE POLICY perm_levels_update ON permission_levels FOR UPDATE
    USING (
        company_is_visible(company_id)
        AND app_current_level() < level_number   -- can only edit levels below your own
    );

CREATE POLICY perm_levels_delete ON permission_levels FOR DELETE
    USING (
        company_is_visible(company_id)
        AND app_current_level() < level_number
    );

-- --- users ---
CREATE POLICY users_select ON users FOR SELECT
    USING (
        id = app_current_user_id()   -- always see yourself
        OR company_is_visible(company_id)
    );

CREATE POLICY users_insert ON users FOR INSERT
    WITH CHECK (
        company_is_visible(company_id)
        AND app_current_level() <= 3
    );

CREATE POLICY users_update ON users FOR UPDATE
    USING (
        id = app_current_user_id()   -- can always update yourself
        OR (
            company_is_visible(company_id)
            AND app_current_level() <= 3
        )
    );

CREATE POLICY users_delete ON users FOR DELETE
    USING (
        company_is_visible(company_id)
        AND app_current_level() <= 2
    );

-- --- roles ---
CREATE POLICY roles_select ON roles FOR SELECT
    USING (company_is_visible(company_id));

CREATE POLICY roles_insert ON roles FOR INSERT
    WITH CHECK (
        company_is_visible(company_id)
        AND app_current_level() <= 3
    );

CREATE POLICY roles_update ON roles FOR UPDATE
    USING (
        company_is_visible(company_id)
        AND app_current_level() <= 3
    );

CREATE POLICY roles_delete ON roles FOR DELETE
    USING (
        company_is_visible(company_id)
        AND app_current_level() <= 2
    );

-- --- role_dimensions ---
-- visible_from_level = 3 means level 3 and below (1, 2, 3) can see it.
-- Lower number = more senior = more access.
CREATE POLICY role_dims_select ON role_dimensions FOR SELECT
    USING (
        app_current_level() <= visible_from_level
        AND EXISTS (
            SELECT 1 FROM roles r WHERE r.id = role_id
            AND company_is_visible(r.company_id)
        )
    );

CREATE POLICY role_dims_insert ON role_dimensions FOR INSERT
    WITH CHECK (
        app_current_level() <= 3
        AND EXISTS (
            SELECT 1 FROM roles r WHERE r.id = role_id
            AND company_is_visible(r.company_id)
        )
    );

CREATE POLICY role_dims_update ON role_dimensions FOR UPDATE
    USING (
        app_current_level() <= 3
        AND EXISTS (
            SELECT 1 FROM roles r WHERE r.id = role_id
            AND company_is_visible(r.company_id)
        )
    );

CREATE POLICY role_dims_delete ON role_dimensions FOR DELETE
    USING (
        app_current_level() <= 2
        AND EXISTS (
            SELECT 1 FROM roles r WHERE r.id = role_id
            AND company_is_visible(r.company_id)
        )
    );

-- --- interviews ---
CREATE POLICY interviews_select ON interviews FOR SELECT
    USING (
        interviewer_id = app_current_user_id()
        OR (
            app_current_level() <= 3
            AND EXISTS (
                SELECT 1 FROM roles r WHERE r.id = role_id
                AND company_is_visible(r.company_id)
            )
        )
    );

CREATE POLICY interviews_insert ON interviews FOR INSERT
    WITH CHECK (
        interviewer_id = app_current_user_id()
        AND app_current_level() <= 3
    );

CREATE POLICY interviews_update ON interviews FOR UPDATE
    USING (
        interviewer_id = app_current_user_id()
        OR app_current_level() <= 2
    );

-- --- interview_messages ---
CREATE POLICY intview_msgs_select ON interview_messages FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM interviews i WHERE i.id = interview_id
            AND (
                i.interviewer_id = app_current_user_id()
                OR app_current_level() <= 2
            )
        )
    );

CREATE POLICY intview_msgs_insert ON interview_messages FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM interviews i WHERE i.id = interview_id
            AND i.interviewer_id = app_current_user_id()
        )
    );

-- --- conversation_history ---
CREATE POLICY conv_history_select ON conversation_history FOR SELECT
    USING (
        user_id = app_current_user_id()
        OR app_current_level() <= 2
    );

CREATE POLICY conv_history_insert ON conversation_history FOR INSERT
    WITH CHECK (user_id = app_current_user_id());

-- =============================================================================
-- TRIGGER: keep roles.updated_at current
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER roles_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- SEED: default permission levels for first company (run separately after
-- inserting your first company row — replace the UUID below).
-- =============================================================================
-- INSERT INTO permission_levels (company_id, level_number, level_name, can_edit_levels)
-- VALUES
--   ('<company_uuid>', 1, 'Owner / Board',   '{1,2,3,4,5}'),
--   ('<company_uuid>', 2, 'CEO',              '{3,4,5}'),
--   ('<company_uuid>', 3, 'VPs / C-Level',    '{4,5}'),
--   ('<company_uuid>', 4, 'Middle Managers',  '{}'),
--   ('<company_uuid>', 5, 'Employees',        '{}');
