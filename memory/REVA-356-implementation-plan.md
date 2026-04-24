# REVA-356 Implementation Plan — Ready for Immediate Execution

## Quick Reference
- **Issue**: REVA-356 - Security: add HMAC/shared-secret verification to /paperclip/webhook endpoint
- **Assigned to**: Code Worker B (agent e5efa3c2-9c67-4617-8612-998ea68edfed)
- **Status**: IN_PROGRESS (blocked by REVA-358 — RevCortex code restoration)
- **Blocker**: REVA-358 (repo migration/code availability)

## Scope Requirements
1. Add HMAC-SHA256 signature verification to `/api/adversarial-feedback/paperclip/webhook`
2. Verify `X-Paperclip-Signature` header against shared secret from env
3. Return 403 on missing/invalid signature (even if JWT is valid)
4. Never hardcode or log the secret
5. Add tests for both reject-without-sig and accept-with-sig cases
6. Prove tests passing + commit SHA + doc update at closure

## Implementation Steps (Once Code Available)
1. **Locate endpoint**:
   - File: `backend/routes/adversarial_feedback.py` (likely)
   - Endpoint: `/api/adversarial-feedback/paperclip/webhook`

2. **Add HMAC verification middleware/guard**:
   ```python
   import hmac
   import hashlib
   from fastapi import HTTPException, Header
   
   # Get secret from environment
   secret = os.getenv("PAPERCLIP_WEBHOOK_SECRET")
   
   # Verify signature header
   # Expected format: X-Paperclip-Signature: sha256=<hex>
   ```

3. **Modify endpoint**:
   - Add signature verification before processing webhook
   - Reject with 403 if signature missing or invalid
   - Allow processing if signature valid

4. **Write tests**:
   - Test rejection without signature
   - Test rejection with invalid signature
   - Test acceptance with valid signature
   - Update test file: `backend/tests/test_adversarial_feedback_api.py` (likely)

5. **Verify**:
   - Run full test suite
   - Commit with clear message
   - Document changes in issue

## Code Patterns from REVA-168
- Pydantic v2 (use `model_dump()` not `.dict()`)
- FastAPI patterns for route definitions
- Test structure: separate unit and API tests
- All endpoints in `backend/routes/` directory
- Tests in `backend/tests/` directory with consistent naming

## Expected Files to Modify
- ✅ `backend/routes/adversarial_feedback.py` — Add HMAC guard
- ✅ `backend/tests/test_adversarial_feedback_api.py` — Add HMAC tests
- ✅ Possibly `backend/models/adversarial_feedback.py` — If new model needed for request/response

## Environment Variables
- Need to add/document: `PAPERCLIP_WEBHOOK_SECRET` (HMAC shared secret)
- Should be obtained from secure config, never hardcoded

## Execution Timeline Once Code Available
1. Pull latest RevCortex
2. Check STOP command status (review REVA-326, REVA-333, REVA-334)
3. If STOP lifted: Implement immediately (estimated 2-3 hours)
4. If STOP still active: Wait for explicit approval

## Verification Checklist
- [ ] HMAC verification working (tests passing)
- [ ] 403 returned for missing signature
- [ ] 403 returned for invalid signature
- [ ] Valid signature accepted
- [ ] Secret not logged or hardcoded
- [ ] All tests passing
- [ ] Commit SHA recorded
- [ ] Issue updated with evidence
- [ ] Closure comment posted with test results
