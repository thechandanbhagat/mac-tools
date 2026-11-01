# System Monitor
Mode: Operate. Extend the existing native Mac Tools visual system.

## Direction contract
THESIS: Read current system activity at a glance and optionally keep it available in the menu bar.
OWN-WORLD: Inherit semantic surfaces, system typography, SF Symbols, native dividers, contextual help, and the existing accent.
STORY: Open the tool; read live measurements; optionally enable Menu bar; refresh or reopen the app from the native menu.
FIRST VIEWPORT: Title/help, Menu bar checkbox, five plain metric rows, and concise update status.
FORM: A native measurement list and menu-bar extra, without decorative graphs, cards, or health scores.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Constraints
Read local public system counters only; make no network requests. CPU is averaged across cores. Active memory includes active, wired, and compressed pages and differs from Activity Monitor’s Memory Used. Storage is home-volume capacity. Disk rates cover available physical storage drivers; network rates use active Ethernet/Wi-Fi/cellular interfaces and exclude loopback, bridges, and VPN tunnels.

Sample every two seconds only while the tool is selected or the optional menu-bar item is enabled. Rates require two compatible readings and reset after a long gap; unavailable values must not become invented zeroes. The menu-bar preference persists and allows the app to remain running after its window closes. Stop sampling on quit. Label demo values clearly. Metric scope belongs in accessible contextual help.

## Source and evidence
`SystemMonitorView.swift`, `SystemMonitorModel.swift`, `Core/SystemMonitor.swift`, and `MacToolsApp.swift` define behavior. This brief records source scope; runtime and visual evidence is tracked separately under `.impeccable/review`.
