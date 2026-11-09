import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// The process table's host: a standard `NSOutlineView` inside the standard `NSScrollView`
/// (WIN-04, D-10, D-14).
///
/// It replaced SwiftUI's `Table` after the day-one fitness check (plan 03-10, Rule 4, owner choice
/// A): `DisclosureTableRow` with no children still reports an expandable item, and the rows builder
/// cannot choose a plain row for a leaf, so every one of the ~500 leaf rows grew a disclosure
/// triangle. `NSOutlineView` asks `isItemExpandable` per item, and it gives the expansion and
/// selection a programmatic handle that search (D-13) and the "and N more…" deep link (D-01) need.
///
/// The host is view-agnostic about data: it draws the rows `ProcessTableModel` hands it, in that
/// order, and never sorts. Nothing here draws a background, a blur or a custom selection; the
/// system supplies the header, the alternating rows, the selection and the disclosure triangles.
///
/// A refresh keeps the user's place: expansion and selection are re-applied from the model, the
/// scroll offset is restored, and when only numbers changed just the visible changed rows redraw.
struct ProcessOutlineView: NSViewRepresentable {
    let model: ProcessTableModel
    /// The root rows in display order, each with every helper as a child.
    let rows: [ProcessTableRow]
    /// The column the order and the number emphasis follow, and its direction.
    let active: ProcessTableColumn
    let activeAscending: Bool
    let text: MetricText

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = ProcessOutline()
        outline.onCancel = { [weak model] in model?.clearSelection() }
        outline.onMenu = { [weak coordinator] id in coordinator?.contextMenu(for: id) }
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The columns are laid out edge to edge: the default 17 pt between columns would push the
        // five of them past the 900 pt window minimum (UI-SPEC sums the widths without it). The
        // cells carry their own padding instead.
        outline.intercellSpacing = NSSize(width: 0, height: outline.intercellSpacing.height)
        outline.setAccessibilityLabel(String(localized: "Processes"))

        let name = Self.column(.name, title: String(localized: "Name"), width: nil, ascending: true)
        let cpu = Self.column(.cpu, title: String(localized: "CPU"), width: 72, ascending: false)
        let memory = Self.column(.memory, title: String(localized: "Memory"), width: 88, ascending: false)
        let diskRead = Self.column(
            .diskRead, title: String(localized: "Disk Read"), width: 140, ascending: false)
        let diskWrite = Self.column(
            .diskWrite, title: String(localized: "Disk Write"), width: 140, ascending: false)
        for column in [name, cpu, memory, diskRead, diskWrite] { outline.addTableColumn(column) }
        outline.outlineTableColumn = name

        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline

        let scrollView = TableScrollView()
        scrollView.onPointer = { [weak model] inside in model?.setPointerInTable(inside) }
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.apply(rows: rows, active: active, ascending: activeAscending)
    }

    /// One fixed-width number column (or the flexible Name column) with its sortable header. The
    /// prototype's direction is what the first click on the header applies: Name A to Z, numbers
    /// biggest first (D-12).
    private static func column(
        _ kind: ProcessTableColumn, title: String, width: CGFloat?, ascending: Bool
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(kind.rawValue))
        column.title = title
        column.sortDescriptorPrototype = NSSortDescriptor(key: kind.rawValue, ascending: ascending)
        if let width {
            column.minWidth = width
            column.maxWidth = width
            column.width = width
            column.resizingMask = []
            column.headerCell.alignment = .right
        } else {
            column.minWidth = 200
            column.width = 200
            column.resizingMask = .autoresizingMask
        }
        return column
    }

    // MARK: Coordinator

    /// An outline item. One object per row id for the whole window session, so the outline keeps
    /// its expansion and selection by identity across reloads (RESEARCH Pitfall 7).
    final class Node: NSObject {
        let id: String
        var row: ProcessTableRow
        var children: [Node] = []

        init(row: ProcessTableRow) {
            id = row.id
            self.row = row
        }
    }

    private struct Structure: Equatable {
        var id: String
        var children: [String]
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: ProcessTableModel
        weak var outline: NSOutlineView?
        weak var scrollView: NSScrollView?
        var text = MetricText(locale: .current)

        private var roots: [Node] = []
        private var nodes: [String: Node] = [:]
        private var structure: [Structure] = []
        private var lastActive: ProcessTableColumn?
        private var lastAscending: Bool?
        /// True while this host changes the outline itself, so its own callbacks are not mistaken
        /// for the user's and never write to the model during a view update.
        private var isApplying = false

        init(model: ProcessTableModel) {
            self.model = model
        }

        // MARK: Applying a refresh

        func apply(rows: [ProcessTableRow], active: ProcessTableColumn, ascending: Bool) {
            guard let outline, let scrollView else { return }
            isApplying = true
            defer { isApplying = false }

            var live: [String: Node] = [:]
            var dirty: [Node] = []
            func resolve(_ row: ProcessTableRow) -> Node {
                if let known = live[row.id] { return known }
                let node: Node
                if let existing = nodes[row.id] {
                    node = existing
                    if existing.row != row {
                        existing.row = row
                        dirty.append(existing)
                    }
                } else {
                    node = Node(row: row)
                }
                live[row.id] = node
                return node
            }

            var newRoots: [Node] = []
            var newStructure: [Structure] = []
            newRoots.reserveCapacity(rows.count)
            for row in rows {
                let node = resolve(row)
                node.children = row.children.map(resolve)
                newRoots.append(node)
                newStructure.append(Structure(id: row.id, children: row.children.map(\.id)))
            }
            nodes = live
            roots = newRoots

            // The header indicator follows the effective sort, not only the user's choice.
            if outline.sortDescriptors.first?.key != active.rawValue
                || outline.sortDescriptors.first?.ascending != ascending
            {
                outline.sortDescriptors = [NSSortDescriptor(key: active.rawValue, ascending: ascending)]
            }

            let oldStructure = structure
            let reordered = newStructure != structure
            structure = newStructure
            let activeChanged = lastActive != active
            let directionChanged = lastAscending != nil && lastAscending != ascending
            lastActive = active
            lastAscending = ascending
            let clip = scrollView.contentView
            if reordered {
                // Rows came, went or moved. The numbers of the rows on screen are refreshed first, then
                // the change animates as removals, moves and insertions keyed by identity (0.35 s, none
                // under Reduce Motion). A new sort, a first build or a big upheaval reloads at once.
                let animated =
                    !activeChanged && !directionChanged && !oldStructure.isEmpty
                    && animate(from: oldStructure, to: newStructure, dirty: dirty, in: outline)
                if animated {
                    reconcileExpansion(in: outline)
                } else {
                    // Reload once, then put expansion, selection and the scroll offset back so the
                    // user's place never changes.
                    let origin = clip.bounds.origin
                    outline.reloadData()
                    reconcileExpansion(in: outline)
                    let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
                    clip.scroll(to: target)
                    scrollView.reflectScrolledClipView(clip)
                }
            } else {
                reconcileExpansion(in: outline)
                if activeChanged {
                    // The emphasised column changed (the first CPU reading): redraw what is on screen.
                    let visible = outline.rows(in: outline.visibleRect)
                    if visible.length > 0 {
                        outline.reloadData(
                            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                            columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
                    }
                } else {
                    redrawVisible(dirty, in: outline)
                }
            }
            reconcileSelection(in: outline)
            consumeScrollTarget(in: outline)
        }

        // MARK: Scrolling a group into view (the "and N more…" deep link, D-01, D-03)

        /// A group the model asked to show (`ProcessTableModel.focus`) is scrolled to the middle of
        /// the table. The model's expansion and selection were applied just before this, so the row
        /// is there and highlighted by the time it moves.
        private func consumeScrollTarget(in outline: NSOutlineView) {
            guard let id = model.scrollTarget else { return }
            model.scrollTarget = nil
            guard nodes[id] != nil else { return }
            center(id: id, attempt: 0)
            #if DEBUG
            logFocus(id: id)
            #endif
        }

        /// Puts the row in the middle of the visible area. On the very first layout the clip view has
        /// no height yet, so it tries again for up to a second.
        private func center(id: String, attempt: Int) {
            guard let outline, let scrollView, let node = nodes[id] else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            let clip = scrollView.contentView
            guard clip.bounds.height >= 1 else {
                guard attempt < 10 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.center(id: id, attempt: attempt + 1) }
                }
                return
            }
            let rect = outline.rect(ofRow: row)
            let wanted = NSRect(
                x: clip.bounds.origin.x, y: rect.midY - clip.bounds.height / 2,
                width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
            scrollView.reflectScrolledClipView(clip)
        }

        #if DEBUG
        /// Half a second after a deep link, says whether the group is there, open, selected and on
        /// screen. When it is not on screen, falls back to the table's own `scrollRowToVisible`
        /// (RESEARCH assumption A5) and measures again; `fallback=1` records that it was needed.
        private func logFocus(id: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let outline = self.outline, let scrollView = self.scrollView else { return }
                    guard let node = self.nodes[id] else {
                        DebugHooks.log("table focus found=0 expanded=0 selected=0 inview=0 fallback=0")
                        return
                    }
                    var fallback = 0
                    var row = outline.row(forItem: node)
                    if row >= 0, !Self.isInView(row: row, outline: outline, scrollView: scrollView) {
                        outline.scrollRowToVisible(row)
                        fallback = 1
                    }
                    row = outline.row(forItem: node)
                    let inview = row >= 0 && Self.isInView(row: row, outline: outline, scrollView: scrollView)
                    let selected = row >= 0 && outline.selectedRowIndexes.contains(row)
                    DebugHooks.log(
                        "table focus found=1 expanded=\(outline.isItemExpanded(node) ? 1 : 0)"
                            + " selected=\(selected ? 1 : 0) inview=\(inview ? 1 : 0) fallback=\(fallback)")
                }
            }
        }

        /// The whole row is inside the part of the table not hidden under the toolbar.
        private static func isInView(row: Int, outline: NSOutlineView, scrollView: NSScrollView) -> Bool {
            var visible = outline.visibleRect
            let top = scrollView.contentInsets.top
            visible.origin.y += top
            visible.size.height -= top
            return visible.contains(outline.rect(ofRow: row))
        }
        #endif

        /// Redraws the rows on screen whose numbers changed, without touching the others.
        private func redrawVisible(_ dirty: [Node], in outline: NSOutlineView) {
            let visible = outline.rows(in: outline.visibleRect)
            var indexes = IndexSet()
            for node in dirty {
                let index = outline.row(forItem: node)
                if index >= visible.location, index < visible.location + visible.length { indexes.insert(index) }
            }
            if !indexes.isEmpty {
                outline.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
            }
        }

        /// The animated update: the outline's own remove, move and insert, in one batch with a 0.35 s
        /// smooth timing, so a row keeps its identity (selection, expansion, scroll) while it moves.
        /// Returns false, having changed nothing, when the change is not worth animating: Reduce Motion,
        /// or more than `maximumAnimatedOperations` rows involved (a search, a big re-rank).
        private func animate(from old: [Structure], to new: [Structure], dirty: [Node], in outline: NSOutlineView) -> Bool {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
            // A second change while the first is still moving (a freeze released right at a reading)
            // reloads instead of stacking batches on a table that is mid-animation.
            guard ProcessInfo.processInfo.systemUptime >= animationEnd else { return false }
            let rootDiff = RowDiff.between(old: old.map(\.id), new: new.map(\.id))

            // Roots in both lists whose helpers changed: an open group animates its helpers too; a
            // closed one, or one that gained or lost its triangle, just reloads that item.
            let oldChildren = Dictionary(old.map { ($0.id, $0.children) }, uniquingKeysWith: { first, _ in first })
            var childDiffs: [(parent: Node, diff: RowDiff)] = []
            var reloaded: [Node] = []
            for entry in new {
                guard let before = oldChildren[entry.id], before != entry.children, let node = nodes[entry.id] else { continue }
                if before.isEmpty || entry.children.isEmpty || !outline.isItemExpanded(node) {
                    reloaded.append(node)
                } else {
                    childDiffs.append((node, RowDiff.between(old: before, new: entry.children)))
                }
            }
            let total = rootDiff.operationCount + childDiffs.reduce(0) { $0 + $1.diff.operationCount } + reloaded.count
            guard total <= Self.maximumAnimatedOperations else { return false }

            // Numbers first, at the rows' current places, so a moving row already shows fresh values.
            redrawVisible(dirty, in: outline)

            func run(_ diff: RowDiff, parent: Node?) {
                if !diff.removed.isEmpty {
                    outline.removeItems(at: diff.removed, inParent: parent, withAnimation: .effectFade)
                }
                for move in diff.moves {
                    outline.moveItem(at: move.from, inParent: parent, to: move.to, inParent: parent)
                }
                if !diff.inserted.isEmpty {
                    outline.insertItems(at: diff.inserted, inParent: parent, withAnimation: .effectFade)
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                outline.beginUpdates()
                run(rootDiff, parent: nil)
                for (parent, diff) in childDiffs { run(diff, parent: parent) }
                outline.endUpdates()
            }
            animationEnd = ProcessInfo.processInfo.systemUptime + Self.animationDuration + 0.1
            for node in reloaded { outline.reloadItem(node, reloadChildren: true) }
            #if DEBUG
            logAnimation(rootDiff: rootDiff, helperOperations: childDiffs.reduce(0) { $0 + $1.diff.operationCount })
            #endif
            return true
        }

        /// When the last animated batch is done moving (`systemUptime`).
        private var animationEnd: TimeInterval = 0
        private static let animationDuration: TimeInterval = 0.35
        private static let maximumAnimatedOperations = 60

        #if DEBUG
        /// `table animate moves=<n> inserts=<n> removes=<n> helpers=<n>` for each animated update, and
        /// `table animate consistent=<0|1>` once it has settled: the outline's root order is the
        /// model's. A mismatch would mean the animated path drifted from the rows it was given.
        private func logAnimation(rootDiff: RowDiff, helperOperations: Int) {
            DebugHooks.log(
                "table animate moves=\(rootDiff.moves.count) inserts=\(rootDiff.inserted.count)"
                    + " removes=\(rootDiff.removed.count) helpers=\(helperOperations)")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let outline = self.outline else { return }
                    let expected = self.roots.map(\.id)
                    var actual: [String] = []
                    for index in 0..<outline.numberOfRows {
                        if let node = outline.item(atRow: index) as? Node, outline.level(forItem: node) == 0 {
                            actual.append(node.id)
                        }
                    }
                    DebugHooks.log("table animate consistent=\(actual == expected ? 1 : 0)")
                }
            }
        }
        #endif

        private func reconcileExpansion(in outline: NSOutlineView) {
            for node in roots where !node.children.isEmpty {
                let open = model.isOpen(node.id)
                guard open != outline.isItemExpanded(node) else { continue }
                if open { outline.expandItem(node) } else { outline.collapseItem(node) }
            }
        }

        private func reconcileSelection(in outline: NSOutlineView) {
            var wanted = IndexSet()
            for id in model.selection {
                if let node = nodes[id] {
                    let index = outline.row(forItem: node)
                    if index >= 0 { wanted.insert(index) }
                }
            }
            if outline.selectedRowIndexes != wanted {
                outline.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return roots[index] }
            return node.children[index]
        }

        /// Only a group with helpers is expandable; a leaf never shows a disclosure triangle.
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return !node.children.isEmpty
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let identifier = tableColumn?.identifier,
                let column = ProcessTableColumn(rawValue: identifier.rawValue)
            else { return nil }
            let row = node.row
            switch column {
            case .name:
                let cell =
                    outlineView.makeView(withIdentifier: NameCellView.identifier, owner: nil) as? NameCellView
                    ?? NameCellView()
                cell.configure(row: row) { [weak self] in self?.model.presentForceQuit(row.id) }
                return cell
            case .cpu:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.processCPU(row.cpuPercent),
                    active: lastActive == .cpu, row: row, quittingText: true)
            case .memory:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.processMemory(row.footprintBytes),
                    active: lastActive == .memory, row: row)
            case .diskRead:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.rate(row.diskReadPerSec),
                    active: lastActive == .diskRead, help: Self.diskHelp(for: row), row: row)
            case .diskWrite:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.rate(row.diskWritePerSec),
                    active: lastActive == .diskWrite, help: Self.diskHelp(for: row), row: row)
            }
        }

        /// The explanation under a quiet "—" in the disk columns of another user's or root's row:
        /// macOS's top has no per-process I/O, so Metr says so instead of showing a zero (D-11).
        private static func diskHelp(for row: ProcessTableRow) -> String? {
            row.isOwn ? nil : String(localized: "Disk activity isn't available for system processes.")
        }

        /// `quittingText` marks the CPU cell, which reads "Quitting…" while the row's app closes (D-15).
        /// Every cell of a working row is dimmed to half, so the whole row reads as on its way out.
        private func numberCell(
            in outlineView: NSOutlineView, identifier: NSUserInterfaceItemIdentifier, text: String, active: Bool,
            help: String? = nil, row: ProcessTableRow, quittingText: Bool = false
        ) -> NSView {
            let cell =
                outlineView.makeView(withIdentifier: identifier, owner: nil) as? NumberCellView
                ?? NumberCellView(identifier: identifier)
            cell.configure(
                text: text, active: active, help: help, working: row.isWorking, showsQuitting: quittingText)
            return cell
        }

        // MARK: Context menu (D-15)

        /// The right-click menu of a row: the same items as the toolbar control, text only. A row that
        /// may not be acted on keeps its items greyed out, then a divider and the reason (PROC-07, D-17).
        func contextMenu(for id: String) -> NSMenu? {
            guard let description = model.actionMenu(for: id), !description.items.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in description.items {
                let entry = ClosureMenuItem(title: item.title) { [weak self] in
                    self?.model.perform(item.kind, on: id)
                }
                entry.isEnabled = description.enabled
                menu.addItem(entry)
            }
            if let reason = description.reason {
                menu.addItem(.separator())
                let line = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
            return menu
        }

        // MARK: VoiceOver (UI-SPEC Keyboard)

        /// One row view per row, which VoiceOver reads as a single element and offers custom actions on.
        /// Both are computed only when VoiceOver asks, so nothing here costs anything while it is off.
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let node = item as? Node else { return nil }
            let view =
                outlineView.makeView(withIdentifier: ProcessRowView.identifier, owner: nil) as? ProcessRowView
                ?? ProcessRowView()
            view.identifier = ProcessRowView.identifier
            view.node = node
            view.coordinator = self
            return view
        }

        /// "<Name>, <CPU> percent CPU, <memory> memory, <read> read, <write> write", with "not available" for
        /// an unknown value, "System process" on system rows (or the reason a row offers nothing), and
        /// "<n> helper processes, collapsed / expanded" on groups.
        func spokenLabel(for node: Node) -> String {
            let row = node.row
            if row.isWorking { return row.name + ", " + String(localized: "Quitting…") }
            if row.offersForceQuit { return String(localized: "\(row.name) didn't quit. It may be waiting for you.") }
            let missing = String(localized: "not available")
            func spoken(_ text: String) -> String { text == "\u{2014}" ? missing : text }
            let cpu =
                row.cpuPercent == nil
                ? missing
                : text.processCPU(row.cpuPercent).replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            let memory = spoken(text.processMemory(row.footprintBytes))
            let read = spoken(text.rate(row.diskReadPerSec))
            let write = spoken(text.rate(row.diskWritePerSec))
            var parts = [
                String(localized: "\(row.name), \(cpu) percent CPU, \(memory) memory, \(read) read, \(write) write")
            ]
            if row.helperCount > 0 {
                parts.append(String(localized: "\(row.helperCount) helper processes"))
                let open = outline?.isItemExpanded(node) ?? false
                parts.append(open ? String(localized: "expanded") : String(localized: "collapsed"))
            }
            if row.kind == .system { parts.append(String(localized: "System process")) }
            if case .disabled(let reason) = row.availability, !parts.contains(reason.menuText) {
                parts.append(reason.menuText)
            }
            return parts.joined(separator: ", ")
        }

        /// Expand or Collapse on a group, and Quit and Force Quit only on a row the guard allows and that
        /// is not already working. A protected row exposes neither, instead of an action that does nothing
        /// (PROC-07, T-03-30).
        func customActions(for node: Node) -> [NSAccessibilityCustomAction] {
            let row = node.row
            var list: [NSAccessibilityCustomAction] = []
            if row.helperCount > 0 || !node.children.isEmpty {
                let open = outline?.isItemExpanded(node) ?? false
                let name = open ? String(localized: "Collapse \(row.name)") : String(localized: "Expand \(row.name)")
                list.append(
                    NSAccessibilityCustomAction(name: name) { [weak self, weak node] in
                        guard let self, let node, let outline = self.outline else { return false }
                        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
                        return true
                    })
            }
            guard let menu = model.actionMenu(for: row.id), menu.enabled else { return list }
            for item in menu.items {
                let name: String
                switch item.kind {
                case .quit: name = String(localized: "Quit")
                case .forceQuit: name = String(localized: "Force Quit…")
                case .forceQuitProcess: name = String(localized: "Force Quit Process…")
                }
                let id = row.id
                list.append(
                    NSAccessibilityCustomAction(name: name) { [weak self] in
                        self?.model.perform(item.kind, on: id)
                        return true
                    })
            }
            return list
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isApplying, let node = notification.userInfo?["NSObject"] as? Node else { return }
            model.userSetExpanded(node.id, open: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isApplying, let node = notification.userInfo?["NSObject"] as? Node else { return }
            model.userSetExpanded(node.id, open: false)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let outline else { return }
            let ids = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.id }
            model.selection = Set(ids)
        }

        /// A header click: the first click on a column applies the prototype's direction, a second
        /// reverses it. The model re-sorts at once (D-12).
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let first = outlineView.sortDescriptors.first, let key = first.key,
                let column = ProcessTableColumn(rawValue: key)
            else { return }
            model.setSort(column, ascending: first.ascending)
        }
    }
}

