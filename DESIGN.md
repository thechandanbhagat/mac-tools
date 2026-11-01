---
name: Mac Tools
description: A native macOS workbench for storage, files, startup review, clipboard history, and system activity.
colors:
  primary-light: "color(srgb 0.08 0.40 0.33)"
  primary-dark: "color(srgb 0.39 0.79 0.69)"
typography:
  headline:
    fontFamily: "system-ui"
    fontSize: "28pt"
    fontWeight: 600
  confirmation-title:
    fontFamily: "system-ui"
    fontSize: "21pt"
    fontWeight: 600
  dialog-title:
    fontFamily: "system-ui"
    fontSize: "23pt"
    fontWeight: 600
  title:
    fontFamily: "system-ui"
    fontSize: "20pt"
    fontWeight: 600
  section-label:
    fontFamily: "system-ui"
    fontSize: "18pt"
    fontWeight: 600
  subtitle:
    fontFamily: "system-ui"
    fontSize: "14pt"
    fontWeight: 400
  row-title:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 500
  body:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 400
  detail:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 400
  label:
    fontFamily: "system-ui"
    fontSize: "11pt"
    fontWeight: 400
  map-total:
    fontFamily: "system-ui"
    fontSize: "25pt"
    fontWeight: 600
  tile-label:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 600
rounded:
  meter: "5pt"
  field: "6pt"
  navigation: "8pt"
  card: "12pt"
spacing:
  text: "5pt"
  compact: "8pt"
  row-gap: "12pt"
  control: "16pt"
  group: "20pt"
  inset: "22pt"
  section: "26pt"
  map-section: "24pt"
  dialog: "28pt"
  content-gutter: "36pt"
components:
  help-control:
    width: "22pt"
    height: "22pt"
  help-popover:
    typography: "{typography.body}"
    padding: "18pt"
    width: "320pt"
  navigation-selected:
    textColor: "{colors.primary-light}"
    rounded: "{rounded.navigation}"
    padding: "12pt 13pt"
  search-field:
    typography: "{typography.body}"
    rounded: "{rounded.field}"
    padding: "9pt"
  category-filter:
    typography: "{typography.label}"
    rounded: "{rounded.field}"
    padding: "8pt 10pt"
  disk-card:
    rounded: "{rounded.card}"
    padding: "{spacing.inset}"
  disk-meter:
    backgroundColor: "{colors.primary-light}"
    rounded: "{rounded.meter}"
    height: "13pt"
  storage-map-trash-confirmation:
    typography: "{typography.confirmation-title}"
    padding: "26pt"
    width: "470pt"
  uninstaller-search:
    typography: "{typography.body}"
    rounded: "{rounded.navigation}"
    padding: "10pt"
  uninstaller-confirmation:
    typography: "{typography.confirmation-title}"
    padding: "26pt"
    width: "560pt"
  storage-map-chart:
    height: "206pt"
  storage-map-tile:
    typography: "{typography.tile-label}"
    rounded: "{rounded.meter}"
    padding: "12pt"
  storage-map-scope:
    rounded: "{rounded.card}"
    padding: "{spacing.group}"
---

# Design System: Mac Tools

## Overview

**Creative North Star: "A legible storage workbench"**

Mac Tools uses native macOS typography, controls, and adaptive surfaces to keep file information easy to read. Forest teal marks the current tool, category selection, storage usage, and primary actions. The interface is compact where files repeat and spacious where the user chooses the next step. Concise necessary labels carry the workflow; secondary explanations live in contextual help. The user explicitly prefers a clean, simple interface without slogans, redundant labeling, or repeated reassurance.

This document records the nine implemented SwiftUI tools on macOS 14 or later. The name is provisional. Native source is authoritative: `Sources/MacTools/UI/Theme.swift`, the shared `AppShellView.swift`, each tool’s view and model in that directory, and `Sources/MacTools/MacToolsApp.swift`. All layout measurements are macOS logical points. Frontmatter captures explicit reusable values; native colors and control styling remain owned by AppKit and SwiftUI. No fixed neutral colors, custom font, or separate visual identity for individual tools has been established. New tool descriptions below record source behavior; they do not imply a completed runtime or visual verification pass.

