# Steering: Native (NDK) Direct Replacement

> **File-storage rules have moved.** Native file I/O discovery,
> classification, C API replacement tables, include paths, path semantics,
> and validator routing for the `secureFileStorage` domain are now in
> **`40-secure-file-storage.md` §1b, §2b, §8**.
>
> This file retains only the **networking** scope and general classification
> guidance that applies to both domains.

This steering covers the **networking** scope for app code built via the
Android NDK (`externalNativeBuild` CMake or ndk-build). It complements:

- `40-secure-file-storage.md` — canonical `secureFileStorage` guide
  (including native file I/O replacement).
- `14-api-provenance-and-replacement-catalog.md` — the canonical
  C / POSIX → Dynamics C API mapping tables.
- `30-secure-networking.md` — the `secureNetworking` domain for
  Java/Kotlin networking.
- `13-unsupported-feature-detection-matrix.md` — prebuilt `.so` and
  out-of-tree native source handling.

It does **not** introduce a new report-schema domain. Native findings
must be projected into the existing `secureNetworking` domain evidence
and `manualTodos`.

---

## Discovery (mandatory — networking scope)

For every in-scope module from `module-map.json`, check native source
(`.c`, `.cpp`, `.h`, `.hpp` under `src/main/`) for BSD socket and
name-resolution calls: `socket`, `connect`, `accept`, `bind`, `listen`,
`send`, `recv`, `sendto`, `recvfrom`, `shutdown`, `getaddrinfo`, etc.

For file-storage native I/O discovery, see `40-secure-file-storage.md` §1b.

---

## Classification

Each native artifact falls into exactly one of three buckets:

1. **App-controlled native source** — direct replacement applies.
2. **Prebuilt native libraries** — high-priority `manualTodo` and
   `unsupportedFeatures` entry. Default this `manualTodo` to
   `blocking: false` (developer-owned residual risk) unless concrete
   evidence proves overlap with a non-waivable storage/networking rule.
3. **Vendored third-party source** — treat like prebuilt unless the
   developer patches and maintains it.

See `40-secure-file-storage.md` §2b for full classification rules.

---

## Direct-replacement rules (networking)

Use the canonical tables in
`14-api-provenance-and-replacement-catalog.md`. Summary:

- BSD socket calls (`socket`, `connect`, `accept`, `bind`, `listen`,
  `send`, `recv`, `sendto`, `recvfrom`, `shutdown`, `getaddrinfo`,
  …) → `GD_*` equivalents (use only those listed in the catalog or
  verified in installed `sdk/libs/handheld/libs/gd/inc/` headers).

**Where to verify symbols:**

| Header (installed) | POSIX family |
|---|---|
| `GD_C_sys_socket.h`, `GD_C_netdb.h` | sockets and DNS — `GD_socket`, `GD_getaddrinfo`, … |

If a POSIX call has no documented `GD_*` equivalent, **do not invent
one** — record a manual TODO.

---

## Validator routing

`validate.sh` flags native socket / name-resolution calls as
`fail_or_defer "secureNetworking"` violations. The deferral and
non-waivable rules apply consistently.

Prebuilt `.so` files produce `check_warn` — they do not auto-close any
domain.

---

## What this steering does **not** cover

- File-storage native I/O — see `40-secure-file-storage.md` §8.
- Optional/migration-relevant features (Push Channel, Launcher,
  Analytics, SSO, Play Integrity, Background Authorize,
  certificates/Kerberos).
- WebView — `com.blackberry.bbwebview.BBWebView` remains the only
  WebView migration target.
