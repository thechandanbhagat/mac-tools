# Key Vault quick-paste review

## Disposition

**ship** at the source and screenshot review scope. The finish reviewer reported no confirmed material findings. This report records the builder's native demo checks and automated results; it does not claim a verified physical global shortcut or successful insertion into another app.

## Native demo evidence

The final picker is a borderless, nonactivating native panel, 380pt wide, with adaptive height, native shadow, 12pt corners, and the existing light/dark palette. The Settings addition uses the existing grouped native form. No web design detector ran for native SwiftUI.

| Capture | Size | Observed state |
| --- | --- | --- |
| `key-vault-quick-paste-light.png` | 380 × 242 | Light picker with saved demo items. |
| `key-vault-quick-paste-dark.png` | 380 × 242 | Dark picker with saved demo items. |
| `key-vault-quick-paste-filtered.png` | 380 × 220 | Search-filtered picker at reduced height. |
| `quick-paste-settings.png` | 1120 × 790 | Settings with quick-paste controls. |

Builder-verified interactions: Tools → Quick Paste… opens the panel; searching for “notes” filters results; Down and Return select an item and display “Demo · Pasting disabled”; Escape closes the panel; light and dark appearances render. These checks use demo content and do not write the host clipboard or paste into another app. Accessibility permission was not granted or exercised.

## Shortcut probe and remaining limits

A separate disposable AppKit probe compiled the actual `VaultGlobalShortcut.swift` implementation and registered the shortcut without a reported error. Sending synthetic Control–Option–V through computer automation did **not** produce a callback. That result does not establish why dispatch was absent; physical/global shortcut dispatch remains **unverified**. The probe was closed and its absence was confirmed in the application inventory, releasing its registration.

Actual cross-app insertion was not verified. Manual checks still need to cover the physical shortcut, granting Accessibility access, focus restoration, and receiving-editor behavior. An emitted native paste event is not an acknowledgement that an editor inserted content; image insertion also depends on target support. Demo keyboard navigation is not evidence for these untested paths.

## Build and automated tests

The final bundle at `build/Mac Tools.app` built and passed signing verification. The focused run passed **40 tests**: 7 App Settings, 11 Key Vault model, 9 Key Vault persistence, and 13 paste-service tests. Paste-service tests use injected dependencies and do not post host input events.

The full suite ran **259 tests: 258 passed and one failed**. The failure remains `MetadataScrubberTests.testInspectAndScrubImageEXIFAndExtendedAttributes` at `Tests/MacToolsTests/AdditionalToolsTests.swift:115`, the previously reproduced baseline sandbox issue where the JPG `UTType` resolves to a dynamic type rather than `.image`. The full suite is not reported as passing.

## Documentation scope

README, PRODUCT, DESIGN, the design sidecar, and the Settings, Key Vault, and quick-paste surface briefs describe the default-on shortcut, its background lifetime, manual Accessibility setup, target checks, Copy fallback, and editor limitations. Earlier Settings/vault evidence remains historical and does not validate this new cross-app feature.
