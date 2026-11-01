# Duplicate Finder
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Compare local file contents, choose redundant copies, and confirm removal while retaining one copy.
OWN-WORLD: Inherit system typography, semantic AppKit surfaces, forest-teal selection, SF Symbols, native help, and the fixed footer.
STORY: Choose a folder; scan size and SHA-256 matches; inspect grouped paths; select copies; review; explicitly confirm Trash.
FIRST VIEWPORT: Concise title/help, chosen folder, a flat grouped file list or empty state, and scan/review actions.
FORM: A focused file-review tool inside the shared workbench, without additional dashboard panels or persistent Trash buttons.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Selection starts empty and must leave at least one copy per group. The confirmation names selected files, paths, and sizes and visibly states that a copy stays. Return and Escape cancel; demo disables the move. Recheck the affected group, including the retained copy, before Trash.

Content hashing reads local files. Skip links, hidden files, packages, cloud locations, other mounted volumes, and duplicate hard-link identities. Keep scan limits, access failures, and stale-file refusals visible through notices or alerts. Secondary scope explanations belong in native help. No permanent deletion or automatic emptying of Trash.

## Source and evidence
`DuplicateFinderView.swift`, `DuplicateFinderModel.swift`, `Core/DuplicateFinder.swift`, and `Core/DuplicateFileAccess.swift` define behavior. This brief records implementation scope; runtime and visual evidence is tracked separately under `.impeccable/review`.

Finder aliases and files with resource forks are excluded with scan notices because their data fork alone does not represent all content. This check repeats before removal.
