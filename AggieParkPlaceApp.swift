// SPDX-License-Identifier: LicenseRef-UPP-NC-1.0
// Copyright (c) 2025 Mixin Zhao

// Uses coordinate exclusions to reduce false positives.
// Geofences are approximate; accuracy varies by device/iOS.
// Uses UC Davis as an example (Aggie ParkPlace). 
// Assumes one parking payment per day, even if you change lots. 

// License & disclaimers:
// - See LICENSE for terms and warranty/liability disclaimer.
// - See DISCLAIMER.md for limits (no legal/compliance guarantee, background limits, etc.).
// Not affiliated with or endorsed by UC Davis, AIMS Mobile Pay, or Apple.


import SwiftUI
import UIKit
import CoreLocation
import MapKit
import UserNotifications
import Foundation

// Narrower geofence + search box focused on campus core
private let desiredGeofenceRadius: CLLocationDistance = 150   // was 150
private let maxActiveGeofences = 19
private let campusCenter = CLLocationCoordinate2D(latitude: 38.5390, longitude: -121.7500)

private let campusLatRange = 38.528...38.555                   // was 38.50...38.57
private let campusLonRange = (-121.785)...(-121.742)           // was (-121.79)...(-121.70)

// Shrink the MKLocalSearch region so it returns fewer off-campus hits
private let campusSearchSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

// When moving this far from the last anchor, we’ll reshuffle the nearest 20
private let reshuffleThresholdMeters: CLLocationDistance = 400

struct Lot: Identifiable {
    let id: String            // stable
    let name: String
    let coordinate: CLLocationCoordinate2D
    let distance: CLLocationDistance
}

@main
struct UCD_Parking_PingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = AppCoordinator()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator.geo)
                .onAppear { coordinator.bootstrap() } // now only starts location; NOT notification wiring
        }
    }
}

final class AppCoordinator: ObservableObject {
    // Reference the shared instance instead of creating a new one
    let geo = GeoManager.shared

    func bootstrap() {
        geo.bootstrap()
    }
}

struct LoadingButton: View {
    let title: String
    @Binding var isLoading: Bool
    let action: () -> Void

    private let height: CGFloat = 50

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: height/2, style: .continuous)
                    .fill(Color.blue)
                    .frame(height: height) // ← fixed height & width from parent
                Text(title)
                    .foregroundColor(.white)
                    .font(.headline)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .contentShape(Rectangle()) // reliable hit test
        }
        .buttonStyle(PressableButtonStyle())          // ← instant press feedback
        .disabled(isLoading)
    }
}

struct StatusBar: View {
    let text: String
    private let height: CGFloat = 36   // 18 for 1 line, ~36 for 2 lines

    var body: some View {
        ZStack {
            Text(text.isEmpty ? " " : text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.95)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)          // reserves space → no reflow
    }
}

struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct PayControlsView: View {
    @EnvironmentObject var geo: GeoManager
    private let pillH: CGFloat = 48

    private var locked: Bool { !geo.payFlowActive }  // locked until T0 fires

    // Dynamic colors for locked vs unlocked
    private var ampBG: Color     { locked ? .gray.opacity(0.15)   : Color.blue.opacity(0.15) }
    private var paidBG: Color    { locked ? .gray.opacity(0.15)   : Color.green.opacity(0.20) }
    private var laterBG: Color   { locked ? .gray.opacity(0.15)   : Color.orange.opacity(0.20) }
    private var labelColor: Color { locked ? .secondary : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                Text("Parking payment")
                    .font(.headline)
                Spacer()
                StatusPill(title: locked ? "Locked" : "Ready",
                           color: locked ? .secondary : .green)
            }

            Text(locked
                 ? "Unlocks after you enter a UC Davis lot."
                 : "Mark as paid or set a reminder.")
            .font(.footnote)
            .foregroundColor(.secondary)

            // Open AMP
            Button {
                geo.openAmp()
            } label: {
                Text("Open AMP")
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .frame(maxWidth: .infinity, minHeight: pillH)
                    .contentShape(Rectangle())
            }
            .foregroundColor(labelColor)
            .background(ampBG)
            .cornerRadius(12)
            .disabled(locked)

            // Two equal-sized action buttons
            HStack(spacing: 12) {
                Button {
                    geo.markPaidFromUI()
                } label: {
                    Text("I paid")
                        .lineLimit(1)
                        .minimumScaleFactor(0.95)
                        .frame(maxWidth: .infinity, minHeight: pillH)
                        .contentShape(Rectangle())
                }
                .foregroundColor(labelColor)
                .background(paidBG)
                .cornerRadius(12)
                .disabled(locked)

                Button {
                    geo.remindLaterFromUI()
                } label: {
                    Text("Remind me later")
                        .lineLimit(1)
                        .minimumScaleFactor(0.90)
                        .frame(maxWidth: .infinity, minHeight: pillH)
                        .contentShape(Rectangle())
                }
                .foregroundColor(labelColor)
                .background(laterBG)
                .cornerRadius(12)
                .disabled(locked)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// Small, readable state chip
private struct StatusPill: View {
    let title: String
    let color: Color
    var body: some View {
        Text(title)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// Light haptic on taps
private func hapticLight() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}


struct ContentView: View {
    @EnvironmentObject var geo: GeoManager

    
    var body: some View {
        VStack(spacing: 16) {
            Text("Aggie ParkPlace").font(.title).bold()
            Text("Notifies you when you enter a UC Davis lot.")
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                Text("Location permission: \(geo.permissionLabel)")
                    .font(.caption).foregroundColor(.secondary)
                Text("Arrival alerts require “Always” Location and Notifications.")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            LoadingButton(title: "Refresh lots now", isLoading: $geo.isSearching) {
                geo.checkAuthorizationAndProceed()
            }
            .padding(.horizontal) // Give the button some side padding

            StatusBar(text: geo.statusText)

            if geo.needsSettingsHop {
                Button("Open Settings") { geo.openSettings() }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.gray.opacity(0.2)).cornerRadius(10)
            }
            // Always render the panel; disable + dim until the first notification (T0) fires.
            VStack(spacing: 6) {
                PayControlsView()
                    .environmentObject(geo)
                }

            if geo.notificationDenied {
                Button("Enable notifications") { geo.openSettings() }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2)).cornerRadius(10)
            }
        }
        .padding()
        // 👇 Put them HERE on the OUTERMOST container
        .animation(nil, value: geo.statusText)
        .animation(nil, value: geo.permissionLabel)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                geo.refreshLotsAndRegions()

                }
    }
}

// Top of class
/// Phase 2.0 adds a longer global throttle + daily cap to block further banners that day.
final class GeofenceEventRouter {
    static let shared = GeofenceEventRouter()
    private init() {}
    
