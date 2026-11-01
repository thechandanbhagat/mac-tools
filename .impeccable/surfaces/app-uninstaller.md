# App uninstaller
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Choose an installed app, review its size and optional related files, then confirm what moves to Trash.
OWN-WORLD: Inherit system type, adaptive AppKit surfaces, teal accent, SF Symbols, the utility sidebar, native help, and fixed action footer. App icons come from the installed bundle through AppKit.
STORY: Find apps in the two Applications folders; search or choose an app; inspect its size; optionally select exact related-file matches; review item paths and sizes; explicitly confirm Trash; report success or failure.
FIRST VIEWPORT: App uninstaller title and help, a searchable app list on the left, a focused app detail area on the right, and the fixed refresh/review footer. Selecting an app reveals related-file checkboxes; initial related selection is empty.
FORM: New utility inside the established native workbench. No separate visual style, extra dashboard, persistent warning panel, or decorative labels.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Discovery is scoped to /Applications and ~/Applications. App metadata is read from Info.plist; the app is never launched to identify it. Size inspection reads filesystem metadata. Related candidates use only exact bundle-identifier paths in supported user Library locations. Do not guess by app name or promise exhaustive installer cleanup. Shared containers, privileged helpers, system locations, and Mac Tools itself are excluded. Native help explains the scope and points to the developer’s uninstaller for apps with background services.

Keep only necessary labels: search, app identity and path, sizes, related files, progress, notices, and the next action. Secondary explanation belongs in hover/click help. Essential incomplete results, running-app requirements, destructive consequences, and failures remain visible.

Related files are optional and unchecked on each new inspection. Partial items cannot be selected. A running app must be quit and checked again. Review always includes the app, plus exactly the selected related items; the immutable confirmation lists their paths and sizes. Explain there that selected related files may contain settings and app data. Return and Escape cancel; Move to Trash requires explicit activation.

Recheck reviewed trees before moving. Move the app first, and leave all related files untouched if it fails. Record internal symbolic links without following their targets. Use native macOS Trash only, without elevation, permanent-delete fallback, or emptying Trash. Demo mode uses temporary sample apps and disables moves. Switching tools preserves state and ongoing work; refresh and selection changes invalidate pending confirmation.
