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

2. **Add HMAC verification function**:
   ```python
   import hmac
   import hashlib
   import os
   from fastapi import HTTPException, status
   
   def verify_paperclip_signature(
       body: bytes,
       signature_header: str | None
   ) -> bool:
       """Verify Paperclip webhook HMAC-SHA256 signature."""
       secret = os.getenv("PAPERCLIP_WEBHOOK_SECRET")
       if not secret:
           raise HTTPException(
               status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
               detail="Webhook secret not configured"
           )
       
       if not signature_header:
           return False
       
       # Parse header: "sha256=<hex>"
       if not signature_header.startswith("sha256="):
           return False
       
       expected_sig = signature_header[7:]  # Remove "sha256=" prefix
       computed_sig = hmac.new(
           secret.encode(),
           body,
           hashlib.sha256
       ).hexdigest()
       
       # Use constant-time comparison to prevent timing attacks
       return hmac.compare_digest(computed_sig, expected_sig)
   ```

3. **Modify endpoint** (in `backend/routes/adversarial_feedback.py`):
   ```python
   from fastapi import Request
   
   @router.post("/api/adversarial-feedback/paperclip/webhook")
   async def paperclip_webhook(request: Request):
       # Read raw body for signature verification
       body = await request.body()
       
       # Get signature header
       signature = request.headers.get("X-Paperclip-Signature")
       
       # Verify signature (403 if missing or invalid)
       if not verify_paperclip_signature(body, signature):
           raise HTTPException(
               status_code=403,
               detail="Invalid or missing webhook signature"
           )
       
       # Parse JSON and process webhook
       data = json.loads(body)
       # ... rest of webhook handling logic ...
   ```
   - Signature verification happens BEFORE JWT validation
   - Returns 403 regardless of JWT validity if signature fails
   - No logging of signature or secret values

4. **Write tests** (in `backend/tests/test_adversarial_feedback_api.py`):
   ```python
   import hmac
   import hashlib
   import json
   
   def test_webhook_rejects_missing_signature():
       """Test 403 when X-Paperclip-Signature header is missing."""
       response = client.post(
           "/api/adversarial-feedback/paperclip/webhook",
           json={"test": "data"},
           headers={}  # No signature header
       )
       assert response.status_code == 403
   
   def test_webhook_rejects_invalid_signature():
       """Test 403 when signature is invalid."""
       response = client.post(
           "/api/adversarial-feedback/paperclip/webhook",
           json={"test": "data"},
           headers={"X-Paperclip-Signature": "sha256=invalid"}
       )
       assert response.status_code == 403
   
   def test_webhook_accepts_valid_signature():
       """Test success with valid HMAC signature."""
       secret = "test_secret"
       body = json.dumps({"test": "data"}).encode()
       sig = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
       
       response = client.post(
           "/api/adversarial-feedback/paperclip/webhook",
           data=body,
           headers={
               "X-Paperclip-Signature": f"sha256={sig}",
               "Content-Type": "application/json"
           }
       )
       assert response.status_code == 200  # Or whatever success code
   ```
   - Ensure tests set PAPERCLIP_WEBHOOK_SECRET env var
   - Test both rejection and acceptance cases
   - Use monkeypatch or fixture to set secret for tests

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
