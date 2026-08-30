import AppKit
import CodexMetricsCore
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
enum MenuBarQuotaIconRenderer {
    private static let alertLineWidth: CGFloat = 1.4
    private static let twoRowsCanvasWidth: CGFloat = 28

    struct AlertMarkers: Hashable {
        static let none = AlertMarkers(primary: nil, secondary: nil)

        let primary: Double?
        let secondary: Double?

        var isEmpty: Bool { primary == nil && secondary == nil }
    }

    struct Key: Hashable {
        let windows: [UsageQuotaWindow]
        let style: MenuBarQuotaIconStyle
        let alertMarkers: AlertMarkers
    }

    private static var cachedKey: Key?
    private static var cachedImage: NSImage?

    static func image(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertMarkers: AlertMarkers = .none
    ) -> NSImage {
        let key = Key(windows: windows, style: style, alertMarkers: alertMarkers)
        if let cachedImage, cachedKey == key {
            return cachedImage
        }
        let rendered = render(windows: windows, style: style, alertMarkers: alertMarkers)
        cachedKey = key
        cachedImage = rendered
        return rendered
    }

    private static func render(
        windows: [UsageQuotaWindow],
        style: MenuBarQuotaIconStyle,
        alertMarkers: AlertMarkers
    ) -> NSImage {
        let size = NSSize(width: style == .twoRows ? twoRowsCanvasWidth : 18, height: 18)
        let image = NSImage(size: size)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            image.isTemplate = true
            return image
        }
        representation.size = size
        image.addRepresentation(representation)

        let orderedWindows = windows.sorted { $0.windowMinutes > $1.windowMinutes }
        let primaryWindow = orderedWindows.first
        let secondaryWindow = orderedWindows.dropFirst().first
        let iconInk: NSColor = alertMarkers.isEmpty ? .black : .labelColor

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            switch style {
            case .rings: drawRings(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .droplet: drawDroplet(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .capsules: drawCapsules(primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, iconInk: iconInk)
            case .twoRows:
                drawTwoRows(
                    primaryWindow: primaryWindow,
                    secondaryWindow: secondaryWindow,
                    alertMarkers: alertMarkers,
                    iconInk: iconInk
                )
            }
            drawAlertMarkers(
                style: style,
                primaryWindow: primaryWindow,
                secondaryWindow: secondaryWindow,
                alertMarkers: alertMarkers
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = alertMarkers.isEmpty
        return image
    }

    private static func drawRings(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawRing(radius: 6.8, lineWidth: 2.4, window: primaryWindow, iconInk: iconInk)
        drawRing(radius: 3.2, lineWidth: 1.8, window: secondaryWindow, iconInk: iconInk)
    }

    private static func drawRing(radius: CGFloat, lineWidth: CGFloat, window: UsageQuotaWindow?, iconInk: NSColor) {
        let center = NSPoint(x: 9, y: 9)
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        iconInk.withAlphaComponent(window == nil ? 0.12 : 0.2).setStroke()
        track.stroke()

        guard let fraction = remainingFraction(for: window), fraction > 0 else { return }
        let progress: NSBezierPath
        if fraction >= 0.999 {
            progress = NSBezierPath(ovalIn: rect)
        } else {
            progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * fraction,
                clockwise: true
            )
        }
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .butt
        iconInk.setStroke()
        progress.stroke()
    }

    private static func drawDroplet(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        let left = dropletChamber(left: true)
        let right = dropletChamber(left: false)
        drawLiquid(in: left, bounds: NSRect(x: 1.7, y: 2, width: 6.65, height: 14), window: primaryWindow, iconInk: iconInk)
        drawLiquid(in: right, bounds: NSRect(x: 9.65, y: 2, width: 6.65, height: 14), window: secondaryWindow, iconInk: iconInk)
    }

    private static func dropletChamber(left: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        if left {
            path.move(to: NSPoint(x: 8.35, y: 16))
            path.curve(to: NSPoint(x: 1.7, y: 7), controlPoint1: NSPoint(x: 6.2, y: 13.8), controlPoint2: NSPoint(x: 1.7, y: 10.2))
            path.curve(to: NSPoint(x: 8.35, y: 2), controlPoint1: NSPoint(x: 1.7, y: 3.2), controlPoint2: NSPoint(x: 4.8, y: 2))
        } else {
            path.move(to: NSPoint(x: 9.65, y: 16))
            path.curve(to: NSPoint(x: 16.3, y: 7), controlPoint1: NSPoint(x: 11.8, y: 13.8), controlPoint2: NSPoint(x: 16.3, y: 10.2))
            path.curve(to: NSPoint(x: 9.65, y: 2), controlPoint1: NSPoint(x: 16.3, y: 3.2), controlPoint2: NSPoint(x: 13.2, y: 2))
        }
        path.close()
        return path
    }

    private static func drawLiquid(in chamber: NSBezierPath, bounds: NSRect, window: UsageQuotaWindow?, iconInk: NSColor) {
        iconInk.withAlphaComponent(0.1).setFill()
        chamber.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            chamber.addClip()
            iconInk.setFill()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * fraction)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        chamber.lineWidth = 1
        iconInk.withAlphaComponent(window == nil ? 0.3 : 0.72).setStroke()
        chamber.stroke()
    }

