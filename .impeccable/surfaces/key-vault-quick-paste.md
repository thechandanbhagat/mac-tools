# Key Vault quick paste
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Retrieve a saved clipboard item without leaving the current text-entry task.
OWN-WORLD: Inherit system typography, semantic surfaces, native controls, SF Symbols, and the app's adaptive accent.
STORY: Focus a text field; press Control–Option–V; search or choose a saved item; return to the original field with a native paste action.
FIRST VIEWPORT: Compact Key Vault title and shortcut, search, saved-item list, destination or status footer, and Copy fallback. Permission or operation errors appear when needed.
FORM: A temporary borderless, nonactivating native panel near the pointer, 380pt wide and 220–450pt high according to visible results and required status. Use native shadow, 12pt corners, 16pt padding, 12pt group spacing, a 15pt semibold title, 13pt rows, and compact footer controls. Keep it free of full-page navigation and decorative cards.

## Constraints
Register only Control–Option–V using Carbon while quick paste is enabled and the app is running; do not monitor ordinary keystrokes or request Input Monitoring. The setting defaults on, persists, and takes effect immediately. It keeps the app running after its main window closes. Disabling it releases registration; conflicts remain visible in Settings. Tools → Quick Paste… can open the picker directly.

Clamp the panel to the current screen's visible area on opening and when its height changes, including after search changes. Focus search when shown; Up/Down changes the selected row and Return chooses it. Escape, an outside click, or the shortcut again dismisses the panel. Preserve the prior app's identity before the panel takes keyboard focus. Show loading, empty, no-match, permission, registration, and operation errors without adding permanent explanatory copy.

Sensitive rows and their accessibility labels show only their visible name or “Sensitive item.” Search matches those safe names only, never a sensitive value. Do not add a value preview or Reveal control to this compact picker. Clicking a sensitive row, Return, and Copy remain explicit actions without authentication; the full page's Reveal option is visual privacy, not an authorization step.

On choice, close the picker, verify Accessibility access, the original app and focused editable element, and released modifier keys. Put the selected item on the clipboard and dispatch native Command-V only to that validated destination. Do not read textbox contents, replace the field's entire value, send Return, or submit. If focus changes or cannot be verified, stop and show a manual Copy alternative. Ordinary items remain on the clipboard. Sensitive items carry a concealed marker and clear after 30 seconds, or on normal quit, only if Mac Tools still owns the unchanged copy. Never clear a replacement value or claim that other apps obey markers or forget values they already read. A custom editor may reject a dispatched paste; images need a compatible target. Do not claim guaranteed insertion merely because keyboard events were sent.

Accessibility Settings opens System Settings for the user to grant access manually. No automatic permission change or prompt is part of registration. The full Key Vault page's Copy remains copy-only. Demo previews from Tools with sample items, but never registers the shortcut, reads/writes the host clipboard, or pastes into another app.

## Source and evidence
`VaultQuickPasteController.swift`, `VaultQuickPasteView.swift`, `VaultPasteService.swift`, `VaultGlobalShortcut.swift`, `AppSettings.swift`, and `MacToolsApp.swift` define behavior. `.impeccable/review/QUICK-PASTE-REVIEW.md` records the earlier bounded source/screenshot review, native demo checks, and tests; it predates Sensitive masking and conditional clipboard clearing. New build/review evidence is pending. Physical/global shortcut dispatch and actual cross-app insertion remain unverified: the disposable registration probe accepted registration, but synthetic Control–Option–V produced no callback. Manual Accessibility setup and receiving-editor checks are still required.
