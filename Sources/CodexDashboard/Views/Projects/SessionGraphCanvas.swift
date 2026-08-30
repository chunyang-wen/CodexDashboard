import AppKit
import CodexMetricsCore
import SwiftUI

struct SessionGraphCanvas: NSViewRepresentable {
    let graph: SessionGraph
    @Binding var selectedNodeID: String?
    let fitRequestID: UUID
    let onOpenSession: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SessionGraphViewport {
        let view = SessionGraphViewport()
        view.onSelection = { context.coordinator.select($0) }
        view.onOpenSession = { context.coordinator.open($0) }
        return view
    }

    func updateNSView(_ view: SessionGraphViewport, context: Context) {
        context.coordinator.parent = self
        view.onSelection = { context.coordinator.select($0) }
        view.onOpenSession = { context.coordinator.open($0) }
        view.update(
            graph: graph,
            layout: SessionGraphLayout.make(graph: graph),
            selectedNodeID: selectedNodeID,
            fitRequestID: fitRequestID
        )
    }

    @MainActor final class Coordinator {
        var parent: SessionGraphCanvas

        init(_ parent: SessionGraphCanvas) { self.parent = parent }

        func select(_ id: String?) {
            guard parent.selectedNodeID != id else { return }
            parent.selectedNodeID = id
        }

        func open(_ id: String) { parent.onOpenSession(id) }
    }
}

final class SessionGraphViewport: NSView {
    var onSelection: ((String?) -> Void)?
    var onOpenSession: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let drawingView = SessionGraphDrawingView()
    private var graphSignature = ""
    private var lastFitRequestID: UUID?
    private var shouldFit = false
    private var shouldResetViewport = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.35
        scrollView.maxMagnification = 2
        scrollView.documentView = drawingView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        drawingView.onSelection = { [weak self] in self?.onSelection?($0) }
        drawingView.onOpenSession = { [weak self] in self?.onOpenSession?($0) }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if shouldResetViewport {
            shouldResetViewport = false
            resetViewport()
        } else if shouldFit {
            shouldFit = false
            fitGraph()
        }
    }

    func update(
        graph: SessionGraph,
        layout: SessionGraphLayoutResult,
        selectedNodeID: String?,
        fitRequestID: UUID
    ) {
        let signature = graph.nodes.map(\.id).joined(separator: "|") + "#" + graph.edges.map(\.id).joined(separator: "|")
        let graphChanged = signature != graphSignature
        graphSignature = signature
        drawingView.update(graph: graph, layout: layout, selectedNodeID: selectedNodeID)
        let documentSize = CGSize(
            width: max(layout.bounds.width, scrollView.contentSize.width),
            height: max(layout.bounds.height, scrollView.contentSize.height)
        )
        drawingView.frame = CGRect(origin: .zero, size: documentSize)
        if graphChanged {
            shouldFit = false
            shouldResetViewport = true
            lastFitRequestID = fitRequestID
            needsLayout = true
        } else if lastFitRequestID != fitRequestID {
            shouldFit = true
            lastFitRequestID = fitRequestID
            needsLayout = true
        }
    }

    private func resetViewport() {
        scrollView.magnification = 1
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func fitGraph() {
        let contentSize = scrollView.contentSize
        let documentSize = drawingView.frame.size
        guard documentSize.width > 0, documentSize.height > 0 else { return }
        let scale = min(
            1,
            max(scrollView.minMagnification, min(contentSize.width / documentSize.width, contentSize.height / documentSize.height) * 0.94)
        )
        scrollView.setMagnification(
            scale,
            centeredAt: CGPoint(x: documentSize.width / 2, y: documentSize.height / 2)
        )
    }
}

private final class SessionGraphDrawingView: NSView {
    var onSelection: ((String?) -> Void)?
    var onOpenSession: ((String) -> Void)?