    private static func drawCapsules(primaryWindow: UsageQuotaWindow?, secondaryWindow: UsageQuotaWindow?, iconInk: NSColor) {
        drawCapsule(in: NSRect(x: 1.5, y: 9, width: 15, height: 6), window: primaryWindow, iconInk: iconInk)
        drawCapsule(in: NSRect(x: 1.5, y: 3, width: 15, height: 4), window: secondaryWindow, iconInk: iconInk)
    }

    private static func drawCapsule(in rect: NSRect, window: UsageQuotaWindow?, iconInk: NSColor) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        iconInk.withAlphaComponent(0.16).setFill()
        track.fill()
        if let fraction = remainingFraction(for: window), fraction > 0 {
            NSGraphicsContext.current?.cgContext.saveGState()
            track.addClip()
            iconInk.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)).fill()
            NSGraphicsContext.current?.cgContext.restoreGState()
        }
        let stroke = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: max(0, radius - 0.5),
            yRadius: max(0, radius - 0.5)
        )
        stroke.lineWidth = 1
        iconInk.withAlphaComponent(window == nil ? 0.3 : 0.48).setStroke()
        stroke.stroke()
    }

    private static func drawTwoRows(
        primaryWindow: UsageQuotaWindow?,
        secondaryWindow: UsageQuotaWindow?,
        alertMarkers: AlertMarkers,
        iconInk: NSColor
    ) {
        if let primaryWindow, let secondaryWindow {
            drawTwoRowsValue(for: primaryWindow, centerY: 13.5, alertRemainingPercent: alertMarkers.primary, iconInk: iconInk)
            drawTwoRowsValue(for: secondaryWindow, centerY: 4.5, alertRemainingPercent: alertMarkers.secondary, iconInk: iconInk)
        } else if let window = primaryWindow ?? secondaryWindow {
            drawTwoRowsValue(
                for: window,
                centerY: 9,
                alertRemainingPercent: primaryWindow == nil ? alertMarkers.secondary : alertMarkers.primary,
                iconInk: iconInk
            )
        } else {
            drawTwoRowsText("N/A", centerY: 9, iconInk: iconInk.withAlphaComponent(0.45))
        }
    }

    private static func drawTwoRowsValue(
        for window: UsageQuotaWindow,
        centerY: CGFloat,
        alertRemainingPercent: Double?,
        iconInk: NSColor
    ) {
        drawTwoRowsText(
            "\(Int(window.remainingPercent.rounded()))%",
            centerY: centerY,
            iconInk: alertRemainingPercent.map { window.remainingPercent <= $0 } == true ? .systemRed : iconInk
        )
    }

    private static func drawTwoRowsText(_ value: String, centerY: CGFloat, iconInk: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: iconInk
        ]
        let size = (value as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: twoRowsCanvasWidth / 2 - size.width / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height
        )
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }

    private static func drawAlertMarkers(
        style: MenuBarQuotaIconStyle,
        primaryWindow: UsageQuotaWindow?,
        secondaryWindow: UsageQuotaWindow?,
        alertMarkers: AlertMarkers
    ) {
        switch style {
        case .rings:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawRingAlertLine(radius: 6.8, ringWidth: 2.4, remainingPercent: alert)
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawRingAlertLine(radius: 3.2, ringWidth: 1.8, remainingPercent: alert)
            }
        case .droplet:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawAlertBar(y: alertY(alert), from: 1.5, to: 8.5, clippedTo: dropletChamber(left: true))
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawAlertBar(y: alertY(alert), from: 9.5, to: 16.5, clippedTo: dropletChamber(left: false))
            }
        case .capsules:
            if let alert = alertMarkers.primary, primaryWindow != nil {
                drawCapsuleAlertLine(remainingPercent: alert, y: 12, height: 5)
            }
            if let alert = alertMarkers.secondary, secondaryWindow != nil {
                drawCapsuleAlertLine(remainingPercent: alert, y: 5, height: 3)
            }
        case .twoRows:
            break
        }
    }

    private static func ringMarkerPoint(radius: CGFloat, remainingPercent: Double) -> NSPoint {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        let angle = CGFloat.pi / 2 - 2 * .pi * fraction
        return NSPoint(x: 9 + radius * cos(angle), y: 9 + radius * sin(angle))
    }

    private static func alertY(_ remainingPercent: Double) -> CGFloat {
        2 + 14 * CGFloat(min(100, max(0, remainingPercent)) / 100)
    }

    private static func capsuleMarkerPoint(remainingPercent: Double, y: CGFloat) -> NSPoint {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        return NSPoint(x: 1.5 + 15 * fraction, y: y)
    }

    private static func drawRingAlertLine(radius: CGFloat, ringWidth: CGFloat, remainingPercent: Double) {
        let fraction = CGFloat(min(100, max(0, remainingPercent)) / 100)
        let angle = CGFloat.pi / 2 - 2 * .pi * fraction
        let center = ringMarkerPoint(radius: radius, remainingPercent: remainingPercent)
        let radial = NSPoint(x: cos(angle), y: sin(angle))
        let halfLength = ringWidth / 2
        drawAlertLine(
            from: NSPoint(x: center.x - radial.x * halfLength, y: center.y - radial.y * halfLength),
            to: NSPoint(x: center.x + radial.x * halfLength, y: center.y + radial.y * halfLength),
            lineCapStyle: .butt
        )
    }

    private static func drawCapsuleAlertLine(remainingPercent: Double, y: CGFloat, height: CGFloat) {
        let point = capsuleMarkerPoint(remainingPercent: remainingPercent, y: y)
        drawAlertLine(
            from: NSPoint(x: point.x, y: point.y - height / 2),
            to: NSPoint(x: point.x, y: point.y + height / 2)
        )
    }

    private static func drawAlertLine(
        from start: NSPoint,
        to end: NSPoint,
        lineCapStyle: NSBezierPath.LineCapStyle = .round
    ) {
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineWidth = alertLineWidth
        line.lineCapStyle = lineCapStyle
        NSColor.systemRed.setStroke()
        line.stroke()
    }

    private static func drawAlertBar(y: CGFloat, from startX: CGFloat, to endX: CGFloat, clippedTo clip: NSBezierPath) {
        NSGraphicsContext.current?.cgContext.saveGState()
        clip.addClip()
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: startX, y: y))
        bar.line(to: NSPoint(x: endX, y: y))
        bar.lineWidth = alertLineWidth
        bar.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        bar.stroke()
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private static func remainingFraction(for window: UsageQuotaWindow?) -> CGFloat? {
        window.map { CGFloat(min(100, max(0, $0.remainingPercent)) / 100) }
    }
}

