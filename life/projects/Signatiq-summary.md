# Signatiq (EngageAI2)

**Type:** Project  
**Status:** Active development  
**Created:** 2026-04-15  
**Last Updated:** 2026-04-15  

## Overview
Signatiq (formerly EngageAI2) is an AI-powered sales execution platform with native multichannel capabilities. The platform is undergoing a monolith decomposition to improve scalability and maintainability.

## Key Components
- **Frontend:** Vite + React (frontend/)
- **Backend:** Python/FastAPI (backend/), virtualenv at ../.venv311
- **Database:** Drizzle ORM (drizzle.config.ts)
- **Shared types:** shared/
- **MCP integrations:** 117+ connectors (high-risk security surface)

## Current Status (as of 2026-04-15)
- **Phase 1:** Code Recovery - "In progress" (merging main services with security-phase2 additions)
- **Security Audit:** REVA-127/128/129 tasks completed (CSP/HSTS headers, token vault fixes, security hardening)
- **Milestone:** v2.0 Native Execution Platform

## Project Structure
- Working directory: `/Volumes/Seagate Portable Drive/Project Repos/EngageAI/Signatiq`
- Planning: `.planning/` directory with ROADMAP.md, REQUIREMENTS.md
- Development rules: CLAUDE.md
- Design system: `.impeccable.md`

## Development Rules
- Follow `/autonomous-coding-workflow` for phase execution
- Quality gates enforced during GSD execution
- Security-sensitive changes require `/security-best-practices` review
- Connector layer changes are high-risk, require `/review + /security-best-practices`

## Testing
- Backend: `cd backend && ../.venv311/bin/python -m pytest tests/ -q --tb=short`
- Frontend: `npm run check` (TypeScript)
- E2E: test-e2e.mjs, test-e2e.js

## Relevance to Code Worker B
- Primary project for implementation work
- Capabilities: "Build features for the Signatiq platform. Handle mid-complexity implementation tasks: API endpoints, database queries, UI components, integrations, and bug fixes."
- Recent work: Security audit fixes (REVA-127/128/129)
- Likely future work: Phase 1 code recovery, feature implementation, bug fixes