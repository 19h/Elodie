import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit

/// A frame from a display.
public struct CapturedFrame: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer
    public var displayID: CGDirectDisplayID
    public var capturedAt: Date
    /// When this frame was composed, in mach time.
    public var displayTime: UInt64
    public var dirtyRects: [CGRect]
    /// Screen rows to ignore when comparing frames, which cover the menu bar.
    public var menuBarRows: Int

    public init(
        pixelBuffer: CVPixelBuffer,
        displayID: CGDirectDisplayID,
        capturedAt: Date,
        displayTime: UInt64,
        dirtyRects: [CGRect],
        menuBarRows: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.displayID = displayID
        self.capturedAt = capturedAt
        self.displayTime = displayTime
        self.dirtyRects = dirtyRects
        self.menuBarRows = menuBarRows
    }
}

/// Why capture stopped.
public enum StreamStop: Sendable, Equatable {
    /// The user stopped it from the system's recording indicator.
    case stoppedByUser
    /// macOS stopped it, for example when access needs confirming again.
    case stoppedBySystem
    case permissionMissing
    case displayGone
    /// Video encoding kept failing.
    case encoderFailed
    case other(code: Int)

    public init(_ error: any Error) {
        guard (error as NSError).domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: (error as NSError).code)
        else {
            self = .other(code: (error as NSError).code)
            return
        }
        switch code {
        case .userStopped: self = .stoppedByUser
        case .systemStoppedStream: self = .stoppedBySystem
        case .userDeclined: self = .permissionMissing
        case .noCaptureSource, .noDisplayList: self = .displayGone
        default: self = .other(code: code.rawValue)
        }
    }
}

/// A filter that has been applied.
public struct AppliedFilter: Sendable, Equatable {
    /// When it took effect, in mach time.
    public var appliedAt: UInt64
    /// The windows it hides. A window that capture doesn't know about yet can't be hidden,
    /// however much it should be, so this can be fewer than were asked for.
    public var covered: Set<CGWindowID>

    public init(appliedAt: UInt64, covered: Set<CGWindowID>) {
        self.appliedAt = appliedAt
        self.covered = covered
    }
}

public enum DisplayStreamError: Error {
    case displayNotFound(CGDirectDisplayID)
}

