# REVA-335 Implementation Plan — Ready for Immediate Execution

## Quick Reference
- **Issue**: REVA-335 - Install Adversarial Feedback Loops into Paperclip (from REVA-168)
- **Type**: Feature extraction/installation from REVA-168
- **Assigned to**: Code Worker B (agent e5efa3c2-9c67-4617-8612-998ea68edfed)
- **Status**: TODO (blocked by code restoration + CEO approval)
- **Blockers**: 
  - REVA-358 (RevCortex code restoration)
  - CEO STOP command (scope violation incident resolution)

## Scope Understanding
**Context**: This ticket enables adversarial feedback loops as part of Paperclip's webhook system.

**REVA-168 (prerequisite)** - Code Quality Fixes:
- Fixed deprecated Pydantic v1 `.dict()` → v2 `model_dump()` calls
- Fixed test return value issues in feedback test suite
- Files touched: `backend/routes/adversarial_feedback.py`, `backend/models/adversarial_feedback.py`, `backend/tests/test_adversarial_feedback_api.py`
- Status: ✅ APPROVED

**REVA-335 (this work)** - Install into Paperclip:
- Enable adversarial feedback webhook endpoint: `/api/adversarial-feedback/paperclip/webhook`
- Connect feedback loop logic to Paperclip's agent system
- Add security (HMAC verification via REVA-356)
- Ensure integration with Paperclip's existing middleware/auth
- Add documentation for Paperclip users

## Expected Location
- Model definition: `backend/models/adversarial_feedback.py`
- Route handler: `backend/routes/adversarial_feedback.py`
- Tests: `backend/tests/test_adversarial_feedback_api.py`

## Implementation Strategy (Once Code + Approval Available)

### Phase 1: Review & Assess (1-2 hours)
1. Pull latest RevCortex code
2. Review REVA-168 fixes in:
   - `backend/models/adversarial_feedback.py` — feedback model structure
   - `backend/routes/adversarial_feedback.py` — existing endpoint implementations
   - `backend/tests/test_adversarial_feedback_api.py` — test patterns

### Phase 2: Enable Paperclip Webhook (2-3 hours)
1. **Ensure endpoint exists**: `/api/adversarial-feedback/paperclip/webhook`
   - Should accept POST requests with feedback data
   - Must integrate with Paperclip's agent session system
2. **Connect to feedback loop logic**:
   - Webhook receives adversarial feedback from Paperclip
   - Feedback triggers internal feedback loop processing
   - Results returned to Paperclip agent
3. **Add middleware requirements**:
   - HMAC signature verification (REVA-356)
   - JWT validation (if applicable)
   - Error handling and logging

### Phase 3: Integration & Testing (1-2 hours)
1. **Test webhook integration**:
   - Test endpoint receives and processes Paperclip feedback
   - Test feedback loops execute correctly
   - Test results are properly formatted for Paperclip
2. **Run full test suite**:
   - Unit tests for feedback models/logic
   - Integration tests for webhook
   - End-to-end tests with Paperclip scenario
3. **Verify security**:
   - HMAC signatures working (dependency on REVA-356)
   - No secrets logged
   - Proper error responses

### Phase 4: Documentation & Closure (30 min - 1 hour)
1. Update API documentation with Paperclip webhook endpoint
2. Document required environment variables
3. Add usage examples for Paperclip agents
4. Close issue with evidence and test results

## Key Components to Integrate
- **Adversarial Feedback Model**: Pydantic v2 model defining feedback structure
- **Feedback Routes**: FastAPI routes for handling feedback submissions
- **Feedback Logic**: Core algorithm for processing adversarial feedback
- **Test Suite**: Comprehensive tests ensuring functionality

## Code Patterns (from REVA-168)
- Pydantic v2: `model_dump()` for serialization
- FastAPI: Standard route decorators and response models
- Python backend structure: `backend/routes/`, `backend/models/`, `backend/tests/`

## Execution Order & Timeline

### Recommended Sequence
1. **REVA-356 first** (2-3 hours) — HMAC verification for webhook security
2. **REVA-335 second** (4-6 hours) — Integration depends on REVA-356 completion

### Total Estimated Time
- **REVA-356**: 2-3 hours (independent)
- **REVA-335**: 4-6 hours (can start once REVA-356 complete)
- **Total**: ~6-9 hours for both

### Execution Steps
1. Pull latest RevCortex with full code
2. Verify CEO STOP command is lifted (check REVA-326, REVA-333, REVA-334 status)
3. **Start REVA-356** (HMAC verification)
   - Implement signature verification
   - Write tests
   - Get to passing test state
   - Don't close yet — need it working for REVA-335
4. **Start REVA-335** (Adversarial feedback integration)
   - Review REVA-168 work
   - Integrate webhook with feedback loop logic
   - Add HMAC verification guard (from REVA-356)
   - Test integration
5. **Close both issues**
   - REVA-356: Close with HMAC test evidence
   - REVA-335: Close with integration test evidence

## Expected Deliverables
- ✅ Adversarial feedback loops installed in Paperclip
- ✅ All tests passing (unit + integration)
- ✅ Commit SHA documented
- ✅ Issue closed with evidence
- ✅ Documentation updated

## Dependencies
- REVA-168 work (completed and approved)
- REVA-358 (code restoration)
- CEO/Board approval to resume after scope violation incident
- REVA-326 parent ticket resolution

## Blocking Issues
1. **REVA-358**: RevCortex code not available (root blocker)
2. **CEO STOP command**: Scope violation incident requires resolution before proceeding
3. **REVA-326**: Parent ticket for scope violation handling
