# Mac Tools feature scope

The user approved implementation of every tool in the original feature list on 17 October 2026. All tools share the existing native macOS interface and the clean UI preference in AGENTS.md.

| Tool | Scope | Status |
| --- | --- | --- |
| Storage Cleaner | Review caches, logs, downloads, and large files before Trash | Implemented |
| Storage Map | Folder breakdown, automatic drilldown scans, confirmed file/folder Trash | Implemented |
| Large & Old Files | Scan folders for 10 MB+ files with size, age, and kind filters before confirmed Trash | Implemented |
| Developer Cleaner | Scan projects for rebuildable build and dependency folders before confirmed Trash | Implemented |
| Duplicate Finder | Size and SHA-256 comparisons, explicit selection, retain a copy, confirmed Trash | Implemented |
| Empty & Broken | Find empty folders and broken symbolic links with revalidated Trash cleanup | Implemented |
| Batch Renamer | Find/replace, affixes, numbering, dates, preview, confirmation, latest-batch Undo | Implemented |
| File Converter | Image resize/format conversion, PDF combine and rasterized compression into new files | Implemented |
| Metadata | Inspect and scrub EXIF, GPS, document properties, and extended attributes | Implemented |
| Checksums | Local SHA-256, SHA-512, SHA-1, and MD5 digest computation and checksum comparison | Implemented |
| Clipboard History | Off by default; searchable session-local text and images; pause and clear | Implemented |
| App Uninstaller | App review with optional exact-match related files | Implemented |
| Startup Manager | Scoped launch-configuration review and native Login Items controls | Implemented |
| Active Ports | Inspect listening TCP/UDP ports and stop user-owned processes after confirmation | Implemented |
| System Monitor | CPU, active memory, disk, and network activity; optional menu-bar view with clipboard & tool shortcuts | Implemented |

File operations must preserve originals unless a user explicitly confirms the reviewed change. Clipboard collection starts off. Permissions and unavailable metrics are reported accurately. Startup Manager must use public macOS mechanisms and distinguish its scope from the complete system Login Items list.

Implementation status records available source features, not distribution or verification status. Startup Manager leaves service management to System Settings. Clipboard history is never persisted. PDF compression visibly explains loss of text, links, forms, and annotations. Batch Undo covers the latest session batch when its files remain unchanged. Duplicate cleanup always retains a copy. Detailed behavior and limits are documented in `README.md` and `PRODUCT.md`.
