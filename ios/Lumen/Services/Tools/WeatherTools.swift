import Foundation
import CoreLocation

@MainActor
enum WeatherTools {
    static func currentWeather(location: String? = nil) async -> String {
        let coordinate: CLLocationCoordinate2D?
        let requestedLocation = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if requestedLocation.isEmpty || requestedLocation.lowercased() == "current" || requestedLocation.lowercased() == "here" {
            coordinate = await LocationProbe.currentCoordinate()
        } else {
            coordinate = await geocode(requestedLocation)
        }

        guard let coordinate else {
            return "I need location access, or a city name, to check the weather. Try asking `weather in Montreal` or enable Location permission."
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.5f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.5f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,cloud_cover,wind_speed_10m,wind_gusts_10m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]

        guard let url = components?.url else {
            return "Couldn't build the weather request."
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Lumen iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return "Weather service returned HTTP \(http.statusCode). Try again later."
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else {
                return "Couldn't parse the weather response."
            }

            let temp = currentDouble(current, "temperature_2m")
            let apparent = currentDouble(current, "apparent_temperature")
            let humidity = currentDouble(current, "relative_humidity_2m")
            let wind = currentDouble(current, "wind_speed_10m")
            let gusts = currentDouble(current, "wind_gusts_10m")
            let precipitation = currentDouble(current, "precipitation")
            let cloud = currentDouble(current, "cloud_cover")
            let code = Int(currentDouble(current, "weather_code") ?? -1)
            let time = current["time"] as? String ?? "now"

            var parts: [String] = []
            parts.append("Weather \(requestedLocation.isEmpty ? "at your location" : "for \(requestedLocation)"):")
            if code >= 0 { parts.append(weatherDescription(code)) }
            if let temp { parts.append(String(format: "%.0f°C", temp)) }
            if let apparent { parts.append(String(format: "feels like %.0f°C", apparent)) }
            if let humidity { parts.append(String(format: "humidity %.0f%%", humidity)) }
            if let wind { parts.append(String(format: "wind %.0f km/h", wind)) }
            if let gusts, gusts > (wind ?? 0) + 5 { parts.append(String(format: "gusts %.0f km/h", gusts)) }
            if let precipitation, precipitation > 0 { parts.append(String(format: "precipitation %.1f mm", precipitation)) }
            if let cloud { parts.append(String(format: "cloud cover %.0f%%", cloud)) }
            parts.append("updated \(time)")

            return parts.joined(separator: " · ")
        } catch {
            return "Couldn't load weather: \(error.localizedDescription)"
        }
    }

    private static func geocode(_ text: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(text) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }

    private static func currentDouble(_ dict: [String: Any], _ key: String) -> Double? {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? String { return Double(value) }
        return nil
    }

    private static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75: return "snow"
        case 77: return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "weather code \(code)"
        }
    }
}
