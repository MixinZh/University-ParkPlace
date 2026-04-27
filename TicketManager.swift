//
//  TicketManager.swift
//  AggieParkPlace
//
//  Created by Antigravity on 11/24/25.
//

import Foundation
import CoreLocation
import SwiftUI
import UIKit

#if canImport(FirebaseCore) && canImport(FirebaseFirestore) && canImport(FirebaseFirestoreSwift)
// NOTE: You must add the following Swift Packages to your project:
// 1. FirebaseFirestore
// 2. FirebaseCore
import FirebaseCore
import FirebaseFirestore
import FirebaseFirestoreSwift

struct TicketReport: Identifiable, Codable {
    @DocumentID var id: String?
    let location: GeoPoint
    let timestamp: Date
    let reporterID: String
    
    // Helper to convert to CLLocationCoordinate2D
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

final class TicketManager: ObservableObject {
    static let shared = TicketManager()
    
    @Published var recentReports: [TicketReport] = []
    private var db: Firestore?
    private var reportListener: ListenerRegistration?
    private let reportCollection = "ticket_reports"
    private let reporterIDKey = "ticketManager.reporterID"
    
    // Radius in meters to listen for reports (e.g., 2km around campus)
    // Using the same campus center as AggieParkPlaceApp
    private let campusCenter = CLLocationCoordinate2D(latitude: 38.5390, longitude: -121.7500)
    private let listenRadius: Double = 2000 
    private let localAlertCooldown: TimeInterval = 120
    private var primedSnapshot = false
    private var seenReportKeys: Set<String> = []
    private var lastLocalAlertAt: Date?
    private lazy var localReporterID: String = {
        // Prefer the persisted ID so reporter identity stays stable across
        // launches even if `identifierForVendor` is briefly nil or has reset.
        if let saved = UserDefaults.standard.string(forKey: reporterIDKey), !saved.isEmpty {
            return saved
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: reporterIDKey)
        return id
    }()
    
    private init() {}

    deinit {
        reportListener?.remove()
    }

    func bootstrapIfNeeded() {
        guard reportListener == nil else { return }
        guard FirebaseApp.app() != nil else {
            print("Firebase not configured; skipping TicketManager bootstrap.")
            return
        }
        db = Firestore.firestore()
        listenForReports()
    }
    
    func reportTicket(at location: CLLocationCoordinate2D) {
        guard let db = db else {
            print("Cannot report ticket before Firebase is configured.")
            return
        }
        let report = TicketReport(
            location: GeoPoint(latitude: location.latitude, longitude: location.longitude),
            timestamp: Date(),
            reporterID: localReporterID
        )
        
        do {
            _ = try db.collection(reportCollection).addDocument(from: report)
            print("Ticket reported successfully.")
        } catch {
            print("Error reporting ticket: \(error)")
        }
    }
    
    private func listenForReports() {
        guard let db = db else { return }

        // Bound the snapshot to the most recent reports. A `whereField`
        // capturing `Date().addingTimeInterval(-30*60)` would freeze the
        // cutoff at listener-setup time, so the result set would grow
        // unbounded as the app runs. Order+limit gives a sliding window;
        // the client-side `cutoff` below still trims to the last 30 min
        // for display and notification gating.
        reportListener = db.collection(reportCollection)
            .order(by: "timestamp", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self else { return }
                guard let documents = snapshot?.documents else {
                    print("Error fetching reports: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }
                
                let cutoff = Date().addingTimeInterval(-30 * 60)
                let center = CLLocation(latitude: self.campusCenter.latitude, longitude: self.campusCenter.longitude)
                let radius = self.listenRadius
                let decoded = documents.compactMap { document -> TicketReport? in
                    try? document.data(as: TicketReport.self)
                }.filter { report in
                    guard report.timestamp >= cutoff else { return false }
                    let reportLoc = CLLocation(latitude: report.location.latitude, longitude: report.location.longitude)
                    return reportLoc.distance(from: center) <= radius
                }
                let newNearbyCount = self.newNearbyReportCount(from: snapshot?.documentChanges ?? [], cutoff: cutoff)
                self.maybeNotifyForNewNearbyReports(count: newNearbyCount)

                DispatchQueue.main.async {
                    self.recentReports = decoded
                }
            }
    }

    private func reportKey(for report: TicketReport) -> String {
        if let id = report.id, !id.isEmpty { return id }
        return "\(report.timestamp.timeIntervalSince1970)-\(report.location.latitude)-\(report.location.longitude)-\(report.reporterID)"
    }

    private func isNearbyReport(_ report: TicketReport) -> Bool {
        let center = CLLocation(latitude: campusCenter.latitude, longitude: campusCenter.longitude)
        let reportLoc = CLLocation(latitude: report.location.latitude, longitude: report.location.longitude)
        return reportLoc.distance(from: center) <= listenRadius
    }

    private func newNearbyReportCount(from changes: [DocumentChange], cutoff: Date) -> Int {
        if !primedSnapshot {
            for change in changes where change.type == .added {
                guard let report = try? change.document.data(as: TicketReport.self) else { continue }
                seenReportKeys.insert(reportKey(for: report))
            }
            primedSnapshot = true
            return 0
        }

        var newCount = 0
        for change in changes where change.type == .added {
            guard let report = try? change.document.data(as: TicketReport.self) else { continue }
            let key = reportKey(for: report)
            if seenReportKeys.contains(key) { continue }
            seenReportKeys.insert(key)

            guard report.timestamp >= cutoff else { continue }
            guard report.reporterID != localReporterID else { continue }
            guard isNearbyReport(report) else { continue }
            newCount += 1
        }
        return newCount
    }

    private func maybeNotifyForNewNearbyReports(count: Int) {
        guard count > 0 else { return }
        let now = Date()
        if let last = lastLocalAlertAt, now.timeIntervalSince(last) < localAlertCooldown {
            return
        }
        lastLocalAlertAt = now
        NotificationHandler.notifyEnforcementReport(count: count)
    }
}
#else
struct TicketReport: Identifiable {
    let id: String? = nil
}

final class TicketManager: ObservableObject {
    static let shared = TicketManager()

    @Published var recentReports: [TicketReport] = []

    private init() {}

    func bootstrapIfNeeded() {
        print("Firebase packages unavailable; enforcement reporting is disabled.")
    }

    func reportTicket(at _: CLLocationCoordinate2D) {
        print("Cannot report enforcement without Firebase packages.")
    }
}
#endif
