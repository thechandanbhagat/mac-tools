# Key Vault
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Keep explicitly selected clipboard items available across app launches.
OWN-WORLD: Inherit the searchable split-pane list, text/image preview, semantic surfaces, system typography, adaptive accent, contextual help, and fixed footer.
STORY: Save to Key Vault from Clipboard History with a name and optional Sensitive flag; open Key Vault in Files; search or select a saved item; Reveal a sensitive preview when needed; Copy, edit Details, or confirm Delete. From another app, Control–Option–V offers a temporary quick-paste picker.
FIRST VIEWPORT: Title/help, searchable saved items and preview, count/status, Details…, Delete…, and Copy. Sensitive previews offer Reveal; empty state points to saving an item from Clipboard History.
FORM: A separate saved-item page using the existing list-and-preview pattern, concise native metadata sheets, and visual masking without authentication or a lock feature.

## Constraints
Persist only explicitly saved text and image items. Name and Sensitive are available in the save sheet and the selected item's Details sheet. Name has a visible native label and accessible name. Save is disabled while the vault is busy; preserve the sheet's edits rather than dismissing when a submission cannot start. Session history remains independent: clearing history, changing its limit, and quitting do not delete vault entries. Saving or marking an item sensitive removes matching values from current session history; subsequent capture skips matches against sensitive entries already loaded in memory. Unmarked and not-yet-loaded values can still be captured. This page's Copy writes to the clipboard without pasting; the separate quick-paste picker is defined in `key-vault-quick-paste.md`. Delete… requires a native confirmation sheet using the safe item name and explaining permanent removal from Key Vault and unchanged clipboard/history. Return and Escape cancel; deletion requires explicit activation.

Sensitive rows, picker entries, accessibility labels, and deletion confirmations show only the visible name or “Sensitive item,” never the content. Search matches sensitive names only, even while their preview is revealed. Names are not masked. Reveal explicitly shows the preview; Hide, selecting another item, switching tools, app deactivation, or 30 seconds conceals it again. Copy and Paste do not require Reveal, Touch ID, or a password. Describe this as visual privacy, without claiming authentication or additional encryption.

Sensitive Copy and quick paste add a concealed clipboard marker and clear after 30 seconds, or on normal quit, only if the clipboard still contains the unchanged Mac Tools-owned copy. Do not erase a replacement clipboard value. Other apps may ignore markers or retain copies they read; no claim of deleting those copies is made.

Keep up to 500 saved items and 20 MiB. Refuse saves over a limit without automatically evicting entries. Save locally using AES-GCM at `~/Library/Application Support/MacTools/KeyVault/vault.enc`, with the encryption key in macOS Keychain. Encrypt names and sensitivity flags with the content; old entries lacking metadata remain nonsensitive. Names allow at most 200 characters and 800 UTF-8 bytes. No plaintext fallback. Show Keychain, decryption, load, and save failures, with a loading Retry action. Do not claim password-manager authentication, Touch ID, or a lock feature.

Read encrypted payload schema versions 1 and 2, but save version 2 while retaining the `MTKV1` header and encryption context. Earlier version-1 builds must reject a newly saved vault rather than silently dropping sensitivity metadata. Existing version-1 vaults remain readable, with missing metadata defaulted to unnamed and nonsensitive.

Use accessible names and native tooltips for icon controls. Keep errors and delete consequences visible; secondary storage and masking explanation belongs in shared HelpTip. Preserve selection, loading, unavailable, no-results, and empty states. Demo includes a fictional named sensitive item, supports Reveal/Hide and sample metadata changes in memory, and never reads or writes disk, Keychain, or the host clipboard.

## Source and evidence
`KeyVaultView.swift`, `KeyVaultModel.swift`, `Core/KeyVault.swift`, `ClipboardHistoryView.swift`, `AppShellView.swift`, and `MacToolsApp.swift` define behavior. `.impeccable/review/SETTINGS-VAULT-REVIEW.md` records the earlier bounded review; it predates Sensitive, metadata sheets, masking, and conditional clipboard clearing, so it does not validate those additions. New build and review evidence are pending.

Latest sensitivity evidence: `.impeccable/review/SENSITIVE-VAULT-REVIEW.md`, including final light/dark masking, Details, fictional Reveal, picker captures, 85 focused passing tests, and review limits.
