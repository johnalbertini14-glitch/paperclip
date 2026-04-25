---
name: REVA-495 OAuth Token Encryption Implementation
description: Critical security vulnerability - OAuth tokens and API keys stored in plaintext in MongoDB
type: project
---

## Vulnerability Summary
**CRITICAL**: OAuth connector tokens and API keys are stored in **plaintext** in the `user_integrations` MongoDB collection.

### Affected Credentials (24+ fields)
**OAuth Tokens (Access/Refresh):**
- `hubspot_access_token`, `hubspot_refresh_token`, `hubspot_client_secret`
- `salesforce_access_token`, `salesforce_refresh_token`, `salesforce_client_secret`
- `google_access_token`, `google_refresh_token`, `google_client_secret`
- `microsoft_access_token`, `microsoft_refresh_token`, `microsoft_client_secret`
- `gong_access_token`, `slack_bot_token`, `slack_app_token`
- `outreach_access_token`

**API Keys (Direct):**
- `hubspot_api_key`, `gong_api_key`, `outreach_api_key`
- `apollo_api_key`, `clearbit_api_key`, `crunchbase_api_key`
- `qualified_api_key`, `drift_api_key`

## Encryption Infrastructure Available
✅ `secret_box.py` exists with Fernet encryption (AES 128-bit)
✅ `encrypt_secret()` and `decrypt_secret()` functions available
✅ Key stored in `ENGAGEAI_SECRETBOX_KEY` environment variable

## Implementation Plan

### Phase 1: Code Changes (Non-Breaking)
1. Create credential field mapping in `connector_kernel.py`
2. Add `_encrypt_credentials()` and `_decrypt_credentials()` wrapper functions
3. Update all writes to `user_integrations` to encrypt sensitive fields before insert/update
4. Update all reads from `user_integrations` to decrypt sensitive fields after retrieval
5. Ensure backward compatibility: support both plaintext (legacy) and encrypted (new)

### Phase 2: Data Migration
1. Create migration script `migrate_encrypt_integrations.py` to:
   - Scan all `user_integrations` documents
   - Identify plaintext credentials
   - Encrypt them using `secret_box.encrypt_secret()`
   - Update documents with encrypted values
   - Add `_encrypted_at` timestamp for auditing

### Phase 3: Cutover & Verification
1. Test encryption/decryption on staging database
2. Run migration script on production
3. Verify all reads still work (auto-decryption)
4. Monitor logs for decryption errors
5. Document any legacy plaintext handling required

### Phase 4: Cleanup (Future)
1. Remove support for plaintext credentials after grace period
2. Add audit logging for credential access

## Key Files to Modify
- `/paperclip/repos/RevCortex/backend/core/secret_box.py` — add credential helpers
- `/paperclip/repos/RevCortex/backend/core/services/connector_kernel.py` — encryption at read/write
- `/paperclip/repos/RevCortex/backend/core/services/connector_action_runtime.py` — read decryption
- `/paperclip/repos/RevCortex/backend/core/services/*.py` — all services writing integrations_doc

## Testing Strategy
1. Unit: Test encrypt/decrypt functions
2. Integration: Verify connector operations work with encrypted credentials
3. Migration: Verify all existing documents encrypted without data loss
4. E2E: Test full connector workflows (sync, refresh, action execution)

## Audit & Compliance
- Log all credential access attempts
- Document credential storage location (encrypted at rest)
- Create audit trail for migration
- Prepare security report documenting fix
