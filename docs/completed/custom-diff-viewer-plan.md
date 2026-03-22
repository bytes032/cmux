# Custom Diff Viewer V1

## Completion Status

- [x] Phase 1 - Structured local renderer bridge
- [x] Phase 2 - Remove legacy diff renderer dependency
- [x] Plan closure

## Summary

Replace the current `@pierre/diffs` / `PierreDiffsSwift` hybrid with a bundled custom web diff renderer hosted in `WKWebView`.

V1 should ship as:

- unified view only
- selected-file-first rendering
- syntax highlighting via a Shiki web worker
- word diffs enabled in v1
- no preview modes
- no persisted viewer preferences yet

This keeps the existing Swift-side repo/commit/file-tree state model, but replaces the rendering layer with something cmux owns end-to-end.

## Implementation Changes

### Renderer architecture

- Add a small dedicated bundled web asset for the diff body instead of loading remote JS from `esm.sh`.
- Keep `WKWebView` as the host boundary in the app, but make the HTML/JS local bundle resources loaded from the app.
- The web renderer should own:
  - unified diff layout
  - syntax-highlighted code lines
  - intra-line word diff decorations
  - loading/empty/error states
- Use a Shiki-backed web worker for tokenization/highlighting so large files do not block the main UI thread.

### Swift-side responsibilities

- Keep `DiffPanel` as the source of truth for:
  - current scope: working tree vs selected commit
  - file list / file tree
  - selected file
  - patch and file-level diff data
  - loading state and caches
- Change the renderer contract so Swift sends structured per-file diff payloads, not just a raw patch blob intended for a third-party parser.
- Introduce one stable payload shape for the webview, roughly:
  - file identity/path
  - old/new path
  - hunks
  - per-line kind and line numbers
  - raw text for old/new side where needed for word diff
  - language hint derived from file extension/path
  - theme mode
- Default open behavior should select the first changed file and render only that file until the user chooses another one.

### UI behavior

- Keep the current files tree and commits list shell in SwiftUI.
- The diff body should not blank out during transitions; keep the previous render mounted and show an overlay until the next file render is ready.
- `All Files` should not be part of v1's primary rendering path. If kept at all, treat it as secondary/fallback later, not part of the initial custom renderer scope.
- Split view support is explicitly deferred until after unified mode is stable.

### Performance approach

- Optimize for file-at-a-time rendering, not whole-commit rendering.
- Precompute lightweight file metadata in Swift and defer expensive highlighting/rendering to the worker.
- Reuse the same `WKWebView` instance and apply delta updates for selection/theme changes.
- Add timing markers around:
  - Swift diff payload creation
  - webview message handoff
  - worker highlight time
  - final DOM paint
- Set explicit large-file safeguards:
  - disable word diff above a size threshold
  - disable or simplify syntax highlighting above a higher threshold
  - fall back to plain colored diff lines for pathological files

## Public Interfaces and Types

- Replace the current patch-string-centric renderer bridge with a structured render payload type shared by `DiffPanel` and `DiffPanelView`.
- Add a lightweight line/hunk model on the Swift side so the app is no longer coupled to `parsePatchFiles`.
- Remove the app's dependency on remote `@pierre/diffs` loading for the main diff body.
- Keep current external user-facing behavior unchanged outside the diff panel: same pane-local diff entry point, same single persistent diff panel behavior.

## Test Plan

- Build-only verification through tagged reload.
- Manual acceptance checks in the dev app:
  - open working tree diff and render first file immediately
  - switch between files without body flicker or stale lines
  - switch between working tree and commits with a real loading overlay
  - open large commits and confirm thresholds degrade gracefully instead of freezing
  - verify syntax highlighting appears on common code files
  - verify word diffs appear for small/normal edits and are suppressed for large files
  - verify dark/light theme switching updates without recreating the webview
- Add runtime-focused unit coverage where practical for:
  - diff payload construction
  - file/language detection
  - threshold decisions for word diff / highlighting fallback

## Assumptions

- `WKWebView` remains the renderer host for v1.
- Unified view is the only shipped layout in v1.
- The first changed file becomes the default selected file on open.
- Viewer preferences are not persisted in v1.
- Rich previews, annotations, comments, and patch-apply actions are out of scope for this phase.