**Key Characteristics:**
- Concise action and data labels, with contextual help for secondary explanations.
- Adaptive native surfaces with a single forest-teal accent.
- System type, tabular size readouts, and SF Symbols.
- Compact, separated file rows with visible names, paths, and sizes.
- Explicit selection and a review sheet before moving files to Trash.
- A proportional storage map with a complete child-item list and confirmed file and folder Trash actions.
- A searchable app list, optional related-file selection, and explicit uninstall review.
- Duplicate groups with explicit selection and a required retained copy.
- Before-and-after rename previews, confirmation, and reviewed latest-batch Undo.
- Scoped startup configuration review and local system readings with an optional native menu-bar item.
- Clipboard history that starts paused and remains session-local.
- Original-preserving exports, with PDF flattening consequences visible before conversion.

## Colors

The palette combines forest teal with macOS semantic neutrals. The two primary tokens are the light and dark appearance values of the same accent, not separate product accents.

### Primary

- **Forest teal, light appearance:** `primary-light` supplies `Palette.accent` in Aqua.
- **Forest teal, dark appearance:** `primary-dark` supplies the same role in Dark Aqua with increased luminance.
- Accent-tinted fills indicate selected navigation (10% opacity), active category filters (11%), selected file rows (4.5%), selected app rows (12%), Cleaner notices (7%), and the unfilled meter track (10%). The meter fill uses the full accent.
- Storage Map tiles cycle through accent opacities of 21%, 18.8%, 16.6%, 14.4%, 12.2%, and 10%; Other items uses 6.5%. Their border uses 16% accent opacity. Shade separates regions; it does not encode file type, safety, or scan status. Area carries the size comparison.

### Neutral

- **Window surface:** `NSColor.windowBackgroundColor` backs the sidebar, search field, disk card, the initial Storage Map scope container, and map notices. The disk card and initial map scope container use this color at 70% opacity over the main panel; map notices use the full semantic surface. The active map location toolbar has no separate filled container.
- **Control surface:** `NSColor.controlBackgroundColor` backs the main area and fixed footer.
- **Separators:** `NSColor.separatorColor` is the defined semantic divider token; rendered `Divider` controls use their native styling.
- **Text:** SwiftUI `.primary` and `.secondary` supply the text hierarchy. Native controls also own disabled, focus, destructive, and link treatments.

These dynamic native values have no fixed hex equivalent in this system. Do not replace them with sampled screenshot colors. The portable frontmatter references the light accent for custom components; their native implementations resolve `Palette.accent` automatically in either appearance. The sidecar records this relationship.

**The Adaptive Surface Rule.** Resolve surfaces, text, separators, and control states through native semantic APIs; use the appearance-specific accent through `Palette.accent`.

## Typography

**Display and Body Font:** The macOS system font, requested with SwiftUI `.system`. `system-ui` in frontmatter is its portable family role. There is no custom typeface or separate display face.

The hierarchy uses weight and size to distinguish decisions from file details. Native line metrics remain unchanged. The main heading uses `headline`; Cleaner result and scanning headings and the app name use `title`; Cleaner’s Scan locations heading uses `section-label`; review and settings headings use `dialog-title`; the Storage Map and Uninstaller confirmation questions use `confirmation-title`. The scan-notice sheet has its own 22pt semibold heading. Body copy uses `body`, supporting explanations use `detail`, and paths and utility labels use `label`. Review paths use 10pt. Storage Map uses `map-total` for the current folder’s byte total and `tile-label` for visible tile names; tile sizes use `detail`.

