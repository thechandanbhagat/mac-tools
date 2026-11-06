# System Monitor
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Read current system activity at a glance and optionally keep it available in the menu bar.
OWN-WORLD: Inherit semantic surfaces, system typography, SF Symbols, native dividers, contextual help, and the existing accent.
STORY: Open the tool; read live measurements; optionally enable Show Mac Tools in menu bar and Show CPU usage in Settings; refresh or reopen the app from the native menu.
FIRST VIEWPORT: Title/help, five plain metric rows, and concise update status.
FORM: A native measurement list and menu-bar extra, without decorative graphs, cards, or health scores.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Read local public system counters only; make no network requests. CPU is averaged across cores. Active memory includes active, wired, and compressed pages and differs from Activity Monitor’s Memory Used. Storage is home-volume capacity. Disk rates cover available physical storage drivers; network rates use active Ethernet/Wi-Fi/cellular interfaces and exclude loopback, bridges, and VPN tunnels.

Sample every two seconds only while the tool is visible in the main window or both the menu-bar item and CPU display are enabled. Rates require two compatible readings and reset after a long gap; unavailable values must not become invented zeroes. The two menu-bar preferences live on Settings, default to off, persist, and apply immediately. An existing enabled system-monitor menu preference migrates to an enabled app menu with CPU display. Hiding the app menu preserves the CPU choice. Enabling the app menu allows Mac Tools to remain running after its window closes. A login or explicit background launch enables the menu-bar item and shows no main window or Dock icon; CPU display remains off by default and retains an explicit choice. A saved initial System Monitor tool does not trigger hidden-page sampling. Its SF Symbol changes to a live CPU title and readings/Refresh are included when CPU display is enabled. The menu-bar Settings action opens the same main-window page as the sidebar and Command-comma. Stop sampling on quit. Label demo values clearly. Metric scope belongs in accessible contextual help.

## Source and evidence
`SystemMonitorView.swift`, `SystemMonitorModel.swift`, `Core/SystemMonitor.swift`, and `MacToolsApp.swift` define behavior. This brief records source scope; runtime and visual evidence is tracked separately under `.impeccable/review`.
