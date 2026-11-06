# Settings
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Set app appearance, launch behavior, and clipboard limits in one dedicated page.
OWN-WORLD: Inherit the main content pane, system typography, semantic surfaces, adaptive accent, native form controls, and accessible contextual help.
STORY: Open Settings from the fixed sidebar row or Command-comma; change a preference; continue using tools with their state preserved.
FIRST VIEWPORT: Settings title/help, General, Menu Bar, Clipboard, and Key Vault groups, concise controls, visible history/closed-window consequences, and a quiet version footer. The form scrolls when the available height requires it.
FORM: A native grouped form with a segmented theme picker, tool and history-limit pickers, five toggles, and conditional system-settings actions; no separate modal, Save, or Done action.

## Constraints
The sidebar, Mac Tools menu, Command-comma, and menu-bar Settings action open the same main-window page. Settings uses the tool selection treatment and does not offer scan or file-review actions.

Defaults are System theme, Cleaner at launch, menu-bar item off, CPU display off, clipboard capture on launch off, 100 history items, and Quick paste (⌃⌥V) on. Persist preferences locally and automatically, retaining the existing appearance and CPU-display keys. Initialize the new menu-bar visibility preference from the legacy CPU-display preference once, preserving an existing enabled item. Hiding the item preserves the CPU choice and stays hidden on a normal relaunch; login and explicit background launches enable the menu-bar item. Theme, menu-bar, and quick-paste changes apply immediately. The initial tool is selected next launch without forcing a window during quiet startup. Capture-on-launch changes apply next launch; Start and Pause remain independent session controls. Enabling either the menu-bar item or quick paste keeps the app running when its window closes.

Launch at login uses native macOS registration as its source of truth and is off unless already registered. The toggle explicitly registers or unregisters Mac Tools; refresh state on appearance and app activation. Pending approval and errors remain visible with an action opening Login Items settings when needed. Demo mode previews the control in memory without changing host login registration.

At login, stay in the background with only the menu-bar item and no main window or Dock icon. Do not construct or restore the main window until the user opens the app or chooses a main-window menu action. Detect the native login launch event; `--background` and the `MacToolsBackgroundLaunch` preview flag exercise that path without registration. Core lifecycle setup must run without the main view appearing. An AppKit window controller retains the existing SwiftUI shell and opens it with regular activation policy on demand. Preserve normal manual-opening behavior and the existing startup-tool choice.

Menu Bar separates Show Mac Tools in menu bar from Show CPU usage. Disable the CPU toggle while the item is hidden. The item shows the app SF Symbol or live CPU title and provides access to the main window, Key Vault, Clipboard History, System Monitor, Settings, and Quit, plus recent clipboard items and capture controls. CPU mode adds readings and Refresh. Only active CPU mode or a visible monitor page causes sampling.

Quick paste registers Control–Option–V while Mac Tools is running. Keep shortcut-registration errors visible. When Accessibility access is missing, explain the requirement and offer an explicit action opening the native permission page; the user grants access manually. Do not add Input Monitoring prompts or automatically grant permissions. The picker and its destination safeguards are defined in `key-vault-quick-paste.md`.

The history limit offers 25, 50, 100, 200, or 500 items within a 20 MiB cap. Apply it immediately, retaining newest entries and preserving capture state. Keep the consequence of lowering the limit and clearing history on quit visible. Secondary timing, capture boundaries, and local-processing explanation belong in accessible help. Session history stays in memory; capture never imports the existing clipboard. Explicitly saved Key Vault entries persist separately and are unaffected by this history limit. Demo mode cannot read or write the real clipboard.

## Source and evidence
`SettingsView.swift`, `AppSettings.swift`, `LaunchAtLoginModel.swift`, `AppShellView.swift`, `ClipboardHistoryModel.swift`, `VaultQuickPasteController.swift`, and `MacToolsApp.swift` define behavior. The visible Clipboard footer explicitly names clipboard history so it cannot imply saved vault items clear on quit. `.impeccable/review/SETTINGS-VAULT-REVIEW.md` records the earlier Settings/vault review; its scope predates quick paste, launch at login, and the dedicated menu-bar controls. It is not evidence for those additions.

`.impeccable/review/STARTUP-MENU-REVIEW.md` records the launch-at-login and menu settings review, 20 passing relevant tests, light/dark native captures, and window-close lifecycle checks. Host login/reboot and direct status-item interaction remain unverified.

The latest background launch evidence is `.impeccable/review/BACKGROUND-LAUNCH-REVIEW.md`: release build, live theme/navigation checks, and quiet preview/reopen behavior. Actual OS login delivery and local login-registration availability remain unverified.
