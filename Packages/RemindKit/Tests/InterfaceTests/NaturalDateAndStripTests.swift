import CoreAPI
import Foundation
@testable import FeatureTimeline
@testable import OverlayShell
import CoreGraphics
import StripRenderer
import Testing

@Suite struct NaturalDates {
    private var calendar: Calendar { .current }
    // A fixed moment: 10:00 on a day well away from any year boundary.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
    }

    @Test func understandsARelativeDayAndTime() throws {
        let date = try #require(NaturalDate.parse("yesterday 3pm"))
        let expected = calendar.date(byAdding: .day, value: -1, to: Date())!
        #expect(calendar.isDate(date, inSameDayAs: expected))
        #expect(calendar.component(.hour, from: date) == 15)
    }

    @Test func aTimeLaterTodayMeansYesterday() throws {
        let date = try #require(NaturalDate.parse("3pm", now: now))
        #expect(date <= now)
        #expect(calendar.component(.hour, from: date) == 15)
    }

    @Test func neverReturnsTheFuture() throws {
        let date = try #require(NaturalDate.parse("December 25", now: now))
        #expect(date <= now)
        #expect(calendar.component(.month, from: date) == 12)
    }

    @Test func nonsenseGivesNothing() {
        #expect(NaturalDate.parse("flibbertigibbet", now: now) == nil)
        #expect(NaturalDate.parse("   ", now: now) == nil)
    }
}

@Suite struct StripIcons {
    private func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    // One point per second, 1000 points wide, centred on 500: t maps directly to x.
    private let viewport = StripViewport(center: 500, pointsPerSecond: 1, widthPoints: 1000, heightPoints: 40)

    @Test func anIconSitsInTheMiddleOfItsRun() {
        let icons = [StripIcon(start: 100, end: 300, image: image())]
        let positions = StripView.iconPositions(for: icons, viewport: viewport, iconSize: 24)
        #expect(positions.map(\.x) == [200])
    }

    @Test func aRunPartlyOffScreenCentresOnWhatsVisible() {
        let icons = [StripIcon(start: -500, end: 100, image: image())]
        let positions = StripView.iconPositions(for: icons, viewport: viewport, iconSize: 24)
        #expect(positions.map(\.x) == [50])
    }

    @Test func aRunTooShortForAnIconHasNone() {
        let icons = [StripIcon(start: 100, end: 110, image: image())]
        #expect(StripView.iconPositions(for: icons, viewport: viewport, iconSize: 24).isEmpty)
    }

    @Test func iconsNeverOverlap() {
        let icons = [
            StripIcon(start: 100, end: 130, image: image()),
            StripIcon(start: 130, end: 160, image: image()),
            StripIcon(start: 160, end: 190, image: image()),
        ]
        let positions = StripView.iconPositions(for: icons, viewport: viewport, iconSize: 24)
        for (a, b) in zip(positions, positions.dropFirst()) {
            #expect(b.x - a.x >= 24)
        }
    }
}

@Suite struct SelectingTextOnAFrame {
    private let lines = [
        RecognizedLine(text: "second row, left", rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.02)),
        RecognizedLine(text: "first row", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.02)),
        RecognizedLine(text: "second row, right", rect: CGRect(x: 0.4, y: 0.201, width: 0.2, height: 0.02)),
    ]

    @Test func aPointOnALineFindsIt() {
        #expect(TextSelection.line(at: CGPoint(x: 0.2, y: 0.11), in: lines)?.text == "first row")
    }

    @Test func aPointInEmptySpaceFindsNothing() {
        #expect(TextSelection.line(at: CGPoint(x: 0.9, y: 0.9), in: lines) == nil)
    }

    @Test func aDragTakesEveryLineItTouches() {
        let selected = TextSelection.lines(lines, between: CGPoint(x: 0.15, y: 0.11), and: CGPoint(x: 0.2, y: 0.21))
        #expect(Set(selected.map(\.text)) == ["first row", "second row, left"])
    }

    @Test func draggingBackwardIsTheSame() {
        let forward = TextSelection.lines(lines, between: CGPoint(x: 0.15, y: 0.11), and: CGPoint(x: 0.2, y: 0.21))
        let backward = TextSelection.lines(lines, between: CGPoint(x: 0.2, y: 0.21), and: CGPoint(x: 0.15, y: 0.11))
        #expect(forward == backward)
    }

    @Test func copiedTextIsInReadingOrder() {
        // Vision reports these in no useful order.
        #expect(TextSelection.text(of: lines) == "first row\nsecond row, left\nsecond row, right")
    }
}

