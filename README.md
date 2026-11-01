# Mac Tools

A native macOS utility app for storage cleanup, file tasks, startup review, and system activity. Its fifteen tools share a compact SwiftUI interface organized into **Storage**, **Files**, and **System** sections, using Apple frameworks without third-party dependencies.

## Run the app

Requires macOS 14 or later and an installed Swift 6 toolchain (Xcode 16 or later).

```sh
./scripts/run.sh
```

This builds a debug app, creates `build/Mac Tools.app`, applies a local ad-hoc signature, and opens it. The build and compiler caches stay inside `.build/`. The script works when invoked from another directory.

For an optimized release build:

```sh
./scripts/build-app.sh
open "build/Mac Tools.app"
```

You can also use `./scripts/run.sh --configuration release`. The app bundle remains in the project; the scripts do not install it in `/Applications`. The generated icon is drawn locally using AppKit.

For a restricted build runner that reports `sandbox-exec: sandbox_apply: Operation not permitted`, run `MAC_TOOLS_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/build-app.sh`. This disables SwiftPM's nested build sandbox for that invocation; it does not change the app's filesystem permissions.

## Develop

```sh
swift build
swift test
open Package.swift
```

Open the package in Xcode to edit and debug the `MacTools` executable scheme. The bundled build is recommended for normal use so the app has its own icon and bundle identity.

To inspect the interface using sample files:

```sh
open -n "build/Mac Tools.app" --args --demo --storage-map
```

Demo mode labels sample results and supports scans, filters, previews, and confirmation sheets. Trash, renaming, clipboard recording, and clipboard writes are disabled. File Converter can export its sample files inside its disposable demo folder. The app removes its sample fixtures when it quits normally. Replace `--storage-map` with `--uninstaller`, `--duplicates`, `--startup`, `--monitor`, `--renamer`, `--clipboard`, or `--converter` to open another tool.

## Storage cleaner

Scan storage, inspect the results, and explicitly choose items to move to Trash. Every new scan replaces the previous results and starts with no files selected. The review sheet shows the current selection and file locations before you confirm a move. A scan does not remove files.

The default scan covers:

- App caches in `~/Library/Caches`.
- Log files in `~/Library/Logs`.
- Files in `~/Downloads`.
- Files of at least 100 MiB in `~/Documents` and `~/Desktop`.

Scanning reads file metadata, not file contents. It skips hidden files, symbolic links, application and document packages, and files identified by macOS as iCloud items. These results describe the scanned locations, not every file on the disk.

Each scan allows up to 100,000 inspected entries and 10,000 candidates, divided equally among the enabled categories. With all four enabled, each category receives an allowance of 25,000 entries and 2,500 candidates; Documents and Desktop share the large-files allowance. An unused allowance stays with its category so a busy cache folder cannot consume another category's share. Scan notices identify categories that reached their limit. Scan fewer categories to give each one a larger allowance.

The cleaner is deliberately scoped to files you can inspect and access. macOS can restrict access to some folders; inaccessible locations are reported rather than bypassed. This first version does not request administrator privileges, remove system files, empty Trash, or perform background cleanup.

Before each move, the cleaner checks that the file still belongs to the scanned location and that its identity, size, and modification metadata still match the scan. Changed or replaced files are refused and require a new scan.

Items moved to Trash can be restored through Finder. Moving items to Trash does **not** immediately reclaim their disk space: you must empty Trash manually when you are sure you no longer need them. The results show allocated bytes on disk, while the large-file threshold uses logical file size. Storage figures are estimates; APFS snapshots, clones, compression, and purgeable space can make file totals differ from actual space recovered.

Close affected apps before removing their caches, and check personal files carefully. An app may recreate its caches later. A local build is ad-hoc signed for development, not notarized for distribution.

## Storage Map

