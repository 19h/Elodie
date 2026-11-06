import AppKit
import CoreAPI
import CoreFake
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

@Suite struct LeavingOutWhatWasntRecorded {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let pointsPerSecond = 1.5

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// An hour of recording, ten hours away, another hour, three days away, and another.
    private var periods: [DateInterval] {
        [
            DateInterval(start: at(0), end: at(3600)),
            DateInterval(start: at(39_600), end: at(43_200)),
            DateInterval(start: at(302_400), end: at(306_000)),
        ]
    }

    private var gaps: [DateInterval] { StripAxis.gaps(between: periods) }
    private var axis: StripAxis { StripAxis(gaps: gaps, pointsPerSecond: pointsPerSecond) }

    /// How far apart two moments are on the strip, in points.
    private func points(_ a: Date, _ b: Date, on axis: StripAxis, zoom: Double) -> Double {
        (axis.position(of: b) - axis.position(of: a)) * zoom
    }

    @Test func tenHoursAwayTakesTheSameRoomAsAnyOtherBreak() {
        #expect(abs(points(at(3600), at(39_600), on: axis, zoom: pointsPerSecond) - StripAxis.breakWidth) < 0.001)
        #expect(abs(points(at(43_200), at(302_400), on: axis, zoom: pointsPerSecond) - StripAxis.breakWidth) < 0.001)
    }

    @Test func breaksTakeTheSameRoomAtEveryZoom() {
        for zoom in [0.1, 1.5, 20] {
            let axis = StripAxis(gaps: gaps, pointsPerSecond: zoom)
            #expect(abs(points(at(3600), at(39_600), on: axis, zoom: zoom) - StripAxis.breakWidth) < 0.001)
        }
    }

    @Test func whatWasRecordedStaysToScale() {
        #expect(abs(points(at(0), at(3600), on: axis, zoom: pointsPerSecond) - 3600 * pointsPerSecond) < 0.001)
        #expect(abs(points(at(39_600), at(43_200), on: axis, zoom: pointsPerSecond) - 3600 * pointsPerSecond) < 0.001)
    }

    @Test func recordedMomentsConvertBothWays() {
        for period in periods {
            for fraction in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let moment = period.start.addingTimeInterval(period.duration * fraction)
                let back = axis.time(at: axis.position(of: moment))
                #expect(abs(back.timeIntervalSince(moment)) < 0.001)
            }
        }
    }

    @Test func positionsOnABreakAreTheNearerSideOfIt() {
        let before = axis.position(of: at(3600))
        let length = StripAxis.breakWidth / pointsPerSecond
        #expect(axis.time(at: before + length * 0.25) == at(3600))
        #expect(axis.time(at: before + length * 0.75) == at(39_600))
    }

    @Test func aMomentOnABreakLandsOnTheNearerSide() {
        #expect(axis.time(at: axis.position(of: at(5000))) == at(3600))
        #expect(axis.time(at: axis.position(of: at(38_000))) == at(39_600))
    }

    @Test func scrollingBackAcrossABreakTakesOnlyItsWidth() {
        // From the start of the later hour to the end of the earlier one.
        var position = axis.position(of: at(39_600))
        var scrolled = 0.0
        while axis.time(at: position) > at(3600) {
            position -= 1 / pointsPerSecond
            scrolled += 1
        }
        // Halfway across is where the picture changes, so no more than that is needed.
        #expect(scrolled <= StripAxis.breakWidth / 2 + 1)
    }

    @Test func movingAlongNeverGoesBackward() {
        var position = axis.position(of: at(-100))
        var last = axis.time(at: position)
        let end = axis.position(of: at(306_100))
        while position < end {
            position += 3
            let moment = axis.time(at: position)
            #expect(moment >= last)
            last = moment
        }
    }

    @Test func aBreakIsOnlyFoundOnABreak() {
        let start = axis.position(of: at(3600))
        let length = StripAxis.breakWidth / pointsPerSecond
        #expect(axis.breakInterval(at: start + length / 2) == gaps[0])
        #expect(axis.breakInterval(at: start - 1) == nil)
        #expect(axis.breakInterval(at: start + length + 1) == nil)
    }

    @Test func aGapThatAlreadyFitsStaysToScale() {
        // Wide enough that ten minutes is under the break width: 6 points.
        let axis = StripAxis(gaps: [DateInterval(start: at(0), end: at(600))], pointsPerSecond: 0.01)
        #expect(axis.breaks(in: at(-1)...at(601)).isEmpty)
        #expect(abs((axis.position(of: at(600)) - axis.position(of: at(0))) - 600) < 0.001)
    }

    @Test func aGapTooShortToBeABreakStaysToScaleEvenCloseUp() {
        // At the closest zoom, 10 seconds would otherwise be squeezed.
        let axis = StripAxis(gaps: [DateInterval(start: at(0), end: at(10))], pointsPerSecond: 20)
        #expect(axis.breaks(in: at(-1)...at(11)).isEmpty)
    }

    @Test func noGapsAtAnyZoomIsTheSameAxis() {
        #expect(StripAxis(gaps: [], pointsPerSecond: 1) == StripAxis(gaps: [], pointsPerSecond: 20))
        #expect(StripAxis(gaps: [], pointsPerSecond: 1) == StripAxis())
    }

    @Test func breaksInAPeriodAreTheOnesThatOverlapIt() {
        #expect(axis.breaks(in: at(0)...at(100)).isEmpty)
        #expect(axis.breaks(in: at(0)...at(5000)) == [gaps[0]])
        #expect(axis.breaks(in: at(5000)...at(6000)) == [gaps[0]])
        #expect(axis.breaks(in: at(5000)...at(400_000)) == gaps)
        #expect(axis.breaks(in: at(303_000)...at(304_000)).isEmpty)
    }

    @Test func selectingAcrossABreakCountsOnlyWhatWasRecorded() {
        let selection = DateInterval(start: at(3000), end: at(40_000))
        #expect(abs(StripAxis.recordedTime(in: selection, gaps: gaps) - 1000) < 0.001)
    }

    @Test func fittingAStretchAllowsForItsBreaks() {
        let selection = DateInterval(start: at(0), end: at(43_200))
        let zoom = StripAxis.pointsPerSecond(toFit: selection, gaps: gaps, width: 1000)
        let axis = StripAxis(gaps: gaps, pointsPerSecond: zoom)
        let width = points(selection.start, selection.end, on: axis, zoom: zoom)
        #expect(abs(width - 1000) < 0.001)
    }

    @Test func theStripWorksAcrossABreak() {
        // The playhead just after the break, 1000 points wide.
        let geometry = StripGeometry(
            centerPosition: axis.position(of: at(39_610)),
            pointsPerSecond: pointsPerSecond,
            width: 1000,
            axis: axis
        )
        // 15 points back is the start of the later hour, and then the break's width.
        #expect(abs(geometry.x(for: at(39_600)) - 485) < 0.001)
        #expect(abs(geometry.x(for: at(3600)) - (485 - StripAxis.breakWidth)) < 0.001)
        #expect(geometry.time(atX: 485 - StripAxis.breakWidth - 15) == at(3590))
    }

    @Test func labelsAreShort() {
        #expect(SliceDescription.shortDuration(36_000) == "10h")
        #expect(SliceDescription.shortDuration(3 * 86_400) == "3d")
        #expect(SliceDescription.shortDuration(25 * 60) == "25m")
        #expect(SliceDescription.shortDuration(45) == "45s")
    }

    @Test func atTheLastRecordingThereIsNowhereFurtherToGo() async {
        await MainActor.run {
            let model = TimelineModel()
            let now = Date()
            model.now = { now }
            model.endOfRecordings = now.addingTimeInterval(-36_000)
            model.playheadMoved(to: now.addingTimeInterval(-36_000))
            #expect(model.isAtNow)
            model.playheadMoved(to: now.addingTimeInterval(-36_100))
            #expect(!model.isAtNow)
        }
    }
}

