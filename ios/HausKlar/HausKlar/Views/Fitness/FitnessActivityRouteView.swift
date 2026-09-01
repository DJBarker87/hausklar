import CoreLocation
import MapKit
import SwiftUI

struct FitnessLocalRouteSample: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let offsetMs: Int?

    init?(latitude: Double, longitude: Double, offsetMs: Int? = nil) {
        guard latitude.isFinite, longitude.isFinite,
            abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.offsetMs = offsetMs
    }

    init?(coordinate: CLLocationCoordinate2D, offsetMs: Int? = nil) {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            offsetMs: offsetMs
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct FitnessRouteUnitPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// A testable north-up projection for the private route Canvas. A shared scale
/// preserves route proportions and longitude is unwrapped at the date line.
struct FitnessLocalRouteProjection: Equatable, Sendable {
    let samples: [FitnessLocalRouteSample]
    let points: [FitnessRouteUnitPoint]

    init(samples input: [FitnessLocalRouteSample]) {
        let deduplicated = Self.removeConsecutiveDuplicates(input)
        samples = deduplicated
        guard !deduplicated.isEmpty else {
            points = []
            return
        }

        let longitudes = Self.unwrapLongitudes(deduplicated.map(\.longitude))
        let meanLatitude = deduplicated.map(\.latitude).reduce(0, +) / Double(deduplicated.count)
        let longitudeScale = max(0.01, cos(meanLatitude * .pi / 180))
        let raw = deduplicated.indices.map {
            FitnessRouteUnitPoint(
                x: longitudes[$0] * longitudeScale,
                y: deduplicated[$0].latitude
            )
        }
        let minimumX = raw.map(\.x).min() ?? 0
        let maximumX = raw.map(\.x).max() ?? 0
        let minimumY = raw.map(\.y).min() ?? 0
        let maximumY = raw.map(\.y).max() ?? 0
        let centreX = (minimumX + maximumX) / 2
        let centreY = (minimumY + maximumY) / 2
        let span = max(maximumX - minimumX, maximumY - minimumY)

        if span <= .ulpOfOne {
            points = raw.map { _ in FitnessRouteUnitPoint(x: 0, y: 0) }
        } else {
            points = raw.map {
                FitnessRouteUnitPoint(
                    x: ($0.x - centreX) / span,
                    y: (centreY - $0.y) / span
                )
            }
        }
    }

    func canvasPoints(in size: CGSize, padding: CGFloat) -> [CGPoint] {
        let availableWidth = max(1, size.width - padding * 2)
        let availableHeight = max(1, size.height - padding * 2)
        let scale = min(availableWidth, availableHeight)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return points.map {
            CGPoint(
                x: centre.x + CGFloat($0.x) * scale,
                y: centre.y + CGFloat($0.y) * scale
            )
        }
    }

    func selectedIndex(nearest offsetMs: Int?) -> Int? {
        guard let offsetMs else { return nil }
        return samples.indices
            .filter { samples[$0].offsetMs != nil }
            .min {
                abs((samples[$0].offsetMs ?? offsetMs) - offsetMs)
                    < abs((samples[$1].offsetMs ?? offsetMs) - offsetMs)
            }
    }

    func nearestIndex(to location: CGPoint, in size: CGSize, padding: CGFloat) -> Int? {
        let rendered = canvasPoints(in: size, padding: padding)
        return rendered.indices.min {
            rendered[$0].fitnessSquaredDistance(to: location)
                < rendered[$1].fitnessSquaredDistance(to: location)
        }
    }

    func nearestIndex(to coordinate: CLLocationCoordinate2D) -> Int? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return samples.indices.min {
            target.distance(
                from: CLLocation(
                    latitude: samples[$0].latitude,
                    longitude: samples[$0].longitude
                ))
                < target.distance(
                    from: CLLocation(
                        latitude: samples[$1].latitude,
                        longitude: samples[$1].longitude
                    ))
        }
    }

    func selectableIndex(nearest index: Int) -> Int? {
        samples.indices
            .filter { samples[$0].offsetMs != nil }
            .min { abs($0 - index) < abs($1 - index) }
    }

    func accessibilitySummary(selectedIndex: Int?) -> String {
        guard samples.count > 1 else { return "A single recorded position." }
        var parts = [
            endpointsAreClose
                ? "Start and finish are close together."
                : "Start and finish are marked."
        ]
        if !endpointsAreClose, let direction = endpointDirection {
            parts.append("The finish is \(direction) of the start.")
        }
        if let selectedIndex {
            let rawPercent = Double(selectedIndex) / Double(max(1, samples.count - 1)) * 100
            let percent = min(100, max(0, Int((rawPercent / 5).rounded()) * 5))
            parts.append("The selected position is \(percent) percent through the route.")
        } else {
            parts.append("No position is selected.")
        }
        return parts.joined(separator: " ")
    }

    var endpointsAreClose: Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        let direct = Self.distance(from: first, to: last)
        let travelled = zip(samples, samples.dropFirst()).reduce(0) {
            $0 + Self.distance(from: $1.0, to: $1.1)
        }
        return travelled > 0 && direct <= max(75, travelled * 0.05)
    }

    private var endpointDirection: String? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let longitudes = Self.unwrapLongitudes([first.longitude, last.longitude])
        guard longitudes.count == 2 else { return nil }
        let north = last.latitude - first.latitude
        let east =
            (longitudes[1] - longitudes[0])
            * cos(((last.latitude + first.latitude) / 2) * .pi / 180)
        guard abs(north) + abs(east) > .ulpOfOne else { return nil }
        let angle = atan2(east, north) * 180 / .pi
        switch angle {
        case -22.5..<22.5: return "north"
        case 22.5..<67.5: return "north-east"
        case 67.5..<112.5: return "east"
        case 112.5..<157.5: return "south-east"
        case -67.5 ..< -22.5: return "north-west"
        case -112.5 ..< -67.5: return "west"
        case -157.5 ..< -112.5: return "south-west"
        default: return "south"
        }
    }

    private static func removeConsecutiveDuplicates(
        _ values: [FitnessLocalRouteSample]
    ) -> [FitnessLocalRouteSample] {
        var result: [FitnessLocalRouteSample] = []
        for sample in values {
            guard let last = result.last else {
                result.append(sample)
                continue
            }
            if abs(last.latitude - sample.latitude) > 0.000_000_1
                || abs(last.longitude - sample.longitude) > 0.000_000_1
            {
                result.append(sample)
            }
        }
        return result
    }

    private static func unwrapLongitudes(_ values: [Double]) -> [Double] {
        guard let first = values.first else { return [] }
        return values.dropFirst().reduce(into: [first]) { result, raw in
            guard let previous = result.last else { return }
            var next = raw
            while next - previous > 180 { next -= 360 }
            while next - previous < -180 { next += 360 }
            result.append(next)
        }
    }

    private static func distance(
        from first: FitnessLocalRouteSample,
        to second: FitnessLocalRouteSample
    ) -> Double {
        let radius = 6_371_000.0
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let firstLatitude = first.latitude * .pi / 180
        let secondLatitude = second.latitude * .pi / 180
        let a =
            sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

enum FitnessLocalRoutePrivacyPolicy {
    static let usesAppleMapsBasemap = true
    static let requestsUserLocation = false
    static let usesThirdPartyMapSDK = false
}

enum FitnessRouteMapLoadState: Equatable {
    case loading
    case loaded
    case failed
}

enum FitnessAppleRouteViewport {
    static let minimumMapPointSpan = 1_200.0

    static func visibleMapRect(for samples: [FitnessLocalRouteSample]) -> MKMapRect {
        let coordinates = samples.map(\.coordinate)
        guard !coordinates.isEmpty else { return .world }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        var rect = polyline.boundingMapRect
        if rect.isNull {
            let point = MKMapPoint(coordinates[0])
            rect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
        }
        if rect.width < minimumMapPointSpan {
            rect.origin.x -= (minimumMapPointSpan - rect.width) / 2
            rect.size.width = minimumMapPointSpan
        }
        if rect.height < minimumMapPointSpan {
            rect.origin.y -= (minimumMapPointSpan - rect.height) / 2
            rect.size.height = minimumMapPointSpan
        }
        return rect
    }
}

private enum FitnessRouteAnnotationKind: String {
    case start
    case finish
    case selected
}

private final class FitnessRouteMapAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    let kind: FitnessRouteAnnotationKind

    init(coordinate: CLLocationCoordinate2D, kind: FitnessRouteAnnotationKind) {
        self.coordinate = coordinate
        self.kind = kind
    }
}

