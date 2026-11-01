# Storage Map Trash review

## Disposition

**ship** at the reviewed source, test, and captured-flow scope. No material issue remains in this bounded review. The builder reports a successful release build and strict signature verification.

## Evidence

- Read `AGENTS.md`, the existing Storage Map direction contract, scanner snapshots, `StorageMapTrash.swift`, model integration, row and chart context menus, confirmation view, and backend/model tests.
- Inspected the 1120 × 790 dark-mode `map-trash-menu.png` and 470 × 259 `map-trash-confirmation.png` captures. The menu belongs to the Preview.mov tile; its confirmation identifies the same file, full sample path, and 3 MB size on disk.
- Builder's demo-only native interaction record: a folder menu had no Trash action; the Preview.mov tile opened its 3 MB confirmation and Return dismissed it; the Assets.zip row opened its 1.2 MB confirmation and Escape dismissed it. Move to Trash was disabled in demo. Native accessibility exposed the file action.
- Builder reports 74/74 tests passing, including 21 backend Trash tests and eight model-flow tests. These exercise changed files, replaced paths, packages, cloud exclusions, hidden files, hard links, confirmation cancellation, busy-state guards, pending-request invalidation, same-folder refresh, refresh failure, and demo protection.
- The busy hidden-items setter was corrected to guard a computed property before mutating its published backing value, avoiding recursive rollback while preserving SwiftUI updates.
- The preview quit normally and removed its own sample files; its temporary app bundle was removed.

## Findings

- The new command remains in context menus and accessibility actions on individual file rows and tiles. Folders, packages, the current root, and the aggregate Other items tile do not acquire a Trash command. No persistent button or explanatory panel was added.
- Confirmation presents the file name, path, allocated size, and restore consequence without crowding the sheet. The captured Cancel button is the default; Return and Escape cancel. Moving requires the explicit destructive action and is disabled in demo.
- The service binds the request to a direct child of the current scan and checks scan-recorded identity and metadata before confirmation and again before native Trash. Symbolic-link paths, changed files/folders, package locations, and cloud locations are rejected. Failure never falls back to permanent deletion.
- Busy-state and generation guards prevent conflicting actions and stale preflight results. A successful move clears the old result before rescanning the current folder, so a failed refresh cannot show the moved file as a current result. Errors distinguish a failed move from a failed scan.
- Both supplied captures preserve the established native surfaces, typography, spacing, and teal accent. No clipped controls, overlapping content, or unnecessary permanent labels are visible.

## Contract assessment

The requested right-click action with confirmation is implemented while preserving the clean Storage Map layout. Secondary discovery remains in contextual help, and essential identity, consequence, progress, and failure information appears only where it is needed. Scanner behavior remains metadata-only; Trash is a separate explicit operation. The native path-based Trash API retains a final path-operation race after validation, which is acknowledged in source rather than presented as an atomic identity-bound operation.

## Required corrections

None from this review. Actual native Trash execution was not exercised: backend tests inject handlers, model success tests move disposable fixture files within their fixture directory, and the native UI preview disables moving. Light mode, minimum window size, and exceptionally long names/paths were not recaptured in this pass; wrapping, truncation, and full-path help were reviewed in source.