File names use `row-title`; scope names use 14pt medium. Native buttons, checkboxes, menus, and pickers use platform typography. Selected filter text becomes semibold. Byte totals, sizes, and counts that change use `.monospacedDigit()`; this is not a monospaced body font. File names and paths truncate when necessary, generally in the middle, and Finder reveal actions provide access to the original item.

**The File Legibility Rule.** Keep the filename visually stronger than its path, and right-align file sizes so a list can be compared quickly.

## Layout

The window opens at 1120 × 790pt and has a 1000 × 720pt minimum. A fixed 208pt sidebar sits to the left of a native divider; the main task area expands with the window. This is a desktop composition, with no mobile breakpoints or alternate collapsed navigation.

The main header and footer share the content gutter token. The header leaves 45pt above its content for the hidden-title-bar window treatment. Between header and footer, one vertical scroll region holds disk usage and the current workflow. Cleaner section spacing uses `section`; Storage Map uses `map-section`. Both horizontal insets use `content-gutter`. The footer remains outside the scroll view so the selected total and next action stay visible.

Scope rows use 15pt vertical padding and separators inset to align with the text. Both tools’ result rows use 13pt vertical padding and 5pt horizontal padding with a 24pt icon column. Cleaner has an 80pt right-aligned size column; Storage Map has 94pt for size, 72pt for percentage of the current folder, and 20pt for Finder reveal. The search field grows alongside a 136pt sort picker. Filters stay in a single horizontal group at the supported minimum width.

Storage Map gives its chart a fixed 206pt height and the available content width. The size-sorted list follows in the main scroll view. Before the first scan, the scope container uses 20pt padding. Once a location is active, one unfilled toolbar contains scrolling breadcrumbs, current-folder Finder reveal, an icon-only Scan options menu, and Choose folder. The current location appears once, without a duplicate root card or folder heading. Changing folders scrolls back to this toolbar, which remains visible in the content during scanning.

Sheets have overall widths of 610pt for Cleaner review, 560pt for scan notices, and 470pt for Settings and the Storage Map item confirmation, including their respective padding. The Storage Map confirmation uses 26pt padding and 18pt vertical group spacing. Uninstaller uses the same padding and group spacing in a 560pt sheet with a scrollable item list capped at 220pt. Review and scan-notice lists scroll within fixed 220pt and 240pt viewports. Uninstaller separates a 260pt app list from its flexible detail pane with a native divider and 24pt horizontal gaps, inside the inherited 36pt content gutters. Each pane scrolls independently. Keep full-window scrolling and local sheet viewports functional when content is long.

## Elevation & Depth

The app defines no custom shadows. Surface differences, rounded containers, and fine separators establish grouping. macOS supplies sheet, popover, alert, and control depth. Do not encode a screenshot's system shadow as an application token.

There are no custom animation durations or easing curves. Progress indicators use native behavior, and workflow changes do not add decorative motion. Continue to rely on native accessibility behavior, including reduced-motion preferences.

## Shapes

Custom corners are modest and functional: `card` for the disk overview, `navigation` for the current-tool background and notices, `field` for search and filters, and `meter` for the storage bar and Storage Map tiles. Map tiles have a 1pt inset border and a 4pt gutter between allocated rectangles. File rows remain rectangular and flat. Native buttons, checkboxes, segmented pickers, and sheets retain system geometry rather than borrowing a custom card radius.

## Components

### Labels and contextual help

Use concise labels that identify an action, field, navigation destination, or data value. The Cleaner header shows only its title and help control; scanning uses Scanning… with progress, count, and path; results use Files to review. The footer keeps selection totals and actions, without generic reassurance. Do not add explanatory copy simply to fill available space.

The shared `HelpTip` uses a secondary `questionmark.circle` symbol at 15pt inside a 22 × 22pt native plain button. Native `.help` provides hover information. The button also has an accessibility label and hint, and keyboard or click activation opens a selectable-text popover using body type, 18pt padding, and a 320pt overall width. Use this affordance where an explanation helps; do not add an icon beside every self-explanatory control.