/// Delivers a display's changed frames at a low rate.
///
/// `Idle` frames are skipped here, so an unchanged screen costs almost nothing.
/// Only `queueDepth` frames can be in flight: the stream stalls if they're held,
/// so whoever receives one must let it go quickly.
public final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let captureInterval: TimeInterval = 2
    /// In Low Power Mode, half as often.
    public static let lowPowerInterval: TimeInterval = 4
    /// Three in flight, plus one kept to show the instant the timeline opens.
    private static let queueDepth = 4
    /// The height of the menu bar, in points.
    private static let menuBarPoints: CGFloat = 26

    public let displayID: CGDirectDisplayID
    private let queue: DispatchQueue
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onStop: @Sendable (StreamStop) -> Void
    private var stream: SCStream?
    private var menuBarRows = 0

    public init(
        displayID: CGDirectDisplayID,
        queue: DispatchQueue,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onStop: @escaping @Sendable (StreamStop) -> Void
    ) {
        self.displayID = displayID
        self.queue = queue
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Native pixel dimensions, so the recording is never downscaled.
    public static func pixelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    public static func configuration(for displayID: CGDirectDisplayID) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        if let size = pixelSize(of: displayID) {
            configuration.width = size.width
            configuration.height = size.height
        }
        configuration.minimumFrameInterval = CMTime(seconds: captureInterval, preferredTimescale: 600)
        configuration.queueDepth = queueDepth
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    /// Starts capture with the given windows left out. Returns when that filter took effect,
    /// in mach time, and which windows it really covers.
    @discardableResult
    public func start(
        excluding windows: Set<CGWindowID>,
        interval: TimeInterval = captureInterval
    ) async throws -> AppliedFilter {
        let (filter, covered) = try await ScreenContent.filter(displayID: displayID, excluding: windows)
        let configuration = Self.configuration(for: displayID)
        configuration.minimumFrameInterval = CMTime(seconds: interval, preferredTimescale: 600)
        let pointWidth = max(CGDisplayPixelsWide(displayID), 1)
        let scale = CGFloat(configuration.width) / CGFloat(pointWidth)
        menuBarRows = Int((Self.menuBarPoints * scale).rounded(.up))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return AppliedFilter(appliedAt: mach_absolute_time(), covered: covered)
    }

    /// Starts capture of one window only. Used by tests that should see nothing else.
    public func start(including windowNumber: Int, interval: TimeInterval) async throws {
        // An app can capture its own windows with no permission, so tests can run anywhere.
        let content = try await SCShareableContent.currentProcess
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let window = content.windows.first(where: { Int($0.windowID) == windowNumber })
        else {
            throw DisplayStreamError.displayNotFound(displayID)
        }
        let filter = SCContentFilter(display: display, including: [window])
        let configuration = Self.configuration(for: displayID)
        configuration.minimumFrameInterval = CMTime(seconds: interval, preferredTimescale: 600)
        let pointWidth = max(CGDisplayPixelsWide(displayID), 1)
        menuBarRows = Int((Self.menuBarPoints * CGFloat(configuration.width) / CGFloat(pointWidth)).rounded(.up))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Changes which windows are left out. Returns when the new filter took effect, in mach
    /// time, and which windows it really covers.
    @discardableResult
    public func update(excluding windows: Set<CGWindowID>) async throws -> AppliedFilter {
        let (filter, covered) = try await ScreenContent.filter(displayID: displayID, excluding: windows)
        try await stream?.updateContentFilter(filter)
        return AppliedFilter(appliedAt: mach_absolute_time(), covered: covered)
    }

    public func stop() async {
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusValue = info[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let dirty = (info[.dirtyRects] as? [NSDictionary])?.compactMap { dictionary -> CGRect? in
            CGRect(dictionaryRepresentation: dictionary)
        } ?? []

        onFrame(CapturedFrame(
            pixelBuffer: pixelBuffer,
            displayID: displayID,
            capturedAt: Date(),
            displayTime: info[.displayTime] as? UInt64 ?? mach_absolute_time(),
            dirtyRects: dirty,
            menuBarRows: menuBarRows
        ))
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        onStop(StreamStop(error))
    }
}

/// Finds displays and builds content filters.
public enum ScreenContent {
    /// Takes one screenshot of a display and discards it. For comparing capture costs.
    public static func screenshot(displayID: CGDirectDisplayID) async throws -> CGSize {
        let (filter, _) = try await Self.filter(displayID: displayID, excluding: [])
        let configuration = DisplayStream.configuration(for: displayID)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CGSize(width: image.width, height: image.height)
    }

    /// A stable ID for a display. `CGDirectDisplayID` can change between boots.
    public static func stableID(of displayID: CGDirectDisplayID) -> UUID? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        let bytes = CFUUIDGetUUIDBytes(uuid)
        return UUID(uuid: (
            bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3,
            bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
            bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11,
            bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15
        ))
    }

    /// This process's windows on screen, largest first. The window server's own list is
    /// the authority on who owns what, and it needs no permission for one's own windows.
    private static func ownWindowsOnScreen() -> [CGWindowID] {
        let own = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        func area(_ window: [CFString: Any]) -> CGFloat {
            guard let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return 0 }
            return rect.width * rect.height
        }
        return list
            .filter { ($0[kCGWindowOwnerPID] as? pid_t) == own }
            .sorted { area($0) > area($1) }
            .compactMap { ($0[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) } }
    }

    /// Saves a screenshot of one of this app's windows. Glass and shadows render as they
    /// really do, which a view snapshot doesn't manage. It refuses anything else, because
    /// the current-process list can include windows that aren't ours, such as the desktop.
    public static func saveScreenshot(ofWindow windowID: CGWindowID, to url: URL) async throws {
        guard ownWindowsOnScreen().contains(windowID) else {
            throw DisplayStreamError.displayNotFound(windowID)
        }
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw DisplayStreamError.displayNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw DisplayStreamError.displayNotFound(windowID)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Saves a screenshot of this app's largest window on screen.
    public static func saveScreenshotOfLargestOwnWindow(to url: URL) async throws {
        guard let largest = ownWindowsOnScreen().first else { throw DisplayStreamError.displayNotFound(0) }
        try await saveScreenshot(ofWindow: largest, to: url)
    }

    /// A filter showing a display with the given windows left out, and which of them it covers.
    public static func filter(
        displayID: CGDirectDisplayID,
        excluding windows: Set<CGWindowID>
    ) async throws -> (SCContentFilter, covered: Set<CGWindowID>) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DisplayStreamError.displayNotFound(displayID)
        }
        let excluded = content.windows.filter { windows.contains($0.windowID) }
        return (
            SCContentFilter(display: display, excludingWindows: excluded),
            Set(excluded.map(\.windowID))
        )
    }
}