Select **Storage Map** in the sidebar, choose a folder (or use Home or Downloads), then scan it. The map shows the relative allocated space of its contents. Opening a folder automatically scans that folder. Back and breadcrumb navigation also scan the destination, while **Rescan** or **Command-R** refreshes the current folder without returning to the chosen root. Files and packages open in Finder. The ordered list includes every discovered immediate child, including items too small to label in the map.

Storage Map scans only read metadata and never remove files. Scanning includes hidden items by default through an explicit toggle and treats app/document packages as single entries. It does not follow symbolic links, download cloud content, or cross into other mounted volumes. Scan notices identify omissions and permission failures; affected totals are marked partial. File allocation estimates can differ from recoverable space because of APFS sharing and snapshots.

Each folder scan is independent and receives a fresh allowance of 100,000 entries and 64 directory levels. Hard-linked file contents count once within that scan; alias entries explain that their size is counted elsewhere. Entering a folder can change hard-link attribution and its reported total, so separately scanned folder totals are not merged into an older parent snapshot. Changing the hidden-items option clears the incompatible snapshot and timestamp, then automatically rescans the current folder.

Scans are cancellable. A manual refresh keeps the current folder’s previous snapshot and completed-scan time visible; cancellation or failure preserves them when available. Entering another folder clears the old folder’s snapshot so it cannot appear under the new path. Breadcrumbs remain available during scanning, and going back starts a fresh scan of the parent. Switching tools preserves the current location and scan state.

To remove an ordinary file or folder, right-click its list row or map tile and choose **Move to Trash…**. The confirmation names the item, shows its full path and allocated size, and requires the explicit **Move to Trash** button. A folder confirmation states that all contents, including hidden items, move with it. Return or Escape cancels. Packages, the current root, and the grouped Other items tile have no Trash action; eligible items also expose an equivalent accessibility action.

Before confirmation and again before the move, the app rechecks the item snapshot and folder path. Folder preparation additionally inspects the entire subtree, including hidden items regardless of the map toggle, and calculates its allocated size independently of the map’s partial totals or hard-link attribution. It refuses folders containing packages, symbolic links, special files, cloud items, other mounted volumes, unreadable entries, or more contents than it can fully verify. Detected changes or replacements after confirmation require a rescan. The operation uses macOS Trash only, with no permanent-deletion fallback or automatic emptying. On success, Storage Map refreshes the current folder. Demo mode can preview the confirmation, but moving items is disabled.

## App uninstaller

Select **Uninstaller** in the sidebar to find apps in `/Applications` and `~/Applications`. Search by name, path, or bundle identifier, then choose an app to inspect its allocated size. The app list loads on first use; the refresh control or **Command-R** finds apps again.

Related files are optional and initially unchecked. The app looks only for exact bundle-identifier matches in these locations under your Library: `Caches`, `Preferences` (`.plist`), `Application Support`, `Saved Application State` (`.savedState`), `Logs`, `WebKit`, and `HTTPStorages`. It does not guess by app name, search all user data, or remove shared containers or privileged helpers. This is a scoped app-and-file removal tool, not a claim to find every component an installer may add. Use the developer’s uninstaller for apps that install background services.

Choose any related files you want to include, then choose **Review…**. The confirmation lists the app and every selected related item, with paths and sizes. Its visible consequence explains that selected related files may contain settings or data. The app is always included; related items remain on the Mac unless selected. **Move to Trash** requires an explicit click; Return or Escape cancels. Demo mode shows this flow with temporary sample apps and disables the move.

Running apps must be quit and checked again. System locations and Mac Tools itself are excluded. Incomplete inspections cannot be selected for removal. App bundles and selected related trees are rechecked against their reviewed metadata before any move and again before each item moves. Symbolic links inside a bundle or related folder are recorded without following their targets; linked removal targets and linked ancestor paths are refused. The app moves first, and related files are untouched if moving the app fails. Failures remain visible. There is no administrator prompt, background-service removal, permanent-delete fallback, or automatic emptying of Trash.