**The Necessary Labels Rule.** Keep action and data labels concise; put secondary explanations in accessible contextual help. Keep errors, partial results, and destructive consequences visible at the point where they affect a decision.

### Actions and native controls

Scan storage, Review selection, and Storage Map’s Scan folder / Rescan use `.borderedProminent` with `.controlSize(.large)` and the window's accent tint. Secondary actions use native buttons, links, or plain buttons according to their context. Hover, pressed, focus, and disabled rendering are native; no custom transition is specified. The source contains an unused `PrimaryButtonStyle`; its padding and pressed opacity are not part of the shipping action design.

Disable Scan storage when no categories are enabled and Review selection when no files are selected. During scanning, the footer shows Cancel scan; during cleanup, it shows a spinner and Moving to Trash. The review sheet uses a native destructive-role Move to Trash button and Cancel with the native cancel shortcut. Command-R scans or refreshes the selected tool, targeting the current folder in Storage Map and opening Add files in File Converter; it is disabled for Clipboard History. Command-Return opens an available Cleaner, Uninstaller, Duplicate Finder, or Batch Renamer review. Command-1 through Command-9 select tools in sidebar order.

### Navigation and appearance

The shared sidebar contains the app name, nine tools, and Settings. Tool order is Cleaner (`internaldrive`), Storage Map (`square.grid.2x2`), Uninstaller (`app.badge`), Duplicate Finder (`doc.on.doc`), Startup Manager (`power`), System Monitor (`waveform.path.ecg`), Batch Renamer (`character.cursor.ibeam`), Clipboard History (`clipboard`), and File Converter (`arrow.triangle.2.circlepath`). The tool list scrolls within the existing 208pt sidebar. It has no slogan or repeated local-processing note. Tool rows are native plain buttons separated by 4pt. Selection combines semibold accent text, a pale accent fill, and an accessibility selected trait; unselected rows use regular primary text. A mini native progress indicator marks finite scan or file-operation work; continuous monitoring and clipboard recording do not add sidebar spinners. All tool models are retained by the app and passed through the shell, so switching tools preserves their model state. The sidebar's `square.stack.3d.up.fill` mark is an SF Symbol, not a custom raster logo.

Settings contains a concise title, native segmented System / Light / Dark appearance picker, version, and Done action. Contextual help holds the local-processing and tool-behavior explanation. The `appearance` value persists with `@AppStorage`; the main window and Settings scene apply the corresponding `.preferredColorScheme`, with System represented by no override.

### Scope rows and category filters

Cleaner’s Scan locations section uses category names and native checkboxes. Category explanations and folder locations are available through adjacent contextual help controls. SF Symbols identify caches (`shippingbox`), logs (`doc.text`), downloads (`arrow.down.circle`), and large files (`doc.zipper`). Results use compact plain-button filters with counts; only a selected filter receives a tinted background and semibold label. Filtering never selects files.

### Search and file rows

Search is a plain native text field inside a rounded semantic surface, with `magnifyingglass` and a clear control that appears only when needed. The native sort picker switches between Largest first and Name A–Z. Rows combine a checkbox, category symbol, name and path, size, and `arrow.up.forward.square` Finder reveal action. Selection changes the checkbox and adds a subtle accent wash. Select all N explicitly refers to the visible filtered file count; Clear selection clears the full selection. Accessibility labels identify the file being selected or revealed.

### Disk overview

A quiet rounded container presents volume name, available storage, used storage, and total capacity. The bar represents used divided by total capacity, not an estimate of reclaimable space. Its label exposes used and total values to accessibility. If capacity information is unavailable, a plain explanation replaces the meter while scanning remains possible.

### Status, empty states, and review

Cleaner has separate ready, scanning, results, and cleaning model phases. Scanning shows activity, inspected count, and the current folder. Scan notices open a sheet with readable details, and failures use a native alert. An empty result with no notices uses a neutral folder; incomplete scans use `exclamationmark.circle` and direct the user to notices. A search with no matches uses native `ContentUnavailableView.search`.

