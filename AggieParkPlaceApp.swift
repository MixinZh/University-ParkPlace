// SPDX-License-Identifier: LicenseRef-UPP-NC-1.0
// Copyright (c) 2025 Mixin Zhao

// Uses coordinate exclusions to reduce false positives.
// Geofences are approximate; accuracy varies by device/iOS.
// Uses UC Davis as an example (Aggie ParkPlace). 
// Assumes one parking payment per day, even if you change lots. 

// License & disclaimers:
// - See LICENSE for terms and warranty/liability disclaimer.
// - See DISCLAIMERS for limits (no legal/compliance guarantee, background limits, etc.).
// Not affiliated with or endorsed by UC Davis, AIMS Mobile Pay, or Apple.


import SwiftUI
import UIKit
import CoreLocation
import MapKit
import UserNotifications
import Foundation
#if canImport(FirebaseCore)
import FirebaseCore
#endif

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
    @StateObject private var ticketManager = TicketManager.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator.geo)
                .environmentObject(ticketManager)
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

// MARK: - Brand palette (Aggie ParkPlace Design System)
// Refined UC-Davis-derived tokens: navy + gold + cream + a lighter
// "Aggie" blue than SwiftUI's stock .blue. See design bundle README.
enum Brand {
    static let navy    = Color(red: 0x0B/255.0, green: 0x2A/255.0, blue: 0x4A/255.0)
    static let navyInk = Color(red: 0x05/255.0, green: 0x1B/255.0, blue: 0x33/255.0)
    static let blue    = Color(red: 0x1E/255.0, green: 0x6F/255.0, blue: 0xB8/255.0)
    static let gold    = Color(red: 0xFD/255.0, green: 0xB5/255.0, blue: 0x15/255.0)
    static let cream   = Color(red: 0xF5/255.0, green: 0xEC/255.0, blue: 0xD4/255.0)
    static let goldInk = Color(red: 0x7A/255.0, green: 0x52/255.0, blue: 0x00/255.0)
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
                    .fill(Brand.blue)
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
    @EnvironmentObject var ticketManager: TicketManager
    private let pillH: CGFloat = 48

    private var locked: Bool { !geo.payFlowActive && !geo.paidToday }

    // Refined palette — brand-led tints per button role.
    // Open AMP is the primary call-to-action (solid lighter blue).
    // "I paid" uses a soft gold tint; "Remind me later" uses a soft blue tint.
    private var ampBG: Color     { locked ? Brand.blue.opacity(0.08) : Brand.blue }
    private var ampFG: Color     { locked ? Brand.blue.opacity(0.40) : .white }
    private var paidBG: Color    { locked ? Brand.blue.opacity(0.08) : Brand.gold.opacity(0.28) }
    private var paidFG: Color    { locked ? Brand.blue.opacity(0.40) : Brand.goldInk }
    private var laterBG: Color   { locked ? Brand.blue.opacity(0.08) : Brand.blue.opacity(0.12) }
    private var laterFG: Color   { locked ? Brand.blue.opacity(0.40) : Brand.blue }

    private var pillTone: StatusPill.Tone {
        if geo.paidToday { return .paid }
        if geo.payFlowActive { return .ready }
        return .locked
    }
    private var pillTitle: String {
        if geo.paidToday { return "Paid \u{2713}" }
        if geo.payFlowActive { return "Ready" }
        return "Locked"
    }
    private var subtitleText: String {
        if geo.paidToday { return "You\u{2019}ve paid for parking today." }
        if geo.payFlowActive { return "Mark as paid or set a reminder." }
        return "Unlocks after you enter a UC Davis lot."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                Text("Parking payment")
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Spacer()
                StatusPill(title: pillTitle, tone: pillTone)
            }

            Text(subtitleText)
            .font(.footnote)
            .foregroundColor(.secondary)