@MainActor
@Suite struct ScrollingTheTimelineAcrossABreak {
    private let display = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func sample(at time: Date) -> EncodedSample {
        EncodedSample(
            displayID: display,
            width: 16,
            height: 16,
            parameterSets: Data(),
            capturedAt: time,
            monotonicNanoseconds: 0,
            isKeyframe: true,
            context: FrameContext(bundleID: "com.example.app"),
            data: Data()
        )
    }

    /// A minute of frames every 2 seconds, ending at `end`.
    private func record(into core: FakeCore, endingAt end: Date) throws {
        for second in stride(from: 60.0, through: 0, by: -2) {
            _ = try core.append(sample(at: end.addingTimeInterval(-second)))
        }
    }

    /// A timeline with the gaps known, as they are moments after opening.
    private func openTimeline(core: FakeCore, at time: Date) async throws -> TimelineController {
        let controller = TimelineController(core: core, display: display, frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        controller.model.now = { [now] in now }
        controller.present(at: time)
        for _ in 0..<100 where controller.model.endOfRecordings == nil && controller.playhead == time {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        return controller
    }

    @Test func aShortFlickCrossesTenHours() async throws {
        let core = FakeCore()
        let earlier = now.addingTimeInterval(-36_000)
        try record(into: core, endingAt: earlier)
        try record(into: core, endingAt: now)
        let controller = try await openTimeline(core: core, at: now.addingTimeInterval(-60))
        // Half a break's width, and a little more, up is back in time.
        controller.simulateScroll(points: StripAxis.breakWidth / 2 + 1)
        #expect(abs(controller.playhead.timeIntervalSince(earlier)) < 1)
        controller.stop()
    }

    @Test func openingLongAfterTheLastRecordingShowsItsTime() async throws {
        let core = FakeCore()
        let last = now.addingTimeInterval(-36_000)
        try record(into: core, endingAt: last)
        let controller = try await openTimeline(core: core, at: now)
        #expect(controller.playhead == last)
        #expect(controller.model.endOfRecordings == last)
        #expect(controller.model.isAtNow)
        // Nothing lies ahead.
        controller.simulateScroll(points: -200)
        #expect(controller.playhead == last)
        controller.stop()
    }

    @Test func jumpingIntoABreakLandsBesideIt() async throws {
        let core = FakeCore()
        let earlier = now.addingTimeInterval(-36_000)
        try record(into: core, endingAt: earlier)
        try record(into: core, endingAt: now)
        let controller = try await openTimeline(core: core, at: now)
        controller.move(to: earlier.addingTimeInterval(600))
        #expect(controller.playhead == earlier)
        controller.stop()
    }

    @Test func aRecentRecordingStillGoesUpToNow() async throws {
        let core = FakeCore()
        try record(into: core, endingAt: now.addingTimeInterval(-10))
        let controller = try await openTimeline(core: core, at: now)
        #expect(controller.model.endOfRecordings == nil)
        #expect(controller.playhead == now)
        controller.stop()
    }
}