Every Cleaner scan clears selection. The review sheet names each selected file, its path, and its on-disk size. The visible consequence states that selected files will move to Trash and asks the user to close apps that use them. Restoration through Finder, delayed space reclamation, and the fact that Mac Tools never empties Trash are available through contextual help. The sheet retains the explicit Move to Trash action. Success wording reports files moved to Trash and explains that space is freed only when the user empties Trash. Failed items stay selected and are reported. Demo mode is visibly labeled and disables cleanup. Preserve these distinctions in text and symbols instead of communicating outcome through color alone.

**The Review Before Cleanup Rule.** A scan or filter never authorizes removal. Show the exact file scope and require explicit confirmation before moving files to Trash, through Cleaner review, the Storage Map item confirmation, Uninstaller review, or Duplicate Finder review. Renaming also requires a before-and-after review and confirmation.

### Storage Map scope and navigation

Storage Map reuses the existing palette, type, shell, and fixed action footer. Its initial ready state shows the chosen folder, a native folder chooser, Home and Downloads shortcuts, and an Include hidden items checkbox that defaults on. After scanning starts, the breadcrumb toolbar represents the current location. Its `slider.horizontal.3` menu exposes the hidden-items option with native help and an accessibility label; changing that option clears the previous snapshot and timestamp, then rescans the current folder. Choose folder is disabled during scanning, while ancestor navigation and scan options remain available. Navigation and scans are guarded while a file action is being prepared or performed. The footer offers Cancel scan while busy, Scan folder when no result exists, and Rescan with `arrow.clockwise` when a result exists. Scanned at reports the last completed scan of the current folder.

