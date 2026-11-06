# Startup and menu bar settings review

## Disposition
Ship at the reviewed scope. Independent finish review found no material issues or required fixes.

## Scope
Launch at login through native ServiceManagement, a dedicated Mac Tools menu-bar item with optional CPU readings, and migration of existing menu preferences. Existing Settings, Key Vault, and Quick Paste work remains in place.

## Evidence
- Signed debug app built successfully at `build/Mac Tools.app`.
- All 20 relevant tests passed: 9 AppSettings and 11 LaunchAtLogin tests. Tests cover legacy migration, independent menu visibility, actual login-service status, pending approval cancellation, failure status, external changes, and demo isolation.
- Full suite: 272 tests, 271 passed, one previously established MetadataScrubber failure at `AdditionalToolsTests.swift:115`. That failure was reproduced on the untouched baseline during the earlier quick-paste work.
- Native Settings captured at 1120 × 790 in light and dark: `startup-settings-light.png`, `startup-settings-dark.png`. All groups fit, controls retain meaningful labels/help, and CPU display is disabled while the menu item is hidden.
- Demo login toggle changed both ways without host registration. Menu visibility and CPU display toggles updated their native control states.
- With Quick Paste disabled and the menu item enabled, closing the main window kept the app running. Command-comma reopened Settings with the same values.
- With both Quick Paste and the menu item disabled, closing the main window exited the preview. The retained CPU preference did not keep it alive.
- Source and documentation passed an independent consistency review. JSON parsing and diff whitespace checks passed.

## Limits
Actual host registration and logout/login behavior were not exercised. The computer-use surface exposed the main app window, not the status-item menu, so direct icon/menu interaction remains unverified. Minimum-size rendering was not confirmed; the reviewed captures are 1120 × 790. Pending approval and error branches are verified through isolated service tests and source review.

Native registration follows [Apple's SMAppService documentation](https://developer.apple.com/documentation/servicemanagement/smappservice).
