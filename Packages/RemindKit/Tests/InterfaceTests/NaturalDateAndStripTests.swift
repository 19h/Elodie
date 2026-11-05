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
