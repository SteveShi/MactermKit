---
slug: architecture
title: System architecture
role: system architecture
updated: "2026-08-21T06:38:37"
---

# System architecture

```mermaid
graph TD
    App[Host App e.g. MacSSH] --> Surface[GhosttySurfaceView NSView]
    Surface --> Runtime[GhosttyRuntime Lifecycle Coordinator]
    Runtime --> FFI[C-FFI Bridge Headers]
    FFI --> ZigCore[libghostty.a Zig Static Library]
    Surface --> Metal[Metal GPU Rendering Context]
```
