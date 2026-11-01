# Batch Renamer
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Make filename changes understandable before applying them and offer reviewed restoration of the latest batch.
OWN-WORLD: Inherit the shared header, system controls, flat rows, native confirmation sheets, contextual help, and fixed footer.
STORY: Choose files; adjust names; inspect Original / New name; review; confirm; optionally review Undo Last Batch….
FIRST VIEWPORT: Title/help and file chooser, compact naming fields, two-column preview, and change count with Review….
FORM: A before-and-after table with controls, not a wizard or a separate visual identity.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Support find/replace, prefix/suffix, numbering, and today’s date. Preserve extensions by default. Files remain in their original folders. Keep invalid names, collisions, and changed-file errors visible near the relevant action. The preview never renames files on its own.

Require confirmation for Rename and Restore Names; Return and Escape cancel. Demo disables execution. Revalidate before applying, use exclusive destinations, and attempt rollback on failure without hiding any recovery error. Undo covers the latest successful batch in the current session when files are unchanged. Normal application quit waits for an applying batch to finish or attempt rollback. Secondary naming rules belong in contextual help.

## Source and evidence
`BatchRenamerView.swift`, `BatchRenamerModel.swift`, `Core/BatchRename.swift`, and termination integration in `MacToolsApp.swift` define behavior. This brief records source scope; runtime and visual evidence is tracked separately under `.impeccable/review`.
