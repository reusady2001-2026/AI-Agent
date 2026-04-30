# Role Intelligence Platform

A Claude Skill that conducts structured role interviews and answers role-related questions. All data lives in a Neon PostgreSQL database.

## Repo layout

```
role-intelligence/
  SKILL.md                   ← main Skill logic (Phase 2+)
  db/
    001_phase1_schema.sql    ← all tables, RLS, indexes
    run_migration.sh         ← run against Neon to apply schema
  references/
    dimensions.md
    frameworks.md
    realestate-context.md
    moti-strategy.md
    benchmarks/
      ceo.md  cfo.md  ...
.env.example                 ← copy to .env, fill in DATABASE_URL
.mcp.json                    ← Supabase/Neon MCP config (project-scoped)
```

## Database

- **Engine**: Neon PostgreSQL  
- **Connection**: set `DATABASE_URL` in `.env` (never commit)  
- **RLS**: enabled on all tables — agent must `SET LOCAL app.current_user_id` and `SET LOCAL app.current_level_number` inside a transaction before every query

## Running migrations

```bash
DATABASE_URL="postgresql://..." ./role-intelligence/db/run_migration.sh
```

## Branch

Active development branch: `claude/role-intelligence-platform-QXaes`

## Build phases

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ Done | Schema, RLS, indexes |
| 2 | Pending | Login + identity via Neon |
| 3 | Pending | Build mode — 11-dimension interview |
| 4 | Pending | Service mode — free questions |
| 5 | Pending | Memory — conversation history |
| 6 | Pending | Cross-company intelligence |