## Duplicate Finder

Choose a folder to compare ordinary local files by size and SHA-256 content hashes. Results group matching copies and show their paths; nothing is selected automatically. Select the copies to remove, choose **Review…**, then explicitly confirm **Move to Trash**. At least one copy in every group must stay. Return or Escape cancels the confirmation.

The scan is cancellable and bounded to 100,000 entries. Hidden files, links, Finder aliases, files with resource forks, packages, cloud locations, and other mounted volumes are excluded; multiple hard links to the same file are not presented as independent duplicates. Notices describe incomplete access or limits. Before moving selected copies, the app checks the affected group again, including the copy to keep. Changed files require another scan. Hashing reads file contents locally and can take longer than Storage Map’s metadata scans.

## Startup Manager

Review launch configurations in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, and `/Library/LaunchDaemons`. Search labels or executable paths and filter by **Yours**, **All users**, or **System**. The configured trigger and any **Disabled in file** note describe the plist, not the current running state or launchd overrides. Finder reveal opens the configuration’s location.

This list is scoped to those three locations; it is not a complete list of modern app-managed login and background items. **Login Items…** opens native System Settings for management. Mac Tools does not edit configurations, unload services, or request administrator access. Reads are limited to 1,024 entries per location and 1 MB per plist, with unreadable, oversized, or invalid files reported. Symbolic links are not followed.

## System Monitor

View CPU, active memory, home-volume storage, disk activity, and network activity. Readings update every two seconds while System Monitor is selected or its optional **Menu bar** checkbox is enabled. The menu bar shows CPU usage and opens a compact menu of readings, a refresh action, and controls to reopen or quit Mac Tools. Closing the window keeps the app running only when its menu-bar item is enabled.

CPU is averaged across all cores. Active memory includes active, wired, and compressed pages, so it differs from Activity Monitor’s Memory Used. Storage shows used and total capacity for the home volume. Disk rates cover available physical storage drivers; network rates sum active Ethernet, Wi-Fi, and cellular interfaces while excluding loopback, bridges, and VPN tunnels. Rates need two readings and restart after a long sampling gap. Unavailable readings remain unavailable rather than being shown as zero. The monitor makes no network requests.

## Batch Renamer

Choose up to 5,000 ordinary local files, then use find-and-replace, prefixes, suffixes, numbering, or today’s date. Extensions are preserved by default. The live **Original** / **New name** preview shows every proposed name before **Review…** opens a confirmation. Files stay in their original folders; invalid names, collisions, and selecting multiple hard links to the same file block the change.

Confirmed renames revalidate the files and use exclusive destination creation. If a batch fails, the tool attempts to restore the original names and reports failures. **Undo Last Batch…** previews and confirms restoration of the latest batch while the files still match its recorded state. Undo is session-local. A normal quit waits for an applying batch to finish or roll back. Return or Escape cancels either review sheet; demo mode disables renaming.

## Clipboard History

Recording starts **off** each time the app launches. Choose **Start** to remember subsequent text and image copies for this session; the existing clipboard is not imported. Search the list, inspect a preview, and choose **Copy** to put the selected item on the clipboard. The app never pastes into another app. **Pause** stops collection, individual removal and **Clear** remove stored history, and quitting clears it. Clearing history does not erase the system clipboard.

History stays in memory with limits of 100 items and 20 MiB. Text over 256 KiB and images over 8 MiB or 16 megapixels are skipped. Accepted images are stored as PNG without metadata. Recognized password-manager, concealed, transient, and autogenerated markers are excluded when the source app supplies them; unmarked sensitive content can still be captured. Recording is an explicit session choice, not a setting silently restored at launch.

## File Converter

Choose **Images**, **Combine PDFs**, or **Compress PDFs**, add local files, and choose an output folder. Image exports support JPEG, PNG, and TIFF, optional longest-edge resizing, and JPEG quality. Orientation is applied and metadata is removed; JPEG flattens transparency onto white. Combine PDFs uses the displayed order, with controls to move each input earlier or later.

