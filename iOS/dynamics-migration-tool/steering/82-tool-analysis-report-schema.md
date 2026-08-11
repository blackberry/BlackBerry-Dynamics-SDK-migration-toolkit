# Steering: Toolkit Analysis Report Schema (Optional)

This optional artifact is for internal migration-tool improvement across
active release cycles.

Generate with:

```bash
bash ./dynamics-migration-tool/generate-tool-analysis-report.sh
```

Output path:

- `dynamics-migration-tool/output/tool-analysis-report.json`

## Schema

```json
{
  "schemaVersion": "1.0.0",
  "generatedAt": "ISO-8601",
  "toolkit": {
    "name": "dynamics-migration-tool",
    "platform": "iOS",
    "version": "string"
  },
  "inputArtifacts": {
    "migrationReportPresent": "boolean",
    "migrationReportPath": "string"
  },
  "runSummary": {
    "overallStatus": "complete|partial|failed|unknown",
    "validation": {
      "passed": "boolean",
      "failures": "number",
      "warnings": "number"
    },
    "counts": {
      "filesModified": "number",
      "apisReplaced": "number",
      "manualTodos": "number",
      "unsupportedFeatures": "number"
    }
  },
  "coverageSummary": {
    "migrated": "number",
    "partial": "number",
    "notApplicable": "number",
    "unknown": "number",
    "areas": [
      { "area": "string", "status": "string", "details": "string" }
    ]
  },
  "frictionSignals": {
    "highPriorityManualTodos": "number",
    "highRiskApiReplacements": "number",
    "failedCoverageAreas": ["string"]
  },
  "developerFeedback": {
    "overallExperience": "string",
    "biggestPainPoint": "string",
    "mostHelpfulStep": "string",
    "suggestions": "string"
  },
  "notes": ["string"]
}
```

## Privacy Rules

- Do not include source code snippets.
- Do not include credentials, entitlement IDs, or secrets.
- Keep this artifact metadata-only.
