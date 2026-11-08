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
                cell.configure(row: row)
                return cell
            case .cpu:
                return numberCell(in: outlineView, identifier: identifier, text: text.processCPU(row.cpuPercent), active: lastActive == .cpu)
            case .memory:
                return numberCell(in: outlineView, identifier: identifier, text: text.processMemory(row.footprintBytes), active: lastActive == .memory)
            case .diskRead:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.rate(row.diskReadPerSec),
                    active: lastActive == .diskRead, help: Self.diskHelp(for: row))
            case .diskWrite:
                return numberCell(
                    in: outlineView, identifier: identifier, text: text.rate(row.diskWritePerSec),
                    active: lastActive == .diskWrite, help: Self.diskHelp(for: row))
            }
        }

        /// The explanation under a quiet "—" in the disk columns of another user's or root's row:
        /// macOS's top has no per-process I/O, so Metr says so instead of showing a zero (D-11).
        private static func diskHelp(for row: ProcessTableRow) -> String? {
            row.isOwn ? nil : String(localized: "Disk activity isn't available for system processes.")
        }

        private func numberCell(
            in outlineView: NSOutlineView, identifier: NSUserInterfaceItemIdentifier, text: String, active: Bool,
            help: String? = nil
        ) -> NSView {
            let cell =
                outlineView.makeView(withIdentifier: identifier, owner: nil) as? NumberCellView
                ?? NumberCellView(identifier: identifier)
            cell.configure(text: text, active: active, help: help)
            return cell
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

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
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

/// Icon (20 pt) · 8 · name (13 pt, tail truncation) · 4 · lock on system rows. The full name and the
/// PID are in the tooltip. A helper's name is secondary so the apps read first.
private final class NameCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("process.name")

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let lockView = NSImageView()
    private let lockWidth: NSLayoutConstraint
    private let lockGap: NSLayoutConstraint

    private static let lockImage: NSImage? = {
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    }()

    init() {
        let label = self.label
        let lock = self.lockView
        lockWidth = lock.widthAnchor.constraint(equalToConstant: 0)
        lockGap = lock.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 0)
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
        addSubview(iconView)
        addSubview(label)
        addSubview(lock)
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
            lock.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(row: ProcessTableRow) {
        iconView.image = row.icon
        label.stringValue = row.name
        label.textColor = row.isHelper ? .secondaryLabelColor : .labelColor
        let locked = row.kind == .system
        lockView.isHidden = !locked
        lockWidth.constant = locked ? 12 : 0
        lockGap.constant = locked ? 4 : 0
        toolTip = row.help
    }
}

/// A trailing number that never truncates. The sorted column is semibold primary and the others
/// regular secondary, following the effective sort (UI-SPEC Typography).
private final class NumberCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    private static let regular = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let semibold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

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

    func configure(text: String, active: Bool, help: String? = nil) {
        label.stringValue = text
        label.font = active ? Self.semibold : Self.regular
        label.textColor = active ? .labelColor : .secondaryLabelColor
        toolTip = help
    }
}
