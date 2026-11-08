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
        let outline = NSOutlineView()
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

        let scrollView = NSScrollView()
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

            let reordered = newStructure != structure
            structure = newStructure
            let activeChanged = lastActive != active
            lastActive = active
            let clip = scrollView.contentView
            if reordered {
                // Rows came, went or moved: reload once, then put expansion, selection and the
                // scroll offset back so the user's place never changes.
                let origin = clip.bounds.origin
                outline.reloadData()
                reconcileExpansion(in: outline)
                let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
                clip.scroll(to: target)
                scrollView.reflectScrolledClipView(clip)
            } else {
                reconcileExpansion(in: outline)
                let visible = outline.rows(in: outline.visibleRect)
                let columns = IndexSet(integersIn: 0..<outline.numberOfColumns)
                if activeChanged {
                    // The emphasised column changed (the first CPU reading): redraw what is on screen.
                    if visible.length > 0 {
                        outline.reloadData(
                            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                            columnIndexes: columns)
                    }
                } else {
                    var indexes = IndexSet()
                    for node in dirty {
                        let index = outline.row(forItem: node)
                        if index >= visible.location, index < visible.location + visible.length {
                            indexes.insert(index)
                        }
                    }
                    if !indexes.isEmpty { outline.reloadData(forRowIndexes: indexes, columnIndexes: columns) }
                }
            }
            reconcileSelection(in: outline)
        }

        private func reconcileExpansion(in outline: NSOutlineView) {
            for node in roots where !node.children.isEmpty {
                let open = model.expanded.contains(node.id)
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
            model.expanded.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isApplying, let node = notification.userInfo?["NSObject"] as? Node else { return }
            model.expanded.remove(node.id)
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