    // Persisted pending IDs
    private var _pending30ID: String? {
        get { UserDefaults.standard.string(forKey: UDKey.pending30ID) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.pending30ID) }
    }
    private var _pending60ID: String? {
        get { UserDefaults.standard.string(forKey: UDKey.pending60ID) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.pending60ID) }
    }

    private func cancelAllPendingLocked() {
        var toCancel: [String] = []
        if let a = _pending30ID { toCancel.append(a) }
        if let b = _pending60ID { toCancel.append(b) }
        if !toCancel.isEmpty { NotificationHandler.cancelPending(toCancel) }
        _pending30ID = nil
        _pending60ID = nil
    }
    
    // MARK: - Phase 3 stubs (safe to add now)

    func handleUserOpenedNotification() {
        gateQueue.sync {
            ensureDayContextLocked()
            cancelAllPendingLocked()        // cancel 30m / 60m if they exist
            _flowStage = .completed
            _lastNotifyAt = Date()
        }
    }

    func handleUserMarkedPaid() {
        gateQueue.sync {
            ensureDayContextLocked()
            cancelAllPendingLocked()
            _flowStage = .completed
            _lastNotifyAt = Date()
        }
    }

    func handleUserSnooze(requestID: String?) {
        gateQueue.sync {
            ensureDayContextLocked()

            let cameFrom30 = (requestID != nil && requestID == _pending30ID)

            if cameFrom30 {
                // Snoozed the 30-minute reminder → schedule the final +1h
                if let id = _pending30ID { NotificationHandler.cancelPending([id]) }
                _pending30ID = nil

                let id = NotificationHandler.schedule(
                    title: "Reminder: pay for parking",
                    body: "Final reminder today.",
                    category: "PAY_OPEN",     // keep final as plain tap-to-open; change to PAY_DECIDE if you want buttons
                    in: 60 * 60
                )
                _pending60ID = id
                _flowStage = .finalScheduled
            } else {
                // Snoozed at T0 → (re)schedule the 30-minute reminder from *now*
                if let id = _pending30ID { NotificationHandler.cancelPending([id]) }
                let id = NotificationHandler.schedule(
                    title: "Pay for parking?",
                    body: "Mark as paid or get one more reminder.",
                    category: "PAY_DECIDE",   // the “old” category with buttons
                    in: 30 * 60
                )
                _pending30ID = id
                _flowStage = .secondScheduled
            }

            _lastNotifyAt = Date()
        }
    }

    // MARK: - Phase 2.0 state (persisted)
    private enum FlowStage: Int {
        case none = 0, initialSent, secondScheduled, finalScheduled, completed
    }

    // Keys for UserDefaults
    private enum UDKey {
        static let flowDay     = "router.flowDay"
        static let flowStage   = "router.flowStage"
        static let lastNotify  = "router.lastNotifyAt"
        static let pending30ID = "router.pending30ID" // reserved for Phase 3
        static let pending60ID = "router.pending60ID" // reserved for Phase 3
    }

    // Global throttle (Phase 2.0): prevents rapid re-starts of today's chain
    private let globalMinGap: TimeInterval = 120
    // Not used to decide if today's chain may start—that’s globalMinGap + daily cap.
    
    // Day formatter (yyyy-MM-dd)
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Day + stage state
    private var _flowDay: String? {
        get { UserDefaults.standard.string(forKey: UDKey.flowDay) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.flowDay) }
    }
    private var _flowStage: FlowStage {
        get {
            let raw = UserDefaults.standard.integer(forKey: UDKey.flowStage)
            return FlowStage(rawValue: raw) ?? .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: UDKey.flowStage) }
    }
    
    private var _lastNotifyAt: Date? {
        get { UserDefaults.standard.object(forKey: UDKey.lastNotify) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.lastNotify) }
    }

    // Helpers
    private func todayString(_ date: Date = Date()) -> String {
        Self.dayFormatter.string(from: date)
    }

    private func ensureDayContextLocked(now: Date = Date()) {
        let today = todayString(now)
        if _flowDay != today {
            _flowDay = today
            _flowStage = .none
            UserDefaults.standard.removeObject(forKey: UDKey.pending30ID)
            UserDefaults.standard.removeObject(forKey: UDKey.pending60ID)
            _lastNotifyAt = nil                  // ← reset daily throttle
        }
    }

    private func passesGlobalThrottleLocked(now: Date = Date()) -> Bool {
        guard let last = _lastNotifyAt else { return true }
        return now.timeIntervalSince(last) >= globalMinGap
    }

    private func canStartTodayLocked(now: Date = Date()) -> Bool {
        ensureDayContextLocked(now: now)
        // Only allow a chain if none has started today, and throttle bounce.
        guard _flowStage == .none else { return false }
        return passesGlobalThrottleLocked(now: now)
    }

    @discardableResult
    private func markChainStartedLocked(now: Date = Date()) -> Bool {
        guard canStartTodayLocked(now: now) else { return false }
        _flowStage = .initialSent
        _flowDay = todayString(now)
        _lastNotifyAt = now
        return true
    }

    // Temporary micro-dedupe to absorb paired enter/inside callbacks
    // AFTER (properties)
    private let gateQueue = DispatchQueue(label: "GeofenceEventRouter.gate")

    
    // Inside GeofenceEventRouter
    private func scheduleFollowUpsLocked() {
        let id = NotificationHandler.schedule(
            title: "Pay for parking?",
            body: "Mark as paid or get one more reminder.",
            category: "PAY_DECIDE",
            in: 30 * 60
        )
        _pending30ID = id
        _flowStage = .secondScheduled
        _lastNotifyAt = Date()
    }

    func handleRegionEnter(regionID: String) {
        var shouldPostT0 = false
        gateQueue.sync {
            if markChainStartedLocked() {
                scheduleFollowUpsLocked()
                shouldPostT0 = true
            }
        }
        if shouldPostT0 {
            NotificationHandler.notifyPayNow(
                title: "Entered UC Davis parking",
                body: "Tap to pay for parking."
            )
            DispatchQueue.main.async { GeoManager.shared.payFlowActive = true }
        }
    }

    func handleRegionInside(regionID: String) {
        var shouldPostT0 = false
        gateQueue.sync {
            if markChainStartedLocked() {
                scheduleFollowUpsLocked()
                shouldPostT0 = true
            }
        }
        if shouldPostT0 {
            NotificationHandler.notifyPayNow(
                title: "In UC Davis parking",
                body: "Tap to pay for parking."
            )
            DispatchQueue.main.async { GeoManager.shared.payFlowActive = true }
        }
    }


}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var bgLM: CLLocationManager?
    let notif = NotificationHandler()
    // No longer needs to conform to CLLocationManagerDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = notif
        NotificationHandler.registerCategories(center)

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Immediately reflect the result in UI/state
            GeoManager.shared.updateNotificationAuthFromPrompt(granted: granted, error: error)
            
        }

        // If launched for a location event, create a location manager.
        // Retain the manager so iOS can deliver the pending region callbacks.
        // IMPORTANT: Do NOT start updates or monitoring on bgLM. It exists only to receive the wake.
        if launchOptions?[.location] != nil {
            let lm = CLLocationManager()
            lm.delegate = GeoManager.shared
            lm.pausesLocationUpdatesAutomatically = true // harmless conservative hint
            bgLM = lm
            
            GeoManager.shared.ensureSentinelArmed()   // ⬅️ arm it
            GeoManager.shared.requestSentinelState()  // then query state
        }
        return true
    }
}