    private var graph = SessionGraph.empty
    private var graphLayout = SessionGraphLayoutResult.empty
    private var selectedNodeID: String?
    private var pressedNodeID: String?
    private var dragStartInWindow: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var isDragging = false
    private var accessibilityNodes: [SessionGraphAccessibilityElement] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(graph: SessionGraph, layout: SessionGraphLayoutResult, selectedNodeID: String?) {
        self.graph = graph
        graphLayout = layout
        self.selectedNodeID = selectedNodeID
        needsDisplay = true
        rebuildAccessibilityNodes()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        drawEdges()
        if let unlinkedOriginY = graphLayout.unlinkedOriginY {
            NSString(string: "Unlinked").draw(
                at: CGPoint(x: 40, y: max(8, unlinkedOriginY - 28)),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
        for node in graph.nodes {
            guard let frame = graphLayout.nodeFrames[node.id], frame.intersects(dirtyRect) else { continue }
            drawNode(node, in: frame)
        }
    }

    private func drawEdges() {
        let frames = graphLayout.nodeFrames
        for edge in graph.edges where edge.kind == .spawn {
            guard let source = frames[edge.sourceID], let target = frames[edge.targetID] else { continue }
            let start = CGPoint(x: source.maxX, y: source.midY)
            let end = CGPoint(x: target.minX, y: target.midY)
            let controlOffset = max(28, abs(end.x - start.x) * 0.45)
            let path = NSBezierPath()
            path.move(to: start)
            path.curve(
                to: end,
                controlPoint1: CGPoint(x: start.x + controlOffset, y: start.y),
                controlPoint2: CGPoint(x: end.x - controlOffset, y: end.y)
            )
            path.lineWidth = selectedNodeID == edge.sourceID || selectedNodeID == edge.targetID ? 2 : 1.25
            if graphLayout.excludedEdgeIDs.contains(edge.id) { path.setLineDash([5, 4], count: 2, phase: 0) }
            NSColor.separatorColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }

    private func drawNode(_ node: SessionGraphNode, in frame: CGRect) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        let selected = node.id == selectedNodeID
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        if node.scope == .external { path.setLineDash([5, 3], count: 2, phase: 0) }
        path.stroke()

        let iconRect = CGRect(x: frame.minX + 12, y: frame.minY + 13, width: 18, height: 18)
        NSImage(systemSymbolName: iconName(for: node.kind), accessibilityDescription: nil)?.draw(in: iconRect)

        let textX = frame.minX + 40
        let textWidth = frame.width - 52
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: node.title).draw(
            in: CGRect(x: textX, y: frame.minY + 10, width: textWidth, height: 19),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let detail = [node.agentNickname, node.model].compactMap { $0 }.joined(separator: " · ")
        NSString(string: detail.isEmpty ? kindLabel(node.kind) : detail).draw(
            in: CGRect(x: textX, y: frame.minY + 31, width: textWidth, height: 17),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        NSString(string: node.scope == .external ? "External" : "No recorded status").draw(
            in: CGRect(x: textX, y: frame.minY + 49, width: textWidth, height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: node.scope == .external ? NSColor.systemOrange : NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartInWindow = event.locationInWindow
        dragStartOrigin = enclosingScrollView?.contentView.bounds.origin
        isDragging = false
        let nodeID = nodeID(at: convert(event.locationInWindow, from: nil))
        pressedNodeID = nodeID
        selectedNodeID = nodeID
        onSelection?(nodeID)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartInWindow, let dragStartOrigin, let clipView = enclosingScrollView?.contentView else { return }
        let delta = CGPoint(
            x: event.locationInWindow.x - dragStartInWindow.x,
            y: event.locationInWindow.y - dragStartInWindow.y
        )
        if abs(delta.x) + abs(delta.y) > 4 { isDragging = true }
        guard isDragging else { return }
        let proposed = CGRect(
            origin: CGPoint(x: dragStartOrigin.x - delta.x, y: dragStartOrigin.y + delta.y),
            size: clipView.bounds.size
        )
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedNodeID = nil
            dragStartInWindow = nil
            dragStartOrigin = nil
            isDragging = false
        }
        guard !isDragging,
              let pressedNodeID,
              nodeID(at: convert(event.locationInWindow, from: nil)) == pressedNodeID,
              canOpen(pressedNodeID) else { return }
        onOpenSession?(pressedNodeID)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if let selectedNodeID, canOpen(selectedNodeID) { onOpenSession?(selectedNodeID) }
        case 123: moveSelection(dx: -1, dy: 0)
        case 124: moveSelection(dx: 1, dy: 0)
        case 125: moveSelection(dx: 0, dy: 1)
        case 126: moveSelection(dx: 0, dy: -1)
        default: super.keyDown(with: event)
        }
    }

    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        guard !graph.nodes.isEmpty else { return }
        guard let selectedNodeID, let current = graphLayout.nodeFrames[selectedNodeID] else {
            select(graphLayout.linkedNodeIDs.first ?? graphLayout.unlinkedNodeIDs.first)
            return
        }
        let origin = CGPoint(x: current.midX, y: current.midY)
        let candidate = graphLayout.nodeFrames
            .filter { $0.key != selectedNodeID }
            .filter { _, frame in
                let deltaX = frame.midX - origin.x
                let deltaY = frame.midY - origin.y
                return (dx < 0 && deltaX < 0) || (dx > 0 && deltaX > 0)
                    || (dy < 0 && deltaY < 0) || (dy > 0 && deltaY > 0)
            }
            .min { lhs, rhs in
                directionalDistance(from: origin, to: lhs.value, dx: dx)
                    < directionalDistance(from: origin, to: rhs.value, dx: dx)
            }?.key
        if let candidate { select(candidate) }
    }

    private func directionalDistance(from origin: CGPoint, to frame: CGRect, dx: CGFloat) -> CGFloat {
        let deltaX = abs(frame.midX - origin.x)
        let deltaY = abs(frame.midY - origin.y)
        return dx == 0 ? deltaY * 10 + deltaX : deltaX * 10 + deltaY
    }

    private func select(_ id: String?) {
        selectedNodeID = id
        onSelection?(id)
        needsDisplay = true
        if let id, let frame = graphLayout.nodeFrames[id] { scrollToVisible(frame.insetBy(dx: -20, dy: -20)) }
    }

    private func nodeID(at point: CGPoint) -> String? {
        graphLayout.nodeFrames.first { $0.value.contains(point) }?.key
    }

    private func canOpen(_ id: String) -> Bool {
        graph.nodes.first { $0.id == id }?.projectPath != nil
    }

    private func rebuildAccessibilityNodes() {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        accessibilityNodes = (graphLayout.linkedNodeIDs + graphLayout.unlinkedNodeIDs).compactMap { id in
            guard let node = nodesByID[id], let frame = graphLayout.nodeFrames[id] else { return nil }
            let element = SessionGraphAccessibilityElement()
            element.onPress = { [weak self] in
                self?.select(id)
                if self?.canOpen(id) == true { self?.onOpenSession?(id) }
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityLabel(node.title)
            element.setAccessibilityHelp(node.scope == .external ? "External session" : kindLabel(node.kind))
            element.setAccessibilityFrameInParentSpace(frame)
            return element
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Session graph")
        setAccessibilityChildren(accessibilityNodes)
    }

    private func iconName(for kind: SessionGraphNodeKind) -> String {
        switch kind {
        case .user: "person.crop.circle"
        case .subagent: "cpu"
        case .automation: "clock.arrow.2.circlepath"
        case .agentCreatedThread: "plus.bubble"
        case .unknown: "questionmark.circle"
        }
    }

    private func kindLabel(_ kind: SessionGraphNodeKind) -> String {
        switch kind {
        case .user: "Session"
        case .subagent: "Subagent"
        case .automation: "Automation"
        case .agentCreatedThread: "Agent-created session"
        case .unknown: "Unknown session"
        }
    }
}

private final class SessionGraphAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
