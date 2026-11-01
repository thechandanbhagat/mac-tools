# Storage Map and clean UI finish review

## Disposition

Ship for the reviewed local macOS MVP scope. No blocking source or visual findings remain. This verdict covers the corrected scanner, native tool integration, and captured dark-appearance interface; it does not claim complete device, appearance, or accessibility coverage.

## Evidence

- Reviewed StorageMapScanner, StorageMapModels, StorageMapModel, StorageMapChart, StorageMapView, AppShellView, MacToolsApp, the shared HelpTip, CleanerView, ReviewView, SettingsView, and the relevant tests.
- The implementation owner reported 36 passing tests with the simplified UI. Source coverage includes aggregation, hard links, packages, hidden items, permission failures, symlinks, cloud exclusions, entry/depth budgets, cancellation, canonical folder selection, and chart geometry. The final subsequent zero-state change is wording only.
- The owner confirmed the final optimized release rebuild and strict ad-hoc signature verification passed after that wording correction. Normal preview termination removed both generated sample folders; the temporary preview bundle was also removed.
- Inspected storage-map-results.png and storage-map-detail.png: the sample root shows 13.9 MB across seven items; Projects shows 4.8 MB across two children. Names, totals, percentages, package treatment, breadcrumbs, and the fixed action footer are legible. The tiny file remains in the list when its map region cannot display a label.
- Inspected clean-ui-ready.png, clean-ui-help.png, clean-ui-review.png, and clean-ui-settings.png. Contextual help is readable; the review sheet names one selected file and keeps the Trash consequence visible; demo removal is disabled; Settings retains the labeled appearance choices.
- The owner exercised sample scanning, Projects drilldown, Command-1/2 switching, Cleaner selection and Command-Return review, Escape dismissal, and return to the same Projects map. Click help worked and native tooltip text was present in accessibility output.
- Full-window captures are dark appearance at 2048 × 1234. Fresh 1120 × 790, 1000 × 720, light appearance, hover dwell, full keyboard traversal, and VoiceOver operation were not visually verified. Permission and cancellation states were checked in source/tests rather than these captures. The reviewer did not launch the app or scan personal files.

## Findings

All actionable findings raised during review were corrected:

1. Folder selection now preserves canonical paths with lexical standardization, avoiding creation of a symlink ancestor that the scanner would reject.
2. The global entry budget bounds directory enumeration as well as metadata inspection, including hidden names; depth-limited folders probe only one entry, and exact-budget ambiguity is conservatively partial.
3. Hard-link aliases retain explicit shared-size attribution, including the zero-total state.
4. Navigation resets the results scroll position without hiding the initial scope on scan completion.
5. Scan-option help explains snapshot clearing; zero-total copy says no scanned storage is available rather than claiming no actual allocation.

No further actionable issue was found in the captured interface or reviewed source. Native controls and accessible names remain intact after copy removal.

## Contract assessment

The chosen-folder breakdown and largest-branch drilldown fulfill the thesis. The observed sequence supports scan, compare, drill, return, and Finder reveal affordances. The first captured viewport contains the scope, map, ordered child rows, and persistent action footer. The interface inherits native system type, semantic surfaces, teal accent, and SF Symbols without a separate visual identity.

The clean/simple preference is reflected in the source and captures: slogans, onboarding paragraphs, repeated reassurance, and ordinary row subtitles are removed; contextual question-mark controls hold secondary explanations. Partial results, shared allocation, errors, demo limits, and destructive consequences retain visible treatment where needed. Both tools retain their model state across switching.

DESIGN.md documents the new tool, proportional geometry and visual gutters, partial/shared sizes, navigation, and contextual help. AGENTS.md and PRODUCT.md preserve the user's preference. Storage Map introduces no shipping raster asset; the reviewed PNGs are verification captures.

## Required corrections

None for the observed scope. Retain the coverage limits above in any shipping summary. Do not describe the unobserved window sizes, light appearance, hover dwell, or VoiceOver behavior as verified.