// MARK: Host views

/// The outline, with Esc: it steps back one level by clearing the selection, which also ends the
/// freeze (UI-SPEC Keyboard). A focused search field clears its own text first, natively.
private final class ProcessOutline: NSOutlineView {
    var onCancel: (() -> Void)?
    /// Builds the context menu of a row by id; nil draws no menu.
    var onMenu: ((String) -> NSMenu?)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Right-click on a row selects it first, as Finder does, so the toolbar control, the freeze and
    /// the menu all name the same row. Empty space has no menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? ProcessOutlineView.Node else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return onMenu?(node.id)
    }
}

/// A table row that VoiceOver reads as one element, labelled with the whole reading, and that carries the
/// row's custom actions. Both are answered on demand from the row's current data, so a row that was
/// refreshed in place is never read stale, and nothing is built while VoiceOver is off.
private final class ProcessRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("process.row")

    weak var node: ProcessOutlineView.Node?
    weak var coordinator: ProcessOutlineView.Coordinator?

    override func accessibilityLabel() -> String? {
        guard let node, let coordinator else { return super.accessibilityLabel() }
        return coordinator.spokenLabel(for: node)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let node, let coordinator else { return nil }
        return coordinator.customActions(for: node)
    }

    /// The cells' texts and the disclosure triangle are folded into the row's own reading; the actions
    /// above replace the triangle and the Force Quit… button for VoiceOver.
    override func accessibilityChildren() -> [Any]? { [] }
}

