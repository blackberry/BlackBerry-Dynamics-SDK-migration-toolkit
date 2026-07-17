# Steering: Third-Party Telemetry Scoping (Crashlytics / Sentry / Analytics)

Enterprise migrations must review telemetry SDKs that can exfiltrate sensitive metadata.

## Required actions

1. Inventory telemetry dependencies and runtime init points.
2. Ensure telemetry transport uses Dynamics-managed networking path where applicable.
3. Remove/disable sensitive breadcrumbs and PII fields.
4. Block logging of container paths, tokens, credentials, and enterprise payload content.
5. Document retained telemetry with security rationale and operational owner.
