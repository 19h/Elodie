import CoreAPI
import CoreGraphics

/// Works out which recognised lines a drag covers. Points are fractions of the frame,
/// with the origin at the top left, the same as the lines.
public enum TextSelection {
    /// How far outside a line a point can be and still count as on it. Recognised
    /// rectangles fit the text tightly, which makes them hard to hit.
    private static let margin: CGFloat = 0.003

    /// The line under a point, if any.
    public static func line(at point: CGPoint, in lines: [RecognizedLine]) -> RecognizedLine? {
        lines.first { $0.rect.insetBy(dx: -margin, dy: -margin).contains(point) }
    }

    /// The lines a drag between two points touches.
    public static func lines(_ lines: [RecognizedLine], between a: CGPoint, and b: CGPoint) -> [RecognizedLine] {
        let area = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        ).insetBy(dx: -margin, dy: -margin)
        return lines.filter { $0.rect.intersects(area) }
    }

    /// Text in reading order: top to bottom, and left to right along a row. Lines count as
    /// the same row when their centres are within half a line of each other.
    public static func text(of lines: [RecognizedLine]) -> String {
        lines.sorted { a, b in
            let tolerance = min(a.rect.height, b.rect.height) / 2
            if abs(a.rect.midY - b.rect.midY) > tolerance {
                return a.rect.midY < b.rect.midY
            }
            return a.rect.minX < b.rect.minX
        }
        .map(\.text)
        .joined(separator: "\n")
    }
}