private struct FitnessAppleRouteMap: UIViewRepresentable {
    @Binding var selectedOffsetMs: Int?
    let projection: FitnessLocalRouteProjection
    let emphasized: Bool
    let onLoadStateChange: (FitnessRouteMapLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsTraffic = false
        mapView.showsBuildings = true
        mapView.showsScale = true
        mapView.showsCompass = false
        mapView.showsUserLocation = false
        mapView.userTrackingMode = .none
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.selectRoutePoint(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        context.coordinator.report(.loading)
        context.coordinator.configureRoute(on: mapView, force: true)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configureRoute(on: mapView, force: false)
        context.coordinator.updateSelection(on: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        mapView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: FitnessAppleRouteMap
        private var renderedSamples: [FitnessLocalRouteSample] = []
        private var routePolyline: MKPolyline?
        private var haloPolyline: MKPolyline?
        private var selectedAnnotation: FitnessRouteMapAnnotation?
        private var renderedSelection: Int?
        private var hasLoadedBasemap = false

        init(parent: FitnessAppleRouteMap) {
            self.parent = parent
        }

        func configureRoute(on mapView: MKMapView, force: Bool) {
            let samples = parent.projection.samples
            guard force || renderedSamples != samples else { return }
            renderedSamples = samples
            renderedSelection = nil

            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(
                mapView.annotations.filter { !($0 is MKUserLocation) }
            )
            selectedAnnotation = nil

            let coordinates = samples.map(\.coordinate)
            guard coordinates.count > 1 else { return }
            let halo = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let route = MKPolyline(coordinates: coordinates, count: coordinates.count)
            haloPolyline = halo
            routePolyline = route
            mapView.addOverlays([halo, route], level: .aboveRoads)

            if let first = coordinates.first, let last = coordinates.last {
                mapView.addAnnotations([
                    FitnessRouteMapAnnotation(coordinate: first, kind: .start),
                    FitnessRouteMapAnnotation(coordinate: last, kind: .finish),
                ])
            }

            mapView.setVisibleMapRect(
                FitnessAppleRouteViewport.visibleMapRect(for: samples),
                edgePadding: UIEdgeInsets(top: 34, left: 34, bottom: 34, right: 34),
                animated: false
            )
            updateSelection(on: mapView)
        }

        func updateSelection(on mapView: MKMapView) {
            guard renderedSelection != parent.selectedOffsetMs else { return }
            renderedSelection = parent.selectedOffsetMs
            if let selectedAnnotation {
                mapView.removeAnnotation(selectedAnnotation)
                self.selectedAnnotation = nil
            }
            guard let index = parent.projection.selectedIndex(nearest: parent.selectedOffsetMs),
                parent.projection.samples.indices.contains(index)
            else { return }
            let annotation = FitnessRouteMapAnnotation(
                coordinate: parent.projection.samples[index].coordinate,
                kind: .selected
            )
            selectedAnnotation = annotation
            mapView.addAnnotation(annotation)
        }

        @objc func selectRoutePoint(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                let mapView = recognizer.view as? MKMapView
            else { return }
            let coordinate = mapView.convert(
                recognizer.location(in: mapView),
                toCoordinateFrom: mapView
            )
            guard let nearest = parent.projection.nearestIndex(to: coordinate),
                let selectable = parent.projection.selectableIndex(nearest: nearest),
                let offset = parent.projection.samples[selectable].offsetMs
            else { return }
            parent.selectedOffsetMs = offset
            renderedSelection = nil
            updateSelection(on: mapView)
            HapticManager.selection()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
            if !hasLoadedBasemap { report(.loading) }
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            hasLoadedBasemap = true
            report(.loaded)
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            if !hasLoadedBasemap { report(.failed) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if let haloPolyline, polyline === haloPolyline {
                renderer.strokeColor = UIColor.systemBackground.withAlphaComponent(0.88)
                renderer.lineWidth = parent.emphasized ? 10 : 8
            } else {
                renderer.strokeColor = mapView.tintColor
                renderer.lineWidth = parent.emphasized ? 6 : 4.5
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? FitnessRouteMapAnnotation else { return nil }
            let identifier = "fitness-route-\(annotation.kind.rawValue)"
            let view =
                (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: identifier
                )
            view.annotation = annotation
            view.canShowCallout = false
            view.displayPriority = .required
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            switch annotation.kind {
            case .start:
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "play.fill")
            case .finish:
                view.markerTintColor = .label
                view.glyphImage = UIImage(systemName: "flag.checkered")
            case .selected:
                view.markerTintColor = .systemOrange
                view.glyphImage = UIImage(systemName: "scope")
            }
            return view
        }

        func report(_ state: FitnessRouteMapLoadState) {
            // Preserve the next-main-run-loop delivery used to keep MapKit's
            // delegate callback outside the current SwiftUI update transaction.
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.parent.onLoadStateChange(state)
            }
        }
    }
}

struct FitnessLocalRouteView: View {
    @Binding var selectedOffsetMs: Int?
    private let projection: FitnessLocalRouteProjection
    @State private var mapLoadState: FitnessRouteMapLoadState = .loading
    @State private var mapReloadID = UUID()

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let plotPadding: CGFloat = 24

    init(samples: [FitnessLocalRouteSample], selectedOffsetMs: Binding<Int?>) {
        projection = FitnessLocalRouteProjection(samples: samples)
        _selectedOffsetMs = selectedOffsetMs
    }

    private var selectedIndex: Int? {
        projection.selectedIndex(nearest: selectedOffsetMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Route").font(.headline)
                Spacer()
                if let selectedIndex {
                    Text(selectedProgress(selectedIndex))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    if mapLoadState == .failed {
                        accessibleRoute(
                            routeCanvas
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .gesture(
                                    SpatialTapGesture().onEnded { value in
                                        selectRoutePoint(at: value.location, size: proxy.size)
                                    }
                                )
                        )
                        mapFailure
                    } else {
                        accessibleRoute(
                            FitnessAppleRouteMap(
                                selectedOffsetMs: $selectedOffsetMs,
                                projection: projection,
                                emphasized: colorSchemeContrast == .increased,
                                onLoadStateChange: { mapLoadState = $0 }
                            )
                            .id(mapReloadID)
                        )
                        if mapLoadState == .loading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                                .padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .accessibilityLabel("Loading map")
                                .allowsHitTesting(false)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            Color.primary.opacity(
                                colorSchemeContrast == .increased ? 0.30 : 0.10
                            ))
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 300 : 240)
            routeLegend
        }
        .padding()
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private func accessibleRoute<Content: View>(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recorded route")
            .accessibilityIdentifier("fitnessActivityRoute")
            .accessibilityValue(
                projection.accessibilitySummary(selectedIndex: selectedIndex)
            )
            .accessibilityHint(
                "Tap the route, select a split, or adjust a chart to move the highlighted position."
            )
            .accessibilityAdjustableAction(moveSelection)
    }

    private var mapFailure: some View {
        HStack(spacing: 8) {
            Label("Map unavailable", systemImage: "map.fill")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            Button("Try map again") {
                mapLoadState = .loading
                mapReloadID = UUID()
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }

    private var routeCanvas: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            let rendered = projection.canvasPoints(in: canvasSize, padding: plotPadding)
            drawGrid(context: &context, size: canvasSize)
            guard rendered.count > 1 else { return }

            var route = Path()
            route.move(to: rendered[0])
            for point in rendered.dropFirst() { route.addLine(to: point) }
            let emphasized = colorSchemeContrast == .increased
            context.stroke(
                route,
                with: .color(Color(.systemBackground)),
                style: StrokeStyle(
                    lineWidth: emphasized ? 9 : 7,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            context.stroke(
                route,
                with: .color(Color.accentColor),
                style: StrokeStyle(
                    lineWidth: emphasized ? 5.5 : 4,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            drawStart(at: rendered[0], context: &context, emphasized: emphasized)
            drawFinish(
                at: rendered[rendered.count - 1],
                context: &context,
                emphasized: emphasized
            )
            if let selectedIndex, rendered.indices.contains(selectedIndex) {
                drawSelection(
                    at: rendered[selectedIndex],
                    context: &context,
                    emphasized: emphasized
                )
            }
            drawNorth(context: &context, size: canvasSize)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.30 : 0.10))
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let color = Color.secondary.opacity(colorSchemeContrast == .increased ? 0.30 : 0.13)
        for step in 1..<4 {
            let fraction = CGFloat(step) / 4
            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width * fraction, y: 0))
            vertical.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            context.stroke(vertical, with: .color(color), lineWidth: 1)

            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: size.height * fraction))
            horizontal.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            context.stroke(horizontal, with: .color(color), lineWidth: 1)
        }
    }

    private func drawStart(
        at point: CGPoint,
        context: inout GraphicsContext,
        emphasized: Bool
    ) {
        let diameter: CGFloat = emphasized ? 18 : 16
        let rect = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fill(Path(ellipseIn: rect), with: .color(Color.green))
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(Color(.systemBackground)),
            lineWidth: 2.5
        )
    }

    private func drawFinish(
        at point: CGPoint,
        context: inout GraphicsContext,
        emphasized: Bool
    ) {
        let radius: CGFloat = emphasized ? 10 : 9
        var diamond = Path()
        diamond.move(to: CGPoint(x: point.x, y: point.y - radius))
        diamond.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        diamond.addLine(to: CGPoint(x: point.x - radius, y: point.y))
        diamond.closeSubpath()
        context.fill(diamond, with: .color(Color.primary))
        context.stroke(diamond, with: .color(Color(.systemBackground)), lineWidth: 2.5)
    }

    private func drawSelection(
        at point: CGPoint,
        context: inout GraphicsContext,
        emphasized: Bool
    ) {
        let diameter: CGFloat = emphasized ? 28 : 24
        let rect = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .color(Color(.systemBackground).opacity(0.88))
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(Color.orange),
            lineWidth: emphasized ? 5 : 4
        )
        let centre = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: centre), with: .color(Color.orange))
    }

    private func drawNorth(context: inout GraphicsContext, size: CGSize) {
        let point = CGPoint(x: size.width - 18, y: 18)
        context.draw(
            Text("N").font(.caption.weight(.bold)).foregroundStyle(.secondary),
            at: point
        )
        var arrow = Path()
        arrow.move(to: CGPoint(x: point.x, y: point.y + 9))
        arrow.addLine(to: CGPoint(x: point.x, y: point.y + 19))
        arrow.move(to: CGPoint(x: point.x - 3, y: point.y + 12))
        arrow.addLine(to: CGPoint(x: point.x, y: point.y + 9))
        arrow.addLine(to: CGPoint(x: point.x + 3, y: point.y + 12))
        context.stroke(arrow, with: .color(Color.secondary), lineWidth: 1.5)
    }

    @ViewBuilder private var routeLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                legendItem("Start", systemImage: "circle.fill", color: .green)
                legendItem("Finish", systemImage: "diamond.fill", color: .primary)
                legendItem("Selected", systemImage: "scope", color: .orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                legendItem("Start", systemImage: "circle.fill", color: .green)
                legendItem("Finish", systemImage: "diamond.fill", color: .primary)
                legendItem("Selected", systemImage: "scope", color: .orange)
            }
        }
        .font(.caption.weight(.semibold))
        .accessibilityHidden(true)
    }

    private func legendItem(
        _ label: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            Text(label).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }

    private func selectedProgress(_ index: Int) -> String {
        let percent = Int(
            (Double(index) / Double(max(1, projection.samples.count - 1)) * 100).rounded()
        )
        return "Selected \(percent)%"
    }

    private func selectRoutePoint(at location: CGPoint, size: CGSize) {
        guard
            let nearest = projection.nearestIndex(
                to: location,
                in: size,
                padding: plotPadding
            ), let selectable = projection.selectableIndex(nearest: nearest),
            let offset = projection.samples[selectable].offsetMs
        else { return }
        selectedOffsetMs = offset
        HapticManager.selection()
    }

    private func moveSelection(_ direction: AccessibilityAdjustmentDirection) {
        let selectable = projection.samples.indices.filter {
            projection.samples[$0].offsetMs != nil
        }
        guard !selectable.isEmpty else { return }
        let current =
            selectedIndex.flatMap { selected in
                selectable.indices.min {
                    abs(selectable[$0] - selected) < abs(selectable[$1] - selected)
                }
            } ?? 0
        let next: Int
        switch direction {
        case .increment: next = min(selectable.count - 1, current + 1)
        case .decrement: next = max(0, current - 1)
        @unknown default: return
        }
        selectedOffsetMs = projection.samples[selectable[next]].offsetMs
    }
}

extension CGPoint {
    fileprivate func fitnessSquaredDistance(to other: CGPoint) -> CGFloat {
        let xDistance = x - other.x
        let yDistance = y - other.y
        return xDistance * xDistance + yDistance * yDistance
    }
}