// MARK: - Location / Geofencing (permission-safe)
final class GeoManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = GeoManager() // Make it a singleton
    
    private let lm = CLLocationManager()
    @Published var statusText: String = "Requesting location permission…"
    @Published var lots: [Lot] = []
    @Published var needsSettingsHop: Bool = false
    @Published var permissionLabel: String = "Not determined"
    @Published var notificationDenied: Bool = false
    @Published var isSearching: Bool = false
    @Published var payFlowActive: Bool = false   // show in-app controls when a chain is active

    private var lastKnownLocation: CLLocation?
    private let askedForAlwaysKey = "askedForAlwaysKey"
    private var precisionModeActive = false
    private var precisionStopWorkItem: DispatchWorkItem?
    // GeoManager.swift – near your other constants
    private let excludedCoordinates = [
        CLLocationCoordinate2D(latitude: 38.547401850985445, longitude: -121.76088731557454)
    ]
    private var monitoredSentinel: CLCircularRegion?
    private let showPrecisionStatusUI = false

    // MARK: - Campus sentinel (always-armed wake region)
    static let campusSentinelID = "campus.sentinel"

    func campusSentinel() -> CLCircularRegion {
        // Use the device max (≈1 km) so you cross it a bit before the lots
        let radius = min(lm.maximumRegionMonitoringDistance, 1000)
        let r = CLCircularRegion(center: campusCenter,
                                 radius: radius,
                                 identifier: Self.campusSentinelID)
        r.notifyOnEntry = true
        r.notifyOnExit = false
        return r
    }

    /// Ask CL for current sentinel state (used on background wakes)
    func requestSentinelState() {
        if let s = monitoredSentinel {
            lm.requestState(for: s)
            return
        }
        if let s = lm.monitoredRegions
            .first(where: { $0.identifier == Self.campusSentinelID }) as? CLCircularRegion {
            monitoredSentinel = s
            lm.requestState(for: s)
            return
        }
        // Fallback: arm then request
        ensureSentinelArmed()
        if let s = monitoredSentinel {
            lm.requestState(for: s)
        }
    }


    private let campusGateMeters: CLLocationDistance = 15_000 // 15 km

    private func nearCampus(_ loc: CLLocation) -> Bool {
        let cc = CLLocation(latitude: campusCenter.latitude, longitude: campusCenter.longitude)
        return loc.distance(from: cc) <= campusGateMeters
    }

    // Returns true if this coordinate is within `threshold` metres of any excluded point
    private func isExcluded(_ coordinate: CLLocationCoordinate2D, threshold: CLLocationDistance = 50) -> Bool {
        let candidateLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return excludedCoordinates.contains { exclusion in
            let excludedLocation = CLLocation(latitude: exclusion.latitude, longitude: exclusion.longitude)
            return candidateLocation.distance(from: excludedLocation) < threshold
        }
    }
    
    private struct ParkingCandidate {
            let region: CLCircularRegion
            let name: String
        }
    private func setStatus(_ s: String) {
        onMain { if self.statusText != s { self.statusText = s } }
    }

    // Make the initializer private so only the singleton can be created
    private override init() {
        super.init()
    }
    
    // Small helper to guarantee main-thread updates for @Published state.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // Dedupe by ~10 m grid to avoid near-duplicates
    private func key(_ c: CLLocationCoordinate2D) -> String {
        let lat = (c.latitude * 1e4).rounded() / 1e4
        let lon = (c.longitude * 1e4).rounded() / 1e4
        return "\(lat),\(lon)"
    }
    
    // ---- Entry point ----
    func bootstrap() {
        lm.delegate = self
        lm.pausesLocationUpdatesAutomatically = true
        updatePermissionLabel()
        checkAuthorizationAndProceed()
        checkNotificationAuthorization()
    }

    private func updatePermissionLabel() {
        // safe to write via onMain to avoid “Publishing changes from background threads” warnings
        switch lm.authorizationStatus {
        case .authorizedAlways:
            onMain { self.permissionLabel = "Always" }
        case .authorizedWhenInUse:
            onMain {
                self.permissionLabel = "While Using the App"
                if !self.statusText.lowercased().contains("background") {
                    self.statusText = "Location ready (While Using). Background arrival alerts require “Always”."
                }
            }
        case .denied, .restricted:
            onMain { self.permissionLabel = "Never / Ask Next Time or When I Share" }
        case .notDetermined:
            onMain { self.permissionLabel = "Not determined" }
        @unknown default:
            onMain { self.permissionLabel = "Unknown" }
        }
    }
    
    private func maybeRequestAlwaysUpgrade() {
        guard lm.authorizationStatus == .authorizedWhenInUse else { return }
        let alreadyAsked = UserDefaults.standard.bool(forKey: askedForAlwaysKey)
        if !alreadyAsked {
            UserDefaults.standard.set(true, forKey: askedForAlwaysKey)
            lm.requestAlwaysAuthorization()
        }
    }
    
    private func stopAllRegions(except ids: Set<String> = []) {
        let work = {
            let toStop = Array(self.lm.monitoredRegions.compactMap { $0 as? CLCircularRegion })
                .filter { !ids.contains($0.identifier) }
            for region in toStop { self.lm.stopMonitoring(for: region) }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // Open AMP app (fallback to web)
    func openAmp() {
        onMain {
            if let appURL = URL(string: "aimsmobilepay://"),
               UIApplication.shared.canOpenURL(appURL) {
                UIApplication.shared.open(appURL)
            } else if let web = URL(string: "https://aimsmobilepay.com") {
                UIApplication.shared.open(web)
            }
        }
    }

    private func startPrecisionMode(duration: TimeInterval = 120, reason: String) {
        guard !precisionModeActive else { return }
        precisionModeActive = true

        lm.allowsBackgroundLocationUpdates = true
        lm.pausesLocationUpdatesAutomatically = false
        lm.activityType = .automotiveNavigation
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = 10
        lm.startUpdatingLocation()

        if showPrecisionStatusUI {
            setStatus("Precision mode (\(reason))")
        } else {
            // DEBUG-only log, invisible to users
            #if DEBUG
            print("[Precision] start (\(reason))")
            #endif
        }

        let work = DispatchWorkItem { [weak self] in self?.stopPrecisionMode() }
        precisionStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func stopPrecisionMode() {
        guard precisionModeActive else { return }
        precisionStopWorkItem?.cancel(); precisionStopWorkItem = nil
        lm.stopUpdatingLocation()
        lm.allowsBackgroundLocationUpdates = false
        lm.pausesLocationUpdatesAutomatically = true
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.distanceFilter = kCLDistanceFilterNone
        precisionModeActive = false

        if showPrecisionStatusUI {
            setStatus("Precision mode ended")
        } else {
            // Keep existing status text; no user-facing change.
            #if DEBUG
            print("[Precision] end")
            #endif
        }
    }

    // In-app "I paid"
    func markPaidFromUI() {
        GeofenceEventRouter.shared.handleUserMarkedPaid()
        onMain { self.payFlowActive = false
            self.stopPrecisionMode()   }
    }

    // In-app "Remind me later" (same as tapping banner action at T0)
    func remindLaterFromUI() {
        GeofenceEventRouter.shared.handleUserSnooze(requestID: nil)
        onMain { self.payFlowActive = true }
    }

    
    // GeoManager
    func checkNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.onMain {
                let allowed: Bool
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: allowed = true
                default: allowed = false
                }
                self.notificationDenied = !allowed
                if !allowed { self.setStatus("Notifications are off or quiet. Enable alerts in Settings to get entry reminders.") }
            }
        }
    }

    /// Called once right after the system prompt in AppDelegate.
    func updateNotificationAuthFromPrompt(granted: Bool, error: Error?) {
        onMain {
            self.notificationDenied = !granted
            if !granted {
                self.setStatus("Notifications are off. Enable alerts to get entry reminders.")
            }
            // Optional: log the underlying error in DEBUG
            #if DEBUG
            if let error { print("UN auth error:", error.localizedDescription) }
            #endif
        }
    }

    func ensureSentinelArmed() {
        // If already monitoring, cache the instance and return
        if let s = lm.monitoredRegions
            .first(where: { $0.identifier == Self.campusSentinelID }) as? CLCircularRegion {
            monitoredSentinel = s
            return
        }
        // Otherwise start and retain
        let r = campusSentinel()
        lm.startMonitoring(for: r)
        monitoredSentinel = r
    }

    
    // Centralized permission logic
    func checkAuthorizationAndProceed() {
        updatePermissionLabel()
        switch lm.authorizationStatus {
        case .notDetermined:
            onMain {
                self.setStatus("Requesting permission…")
                self.needsSettingsHop = false
            }
            lm.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            onMain { self.needsSettingsHop = false }
            startServices()
            maybeRequestAlwaysUpgrade() // Now only called in the correct context

        case .authorizedAlways:
            onMain { self.needsSettingsHop = false }
            startServices() // No upgrade needed, just start services

        case .denied, .restricted:
            onMain {
                self.needsSettingsHop = true
                self.setStatus("Location denied. Open Settings to enable Ask Next Time, While Using, or Always.")
            }
            stopServices()
            clearData()

        @unknown default:
            onMain { self.setStatus("Unknown authorization state.") }
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        onMain { self.statusText = "Monitoring failed: \(error.localizedDescription)" }
    }

    private func stopServices() {
        lm.stopUpdatingLocation()
        lm.stopMonitoringSignificantLocationChanges()
        stopAllRegions()
    }

    private func clearData() {
        onMain { self.lots = [] }
    }

    private func startServices() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            onMain { self.statusText = "Region monitoring unavailable on this device." }
            return
        }
        lm.activityType = .automotiveNavigation
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.startMonitoringSignificantLocationChanges()
        lm.requestLocation()

        // 🔹 Always ensure the sentinel is armed
        ensureSentinelArmed()

        self.setStatus("Location ready. Refreshing UC Davis lots…")
        refreshLotsAndRegions()
    }


    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        checkAuthorizationAndProceed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }

        let isFirstFix = (lastKnownLocation == nil)
        let movedFar = lastKnownLocation.map { newest.distance(from: $0) >= reshuffleThresholdMeters } ?? false

        // Always keep the latest anchor
        lastKnownLocation = newest

        // Only trigger a refresh when not already searching
        if !isSearching && (isFirstFix || movedFar) {
            refreshLotsAndRegions()
        }
        // If we are near campus and have monitored regions, ramp up temporarily.
        if nearCampus(newest),
           !precisionModeActive,
           nearestRegionDistance(to: newest) < 1000 {          // 1 km is a good threshold
            startPrecisionMode(duration: 90, reason: "near lot")
        }
        // If we already turned it on, do a quick manual check to end early.
        if precisionModeActive {
            if newest.horizontalAccuracy > 0 && newest.horizontalAccuracy < 25 {
                for region in lm.monitoredRegions {
                    guard let r = region as? CLCircularRegion else { continue }
                    // ⬇️ Skip the sentinel — only treat *lot* regions as “inside”
                    if r.identifier == Self.campusSentinelID { continue }

                    if r.contains(newest.coordinate) {
                        GeofenceEventRouter.shared.handleRegionInside(regionID: r.identifier)
                        DispatchQueue.main.async { self.payFlowActive = true }
                        stopPrecisionMode()
                        break
                    }
                }
            }
        }

    }

    private func nearestRegionDistance(to loc: CLLocation) -> CLLocationDistance {
        let regions = lm.monitoredRegions.compactMap { $0 as? CLCircularRegion }
        guard !regions.isEmpty else { return .greatestFiniteMagnitude }
        return regions.map {
            CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude).distance(from: loc)
        }.min() ?? .greatestFiniteMagnitude
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onMain {
            // Default message for unexpected errors
            var friendlyMessage = "An unknown location error occurred. Please try again."

            // Check if the error is from Core Location (CLError)
            if let clError = error as? CLError {
                switch clError.code {
                case .locationUnknown:
                    // This is our specific "kCLErrorDomain error 0"
                    friendlyMessage = "Couldn't get a location fix. Try moving outdoors and refreshing. 🛰️"
                case .denied:
                    // This error means the user denied permission in Settings
                    friendlyMessage = "Location access is denied. Please enable it in Settings."
                case .network:
                    // This error means there was a network issue
                    friendlyMessage = "Network issue. Please check your internet connection and try again."
                default:
                    friendlyMessage = "A location service error occurred. Please try again later."
                }
            }
            
            // Update the UI with our new friendly message
            self.setStatus(friendlyMessage)
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didDetermineState state: CLRegionState,
                         for region: CLRegion) {
        guard let c = region as? CLCircularRegion else { return }

        if c.identifier == Self.campusSentinelID, state == .inside {
            // Woke up and already inside the sentinel → re-arm lots
            refreshLotsAndRegions()
            startPrecisionMode(duration: 90, reason: "inside campus sentinel")
            return
        }

        if state == .inside {
            GeofenceEventRouter.shared.handleRegionInside(regionID: region.identifier)
            DispatchQueue.main.async { self.payFlowActive = true }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let c = region as? CLCircularRegion else { return }
        if c.identifier == Self.campusSentinelID {
            // Back near campus → re-arm lot regions now
            refreshLotsAndRegions()
            startPrecisionMode(duration: 90, reason: "entered campus sentinel")
            return
        }
        GeofenceEventRouter.shared.handleRegionEnter(regionID: c.identifier)
    }
    
    // Open Settings when denied
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        onMain { UIApplication.shared.open(url) }
    }
    
    // ---- Existing search API ----
    func refreshLotsAndRegions() {
        // Defensive: do nothing if not authorized
            let status = lm.authorizationStatus
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                onMain {
                    self.needsSettingsHop = (status == .denied || status == .restricted)
                    self.setStatus(self.needsSettingsHop
                        ? "Location denied. Open Settings to enable Ask Next Time, While Using, or Always."
                        : "Location permission not granted.")
                    self.lots = []
                }
                return
            }
        // Use last known location or bail if we don't have one
        let current = lastKnownLocation
        if let current, !nearCampus(current) {
            // Pause monitoring if too far
            stopAllRegions(except: [Self.campusSentinelID])
                onMain {
                    self.lots = []
                    self.setStatus("Paused (too far from campus) — sentinel armed")
                }
                return
            }

        onMain { self.isSearching = true }

        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "parking"
        req.region = MKCoordinateRegion(center: campusCenter, span: campusSearchSpan)

        MKLocalSearch(request: req).start { [weak self] result, error in
            guard let self = self else { return }
            defer { self.onMain { self.isSearching = false } }

            if let error = error {
                self.setStatus("Search error: \(error.localizedDescription)")
                return
            }
            guard let items = result?.mapItems, !items.isEmpty else {
                self.onMain {
                    self.lots = []
                    self.setStatus("No parking results found.")
                }
                return
            }

            // Build candidate regions within campus bounds
            let candidates: [ParkingCandidate] = items.compactMap { item in
                let c = item.placemark.coordinate
                guard campusLatRange.contains(c.latitude),
                      campusLonRange.contains(c.longitude),
                      !self.isExcluded(c) else { return nil }
    
                let radius = min(self.lm.maximumRegionMonitoringDistance, desiredGeofenceRadius)
                let id = self.key(c) // stable, rounded identifier
                let region = CLCircularRegion(center: c, radius: radius, identifier: id)
                region.notifyOnEntry = true
                region.notifyOnExit = false

                let name = item.name ?? "Parking"
                return ParkingCandidate(region: region, name: name)
            }

            // Start/stop monitoring and update UI based on the anchor we chose
            self.applyMonitoredRegions(candidates)
        }
    }

    // 1) Recompute anchor inside apply (remove the anchor parameter)
    private func applyMonitoredRegions(_ candidates: [ParkingCandidate]) {
        DispatchQueue.global(qos: .userInitiated).async {
            // ⬇️ Use the freshest anchor you have *now*
            let anchor = self.lastKnownLocation
                ?? CLLocation(latitude: campusCenter.latitude, longitude: campusCenter.longitude)

            // Sort by distance to current anchor
            let sorted = candidates.sorted {
                let d0 = anchor.distance(from: CLLocation(latitude: $0.region.center.latitude, longitude: $0.region.center.longitude))
                let d1 = anchor.distance(from: CLLocation(latitude: $1.region.center.latitude, longitude: $1.region.center.longitude))
                return d0 < d1
            }

            var seen = Set<String>()
            var unique: [ParkingCandidate] = []
            unique.reserveCapacity(min(sorted.count, maxActiveGeofences))
            for c in sorted {
                let k = self.key(c.region.center)
                if seen.insert(k).inserted { unique.append(c) }
                if unique.count == maxActiveGeofences { break }
            }

            let selectedRegions = unique.map { $0.region }
            let newLots: [Lot] = unique.map { c in
                let d = anchor.distance(from: CLLocation(latitude: c.region.center.latitude, longitude: c.region.center.longitude))
                return Lot(id: self.key(c.region.center), name: c.name, coordinate: c.region.center, distance: d)
            }.sorted { $0.distance < $1.distance }

            self.onMain {
                // Start new ones
                var newlyStarted: [CLCircularRegion] = []
                for region in selectedRegions where self.lm.monitoredRegions.contains(where: { $0.identifier == region.identifier }) == false {
                    self.lm.startMonitoring(for: region)
                    newlyStarted.append(region)
                }

                // Probe only the actively monitored instances that match our selection
                for region in self.lm.monitoredRegions {
                    guard let cr = region as? CLCircularRegion,
                          cr.identifier != Self.campusSentinelID,
                          selectedRegions.contains(where: { $0.identifier == cr.identifier }) else { continue }
                    self.lm.requestState(for: cr)
                }

                // Stop any regions not selected (but never stop the sentinel)
                for existing in Array(self.lm.monitoredRegions) {
                    if let cr = existing as? CLCircularRegion,
                       cr.identifier != Self.campusSentinelID,
                       selectedRegions.contains(where: { $0.identifier == cr.identifier }) == false {
                        self.lm.stopMonitoring(for: cr)
                    }
                }

                self.lots = newLots
                self.setStatus("Monitoring \(selectedRegions.count) lots")
            }
        }
    }
} // ← close GeoManager

