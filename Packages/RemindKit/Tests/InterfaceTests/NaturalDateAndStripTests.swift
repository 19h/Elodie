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

@Suite struct SelectingOnTheStrip {
    private let center = Date(timeIntervalSince1970: 1_800_000_000)
    // One point per second, 1000 points wide, so x 500 is the centre.
    private var geometry: StripGeometry {
        StripGeometry(center: center, pointsPerSecond: 1, width: 1000)
    }

    private func at(_ seconds: Double) -> Date { center.addingTimeInterval(seconds) }

    private var limits: ClosedRange<Date> { at(-500)...at(500) }

    private var runs: [TimelineRun] {
        [
            TimelineRun(start: at(-400), end: at(-100), app: 0),
            TimelineRun(start: at(-100), end: at(200), app: 1),
        ]
    }

    private func drag(_ editor: inout SliceEditor, from: Double, to: Double) -> SliceEditor.Outcome {
        editor.mouseDown(x: from, geometry: geometry)
        editor.mouseDragged(x: to, geometry: geometry, runs: runs, limits: limits)
        return editor.mouseUp(x: to, geometry: geometry)
    }

    @Test func timesAndPositionsConvertBothWays() {
        #expect(geometry.x(for: center) == 500)
        #expect(geometry.time(atX: 600) == at(100))
        #expect(geometry.x(for: at(-250)) == 250)
    }

    @Test func aPressAndReleaseInPlaceIsAClick() {
        var editor = SliceEditor()
        editor.mouseDown(x: 600, geometry: geometry)
        editor.mouseDragged(x: 601, geometry: geometry, runs: runs, limits: limits)
        #expect(editor.mouseUp(x: 601, geometry: geometry) == .clicked(at(101)))
        #expect(editor.selection == nil)
    }

    @Test func aDragDrawsAStretch() {
        var editor = SliceEditor()
        #expect(drag(&editor, from: 450, to: 620) == .selected)
        #expect(editor.selection == DateInterval(start: at(-50), end: at(120)))
    }

    @Test func draggingBackwardGivesTheSameStretch() {
        var editor = SliceEditor()
        _ = drag(&editor, from: 620, to: 450)
        #expect(editor.selection == DateInterval(start: at(-50), end: at(120)))
    }

    @Test func aDragLandsOnARunsEdgeWhenCloseToOne() {
        var editor = SliceEditor()
        // A run edge is at x 400, and this ends 5 points short of it.
        _ = drag(&editor, from: 250, to: 395)
        #expect(editor.selection?.end == at(-100))
    }

    @Test func aDragFarFromAnyEdgeStaysPut() {
        var editor = SliceEditor()
        _ = drag(&editor, from: 450, to: 480)
        #expect(editor.selection?.end == at(-20))
    }

    @Test func aSelectionCantRunPastTheLimits() {
        var editor = SliceEditor()
        editor.mouseDown(x: 600, geometry: geometry)
        // Limits end at x 1000.
        editor.mouseDragged(x: 1500, geometry: geometry, runs: runs, limits: limits)
        #expect(editor.selection?.end == at(500))
    }

    @Test func eitherEndCanBeDraggedToTrim() {
        var editor = SliceEditor(selection: DateInterval(start: at(-50), end: at(120)))
        #expect(editor.isOverHandle(x: 450, geometry: geometry))
        #expect(!editor.isOverHandle(x: 500, geometry: geometry))

        _ = drag(&editor, from: 451, to: 470)
        #expect(editor.selection == DateInterval(start: at(-30), end: at(120)))

        _ = drag(&editor, from: 619, to: 590)
        #expect(editor.selection == DateInterval(start: at(-30), end: at(90)))
    }

    @Test func draggingOneEndPastTheOtherKeepsGoing() {
        var editor = SliceEditor(selection: DateInterval(start: at(-50), end: at(0)))
        editor.mouseDown(x: 450, geometry: geometry)
        editor.mouseDragged(x: 520, geometry: geometry, runs: runs, limits: limits)
        #expect(editor.selection == DateInterval(start: at(0), end: at(20)))
        editor.mouseDragged(x: 530, geometry: geometry, runs: runs, limits: limits)
        #expect(editor.selection == DateInterval(start: at(0), end: at(30)))
    }

