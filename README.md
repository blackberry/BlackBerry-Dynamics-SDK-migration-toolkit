# BlackBerry Dynamics SDK Migration Toolkit

# Version 1.1.0.20

AI-assisted tooling that helps migrate native mobile apps to
[BlackBerry Dynamics](https://developers.blackberry.com/us/en/products/blackberry-dynamics.html).

Each platform ships as a self-contained toolkit: guided prompts, steering
guidance for AI coding agents, deterministic validators, templates, and a
migration report viewer. Use the platform folder that matches your app.

## Repository layout

```text
BlackBerry-Dynamics-SDK-migration-toolkit/
├── android/
│   └── dynamics-migration-tool/   # Android toolkit
└── iOS/
    └── dynamics-migration-tool/   # iOS toolkit
```

| Platform | Path | Status |
|----------|------|--------|
| Android | [`android/dynamics-migration-tool/`](android/dynamics-migration-tool/) | Available |
| iOS | [`iOS/dynamics-migration-tool/`](iOS/dynamics-migration-tool/) | Available |

Treat Android and iOS as separate products. Do not mix prompts, steering, or
validators across platforms.

## Getting started

1. Choose your platform folder above.
2. Open that toolkit’s `README.md` for prerequisites and quickstart.
3. Follow `MIGRATION_INSTRUCTIONS.md` for the full walkthrough.

**Android:**

```bash
cd android/dynamics-migration-tool
# See README.md, then:
# cp -r . /path/to/your-android-app/dynamics-migration-tool
# ./dynamics-migration-tool/tooling/migrate.sh --agent cursor
```

**iOS:**

```bash
cd iOS/dynamics-migration-tool
# See README.md, then:
# cp -r . /path/to/your-ios-app/dynamics-migration-tool
# ./dynamics-migration-tool/tooling/migrate.sh --agent cursor
```

## What each toolkit includes

- `prompts/` — ordered migration steps for an AI coding agent
- `steering/` — agent guidance and API replacement catalog
- `tooling/` — setup (`migrate.sh`), validation, and related scripts
- `templates/` — reference implementations for common Dynamics patterns
- `schemas/` — JSON schemas for migration artifacts and reports
- `migration-report-viewer.html` — HTML viewer for the generated report

Supported agents typically include Cursor, Kiro, and other AI coding agents.
Exact agent flags and prerequisites are documented per platform.

## Requirements (high level)

- A native Android or iOS app that already builds successfully
- BlackBerry Dynamics SDK credentials from your UEM administrator
  (`GDApplicationID` / `GDApplicationVersion`)
- Network access to obtain the Dynamics SDK for your platform
- An AI coding agent with permission to edit project files and run local
  shell commands

Platform-specific SDK versions, JDK/Xcode requirements, and tooling details
live in each toolkit’s README.

## Documentation

| Document | Where |
|----------|--------|
| Platform overview & quickstart | `*/dynamics-migration-tool/README.md` |
| Step-by-step migration walkthrough | `*/dynamics-migration-tool/MIGRATION_INSTRUCTIONS.md` |
| Release notes | `*/dynamics-migration-tool/CHANGELOG.md` |
| Toolkit version | `*/dynamics-migration-tool/VERSION` |

## License

Each platform toolkit is licensed under the Apache License, Version 2.0.
See `LICENSE` and `NOTICE` inside the corresponding
`dynamics-migration-tool/` directory.

Copyright (c) 2026 BlackBerry Limited.
