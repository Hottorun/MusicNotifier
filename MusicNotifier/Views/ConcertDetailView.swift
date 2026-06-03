//
//  ConcertDetailView.swift
//  MusicNotifier
//

import SwiftUI
import MapKit
import SwiftData

struct ConcertDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let concert: ConcertData
    @State private var addCalendarState: CalendarAddState = .idle

    private enum CalendarAddState {
        case idle, loading, success, failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if hasCoordinate {
                    mapBlock
                }

                ticketBlock

                lineupBlock

                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(concert.venueName.isEmpty ? "Concert" : concert.venueName)
        .appScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    concert.savedAt = concert.savedAt == nil ? Date() : nil
                    try? modelContext.save()
                } label: {
                    Image(systemName: concert.savedAt == nil ? "heart" : "heart.fill")
                        .foregroundStyle(concert.savedAt == nil ? AppTheme.secondary : AppTheme.accent)
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(concert.artistName.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.0)
                .foregroundStyle(AppTheme.accent)
            Text(concert.venueName.isEmpty ? "Venue TBA" : concert.venueName)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                Text(locationLabel)
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.secondary)
            if let date = concert.date {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                }
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface))
    }

    // MARK: - Map

    private var hasCoordinate: Bool {
        concert.latitude != nil && concert.longitude != nil
    }

    private var mapBlock: some View {
        let coord = CLLocationCoordinate2D(
            latitude: concert.latitude ?? 0,
            longitude: concert.longitude ?? 0
        )
        let region = MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )

        return Map(initialPosition: .region(region)) {
            Marker(concert.venueName.isEmpty ? "Venue" : concert.venueName, coordinate: coord)
                .tint(AppTheme.accent)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            openInMaps(coord: coord)
        }
    }

    private func openInMaps(coord: CLLocationCoordinate2D) {
        let placemark = MKPlacemark(coordinate: coord)
        let item = MKMapItem(placemark: placemark)
        item.name = concert.venueName.isEmpty ? concert.city : concert.venueName
        item.openInMaps(launchOptions: [MKLaunchOptionsMapTypeKey: NSNumber(value: MKMapType.standard.rawValue)])
    }

    // MARK: - Tickets + Calendar

    private var ticketBlock: some View {
        VStack(spacing: 10) {
            if let url = concert.ticketURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Get Tickets", systemImage: "ticket.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            Button {
                Task { await addToCalendar() }
            } label: {
                HStack(spacing: 8) {
                    switch addCalendarState {
                    case .idle: Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    case .loading: ProgressView().controlSize(.small)
                    case .success: Label("Added", systemImage: "checkmark")
                    case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(isCalendarBusy)
        }
    }

    private var isCalendarBusy: Bool {
        if case .loading = addCalendarState { return true }
        if case .success = addCalendarState { return true }
        return false
    }

    @MainActor
    private func addToCalendar() async {
        addCalendarState = .loading
        do {
            _ = try await CalendarService().addConcert(concert)
            addCalendarState = .success
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            addCalendarState = .idle
        } catch {
            addCalendarState = .failed("Could not add — \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            addCalendarState = .idle
        }
    }

    // MARK: - Lineup

    private var lineupBlock: some View {
        let lineup = concert.lineup ?? []
        if lineup.isEmpty {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("LINEUP")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lineup.enumerated()), id: \.offset) { idx, name in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.secondary)
                                .frame(width: 18)
                            Text(name)
                                .font(.body)
                                .foregroundStyle(name == concert.artistName ? AppTheme.accent : .white)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if idx < lineup.count - 1 {
                            Divider().background(AppTheme.hairline).padding(.leading, 14)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface))
            }
        )
    }

    private var locationLabel: String {
        let parts: [String] = [concert.city, concert.region ?? "", concert.country].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}