    @Test func aPressOutsideTheSelectionStartsAfresh() {
        var editor = SliceEditor(selection: DateInterval(start: at(-50), end: at(0)))
        #expect(drag(&editor, from: 700, to: 720) == .selected)
        #expect(editor.selection == DateInterval(start: at(200), end: at(220)))
    }

    @Test func theRunAtAMomentIsFound() {
        #expect(SliceEditor.run(at: at(-200), in: runs)?.app == 0)
        #expect(SliceEditor.run(at: at(50), in: runs)?.app == 1)
        #expect(SliceEditor.run(at: at(300), in: runs) == nil)
    }
}

@Suite struct DescribingADeletion {
    private let interval = DateInterval(
        start: Date(timeIntervalSince1970: 1_800_000_000),
        duration: 1800
    )

    @Test func itSaysWhatGoes() {
        let details = SliceDescription.deletionDetails(interval, summary: SliceSummary(frames: 100, bytes: 5_000_000))
        #expect(details.contains("5"))
        #expect(!details.contains("starred"))
        #expect(!details.contains("just after"))
    }

    @Test func starsAndSpeechAreCalledOut() {
        let details = SliceDescription.deletionDetails(
            interval,
            summary: SliceSummary(frames: 100, bytes: 1000, starred: 2, transcriptLines: 5)
        )
        #expect(details.contains("2 starred"))
        #expect(details.contains("said"))
    }

    @Test func whatElseDependsOnItIsCalledOut() {
        let details = SliceDescription.deletionDetails(
            interval,
            summary: SliceSummary(frames: 100, bytes: 1000, dependentFrames: 7, dependentUntil: interval.end.addingTimeInterval(14))
        )
        #expect(details.contains("14 seconds"))
        #expect(details.contains("just after"))
    }

    @Test func durationsReadNaturally() {
        #expect(SliceDescription.duration(40) == "40 seconds")
        #expect(SliceDescription.duration(74) == "1 minute, 14 seconds")
        #expect(SliceDescription.duration(29 * 60) == "29 minutes")
        #expect(SliceDescription.duration(2 * 3600 + 5 * 60) == "2 hours, 5 minutes")
    }
}

@Suite struct FittingAPicture {
    private let wide = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func theSameShapeFillsTheSpace() {
        #expect(aspectFit(CGSize(width: 3840, height: 2160), in: wide) == wide)
    }

    /// A MacBook's recording on a 16:9 display has bars at the sides, and marks on the picture
    /// have to start where the picture starts.
    @Test func aDifferentShapeSitsInTheMiddle() {
        let picture = aspectFit(CGSize(width: 3456, height: 2234), in: wide)
        #expect(picture.height == 1080)
        #expect(abs(picture.width - 1670.7) < 0.1)
        #expect(abs(picture.minX - 124.6) < 0.1)
        #expect(picture.minY == 0)
    }

    @Test func aWidePictureOnATallDisplayHasBarsAboveAndBelow() {
        let picture = aspectFit(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(picture == CGRect(x: 0, y: 250, width: 1000, height: 500))
    }

    @Test func aPictureWithNoSizeLeavesTheSpaceAlone() {
        #expect(aspectFit(.zero, in: wide) == wide)
    }
}

@Suite struct DescribingARange {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    /// A short stretch on another day shows seconds at both ends, or it reads as a mistake.
    @Test func aShortStretchOnAnotherDayHasSecondsAtBothEnds() {
        let text = SliceDescription.range(DateInterval(start: day, duration: 74))
        let times = text.components(separatedBy: " – ")
        #expect(times.count == 2, "got: \(text)")
        #expect(times.allSatisfy { $0.filter { $0 == ":" }.count == 2 }, "got: \(text)")
    }

    @Test func aLongStretchLeavesThemOut() {
        let text = SliceDescription.range(DateInterval(start: day, duration: 3600))
        let times = text.components(separatedBy: " – ")
        #expect(times.count == 2, "got: \(text)")
        #expect(times.allSatisfy { $0.filter { $0 == ":" }.count == 1 }, "got: \(text)")
    }
}
