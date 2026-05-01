import Foundation

nonisolated enum LocationReferenceExtractor {
    private static let coordinateRegex = try! NSRegularExpression(pattern: #"(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)"#)

    static func coordinates(from text: String) -> (latitude: Double, longitude: Double)? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = coordinateRegex.firstMatch(in: text, range: range), match.numberOfRanges >= 3 else { return nil }

        let latText = ns.substring(with: match.range(at: 1))
        let lonText = ns.substring(with: match.range(at: 2))
        guard let latitude = Double(latText), let longitude = Double(lonText) else { return nil }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }
}