// MARK: - Notifications
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    // Existing category (kept for current behavior)
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    
    // Pre-register categories we’ll use in Phase 3 (harmless to register now)
    static var payOpenCategory: UNNotificationCategory {
        // Regular notification, no explicit actions; default tap opens AMP
        UNNotificationCategory(identifier: "PAY_OPEN",
                               actions: [],
                               intentIdentifiers: [],
                               options: [])
    }
    
    static var payDecideCategory: UNNotificationCategory {
        // Decision notification: “Paid” or “Remind me later”
        let paid = UNNotificationAction(identifier: "PAY_MARK_PAID",
                                        title: "Paid",
                                        options: []) // no foreground needed
        let later = UNNotificationAction(identifier: "PAY_REMIND_LATER",
                                         title: "Remind me later",
                                         options: []) // schedule follow-up later
        return UNNotificationCategory(identifier: "PAY_DECIDE",
                                      actions: [paid, later],
                                      intentIdentifiers: [],
                                      options: [])
    }
    
    /// Register all categories at launch so actions can render when used
    // AFTER (excerpt)
    static func registerCategories(_ center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([
            NotificationHandler.payOpenCategory,
            NotificationHandler.payDecideCategory
        ])
    }
    
    static func notifyPayNow(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "PAY_DECIDE"  // T0 now has “Paid” / “Remind me later”
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
    
    static func schedule(id: String = UUID().uuidString,
                         title: String,
                         body: String,
                         category: String,
                         in seconds: TimeInterval,
                         sound: UNNotificationSound? = .default,
                         completion: ((Error?) -> Void)? = nil) -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.categoryIdentifier = category

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req) { error in
            completion?(error)
        }
        return id
    }
    
    static func cancelPending(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
    
    static func removeDelivered(_ ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        
        let reqID = response.notification.request.identifier
        NotificationHandler.removeDelivered([reqID])
        
        switch response.actionIdentifier {
            
        case "PAY_MARK_PAID":
            GeofenceEventRouter.shared.handleUserMarkedPaid()
            DispatchQueue.main.async { GeoManager.shared.payFlowActive = false }
            
        case "PAY_REMIND_LATER":
            // T0 has no pending ID → pass nil. 30-min card has a real ID → pass it.
            let idToPass = (response.notification.request.content.categoryIdentifier == "PAY_DECIDE") ? reqID : nil
            GeofenceEventRouter.shared.handleUserSnooze(requestID: idToPass)
            DispatchQueue.main.async { GeoManager.shared.payFlowActive = true }
            
        case UNNotificationDefaultActionIdentifier:
            // User tapped the banner/body → open AMP and end the flow
            GeofenceEventRouter.shared.handleUserOpenedNotification()
            DispatchQueue.main.async {
                GeoManager.shared.payFlowActive = false
                if let appURL = URL(string: "aimsmobilepay://"),
                   UIApplication.shared.canOpenURL(appURL) {
                    UIApplication.shared.open(appURL)
                } else if let web = URL(string: "https://aimsmobilepay.com") {
                    UIApplication.shared.open(web)
                }
            }
            
        default:
            break
        }
        completionHandler()
    }
}