PDF compression rasterizes each page at the chosen resolution and image quality. **The exported copy loses searchable text, links, forms, and annotations.** This consequence is visible before conversion. Compression may produce a larger file; output sizes show the actual result.

Originals are kept and existing destination files are never overwritten. Up to 100 inputs and 256 MiB per input are supported. PDFs are limited to 1,000 pages each, and a combined PDF may contain at most 1,000 pages. Single-frame images must fit the pixel limits; animated and multipage images, encrypted PDFs, cloud files, linked paths, and package contents are refused. Conversion supports cancellation, reports per-file failures, and keeps already completed exports. Demo exports stay inside its disposable fixture folder.

## Large & Old Files

Scan any folder for files of at least 10 MB, then filter interactively by minimum size (**10 MB+**, **50 MB+**, **250 MB+**, **1 GB+**), modification age (**Any age**, **30+ days**, **6+ months**, **1+ year**), and file kind (**Archives & Disk Images**, **Media & Video**, **Documents & Data**, **Other**). Preview files inline with Quick Look and move explicitly selected items to Trash after confirmation and snapshot revalidation.

## Developer Cleaner

Scan a projects folder (such as `~/Projects`, `~/Developer`, or a custom location) for heavy rebuildable build outputs and dependency directories: `node_modules`, `.build`, `DerivedData`, `Pods`, `target`, `.gradle`, `.next`, `.venv`, and `__pycache__`. Filter by artifact type or project name, review selected directories, and move confirmed items to Trash after snapshot revalidation.

## Empty & Broken

Scan a folder tree for empty directories and broken symbolic links. Before moving confirmed items to Trash, the app revalidates each item’s identity and verifies that folders are still empty and symbolic links are still broken.

## Metadata

Inspect local images, PDFs, and files for GPS coordinates, camera EXIF, TIFF/IPTC fields, PDF document attributes, and macOS extended attributes (`com.apple.quarantine`, `kMDItemWhereFroms`). Export clean `-clean` copies with metadata stripped (never overwriting originals) or remove extended attributes in place after confirmation.

## Checksums

Choose one or more local regular files to compute SHA-256, SHA-512, SHA-1, and MD5 digests using streaming file-descriptor reads. Paste an expected checksum to automatically select the matching digest length and verify whether each file matches. Copy any digest to the clipboard without uploading files.

## Active Ports

Inspect local listening TCP sockets and UDP endpoints, including port number, protocol, address, PID, process name, and executable path. Filter by port, process name, or protocol, and quit (`SIGTERM`) or force quit (`SIGKILL`) user-owned processes after confirmation and executable-path verification.

## Keyboard and navigation

**Command-1** through **Command-9** select tools in sidebar order across **Storage**, **Files**, and **System** sections. **Command-R** scans or refreshes the selected tool. **Command-Return** opens an available Cleaner, Developer Cleaner, Uninstaller, Duplicate Finder, or Batch Renamer review. Each tool preserves its state when switching.

## Project structure

- `Sources/MacTools/`: app entry point.
- `Sources/MacTools/UI/`: SwiftUI navigation, views, and presentation state.
- `Sources/MacTools/Core/`: filesystem operations, guarded Trash, duplicate comparison, rename planning, clipboard storage, conversion, startup inventory, and system sampling.
- `Tests/MacToolsTests/`: tests using temporary fixtures.
- `Resources/Info.plist`: app identity and minimum macOS version.
- `scripts/`: build, bundle, icon generation, and launch helpers.

The clean interface preference is recorded in `AGENTS.md`, `PRODUCT.md`, and `DESIGN.md`. Each tool keeps secondary explanation in contextual native help while leaving errors, partial results, and important file consequences visible. `ROADMAP.md` records the implemented feature scope.
