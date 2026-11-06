# Background login launch review

## Disposition
Ship at the reviewed scope. Independent finish review found no remaining material issues after correcting the retained hosting root.

## Result
Login and explicit background launches initialize services and ensure menu-bar visibility without constructing the main window. `LSUIElement` supplies an accessory launch; opening the app or choosing a menu action constructs the retained, nonrestorable native window and switches to regular activation. CPU display defaults to off, preserving an explicit user choice. Sampling requires a visible monitor page or enabled menu CPU mode.

## Evidence
- Release build and strict signature verification passed: `build/Mac Tools.app`.
- Latest focused run: 28 tests passed (8 launch-context, 9 settings, 11 login-service). Synthetic Apple-event descriptors verify the native login launch reason without modifying host login items.
- Full suite: 280 tests, 279 passed, one previously established MetadataScrubber failure at `AdditionalToolsTests.swift:115`.
- Fresh demo domain opened the main window with menu visibility and CPU display both off. Hiding the menu item while the window was visible did not terminate the app.
- Native theme changes updated the full retained window immediately; captures: `background-release-settings-dark.png`, `background-release-settings-light.png`, both 1120 × 790.
- Sidebar System Monitor showed active readings and “Updating every 2 seconds.” Command-comma returned to Settings.
- The preview was quit, given the explicit background-launch flag and a Monitor initial tool, and relaunched. No main window was available. The previously disabled menu preference became enabled. A subsequent explicit reopen showed the main window immediately, confirming the background app remained available.
- The regular release bundle was opened successfully and left showing Settings for the user. Its CPU display was off.
- Startup service configuration and runtime menu/history subscriptions are independent of main-window appearance. Theme/selection modifiers evaluate inside an observed retained root.

## Limits
Actual macOS logout/login delivery and direct status-item clicks were not exercised. The quiet runtime check used `MacToolsBackgroundLaunch`, sharing the same launch branch as the native Apple event. The live local bundle reported `SMAppService.Status.notFound`; its login registration was not changed, so actual registration availability remains unresolved. No cause (installation location, signing, or host configuration) is assumed from that status alone.

The launch-reason check follows [Apple’s launch Apple-event documentation](https://developer.apple.com/documentation/coreservices/apple_events/1556410-launch_apple_event_constants).
