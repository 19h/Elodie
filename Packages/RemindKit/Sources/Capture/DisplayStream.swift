import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
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
    case other(code: Int)

    init(_ error: any Error) {
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
    private static let queueDepth = 3
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

    public func start(filter: SCContentFilter) async throws {
        let configuration = Self.configuration(for: displayID)
        let pointWidth = max(CGDisplayPixelsWide(displayID), 1)
        let scale = CGFloat(configuration.width) / CGFloat(pointWidth)
        menuBarRows = Int((Self.menuBarPoints * scale).rounded(.up))

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func update(filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
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

    /// A filter showing a display with the given windows left out.
    public static func filter(
        displayID: CGDirectDisplayID,
        excluding windows: Set<CGWindowID>
    ) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DisplayStreamError.displayNotFound(displayID)
        }
        let excluded = content.windows.filter { windows.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }
}
