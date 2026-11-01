# Storage Map
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: See where a chosen folder's storage goes, then drill into the largest branch.
OWN-WORLD: Inherit system type, adaptive AppKit surfaces, teal accent, SF Symbols, sidebar and fixed action footer. The treemap uses proportional measured data.
STORY: Choose a folder; scan metadata; compare the map and ordered list; opening a folder automatically scans that folder; move back via breadcrumbs with a fresh scan; manually rescan the current folder; reveal originals in Finder; optionally confirm a context-menu move of one ordinary file or folder to Trash.
FIRST VIEWPORT: Persistent utility sidebar, Storage map title, chosen folder and scan scope, native progress or proportional map, size-sorted child rows, footer scan/cancel action. Empty and partial results name their limits.
FORM: New native tool inside the established storage workbench. Existing direction inherited; no new visual-world seed.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Read-only metadata scans with no file-content reads. Moving an item is a separate, explicit context-menu action on ordinary file and folder rows and tiles, followed by a confirmation showing name, path, and allocated size. A folder confirmation visibly states that all contents, including hidden items, move with it. No persistent Trash buttons. Packages, the current root, and Other items have no Trash action. Use macOS Trash only; never empty it or fall back to permanent deletion. Recheck the scan snapshot and folder path before moving. For a folder, fully inspect all descendants, including hidden items, before confirmation and compare that manifest again before moving. Refuse unsupported, inaccessible, or over-limit subtrees. Reject detected changes, then refresh the current folder after success. Include hidden items is explicit and defaults on. Skip symbolic links, cloud content, and other volumes; show partial totals/permission errors. Aggregate app packages as non-drillable entries. Bound scans and support cancellation. Large lists scroll. Demo mode uses disposable samples only; confirmation can be previewed but moving items is disabled.

Keep one breadcrumb row for the current location, with compact options and a manual rescan action. Do not repeat the chosen root or current folder as extra headings. Preserve current-folder results while a manual refresh is running; never show another folder's snapshot under the new path. Back navigation must remain available during scanning.

The confirmation keeps its consequence visible and supports cancellation with Return or Escape. Scanning and navigation are guarded while an item action is being prepared or performed; Back remains available during ordinary scanning. Errors distinguish a failed scan from a failed move.