/// A menu item that runs a closure. It is its own target, so the menu needs no responder chain.
private nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() {
        let run = handler
        MainActor.assumeIsolated { run() }
    }
}

/// The scroll view, reporting the pointer entering and leaving the table so the order can hold
/// still under it (D-16). An AppKit tracking area over the visible rect: reliable for an AppKit
/// host, where a SwiftUI hover would depend on the hosting view's own tracking.
private final class TableScrollView: NSScrollView {
    var onPointer: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointer?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A table that leaves the window (the section changed, the window closed) is no longer hovered.
        if window == nil { onPointer?(false) }
    }
}

// MARK: Cells

/// A borderless text button, 11 pt secondary, primary under the pointer (D-15). It is the Force Quit…
/// offer of a row whose app did not quit; it only opens the confirmation sheet.
private final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    private var title_ = ""
    private var hovered = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .default
        lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setCaption(_ text: String) {
        title_ = text
        redraw()
    }

    private func redraw() {
        attributedTitle = NSAttributedString(
            string: title_,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: hovered ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        redraw()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        redraw()
    }
}

/// Icon (20 pt) · 8 · name (13 pt, tail truncation) · 4 · lock on system rows · 4 · a small spinner
/// while the app closes. The full name and the PID are in the tooltip. A helper's name is secondary
/// so the apps read first.
private final class NameCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("process.name")

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let lockView = NSImageView()
    private let lockWidth: NSLayoutConstraint
    private let lockGap: NSLayoutConstraint
    private let spinner = NSProgressIndicator()
    private let spinnerWidth: NSLayoutConstraint
    private let spinnerGap: NSLayoutConstraint
    private let forceQuitButton = HoverButton()
    private let forceQuitWidth: NSLayoutConstraint
    private let forceQuitGap: NSLayoutConstraint
    /// What the trailing Force Quit… does; set on every configure.
    private var onForceQuit: (() -> Void)?

    private static let lockImage: NSImage? = {
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    }()

    init() {
        let label = self.label
        let lock = self.lockView
        lockWidth = lock.widthAnchor.constraint(equalToConstant: 0)
        lockGap = lock.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 0)
        let spinner = self.spinner
        spinnerWidth = spinner.widthAnchor.constraint(equalToConstant: 0)
        spinnerGap = spinner.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 0)
        let button = self.forceQuitButton
        forceQuitWidth = button.widthAnchor.constraint(equalToConstant: 0)
        forceQuitGap = button.leadingAnchor.constraint(greaterThanOrEqualTo: spinner.trailingAnchor, constant: 0)
        super.init(frame: .zero)
        identifier = Self.identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lock.translatesAutoresizingMaskIntoConstraints = false
        lock.image = Self.lockImage
        lock.contentTintColor = .secondaryLabelColor
        lock.setContentCompressionResistancePriority(.required, for: .horizontal)
        lock.setAccessibilityElement(false)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(label)
        addSubview(lock)
        addSubview(spinner)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(forceQuitClicked)
        button.isHidden = true
        addSubview(button)
        imageView = iconView
        textField = label

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            lockGap,
            lockWidth,
            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinnerGap,
            spinnerWidth,
            spinner.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            forceQuitGap,
            forceQuitWidth,
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func forceQuitClicked() {
        onForceQuit?()
    }

    func configure(row: ProcessTableRow, onForceQuit: @escaping () -> Void) {
        self.onForceQuit = onForceQuit
        iconView.image = row.icon
        label.stringValue = row.name
        label.textColor = row.isHelper ? .secondaryLabelColor : .labelColor
        let locked = row.kind == .system
        lockView.isHidden = !locked
        lockWidth.constant = locked ? 12 : 0
        lockGap.constant = locked ? 4 : 0
        // A working row is dimmed to half with a small spinner after its name (D-15).
        let working = row.isWorking
        spinnerWidth.constant = working ? 16 : 0
        spinnerGap.constant = working ? 4 : 0
        if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        alphaValue = working ? 0.5 : 1
        // Quit did not end the app: a quiet Force Quit… in place of nothing, never an error banner (D-15).
        let offers = row.offersForceQuit
        forceQuitButton.isHidden = !offers
        forceQuitButton.toolTip = offers ? String(localized: "\(row.name) didn't quit. It may be waiting for you.") : nil
        if offers {
            forceQuitButton.setCaption(String(localized: "Force Quit…"))
            forceQuitWidth.constant = ceil(forceQuitButton.intrinsicContentSize.width)
            forceQuitGap.constant = 8
        } else {
            forceQuitWidth.constant = 0
            forceQuitGap.constant = 0
        }
        toolTip = row.help
    }
}

/// A trailing number that never truncates. The sorted column is semibold primary and the others
/// regular secondary, following the effective sort (UI-SPEC Typography).
private final class NumberCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    private static let regular = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let semibold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let quitting = NSFont.systemFont(ofSize: 11)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, active: Bool, help: String? = nil, working: Bool = false, showsQuitting: Bool = false) {
        alphaValue = working ? 0.5 : 1
        toolTip = help
        if working && showsQuitting {
            // The CPU number gives way to one quiet line while the app closes (D-15).
            label.stringValue = String(localized: "Quitting…")
            label.font = Self.quitting
            label.textColor = .secondaryLabelColor
            return
        }
        label.stringValue = text
        label.font = active ? Self.semibold : Self.regular
        label.textColor = active ? .labelColor : .secondaryLabelColor
    }
}
