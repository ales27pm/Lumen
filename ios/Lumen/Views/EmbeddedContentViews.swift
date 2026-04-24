import SwiftUI
import WebKit
import MapKit

struct EmbeddedWebBrowserSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmbeddedWebView(url: url)
                .navigationTitle(url.host() ?? "Browser")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct EmbeddedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        webView.load(req)
    }
}

struct EmbeddedMapSheet: View {
    let query: String
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var marker: SearchMarker?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let marker {
                    Map(position: $position) {
                        Marker(marker.name, coordinate: marker.coordinate)
                    }
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.slash")
                            .font(.title2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView("Loading map…")
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) {
                await resolveLocation()
            }
        }
    }

    private func resolveLocation() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                errorMessage = "Couldn't find \(query)."
                return
            }
            let coordinate = item.placemark.coordinate
            marker = SearchMarker(name: item.name ?? query, coordinate: coordinate)
            position = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 1200,
                longitudinalMeters: 1200
            ))
            errorMessage = nil
        } catch {
            errorMessage = "Map search failed: \(error.localizedDescription)"
        }
    }
}

private struct SearchMarker {
    let name: String
    let coordinate: CLLocationCoordinate2D
}