            if geo.paidToday {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Brand.goldInk)
                        .font(.title2)
                    Text("Paid today")
                        .font(.headline)
                        .foregroundColor(Brand.goldInk)
                }
                .frame(maxWidth: .infinity, minHeight: pillH)
                .background(Brand.gold.opacity(0.28))
                .cornerRadius(12)
            } else {
            // Open AMP — primary CTA (solid Aggie blue)
            Button {
                geo.openAmp()
            } label: {
                Text("Open AMP")
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .frame(maxWidth: .infinity, minHeight: pillH)
                    .contentShape(Rectangle())
            }
            .foregroundColor(ampFG)
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
                .foregroundColor(paidFG)
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
                .foregroundColor(laterFG)
                .background(laterBG)
                .cornerRadius(12)
                .disabled(locked)
            }
            } // end !paidToday branch

            // Report Enforcement — outline (non-shouty) per design system
            Button {
                if let loc = geo.lastKnownCoordinate {
                    ticketManager.reportTicket(at: loc)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Report Enforcement")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.navy)
                .frame(maxWidth: .infinity, minHeight: pillH)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.navy.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// Small, readable state chip. Tone-driven so fg/bg can diverge
// (locked: muted blue; ready/paid: gold on gold-tint).
private struct StatusPill: View {
    enum Tone { case locked, ready, paid }
    let title: String
    let tone: Tone

    private var bg: Color {
        switch tone {
        case .locked:        return Brand.blue.opacity(0.08)
        case .ready, .paid:  return Brand.gold.opacity(0.28)
        }
    }
    private var fg: Color {
        switch tone {
        case .locked:        return Brand.blue.opacity(0.45)
        case .ready, .paid:  return Brand.goldInk
        }
    }
    var body: some View {
        Text(title)
            .font(.caption2).bold()
            .tracking(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundColor(fg)
            .background(bg, in: Capsule())
    }
}

// Light haptic on taps
private func hapticLight() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}


struct ContentView: View {
    @EnvironmentObject var geo: GeoManager
    @EnvironmentObject var ticketManager: TicketManager

    
    var body: some View {
        VStack(spacing: 16) {
            Text("Aggie ParkPlace")
                .font(.title).bold()
                .foregroundColor(Brand.navy)
            Text("Notifies you when you enter a UC Davis lot.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if !ticketManager.recentReports.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Brand.gold)
                    Text("Enforcement reported nearby!")
                        .font(.headline)
                        .foregroundColor(Brand.cream)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Brand.navy)
                .cornerRadius(12)
                .padding(.horizontal)
            }

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
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.blue)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.blue.opacity(0.12)).cornerRadius(10)
            }
            // Always render the panel; disable + dim until the first notification (T0) fires.
            VStack(spacing: 6) {
                PayControlsView()
                    .environmentObject(geo)
                }

            if geo.notificationDenied {
                Button("Enable notifications") { geo.openSettings() }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.goldInk)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.gold.opacity(0.28)).cornerRadius(10)
            }
        }
        .padding()
        // 👇 Put them HERE on the OUTERMOST container
        .animation(nil, value: geo.statusText)
        .animation(nil, value: geo.permissionLabel)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            geo.handleForegroundRefresh()
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
            // Do NOT cancel pending follow-ups or mark completed here.
            // The user only tapped the banner (redirected to AMP) and may
            // not have paid. Let the 30m / 60m reminders fire as scheduled.
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
                // Snoozed the 30-minute reminder; schedule the final reminder
                // 30 minutes later, which lands about one hour after T0.
                if let id = _pending30ID { NotificationHandler.cancelPending([id]) }
                _pending30ID = nil

                let finalSeconds: TimeInterval = 30 * 60
                let id = NotificationHandler.schedule(
                    title: "Reminder: pay for parking",
                    body: "Final reminder today.",
                    category: "PAY_OPEN",     // keep final as plain tap-to-open; change to PAY_DECIDE if you want buttons
                    in: finalSeconds
                )
                _pending60ID = id
                _flowStage = .finalScheduled

                // Persist an expiration timestamp so the flow auto-expires even
                // if the app is suspended by iOS.
                _flowExpiration = Date().addingTimeInterval(finalSeconds + 5 * 60)
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
        case none = 0, initialSent, secondScheduled, finalScheduled, completed, reminded
    }

    // Keys for UserDefaults
    private enum UDKey {
        static let flowDay        = "router.flowDay"
        static let flowStage      = "router.flowStage"
        static let lastNotify     = "router.lastNotifyAt"
        static let pending30ID    = "router.pending30ID"
        static let pending60ID    = "router.pending60ID"
        static let flowExpiration = "router.flowExpiration"
    }

    // Global throttle (Phase 2.0): prevents rapid re-starts of today's chain
    private let globalMinGap: TimeInterval = 120
    // Not used to decide if today's chain may start—that’s globalMinGap + daily cap.
    
    // Day formatter (yyyy-MM-dd) — fixed Pacific time zone so the "day"
    // boundary never shifts when the user changes time zones mid-chain.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
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

    /// Persisted expiration date for the "finalScheduled" stage.
    /// Replaces unreliable `asyncAfter` timers that never fire when suspended.
    private var _flowExpiration: Date? {
        get { UserDefaults.standard.object(forKey: UDKey.flowExpiration) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.flowExpiration) }
    }

    // Helpers
    private func todayString(_ date: Date = Date()) -> String {
        Self.dayFormatter.string(from: date)
    }

    private func ensureDayContextLocked(now: Date = Date()) {
        let today = todayString(now)
        if _flowDay != today {
            cancelAllPendingLocked()
            _flowDay = today
            _flowStage = .none
            _lastNotifyAt = nil                  // ← reset daily throttle
            _flowExpiration = nil
        }
        // Expire finalScheduled if the persisted expiration has passed
        // (handles app suspension where asyncAfter won't fire).
        if _flowStage == .finalScheduled, let exp = _flowExpiration, now >= exp {
            if let id = _pending60ID { NotificationHandler.cancelPending([id]) }
            _flowStage = .reminded
            _pending60ID = nil
            _flowExpiration = nil
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
        // Stage is set to .secondScheduled by scheduleFollowUpsLocked immediately after,
        // so we just mark the day and throttle here.
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

    // MARK: - Public query for UI sync
    /// Returns whether today's flow has reached `.completed` (user marked paid).
    func isPaidToday() -> Bool {
        var result = false
        gateQueue.sync {
            ensureDayContextLocked()
            result = (_flowStage == .completed)
        }
        return result
    }

    /// Returns whether today's flow is active (chain started but not completed).
    func isFlowActiveToday() -> Bool {
        var result = false
        gateQueue.sync {
            ensureDayContextLocked()
            let s = _flowStage
            result = (s == .initialSent || s == .secondScheduled || s == .finalScheduled)
        }
        return result
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let notif = NotificationHandler()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = notif
        NotificationHandler.registerCategories(center)

        // Configure Firebase once, then start Firestore-dependent services.
        configureOptionalFirebase()
        TicketManager.shared.bootstrapIfNeeded()

        // Only prompt if the user hasn't been asked yet; otherwise just sync the current status.
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    GeoManager.shared.updateNotificationAuthFromPrompt(granted: granted, error: error)
                }
            } else {
                let granted = (settings.authorizationStatus == .authorized
                            || settings.authorizationStatus == .provisional
                            || settings.authorizationStatus == .ephemeral)
                GeoManager.shared.updateNotificationAuthFromPrompt(granted: granted, error: nil)
            }
        }

        // Background location launch: GeoManager.shared.lm already has its
        // delegate set in init(), so it receives pending region callbacks.
        // A second CLLocationManager here would just duplicate them.
        if launchOptions?[.location] != nil {
            GeoManager.shared.ensureSentinelArmed()
            GeoManager.shared.requestSentinelState()
        }
        return true
    }

    private func configureOptionalFirebase() {
        #if canImport(FirebaseCore)
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("GoogleService-Info.plist not found; skipping Firebase services.")
            return
        }
        FirebaseApp.configure()
        #endif
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
    private var _isSearchingBacking = false
    @Published var payFlowActive: Bool = false   // show in-app controls when a chain is active
    @Published var paidToday: Bool = false

    private let stateLock = NSRecursiveLock()
    private var _lastKnownLocation: CLLocation?
    private var _precisionModeActive = false
    private var _regionApplyToken: UInt64 = 0
    private var lastKnownLocation: CLLocation? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastKnownLocation }
        set { stateLock.lock(); defer { stateLock.unlock() }; _lastKnownLocation = newValue }
    }
    private var precisionModeActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _precisionModeActive }
        set { stateLock.lock(); defer { stateLock.unlock() }; _precisionModeActive = newValue }
    }
    private var regionApplyToken: UInt64 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _regionApplyToken }
        set { stateLock.lock(); defer { stateLock.unlock() }; _regionApplyToken = newValue }
    }
    var lastKnownCoordinate: CLLocationCoordinate2D? { lastKnownLocation?.coordinate }
    private let askedForAlwaysKey = "askedForAlwaysKey"
    private var precisionStopWorkItem: DispatchWorkItem?
    private var cachedMaxRegionRadius: CLLocationDistance = 0
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
        lm.delegate = self  // Set early so background launches receive events
        cachedMaxRegionRadius = lm.maximumRegionMonitoringDistance
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
        lm.pausesLocationUpdatesAutomatically = true
        updatePermissionLabel()
        checkAuthorizationAndProceed()
        checkNotificationAuthorization()
        syncPaidState()
    }

    func handleForegroundRefresh() {
        checkAuthorizationAndProceed()
        checkNotificationAuthorization()
        syncPaidState()
    }

    /// Sync UI flags with the persisted flow stage in GeofenceEventRouter.
    /// Re-locks pay controls when the user has exited all monitored lots.
    func syncPaidState() {
        let router = GeofenceEventRouter.shared
        let paid = router.isPaidToday()
        let active = router.isFlowActiveToday()

        var nearAnyLot = false
        if let loc = lastKnownLocation {
            let lotRegions = lm.monitoredRegions.compactMap { $0 as? CLCircularRegion }
                .filter { $0.identifier != Self.campusSentinelID }
            nearAnyLot = lotRegions.contains { region in
                let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
                return loc.distance(from: center) < (region.radius + 50)
            }
        }

        onMain {
            self.paidToday = paid
            if paid {
                self.payFlowActive = false
            } else if active && nearAnyLot {
                self.payFlowActive = true
            } else {
                self.payFlowActive = false
            }
        }
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
            // Bump token so any in-flight applyMonitoredRegions bails.
            self.regionApplyToken &+= 1
            let toStop = Array(self.lm.monitoredRegions.compactMap { $0 as? CLCircularRegion })
                .filter { !ids.contains($0.identifier) }
            for region in toStop { self.lm.stopMonitoring(for: region) }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // Open AMP app (fallback to web)
    func openAmp() {
        onMain {
            let openWeb = {
                if let web = URL(string: "https://aimsmobilepay.com") {
                    UIApplication.shared.open(web)
                }
            }
            guard let appURL = URL(string: "aimsmobilepay://") else {
                openWeb()
                return
            }
            UIApplication.shared.open(appURL, options: [:]) { opened in
                if !opened {
                    DispatchQueue.main.async(execute: openWeb)
                }
            }
        }
    }

    private func startPrecisionMode(duration: TimeInterval = 120, reason: String) {
        let doStart = { [self] in
            guard !self.precisionModeActive else { return }
            // allowsBackgroundLocationUpdates requires Always authorization;
            // setting it with WhenInUse can crash on iOS 14+.
            guard self.lm.authorizationStatus == .authorizedAlways else { return }
            self.precisionModeActive = true

            self.lm.allowsBackgroundLocationUpdates = true
            self.lm.pausesLocationUpdatesAutomatically = false
            self.lm.activityType = .automotiveNavigation
            self.lm.desiredAccuracy = kCLLocationAccuracyBest
            self.lm.distanceFilter = 10
            self.lm.startUpdatingLocation()

            if self.showPrecisionStatusUI {
                self.setStatus("Precision mode (\(reason))")
            } else {
                #if DEBUG
                print("[Precision] start (\(reason))")
                #endif
            }

            // Cancel any existing timer before scheduling a new one.
            self.precisionStopWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopPrecisionMode() }
            self.precisionStopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
        if Thread.isMainThread { doStart() } else { DispatchQueue.main.async(execute: doStart) }
    }

    private func stopPrecisionMode() {
        let doStop = { [self] in
            guard self.precisionModeActive else { return }
            self.precisionStopWorkItem?.cancel()
            self.lm.stopUpdatingLocation()
            self.lm.allowsBackgroundLocationUpdates = false
            self.lm.pausesLocationUpdatesAutomatically = true
            self.lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
            self.lm.distanceFilter = kCLDistanceFilterNone
            self.precisionModeActive = false

            if self.showPrecisionStatusUI {
                self.setStatus("Precision mode ended")
            } else {
                #if DEBUG
                print("[Precision] end")
                #endif
            }
        }
        if Thread.isMainThread { doStop() } else { DispatchQueue.main.async(execute: doStop) }
    }

    // In-app "I paid"
    func markPaidFromUI() {
        GeofenceEventRouter.shared.handleUserMarkedPaid()
        onMain {
            self.payFlowActive = false
            self.paidToday = true
            self.stopPrecisionMode()
        }
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

        // Only trigger a refresh when not already searching.
        // Read the thread-safe backing bool because this delegate callback
        // can fire on any thread.
        let currentlySearching: Bool = {
            stateLock.lock(); defer { stateLock.unlock() }
            return _isSearchingBacking
        }()
        if !currentlySearching && (isFirstFix || movedFar) {
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

                    // Use actual GPS distance (< 50 m) instead of r.contains()
                    // to avoid triggering from the geofence margin.
                    let center = CLLocation(latitude: r.center.latitude, longitude: r.center.longitude)
                    if newest.distance(from: center) < 50 {
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
            .filter { $0.identifier != Self.campusSentinelID }  // exclude large sentinel
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
        DispatchQueue.main.async { self.payFlowActive = true }
    }

    // Detect when the user leaves a parking lot
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let c = region as? CLCircularRegion else { return }
        if c.identifier == Self.campusSentinelID { return }
        // Only re-lock if the user hasn't paid AND no follow-up reminders are pending.
        DispatchQueue.main.async {
            if !self.paidToday && !GeofenceEventRouter.shared.isFlowActiveToday() {
                self.payFlowActive = false
            }
        }
    }

    // Open Settings when denied
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        onMain { UIApplication.shared.open(url) }
    }
    
    // MARK: - Search result caching (offline fallback)
    private let cachedLotsKey = "cachedParkingLots"

    private func cacheCandidates(_ candidates: [ParkingCandidate]) {
        let data = candidates.map {
            ["lat": $0.region.center.latitude, "lon": $0.region.center.longitude, "name": $0.name]
        }
        UserDefaults.standard.set(data, forKey: cachedLotsKey)
    }

    private func loadCachedCandidates() -> [ParkingCandidate]? {
        guard let data = UserDefaults.standard.array(forKey: cachedLotsKey) as? [[String: Any]] else { return nil }
        let candidates = data.compactMap { dict -> ParkingCandidate? in
            guard let lat = dict["lat"] as? Double,
                  let lon = dict["lon"] as? Double,
                  let name = dict["name"] as? String else { return nil }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let radius = min(self.cachedMaxRegionRadius, desiredGeofenceRadius)
            let region = CLCircularRegion(center: coord, radius: radius, identifier: self.key(coord))
            region.notifyOnEntry = true
            region.notifyOnExit = true
            return ParkingCandidate(region: region, name: name)
        }
        return candidates.isEmpty ? nil : candidates
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

        // Guard against concurrent refreshes using stateLock.
        let shouldProceed: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !_isSearchingBacking else { return false }
            _isSearchingBacking = true
            return true
        }()
        guard shouldProceed else { return }
        onMain { self.isSearching = true }

        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "parking"
        req.region = MKCoordinateRegion(center: campusCenter, span: campusSearchSpan)

        MKLocalSearch(request: req).start { [weak self] result, error in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self._isSearchingBacking = false
                self.stateLock.unlock()
                self.onMain { self.isSearching = false }
            }

            if let error = error {
                // Fall back to cached results when offline
                if let cached = self.loadCachedCandidates() {
                    self.setStatus("Using cached lots (offline)")
                    self.applyMonitoredRegions(cached)
                } else {
                    self.setStatus("Search error: \(error.localizedDescription)")
                }
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

                let radius = min(self.cachedMaxRegionRadius, desiredGeofenceRadius)
                let id = self.key(c) // stable, rounded identifier
                let region = CLCircularRegion(center: c, radius: radius, identifier: id)
                region.notifyOnEntry = true
                region.notifyOnExit = true   // detect when user leaves

                let name = item.name ?? "Parking"
                return ParkingCandidate(region: region, name: name)
            }

            self.cacheCandidates(candidates)
            // Start/stop monitoring and update UI based on the anchor we chose
            self.applyMonitoredRegions(candidates)
        }
    }

    // 1) Recompute anchor inside apply (remove the anchor parameter)
    private func applyMonitoredRegions(_ candidates: [ParkingCandidate]) {
        // Capture the current token; if stopAllRegions bumps it before we
        // reach main, we bail out instead of re-registering stale regions.
        let token = regionApplyToken
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
                // If a newer stopAllRegions or refresh invalidated our token, bail.
                guard self.regionApplyToken == token else { return }

                let selectedIDs = Set(selectedRegions.map { $0.identifier })

                // Stop unselected regions FIRST so we stay under the 20-region/app
                // limit before registering the new ones. Never stop the sentinel.
                for existing in Array(self.lm.monitoredRegions) {
                    if let cr = existing as? CLCircularRegion,
                       cr.identifier != Self.campusSentinelID,
                       !selectedIDs.contains(cr.identifier) {
                        self.lm.stopMonitoring(for: cr)
                    }
                }

                // Then start any new ones not already monitored.
                let alreadyMonitored = Set(self.lm.monitoredRegions.map { $0.identifier })
                for region in selectedRegions where !alreadyMonitored.contains(region.identifier) {
                    self.lm.startMonitoring(for: region)
                }

                // Removed: blanket requestState() probing here caused false
                // "already inside" callbacks when the device was merely near a lot.

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

    static var reportAlertCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: "REPORT_ALERT",
                               actions: [],
                               intentIdentifiers: [],
                               options: [])
    }
    
    /// Register all categories at launch so actions can render when used
    // AFTER (excerpt)
    static func registerCategories(_ center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([
            NotificationHandler.payOpenCategory,
            NotificationHandler.payDecideCategory,
            NotificationHandler.reportAlertCategory
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

    static func notifyEnforcementReport(count: Int) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Enforcement reported nearby"
        content.body = (count == 1)
            ? "A driver reported parking enforcement near campus."
            : "\(count) drivers reported parking enforcement near campus."
        content.sound = .default
        content.categoryIdentifier = "REPORT_ALERT"
        content.threadIdentifier = "enforcement-reports"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: "report.\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
    
    static func schedule(id: String = UUID().uuidString,
                         title: String,
                         body: String,
                         category: String,
                         in seconds: TimeInterval,
                         sound: UNNotificationSound? = .default,
                         completion: ((Error?) -> Void)? = nil) -> String {
        // UNTimeIntervalNotificationTrigger requires interval > 0; clamp to avoid a crash.
        let seconds = max(1, seconds)
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
        let category = response.notification.request.content.categoryIdentifier
        NotificationHandler.removeDelivered([reqID])
        
        switch response.actionIdentifier {
            
        case "PAY_MARK_PAID":
            GeofenceEventRouter.shared.handleUserMarkedPaid()
            DispatchQueue.main.async {
                GeoManager.shared.payFlowActive = false
                GeoManager.shared.paidToday = true
            }

        case "PAY_REMIND_LATER":
            // The router compares this ID with the stored 30-minute request ID
            // to distinguish T0 from the second reminder.
            let idToPass = (response.notification.request.content.categoryIdentifier == "PAY_DECIDE") ? reqID : nil
            GeofenceEventRouter.shared.handleUserSnooze(requestID: idToPass)
            DispatchQueue.main.async { GeoManager.shared.payFlowActive = true }

        case UNNotificationDefaultActionIdentifier:
            // User tapped the banner → record engagement but keep follow-up
            // reminders scheduled (user may not have paid yet).
            guard category == "PAY_OPEN" || category == "PAY_DECIDE" else { break }
            GeofenceEventRouter.shared.handleUserOpenedNotification()
            DispatchQueue.main.async {
                GeoManager.shared.payFlowActive = true
                GeoManager.shared.openAmp()
            }
            
        default:
            break
        }
        completionHandler()
    }
}
