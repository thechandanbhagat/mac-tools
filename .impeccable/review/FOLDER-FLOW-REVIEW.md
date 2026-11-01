# Storage Map folder flow review

## Disposition

**ship** at the reviewed source and captured-flow scope. No material issue remains in this bounded review. The builder also confirmed the final optimized build and strict signature verification.

## Evidence

- Read `AGENTS.md`, the existing native design contract, `StorageMapModel.swift`, `StorageMapView.swift`, `StorageMapChart.swift`, the scanner, and model/scanner tests.
- Inspected all three 1120 × 790 dark-mode captures: `folder-flow-auto-scan.png`, `folder-flow-manual-scan.png`, and `folder-flow-back.png`. Each contains the expected complete native window and current location.
- Builder's demo-only interaction record: add a 1 MB file after the root snapshot; enter Projects and obtain 5.8 MB / 3 items automatically. Add a further 2 MB file; Rescan yields 7.8 MB / 4 items in Projects. Command-[ returns to a fresh root result of 16.9 MB with Projects at 7.8 MB. Captures show the resulting new files and totals.
- Model implementer reports 45/45 tests passing, including ten model tests covering real filesystem changes, fresh subtree limits, independent hard-link attribution, breadcrumb targets, cancellation, failed navigation recovery, late callbacks, hidden-option changes, and demo scope.
- After the final rebuild, the builder confirmed native accessibility labels “Scan options” and “Scan sample files (Command-R)”, plus a Projects-specific Rescan tooltip. Both demo preview runs quit normally, removed their fixtures, and the temporary preview bundle was removed.

## Findings

- Opening a child, Back, and ancestor navigation each start a scan rooted at that location. Rescan uses the displayed folder. Ancestor breadcrumb metadata is separate from the current result, preventing mixed-scope totals.
- Generation guards reject superseded progress/results. Cancelling or failing a manual refresh preserves its previous same-folder snapshot and timestamp; entering a different folder clears those values while keeping a usable Back route.
- Review corrections are resolved in source: hidden-option changes discard incompatible snapshots before scanning; long breadcrumb trails scroll to the current item; the current breadcrumb is readable semibold text; the initial `/` breadcrumb has a path fallback.
- The captures preserve the native visual system and show no clipped controls, overlapping content, or redundant folder headings. The chart and list remain primary. Scope, help, Finder reveal, and Rescan are easy to locate.

## Contract assessment

The requested automatic subfolder measurement and manual current-folder scan are implemented. The interface follows project memory: one compact location row, concise data/action labels, contextual help for secondary explanations, and visible partial/error/cancel states. No extra explanatory panel or repeated root label was added. Symlink and cloud exclusions remain enforced by the unchanged scanner.

## Required corrections

None from this review. The supplied captures precede two nonvisual label fixes, which were confirmed in native accessibility after the final rebuild. Light mode, the minimum window size, and a rendered long breadcrumb trail were not recaptured in this pass; their shared styling and breadcrumb behavior were reviewed in source.