struct MenuBarQuotaIcon: View, Equatable {
    let windows: [UsageQuotaWindow]
    let style: MenuBarQuotaIconStyle
    var alertMarkers: MenuBarQuotaIconRenderer.AlertMarkers = .none

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(alertMarkers.isEmpty ? .template : .original)
            .interpolation(.none)
            .frame(width: 18, height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex quota")
            .accessibilityValue(accessibilityValue)
            .help(accessibilityValue)
    }

    private var statusImage: NSImage {
        MenuBarQuotaIconRenderer.image(
            windows: windows,
            style: style,
            alertMarkers: alertMarkers
        )
    }

    private var displayedWindows: [UsageQuotaWindow] {
        Array(windows.sorted { $0.windowMinutes > $1.windowMinutes }.prefix(2))
    }

    private var accessibilityValue: String {
        guard !displayedWindows.isEmpty else { return "Quota unavailable" }
        let quotaDescription = displayedWindows.map { window in
            "\(window.displayName): \(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining"
        }.joined(separator: ", ")
        let markers = [alertMarkers.primary, alertMarkers.secondary].compactMap { $0 }
        guard !markers.isEmpty else { return quotaDescription }
        let thresholds = markers.map { $0.formatted(.number.precision(.fractionLength(0))) }
        return "\(quotaDescription). Attention markers at \(thresholds.joined(separator: ", "))% remaining"
    }
}