Breadcrumbs describe the navigation location independently of scan results. The current crumb is non-interactive 13pt semibold text; ancestors use 12pt native links. The horizontal path automatically scrolls to keep the current location visible. Folder rows and tiles automatically start an independent scan of the opened folder; ancestor breadcrumbs and the parent-folder button also start a fresh scan of their destination. Command-[ goes back. Rescan and Command-R refresh the current folder without resetting the trail to the chosen root. Files and packages reveal the original item in Finder. Packages are grouped, non-drillable entries. The current folder and every child also have a dedicated Finder reveal action. Rows use a name, type icon, size, percentage, and Finder action. Supporting row text appears only for shared-size attribution or partial scans. Accessibility exposes size, percentage, and navigation behavior. The size-column heading uses a down chevron with a tooltip to communicate largest-first ordering.

### Storage Map chart and results

The chart uses a binary partition of positive scanned byte totals. With up to 12 positive children it shows each one; above 12, it shows the largest 11 plus an Other items tile summing all remaining positive entries. Other items scrolls to the full child list rather than representing a folder. Zero-byte entries and tiny entries remain available in that list. Partition areas preserve relative byte weights; fixed visual gutters reduce the colored area slightly, especially for tiny regions.

A tile displays its name only when its allocated rectangle is at least 85pt wide and 40pt tall. It adds the byte total at 100pt by 73pt and the SF Symbol at 145pt width. Tiles with labels use 12pt padding; smaller tiles have none. Every tile retains a tooltip, accessibility name, size value, and action hint even when its visible text is omitted. Native plain-button behavior supplies focus and activation.

The size-sorted list includes every current child without selection checkboxes or persistent Trash buttons. Eligible ordinary files and folders expose Move to Trash… through their row or tile context menu and an equivalent accessibility action. Percentages use one decimal place, show `<0.1%` for a smaller positive share, and show an em dash when the current total is zero. Tile shade is not a category legend. A file's zero allocated bytes do not by themselves mean it is empty: hard links whose storage was already attributed elsewhere in the current scan are labeled “Hard link · Size counted elsewhere”, and folders report shared entries. Each opened folder receives a fresh scan budget and fresh hard-link attribution. Its total can differ from the value previously shown by its parent; independently scanned totals are not merged into a prior parent snapshot. When all current bytes have been counted elsewhere, a message replaces the chart while the rows remain available.

### Storage Map item confirmation

Right-click an eligible ordinary file or folder row or tile to choose Move to Trash… from a native destructive context-menu item. Default click behavior remains unchanged. Packages, the displayed root, and the aggregate Other items tile have no Trash action. A matching accessibility action provides another entry point without adding persistent controls. Item eligibility comes from the current scan snapshot; actions are unavailable while scanning or preparing another item action.

The native confirmation sheet asks Move “[name]” to Trash? with a secondary `trash` symbol, the item’s full selectable path, allocated size, and a visible Finder restoration sentence. For folders, an additional visible sentence states that the folder and all its contents, including hidden items, move to Trash. The size comes from a complete hidden-inclusive preflight, independent of the map’s partial totals or hard-link attribution. Ordinary file confirmation still shows the file allocation. Cancel is the default Return action; Escape also cancels. Move to Trash is a separate explicit destructive-role bordered-prominent button. Demo mode keeps confirmation available but visibly disables the move.

The footer uses a small native progress indicator with Checking item… while preparing the request and Moving to Trash… while executing it. Preparation offers Cancel; navigation and scans remain guarded during the item action. The service validates the scanned item and folder path before confirmation and again before calling macOS Trash. Folder preparation captures the complete subtree, including hidden items, and refuses packages, symbolic links, special files, cloud contents, other volumes, unreadable entries, or limits that prevent full verification. Detected changes are refused; there is no permanent-deletion fallback or automatic emptying. Success clears the stale map, rescans the current folder, and names the moved item in a notice. Errors use a move-specific alert title instead of the scan-failure title.

### Storage Map incomplete and empty states

Ready, scanning, and results are separate map phases. Scanning uses one concise row for activity and inspected count plus a native linear progress indicator; the current path is available through the indicator’s tooltip. An ordinary manual refresh of the same folder with unchanged options keeps its previous results and completed-scan time visible. Cancellation or failure returns to those results when available; otherwise the current breadcrumb location remains ready to scan. Entering a different folder or changing scan options clears the previous results and timestamp before scanning, so another folder’s data or results from old options are never shown as the new scan. Back navigation remains available and starts a new destination scan. Partial results carry a visible notice, a Partial scan label beside the total, and Partial scan row detail. Contextual help beside the total and in the notice sheet explains that partial sizes include only inspected files. Empty partial results use `exclamationmark.circle`; complete empty results use `folder`; grouped package content uses `shippingbox` and a Finder action. Header help explains automatic folder scanning, current-folder refresh, the confirmed file or folder context action, metadata-only scanning, and cloud exclusions. Help beside the size total explains proportional area, independent hard-link attribution, and differences from Finder. The notice sheet keeps issue messages and paths visible, with further guidance in help. Demo mode has a compact Demo label beside the page title.

**The Measured Area Rule.** Derive map geometry from scanned byte totals, keep the full child list available, and name partial or shared-size attribution instead of presenting those values as complete folder usage.

### App uninstaller

Uninstaller inherits the shell, header, footer, native help, system typography, and accent. The header contains App uninstaller, a compact Demo label only when applicable, and one scope help control. Its left pane uses a plain Search apps field with a magnifier and conditional clear button, followed by an app count and scrolling list. The field uses 10pt padding and an 8pt corner radius. Each row shows a 32pt AppKit app icon, 13pt medium app name, and optional 11pt version. Selected rows use a 12% accent wash and the accessibility selected trait. The detail pane uses a 48pt icon, 20pt semibold app name, path, measured size, and Finder reveal.

Discovery runs on the first visit and through the icon-only refresh control or Command-R. Selecting an app begins its inspection, displaying Checking files… until details are ready. The initial detail pane says Choose an app. A blank app list distinguishes no discovered apps from no search matches. Related files has one contextual help control and native checkboxes; every new inspection starts with these unchecked. Rows show the Library location, exact item name, size, and Finder action. Incomplete rows are visibly marked and disabled. A running app shows Quit [name], then check again and a Check again button. Errors and scan notices remain visible without a permanent explanatory panel.

The fixed footer shows notices when present, a refresh icon, the selected size, and Review… when an inspection exists. During discovery or inspection it offers Cancel scan; during removal it shows Moving to Trash…. App selection and refresh are guarded during removal. Switching tools preserves the model and ongoing work. Selecting a different app or refreshing invalidates any pending confirmation.

Review uses a 560pt native sheet headed Uninstall “[app]”? The visible consequence distinguishes app-only removal from removal with selected related files; in the latter case it states that related files may contain settings and data. The scrollable list names every item and shows selectable paths and sizes. A footer total, Finder restoration sentence, Cancel-default Return action, Escape cancellation, and explicit destructive Move to Trash button complete the decision. Demo mode disables the move with a visible explanation.

The scope is deliberate: /Applications and the user’s Applications folder, with exact bundle-identifier matches in supported user Library locations. Shared containers, privileged helpers, system locations, fuzzy name matches, and Mac Tools itself are excluded. Contextual help explains these limits and recommends the developer’s uninstaller for apps with background services. This flow does not claim exhaustive installer cleanup. Before moving, the backend rechecks reviewed content; the app moves first, related files move only after that succeeds, and failures are reported. No tool empties Trash or falls back to permanent deletion.

### Duplicate Finder

The header and folder chooser use the existing 28pt heading, contextual help, and 36pt gutters. Results group copies by matching content; each group shows its count and per-file size above checkbox rows with file names, paths, and Finder reveal. Selection starts empty. The last unselected copy in a group cannot be selected, and review states that one copy stays. The flat list uses native separators and text hierarchy rather than another set of cards.

The fixed footer holds scan notices, selected bytes, an icon-only rescan control, and Review…. Busy states show cancellation while scanning and Checking and moving… during cleanup. The 560pt confirmation lists exactly the selected paths and allocated sizes, retains Cancel as the Return action, and requires explicit Move to Trash. Escape cancels and demo disables moving. Scan and revalidation failures remain visible; help explains local content hashing and exclusions.

### Startup Manager

Startup manager uses the inherited header and help with a concise Login Items… button. Below it, a rounded search field and native scope picker filter the flat list. The necessary Launch agents & daemons and Configured trigger labels distinguish file configuration from a complete or live login-item inventory. Rows show the configuration label, executable path, scope, trigger, optional Disabled in file detail, and Finder reveal. Paths truncate in the middle with full native help.

The fixed footer shows item count or Reading launch items…, a visible unreadable-item action, and Refresh. Unreadable details use a 540 × 400pt native sheet. Help declares the three scanned locations and explains that modern background items and launchd overrides are not exhaustively represented. Management opens native System Settings; there are no switches that pretend to change or report unsupported live service state. Demo uses sample configurations and disables Finder and Settings actions.

### System Monitor

System monitor keeps five flat metric rows: CPU, Active memory, Storage, Disk activity, and Network. Each row uses a secondary SF Symbol, concise 14pt label, and trailing 16pt monospaced-digit value, separated by native dividers with 27pt vertical row padding. No decorative chart, metric card, or invented health judgment is added. The header contains one Menu bar checkbox and contextual help. The footer states the two-second update cadence or paused state and offers an accessible icon-only refresh.

Help defines each metric, including active memory’s difference from Activity Monitor and the interfaces counted for network rates. Missing rates use a dash; unavailable gauges remain explicit. Rates require two readings and reset after long gaps. Sampling runs only when this tool is selected or the menu-bar item is enabled. The native menu-bar extra shows a CPU title, compact readings, Refresh, Open Mac Tools, and Quit Mac Tools. Its setting persists; enabling it keeps the app running when the main window closes. Demo readings are labeled.

### Batch Renamer

Batch Renamer keeps naming controls directly above an Original / New name preview. The first two rows contain Find / Replace with and Prefix / Suffix fields. Number from, a starting-number field, Add date, and Keep extension use native controls and wrap through `ViewThatFits` when needed. Preview rows preserve the two-column comparison, show unchanged names in secondary text, and expose the original path through help and Finder reveal. Invalid names or conflicts appear near the controls.

The fixed footer shows the number of changes, Review…, and Undo Last Batch… when a receipt exists. Applying changes shows Renaming… and prevents settings changes. A 540pt native confirmation lists original and proposed names with their folder paths; Undo uses the same reviewed flow to Restore Names. Return and Escape cancel. Demo disables execution. Normal quit waits for an applying rename batch to finish or attempt rollback. No implicit rename occurs while editing options.

### Clipboard History

Clipboard history uses the existing split-pane list and preview pattern. The searchable list presents concise text or image identity and capture time; the detail pane shows selectable text or a fitted image, size, and a contextual remove action. The fixed footer contains Recording / Paused, item count, Clear, Start / Pause, and Copy. An empty paused view explains the next required action without a permanent onboarding panel.

Recording starts off and remembers only copies made after Start. History stays in bounded session memory, can be cleared or individually removed, and disappears on quit. Copy only writes the selected item to the clipboard; it does not paste elsewhere. Help explains supported content, limits, sensitive-item markers, and that unmarked sensitive content can still be collected. Demo shows sample history while disabling capture and clipboard writes. Native selection, accessibility labels, semantic surfaces, and the existing accent are retained.

### File Converter

File converter uses one native segmented picker for Images, Combine PDFs, and Compress PDFs. Only relevant settings are shown: image format, optional longest-edge resize, quality, or PDF resolution. A flat input list provides names, sizes, removal, and earlier/later controls for PDF combination. The output-folder row shows its name and path with a native chooser. Completed exports show actual size and Finder reveal; PDF compression also reports the change in size.

The PDF compression consequence remains visible beside its settings: pages are flattened, so searchable text, links, forms, and annotations are lost in the exported copy. It must not be moved into a tooltip. Originals and existing exports are kept; conversion writes new names. The fixed footer provides Convert, cancellable progress, completion status, and a visible issue count leading to a 480pt details sheet. Help explains orientation, metadata removal, JPEG transparency, input limits, and unsupported formats. Demo conversion writes only to its disposable sample output folder. No extra confirmation is needed for an original-preserving export.

## Do's and Don'ts

### Do:
- **Do** keep necessary labels concise and provide secondary explanations through contextual help with hover, keyboard, and click access.
- **Do** use native semantic surfaces and the adaptive accent in both appearances.
- **Do** keep file names, paths, sizes, and selection state legible together.
- **Do** preserve the fixed footer and the distinction between scan scope, results, and review.
- **Do** use SF Symbols and native interaction states for controls.
- **Do** state partial scans, cancellation, failures, and demo limitations in visible text.
- **Do** pair the proportional map with its complete, size-sorted child list and accessible item actions.

### Don't:
- **Don't** add slogans, redundant labels, repeated reassurance, or unnecessary help icons.
- **Don't** hide essential errors, partial-result status, or destructive consequences in tooltips.
- **Don't** hard-code neutral colors sampled from a light or dark screenshot.
- **Don't** imply that an empty or partial scan proves the Mac is clean.
- **Don't** automatically select results or substitute a cleanup total for an explicit review.
- **Don't** claim that moving files to Trash immediately frees disk space.
- **Don't** promote the provisional name or undecided future tools into new brand commitments.
- **Don't** use tile shades as safety or file-type categories, or equate a partial total with complete folder usage.
- **Don't** imply startup configuration equals current service state, an unavailable metric equals zero, or PDF compression always saves space.
- **Don't** enable clipboard recording automatically, persist clipboard history, or hide the PDF flattening consequence in help.
