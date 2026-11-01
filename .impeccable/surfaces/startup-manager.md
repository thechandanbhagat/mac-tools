# Startup Manager
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Understand configured launch items and use the native system controls to manage sign-in and background behavior.
OWN-WORLD: Inherit the shared header, 36pt content gutters, system type, flat rows, native pickers, contextual help, and fixed footer.
STORY: Read configurations; search or filter scope; inspect the program and trigger; reveal a file or open Login Items settings.
FIRST VIEWPORT: Title/help and Login Items…, search and scope, clearly identified launch configurations, and Refresh.
FORM: A compact configuration list, not a replacement System Settings interface.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Read only `~/Library/LaunchAgents`, `/Library/LaunchAgents`, and `/Library/LaunchDaemons`, bounded to 1,024 entries per location and 1 MB per plist. Do not follow symbolic links or execute plist commands. Report unreadable or invalid entries.

Configured trigger and Disabled in file are file data, not live running/enabled state. Modern app-managed login items and launchd overrides are not exhaustively represented. Keep the scoped list identity visible and use help for its detailed limits. Management opens native Login Items settings; there are no in-app service toggles or administrator requests. Demo labels samples and disables external Finder/Settings actions.

## Source and evidence
`StartupManagerView.swift`, `StartupManagerModel.swift`, and `Core/StartupManager.swift` define behavior. This brief records source scope; runtime and visual evidence is tracked separately under `.impeccable/review`.
