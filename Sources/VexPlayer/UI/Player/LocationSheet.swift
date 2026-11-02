import MapKit
import SwiftUI

/// Virtual GPS: click on the map or type coordinates.
struct LocationSheet: View {
    let session: InstanceSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastLatitude") private var latitude = 55.7539
    @AppStorage("lastLongitude") private var longitude = 37.6208
    @State private var camera: MapCameraPosition = .automatic
    @State private var status: String?

    private static let presets: [(String, Double, Double)] = [
        ("Москва", 55.7539, 37.6208), ("Санкт-Петербург", 59.9386, 30.3141), ("Минск", 53.9045, 27.5615),
        ("Алматы", 43.2389, 76.8897), ("Лондон", 51.5072, -0.1276), ("Нью-Йорк", 40.7128, -74.0060),
        ("Токио", 35.6762, 139.6503), ("Сеул", 37.5665, 126.9780),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Местоположение").font(.title3.bold())
                Spacer()
                Menu("Города") {
                    ForEach(Self.presets, id: \.0) { p in
                        Button(p.0) { select(p.1, p.2) }
                    }
                }
                .fixedSize()
            }
            MapReader { proxy in
                Map(position: $camera) {
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { latitude = c.latitude; longitude = c.longitude }
                }
            }
            .frame(minHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                TextField("Широта", value: $latitude, format: .number.precision(.fractionLength(5)))
                TextField("Долгота", value: $longitude, format: .number.precision(.fractionLength(5)))
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 520)
        .onAppear { select(latitude, longitude) }
    }

    private func select(_ lat: Double, _ lon: Double) {
        latitude = lat
        longitude = lon
        camera = .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                            span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2)))
    }

    private func apply() {
        Task {
            do {
                try await session.setLocation(latitude: latitude, longitude: longitude)
                status = "Готово: \(String(format: "%.5f, %.5f", latitude, longitude))"
            } catch {
                status = "Ошибка: \(error.localizedDescription)"
            }
        }
    }
}