@Suite struct TheSwipeThatOpensTheTimeline {
    private typealias Router = ScrollGestureRouter

    @Test func ordinaryScrollingIsNeverTouched() {
        var router = Router()
        #expect(router.route(modifiersHeld: false, overlayOpen: false, deltaY: 30, phase: .changed, momentum: .none) == .passThrough)
        #expect(router.route(modifiersHeld: false, overlayOpen: false, deltaY: 30, phase: .none, momentum: .none) == .passThrough)
        // Even with the timeline open, this reaches the panel by the normal route.
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 30, phase: .changed, momentum: .none) == .passThrough)
    }

    @Test func holdingTheKeysAndScrollingUpTakesOver() {
        var router = Router()
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: 12, phase: .changed, momentum: .none) == .takeOver)
    }

    @Test func scrollingDownCantOpenItBecauseThereIsNoFuture() {
        var router = Router()
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: -12, phase: .changed, momentum: .none) == .passThrough)
    }

    @Test func aFingerRestingHasNoDirectionYet() {
        var router = Router()
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: 0, phase: .mayBegin, momentum: .none) == .passThrough)
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: 0, phase: .began, momentum: .none) == .passThrough)
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: 8, phase: .changed, momentum: .none) == .takeOver)
    }

    @Test func onceOpenBothDirectionsMoveThroughTime() {
        var router = Router()
        #expect(router.route(modifiersHeld: true, overlayOpen: true, deltaY: -12, phase: .changed, momentum: .none) == .takeOver)
        #expect(router.route(modifiersHeld: true, overlayOpen: true, deltaY: 12, phase: .changed, momentum: .none) == .takeOver)
    }

    @Test func theSwipeStaysTakenOverAfterTheKeysAreLetGo() {
        var router = Router()
        _ = router.route(modifiersHeld: true, overlayOpen: false, deltaY: 12, phase: .changed, momentum: .none)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 40, phase: .changed, momentum: .none) == .takeOver)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 0, phase: .ended, momentum: .none) == .takeOver)
    }

    @Test func itFollowsTheGlideToItsEnd() {
        var router = Router()
        _ = router.route(modifiersHeld: true, overlayOpen: false, deltaY: 12, phase: .changed, momentum: .none)
        _ = router.route(modifiersHeld: false, overlayOpen: true, deltaY: 0, phase: .ended, momentum: .none)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 20, phase: .none, momentum: .began) == .takeOver)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 10, phase: .none, momentum: .continuing) == .takeOver)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 0, phase: .none, momentum: .ended) == .takeOver)
        // That swipe is over, so the next one is ordinary scrolling.
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 30, phase: .changed, momentum: .none) == .passThrough)
    }

    @Test func aNewSwipeWithoutTheKeysEndsIt() {
        var router = Router()
        _ = router.route(modifiersHeld: true, overlayOpen: false, deltaY: 12, phase: .changed, momentum: .none)
        _ = router.route(modifiersHeld: false, overlayOpen: true, deltaY: 0, phase: .ended, momentum: .none)
        // No momentum this time. The fingers come back later, to scroll search results.
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 0, phase: .began, momentum: .none) == .passThrough)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 20, phase: .changed, momentum: .none) == .passThrough)
    }

    @Test func aMouseWheelHasNoSwipeToFollow() {
        var router = Router()
        #expect(router.route(modifiersHeld: true, overlayOpen: false, deltaY: 3, phase: .none, momentum: .none) == .takeOver)
        #expect(router.route(modifiersHeld: false, overlayOpen: true, deltaY: 3, phase: .none, momentum: .none) == .passThrough)
    }
}

@Suite struct ScrollingUpGoesBack {
    @Test func upIsEarlierAndDownIsLater() {
        var interpreter = ScrollInterpreter(pointsPerSecond: 1.5)
        #expect(interpreter.seconds(for: ScrollInput(deltaX: 0, deltaY: 30)) < 0)
        #expect(interpreter.seconds(for: ScrollInput(deltaX: 0, deltaY: -30)) > 0)
    }
}
