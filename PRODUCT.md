# Product

<!-- impeccable:product-schema 1 -->

## Platform
macOS (native desktop)

## Stack
The user confirmed a native SwiftUI Mac app and asked to build it now. Swift Package Manager, Swift 6, macOS 14+. Foundation, AppKit, CryptoKit, Darwin/IOKit, ImageIO, CoreGraphics, and PDFKit provide local capabilities. No external dependencies.

## Product Purpose
A collection of useful tools for Mac: Cleaner, Storage Map, Large & Old Files, Developer Cleaner, Duplicate Finder, Empty & Broken, Batch Renamer, File Converter, Metadata, Checksums, Clipboard History, Uninstaller, Startup Manager, Active Ports, and System Monitor. These fifteen tools share the existing native interface and concise interaction language, organized into Storage, Files, and System sidebar sections, with cross-tool context menu handoffs, drag-and-drop support, and inline Quick Look previews.

## Capabilities and Constraints
Cleaner scans local storage, explains cleanup candidates, reviews individual files, and moves explicitly selected files to Trash. No automatic deletion or permanent removal. Permissions, partial scans, cancellation, and failed operations remain visible.

Large & Old Files scans a chosen folder for files of at least 10 MB, with filters for minimum size (10 MB+, 50 MB+, 250 MB+, 1 GB+), modification age, and file kind, moving explicitly selected files to Trash after confirmation and snapshot revalidation.

Developer Cleaner scans a chosen projects folder for rebuildable build outputs and dependency directories (`node_modules`, `.build`, `DerivedData`, `Pods`, `target`, `.gradle`, `.next`, `.venv`, `__pycache__`), measures their allocated size, and moves explicitly selected directories to Trash after confirmation and snapshot revalidation.

Empty & Broken scans a chosen folder for empty directories and broken symbolic links, revalidating that folders are still empty and symlinks are still broken before moving confirmed selections to Trash.

Metadata inspects local images, PDFs, and files for EXIF, GPS location coordinates, TIFF/IPTC properties, PDF document attributes, and macOS extended attributes (`com.apple.quarantine`, `kMDItemWhereFroms`), and either exports clean `-clean` copies without overwriting originals or strips extended attributes in place after confirmation.

Checksums computes SHA-256, SHA-512, SHA-1, and MD5 digests for local regular files using streaming descriptor reads, compares them against an expected checksum string, and copies digests to the clipboard without uploading files.

Active Ports lists local TCP listening sockets and UDP endpoints using `/usr/sbin/lsof`, showing port, protocol, address, PID, process name, and executable path, with confirmed Quit (`SIGTERM`) and Force Quit (`SIGKILL`) for user-owned processes after verifying executable path identity.

Storage Map scans a chosen folder, shows a proportional map and size-sorted contents, and automatically scans each folder opened through drilldown or breadcrumbs. Manual refresh targets the current folder. Each scan has independent limits and hard-link attribution; navigation preserves the breadcrumb location. Ordinary refresh cancellation or failure retains that folder’s prior snapshot; changing folders or options clears incompatible results. Scans read metadata only. A separate context-menu action can move an ordinary file or folder to macOS Trash after confirmation. Folder confirmation includes all contents, including hidden items. A fresh complete subtree check supplies the folder size and rejects unsupported or inaccessible contents. Packages, the displayed root, and grouped map regions remain excluded. The app rechecks the item and its path, rejects detected changes, and refreshes the current folder after success.

Uninstaller finds user-installed apps in /Applications and ~/Applications. Selecting an app inspects its size and exact bundle-identifier matches in supported user Library locations. Related items are optional and initially unchecked. A review lists the app and explicitly selected related files before confirmation. Running apps must be quit; system locations, Mac Tools itself, shared containers, privileged helpers, and fuzzy name matches are excluded. Incomplete items cannot be removed. Revalidation precedes Trash, and related items move only after the app succeeds. This scoped tool does not promise exhaustive removal of everything an installer may add.

Duplicate Finder compares ordinary local files using size and SHA-256 content hashes. Selection starts empty and must leave one copy in each affected group. Review names selected files before Trash, and the affected group is rechecked before removal. Scans skip links, Finder aliases, resource-fork files, hidden items, packages, cloud locations, other volumes, and duplicate hard-link identities, with limits and issues visible.

Startup Manager reviews the user and all-user LaunchAgents directories and the all-user LaunchDaemons directory. Search and scope filters expose configured programs and triggers without claiming current running or enabled state. Modern login/background registration is not exhaustively represented by those files. Management uses the native Login Items settings; Mac Tools does not modify launch configurations or unload services.

System Monitor samples CPU, active memory, home-volume capacity, physical disk I/O, and active Ethernet/Wi-Fi/cellular network counters locally. Sampling runs every two seconds only while the tool is selected or the optional menu-bar item is enabled. Rates use differences between compatible readings; unavailable values remain explicit. The menu-bar setting persists and allows the app to remain running after its window closes. Sampling stops on quit and makes no network requests.

Batch Renamer supports find-and-replace, prefixes, suffixes, numbering, and the current date, preserving extensions by default. Preview and confirmation precede changes, files stay in their folders, and changed files or name collisions are refused. The latest successful batch has a session-local, reviewed Undo. Applying a batch finishes or attempts rollback before normal application termination.

Clipboard History is off at launch and collects only new copies after explicit Start. Text and images stay in bounded session memory, with search, preview, Copy, Pause, individual removal, and Clear. Copy never pastes into another app. Recognized sensitive/transient pasteboard markers are skipped when provided; unmarked sensitive data can still be captured. No history is saved to disk, and quit clears it.

File Converter exports images as JPEG/PNG/TIFF with optional resizing, combines PDFs in the chosen order, and rasterizes PDFs at selected resolution and quality. PDF compression visibly warns that searchable text, links, forms, and annotations are lost in the exported copy; smaller size is not guaranteed. Originals and existing exports are preserved. Unsupported inputs, limits, cancellation, and per-file failures remain visible.

Cleanup tools use macOS Trash only after explicit confirmation. They never empty Trash or fall back to permanent deletion. No tool requests administrator privileges. Demo mode labels sample data, disables Trash, renaming, clipboard capture and clipboard writes, and confines converter exports to its disposable sample folder.

## Product Principles
- Show real disk data and a clear scan scope.
- Keep the user in control of every cleanup.
- Use familiar macOS interactions and accessible system controls.
- Keep the interface clean and simple: retain concise necessary labels; omit slogans, redundant explanations, and repeated reassurance.
- Put secondary explanations in contextual native help, using `questionmark.circle` where useful with hover and accessible keyboard/click access. Keep errors, partial results, and destructive consequences visible when needed.

## Open decisions
Product name 'Mac Tools' is provisional. Distribution/signing, capabilities beyond the implemented scope, and commercial plans are undecided. See `ROADMAP.md` for the approved tool set.
