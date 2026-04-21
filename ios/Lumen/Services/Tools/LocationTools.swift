import Foundation
import MapKit
import UIKit

@MainActor
enum LocationTools {
    static func currentLocation() async -> String {
        await LocationProbe.currentDescription()
    }

    static func openDirections(destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "No destination provided." }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)") else {
            return "Couldn't build maps URL."
        }
        Task { await UIApplication.shared.open(url) }
        return "Opening Maps with directions to \(trimmed)."
    }

    static func searchNearby(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Need a search query (e.g. 'coffee')." }

        let coord = await LocationProbe.currentCoordinate()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let coord {
            request.region = MKCoordinateRegion(center: coord, latitudinalMeters: 3000, longitudinalMeters: 3000)
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let items = response.mapItems.prefix(5)
            if items.isEmpty { return "No places found for \"\(trimmed)\"." }
            return items.map { item in
                let name = item.name ?? "Place"
                let addr = [item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
                return "• \(name) — \(addr.isEmpty ? "nearby" : addr)"
            }.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }
}
