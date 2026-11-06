# Sensitive Key Vault items review

## Disposition
Ship at the reviewed scope. Independent finish review found no remaining material issues.

## Behavior
The user chose visual hiding until Reveal, without authentication. Name and Sensitive can be set when saving from Clipboard History or through Details. Sensitive values stay out of list rows, picker labels, accessibility labels, deletion previews, and search matching. Reveal shows only the selected preview; Hide, selection/tool changes, app deactivation, window closure, or 30 seconds conceal it again. Names remain visible.

Sensitive Copy and quick paste write payload and concealed marker atomically. An unchanged owned copy clears after 30 seconds or normal quit; replacement clipboard values are preserved. Successfully marking or saving sensitive content removes matching session-history entries, and later capture skips known sensitive values while they are loaded. Copy/Paste remain explicit actions available without Reveal.

## Evidence
- Final signed release build: `build/Mac Tools.app`.
- Final focused run: 85 tests passed (14 vault storage, 24 vault model, 20 clipboard history, 9 sensitive clipboard, 18 paste service).
- Full suite: 316 tests, 315 passed, one established MetadataScrubber failure at `AdditionalToolsTests.swift:115`.
- Encrypted payload schema 2 preserves sensitivity metadata against older builds. New code reads schemas 1 and 2; legacy decoding and the schema-2 write contract are tested.
- Native captures: `sensitive-vault-hidden.png`, `sensitive-vault-hidden-dark.png`, `sensitive-vault-revealed-demo.png`, `sensitive-vault-details.png`, `sensitive-vault-quick-paste.png`. Revealed contents are fictional demo data.
- Native Reveal showed the fictional value only in the preview. Delete confirmation used its safe name and concealed the underlying preview. Cancelling left all saved items intact.
- The final Details sheet has a visible and accessible Name field, Sensitive checkbox, consequence of removing matching history, and native Cancel/Save. Busy state disables Save with an additional caller guard.
- Saving a demo history item as sensitive changed history from four items to three and added a named, masked vault item. Picker labels used names without fictional sensitive values.
- Native checks used only demo data. The real vault, Keychain, host authentication, and clipboard were not accessed during these checks. Preview was quit afterward; the user's running app was left intact.

## Limits
Reveal is visual privacy, not authentication or additional encryption. Names remain visible. History filtering knows only loaded sensitive entries. Other apps can ignore clipboard markers or retain content they have already read. Clipboard expiry was verified with isolated adapters; live cross-app sensitive paste was not exercised. The existing metadata test failure remains unrelated.
