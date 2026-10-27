---
id: zig-c-ffi-static-link
title: Statically link libghostty Zig engine
category: decision
status: active
created: "2026-08-21T06:38:37"
updated: "2026-10-28T03:54:17"
---

<!-- compiled_truth -->
Precompiled Zig libghostty into static archive `libghostty.a` and wrapped with strict Swift types for maximum execution speed.


## Timeline

- time: 2026-08-21T06:38:37
  kind: decision
  summary: "Created this page: Statically link libghostty Zig engine"
  source: git log
  affects: [zig-c-ffi-static-link]

- time: 2026-08-21T06:38:38
  kind: decision
  summary: Statically linked Zig core via C-FFI.
  source: git log
  affects: [zig-c-ffi-static-link]

- time: 2026-10-28T03:14:41
  kind: decision
  summary: "Upgraded to Ghostty v1.4.0 (Zig 0.17.0) in MactermKit v1.0.28: patched C-ABI to bridge OSC 7501 Program Status Protocol end-to-end (query reply, GHOSTTY_ACTION_PROGRAM_STATUS, RIS clear), updated clipboard callbacks for binary-safe multi-MIME OSC 5522, and exposed foregroundProcessID, ttyName, pasteText, setOccluded, and setColorScheme."
  affects: [zig-c-ffi-static-link]

- time: 2026-10-28T03:40:27
  kind: note
  summary: Fix Swift 6 strict concurrency pasteboard check in v1.0.30 by replacing nonisolated canReadObject with availableType
  affects: [zig-c-ffi-static-link]

- time: 2026-10-28T03:54:17
  kind: note
  summary: "Use string(forType:) exclusively for pasteboard type checks in v1.0.31 to eliminate region-based isolation data-race diagnostics"
  affects: [zig-c-ffi-static-link]
