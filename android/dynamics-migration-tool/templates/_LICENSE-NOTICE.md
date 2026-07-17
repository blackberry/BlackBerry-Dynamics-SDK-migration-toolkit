# License Notice — Sample-Derived Templates

Templates in this directory marked `provenance: sample-derived` in
`_manifest.json` are derived from the
[BlackBerry Dynamics Android Samples](https://github.com/blackberry/BlackBerry-Dynamics-Android-Samples)
repository, which is released under the Apache License, Version 2.0.

> Copyright (c) BlackBerry Limited.
> Licensed under the Apache License, Version 2.0 (the "License");
> you may not use this file except in compliance with the License.
> You may obtain a copy of the License at
> http://www.apache.org/licenses/LICENSE-2.0

Templates marked `provenance: kit-authored` were written independently
by the migration-kit team and are also released under Apache-2.0.

Editorial changes applied to all sample-derived files:
- Package declarations replaced with `__APP_PACKAGE__` placeholder.
- Internal BlackBerry Maven repository URL replaced with the public
  `https://software.download.blackberry.com/repository/maven` URL.
- Fragment/Activity class-level scaffolding simplified to focus on the
  migration-relevant call sites.
- Comments added to annotate migration-critical lines.
