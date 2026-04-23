import Foundation
import MapKit
import UIKit

@MainActor
enum LocationTools {
    static func currentLocation() async -> String {
        await LocationProbe.currentDescription()
    }

    static func openDirections(destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No destination provided." }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)") else {
            return "Couldn't build maps URL."
        }
        Task { await UIApplication.shared.open(url) }
        return "Opening Maps with directions to \(trimmed)."
    }

    static func searchNearby(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Need a nearby-place search query, for example `coffee near me`." }

        // Defense in depth: if the agent accidentally routes a generic research
        // or how-to query here, do not send it to MapKit. MapKit is for local
        // points of interest, not general web/search-engine lookups.
        if ToolRouteGuard.shouldUseWebSearchInsteadOfNearbySearch(query: trimmed) {
            return await WebTools.webSearch(query: trimmed)
        }

        let coord = await LocationProbe.currentCoordinate()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let coord {
            request.region = MKCoordinateRegion(center: coord, latitudinalMeters: 3000, longitudinalMeters: 3000)
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let items = response.mapItems.prefix(5)
            if items.isEmpty { return "No nearby places found for \"\(trimmed)\"." }
            return items.map { item in
                let name = item.name ?? "Place"
                let addr = [item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
                return "• \(name) — \(addr.isEmpty ? "nearby" : addr)"
            }.joined(separator: "\n")
        } catch {
            return localSearchFailureMessage(error: error, query: trimmed)
        }
    }

    private static func localSearchFailureMessage(error: Error, query: String) -> String {
        let nsError = error as NSError
        if nsError.domain == MKErrorDomain {
            switch nsError.code {
            case MKError.Code.placemarkNotFound.rawValue:
                return "No nearby places found for \"\(query)\". This tool only searches local map places; use web.search for general web research."
            case MKError.Code.directionsNotFound.rawValue:
                return "Maps could not find directions for \"\(query)\". Try a more specific address or place name."
            case MKError.Code.serverFailure.rawValue:
                return "Apple Maps search is temporarily unavailable. Try again later or use web.search for non-local information."
            case MKError.Code.loadingThrottled.rawValue:
                return "Apple Maps search is rate-limited right now. Wait briefly and retry."
            default:
                return "Apple Maps could not complete the nearby search for \"\(query)\". Use this tool only for local places such as coffee shops, pharmacies, stores, or addresses."
            }
        }
        return "Apple Maps could not complete the nearby search for \"\(query)\": \(error.localizedDescription)"
    }
}
