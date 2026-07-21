## Task: External Data Movement and DLP Closure

Goal: Close external data movement and DLP-sensitive surfaces so protected data
cannot leave the Dynamics container through unmanaged or unreviewed paths.

**Prerequisites**:
- Prompts 00-03b must be complete
- Prompt 00 must have external movement call-site inventory for `dlpPasteboard`

**Skip this prompt only if** the `dlpPasteboard` domain is truly
not-applicable with evidence.

Note: iOS DLP is enforced at pasteboard/system surfaces. `UITextField` and
`UITextView` do not require widget replacement.

---

## Steps

### 1. Inventory and classify all external surfaces

For each call site in the `dlpPasteboard` domain, classify:
- `surface` (share sheet, document picker, Files, iCloud, Photos, AirDrop, drag/drop, Quick Look, custom URL, universal link, pasteboard, third-party SDK, etc.)
- `movementDirection`:
  - unmanaged-to-managed
  - managed-to-unmanaged
  - managed-to-managed
  - metadata-only
  - unknown-or-bidirectional
- `sourceEndpoint` and `destinationEndpoint` (managed/unmanaged)
- `payloadKind` (file/data/metadata/mixed)
- data sensitivity

### 2. Inbound unmanaged-to-managed closure

For unmanaged inbound content:
- use approved picker/provider flow
- copy into secure storage as early as practical
- avoid unsafe persistent unmanaged staging
- validate/sanitize content as needed
- close temporary artifacts after import

Record `inboundSecureCopyStatus` per call site.

### 3. Outbound managed-to-unmanaged closure

For protected outbound content:
- default to `blocked` unless an approved managed destination exists
- do not silently preserve `UIActivityViewController` for sensitive export
- do not stage decrypted plaintext in unmanaged temporary files
- do not treat in-memory transfer as policy approval by itself
- require explicit evidence for approved exceptions

Record `outboundApprovalStatus` and `plaintextStagingStatus`.

### 4. Preserve verified pasteboard API contract

When native pasteboard access is required, use only:
`GDNativePasteboardAccess.performActionOnNativePasteboard:`

Never reintroduce `open()` or `close()`.

### 5. Remove residual app-level screenshot controls (if redundant)

If app-level screenshot prevention exists only for DLP:
- remove `UIScreen.isCaptured` observers
- remove screenshot-only blur overlays
- document UEM-managed policy ownership

### 6. Build and verify

Run `xcodebuild` and classify failures as pre-existing, migration-introduced,
or unrelated.

---

## Closure Ledger Update (Required)

Before recording Prompt 09 as `completed`, write dispositions for
`dlpPasteboard` using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "09" \
  --domain-id "dlpPasteboard" \
  --updates-file /tmp/dlp-updates.json
```

Do not edit `migration-plan-state.json` directly.

---

## Scoped Validation (Required)

Run prompt-scoped validation before recorder completion:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 09
```

---

## Output

- External surfaces classified by direction/sensitivity
- Inbound unmanaged content securely copied into container storage
- Outbound protected unmanaged egress closed or blocked with evidence
- Verified pasteboard contract preserved (`performActionOnNativePasteboard`)
- Ledger dispositions written for all applicable `dlpPasteboard` call sites
- Scoped validation result captured
