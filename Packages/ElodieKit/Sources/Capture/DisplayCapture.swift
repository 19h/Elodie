import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

/// A picture of a display.
public struct CapturedFrame: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer
    public var displayID: CGDirectDisplayID
    public var capturedAt: Date
    /// The windows this picture was asked to show. Nothing else can be in it.
    public var windows: Set<CGWindowID>
    /// Screen rows to ignore when comparing frames, which cover the menu bar.
    public var menuBarRows: Int

    public init(
        pixelBuffer: CVPixelBuffer,
        displayID: CGDirectDisplayID,
        capturedAt: Date,
        windows: Set<CGWindowID>,
        menuBarRows: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.displayID = displayID
        self.capturedAt = capturedAt
        self.windows = windows
        self.menuBarRows = menuBarRows
    }
}

/// Why capture stopped.
public enum CaptureStop: Sendable, Equatable {
    /// Pictures kept failing with permission still on.
    case stoppedBySystem
    case permissionMissing
    case displayGone
    /// Video encoding kept failing.
    case encoderFailed
    /// This version of macOS can't take the pictures.
    case unsupported
    case other(code: Int)

    public init(_ error: any Error) {
        switch error as? DisplayCaptureError {
        case .permissionMissing: self = .permissionMissing
        case .displayNotFound: self = .displayGone
        case .unsupported: self = .unsupported
        case nil: self = .other(code: (error as NSError).code)
        }
    }
}

public enum DisplayCaptureError: Error {
    case displayNotFound(CGDirectDisplayID)
    case permissionMissing
    case unsupported
}

/// Takes a picture of a display every couple of seconds.
///
/// These are separate one-off pictures because of what a continuous capture stream does: for as
/// long as one runs, macOS shows its screen sharing indicator, and protected video such as a
/// film has gone dark on the screen itself. One-off pictures are there to avoid both.
///
/// Each picture names the windows it shows, so whoever calls this decides what's in it.
public final class DisplayCapture: @unchecked Sendable {
    public static let captureInterval: TimeInterval = 2
    /// In Low Power Mode, half as often.
    public static let lowPowerInterval: TimeInterval = 4
    /// The height of the menu bar, in points.
    private static let menuBarPoints: CGFloat = 26
    /// A picture can fail now and then, but this many in a row is worth saying something about.
    private static let failuresBeforeStopping = 5

