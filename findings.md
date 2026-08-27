Findings:
- Removing Swift Charts rendering eliminates the large memory spike when switching tabs.
- Removing the Charts framework itself produced little additional improvement. The cost is therefore chart rendering/state, not merely linking the framework.
- Disabling session loading and session-row rendering did not eliminate the project expansion spike.
- Replacing the complete project tree with one synthetic expandable row eliminated it.
- Therefore, project expansion is causing SwiftUI to re-evaluate/layout/diff the full project tree. The disclosure animation alone is not the problem.
What we should do now:
1. Replace Swift Charts with lightweight AppKit-backed drawing views. Each chart should be one NSView drawing paths, bars, axes, and labels into a graphics context, avoiding a SwiftUI node for every mark.
2. Replace the Projects ScrollView/nested LazyVStack with NSOutlineView. It provides row reuse and updates only the expanded section. Keep session pagination so disk I/O and retained session data remain bounded.
3. Implement them separately and measure after each:
   - Charts first, because they affect several tabs.
   - Project outline second.
   - Preserve the current experiment build as the low-memory baseline.
4. Remove the experiment flags/placeholders only after both replacements match the existing functionality.
Expected impact: substantially lower transient memory and CPU during chart/tab updates and project expansion, with unchanged database I/O for charts and bounded I/O for project sessions. AppKit is justified here because both confirmed problems involve large SwiftUI render trees.
