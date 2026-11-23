# CLAUDE.md — joetv-tvos-claude-opt (JoeTV tvOS)

This repository is an ISOLATED OPTIMIZATION COPY of `zjoenguyenz/joetv-tvos`.
It exists so Claude Code can optimize the app without touching the production repo.
The human leader (Wally, on behalf of the owner) reviews every result here before
anything is ported back to the original repository. Nothing here ships to the owner
directly.

## The app
- **JoeTV for Apple TV (tvOS)**, Swift / SwiftUI, unsigned IPA built by GitHub
  Actions (workflow `build-joetv.yml`). The owner signs and installs it himself
  (delete + reinstall each time, so anything the app needs must be baked into
  the build via Actions secrets in the ORIGINAL repo — this copy has NO secrets
  and must never receive real tokens).
- Baseline branch: `main`.
- tvOS focus is rendered by the OS itself. Never hand-draw focus rings/faces
  that fight the system treatment; read how tvOS/SwiftUI renders focus before
  touching any focus surface.
- The approved design drawings are the sole standard for appearance. An
  optimization must never change layout, colours, spacing or theme behaviour.

## Hard rules (owner's standing laws — no exceptions)
1. Work ONLY in this repository, and only on branches named `claude/opt-*`.
   Never push to `main` directly. Open a pull request into `main` inside THIS
   repo when a chunk is ready; the leader reviews the diff.
2. No design/spec changes, no data-model changes, nothing that changes what
   the viewer sees or how sources/plugins behave — unless the leader's prompt
   for that round explicitly authorizes it.
3. Optimization means: performance (poster/backdrop loading, list scrolling,
   player start), memory, code clarity, dead-code removal, build reliability —
   with **zero behaviour change** unless the prompt says otherwise. Every
   optimization PR must state what was measured before/after (method +
   numbers). Unmeasured "optimizations" are rejected.
4. Never fabricate APIs, methods, build flags or library names. Check the
   project's actual tvOS/Swift versions in the project files before assuming.
   If behaviour cannot be verified, say so in the PR.
5. Do not add secrets, tokens, debrid credentials or MediaFusion URLs anywhere.
   Do not edit `.github/workflows/*` unless the prompt explicitly asks for CI work.
6. Keep commits small and batched per topic. Do not reformat whole files for
   cosmetic reasons — it destroys diff reviewability.
7. The app must keep its built-in diagnostic-log export (LAN download + QR)
   working.

## Review gate
Code is not "done" when it compiles locally. Each PR description must include:
what changed, why, before/after measurements, risks, and what was NOT verified.
The leader runs the project's own Swift review team + CI before anything is
ported back.