    public let displayID: CGDirectDisplayID
    private let queue: DispatchQueue
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onStop: @Sendable (CaptureStop) -> Void
    private let work = DispatchQueue(label: "elodie.capture", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    /// Keeps macOS from slowing this app's timers. A menu bar app with no windows showing is
    /// exactly what App Nap goes after.
    private var activity: (any NSObjectProtocol)?
    /// Only touched on `work`.
    private var failures = 0

    /// - Parameters:
    ///   - queue: where `onFrame` and `onStop` are called.
    public init(
        displayID: CGDirectDisplayID,
        queue: DispatchQueue,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onStop: @escaping @Sendable (CaptureStop) -> Void
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

    /// Starts taking pictures, the first of them right away.
    ///
    /// - Parameters:
    ///   - needsPermission: whether this looks at other apps' windows. An app can take pictures
    ///     of its own with no permission, so tests can run anywhere.
    ///   - windows: the windows to show in each picture, front to back. It's asked afresh every
    ///     time, just before the picture is taken.
    public func start(
        interval: TimeInterval = captureInterval,
        needsPermission: Bool = true,
        windows: @escaping @Sendable () -> [CGWindowID]
    ) throws {
        guard windowListCreateImageFromArray != nil else {
            throw DisplayCaptureError.unsupported
        }
        if needsPermission, !CGPreflightScreenCaptureAccess() {
            throw DisplayCaptureError.permissionMissing
        }
        guard CGDisplayIsOnline(displayID) != 0, Self.pixelSize(of: displayID) != nil, let converter = FrameConverter() else {
            throw DisplayCaptureError.displayNotFound(displayID)
        }
        let timer = DispatchSource.makeTimerSource(queue: work)
        // Some slack lets macOS wake the processor for this and something else together.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in
            self?.takePicture(needsPermission: needsPermission, windows: windows, converter: converter)
        }
        lock.withLock {
            self.timer?.cancel()
            self.timer = timer
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Recording the screen"
                )
            }
        }
        timer.resume()
    }

    /// Starts taking pictures of one window only. Used by tests that should see nothing else.
    public func start(including windowNumber: Int, interval: TimeInterval) throws {
        try start(interval: interval, needsPermission: false) { [CGWindowID(windowNumber)] }
    }

    /// Stops taking pictures. When this returns, no more are on their way.
    public func stop() async {
        endTimer()
        // Through both queues, since a finished picture may be waiting to be delivered.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            work.async { [queue] in
                queue.async { done.resume() }
            }
        }
    }

    deinit {
        timer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func endTimer() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    private func finish(_ reason: CaptureStop) {
        endTimer()
        let onStop = self.onStop
        queue.async { onStop(reason) }
    }

    private func takePicture(
        needsPermission: Bool,
        windows: () -> [CGWindowID],
        converter: FrameConverter
    ) {
        // Without permission a picture still comes back, showing no other app's windows, so it
        // has to be asked about or Elodie would quietly record an empty desktop.
        if needsPermission, !CGPreflightScreenCaptureAccess() {
            finish(.permissionMissing)
            return
        }
        guard CGDisplayIsOnline(displayID) != 0 else {
            finish(.displayGone)
            return
        }
        // Nobody's looking at this display, so there's nothing to record.
        guard CGDisplayIsAsleep(displayID) == 0, !ScreenContent.isSessionHidden() else { return }

        let listed = windows()
        guard !listed.isEmpty, let size = Self.pixelSize(of: displayID) else { return }
        // Every buffer being in use means the pipeline is behind, so this one can wait.
        guard let buffer = converter.makeBuffer(width: size.width, height: size.height) else { return }

        let capturedAt = Date()
        guard let image = pictureOfWindows(listed, in: CGDisplayBounds(displayID))?.takeRetainedValue(),
              image.width > 0, image.height > 0
        else {
            failures += 1
            if failures >= Self.failuresBeforeStopping {
                failures = 0
                finish(.stoppedBySystem)
            }
            return
        }
        failures = 0
        converter.convert(image, into: buffer)

        let pointWidth = max(CGDisplayPixelsWide(displayID), 1)
        let frame = CapturedFrame(
            pixelBuffer: buffer,
            displayID: displayID,
            capturedAt: capturedAt,
            windows: Set(listed),
            menuBarRows: Int((Self.menuBarPoints * CGFloat(size.width) / CGFloat(pointWidth)).rounded(.up))
        )
        let onFrame = self.onFrame
        queue.async { onFrame(frame) }
    }
}

/// Takes one picture holding exactly these windows, cropped to `bounds` in display coordinates.
private func pictureOfWindows(_ windows: [CGWindowID], in bounds: CGRect) -> Unmanaged<CGImage>? {
    // The array holds window IDs directly, not objects.
    var values = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil) else { return nil }
    return windowListCreateImageFromArray?(bounds, array, .bestResolution)
}

/// Public API, in the SDK's own list of symbols, that the SDK hides from Swift as obsolete. Its
/// replacement is ScreenCaptureKit, which is what this exists to avoid. See `DisplayCapture`.
///
/// It's looked up by name because linking to it would stop Elodie launching on a macOS that no
/// longer has it, and that would lock people out of what they've already recorded.
private let windowListCreateImageFromArray: (@convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?)? = {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray").map {
        unsafeBitCast($0, to: (@convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?).self)
    }
}()

/// Turns pictures into the format the comparison and the encoder take.
private final class FrameConverter {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    /// Enough for one being compared, two being encoded, the newest kept to show when the
    /// timeline opens, and the next one.
    private static let maxBuffers = 5

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // Low priority, so this never gets in the way of whatever's on screen.
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .priorityRequestLow: true])
    }

    /// A buffer to convert into, or `nil` if they're all in use.
    func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: Self.maxBuffers] as CFDictionary
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &buffer)
        return buffer
    }

    /// A picture that isn't the buffer's size is scaled to fit, as happens when a window from a
    /// sharper display overlaps this one.
    func convert(_ image: CGImage, into buffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // These say how to read the buffer, and rendering follows them.
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)

        var source = CIImage(cgImage: image)
        if image.width != width || image.height != height {
            source = source.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(image.width),
                y: CGFloat(height) / CGFloat(image.height)
            ))
        }
        context.render(source, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: Self.displayP3)
    }
}

