//
//  Artists.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import MusicKit

struct Artists: View {
    @State private var artists: [Artist] = []
    @State private var hasFetched: Bool = false
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: {
                    Task {
                        do {
                            let fetched = try await fetchAllLibraryArtists()
                            await MainActor.run {
                                artists = fetched
                                hasFetched = true
                            }
                        } catch {
                            print("Error fetching artists: \(error.localizedDescription)")
                        }
                    }
                }, label: {
                    Image(systemName: "plus")
                })
                .padding()
            }
            if hasFetched {
                ForEach(artists, id: \.id) { artist in
                    HStack(alignment: .top, spacing: 12) {
                        // Artwork
                        AsyncImage(url: artist.artwork?.url(width: 200, height: 200)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure:
                                Color.gray.opacity(0.2)
                            case .empty:
                                Color.gray.opacity(0.1)
                            @unknown default:
                                Color.gray.opacity(0.2)
                            }
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        VStack(alignment: .leading) {
                            Text(artist.name)
                                .font(.title2)
                                .bold()
                        /*
                            Text(artist.genreNames)
                                    .font(.caption)*/
                        }
                        .fontDesign(.rounded)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }
            
            Spacer()
        }
    }
    
    private func fetchAllLibraryArtists() async throws -> [Artist] {
        let request = MusicLibraryRequest<Artist>()
        let response = try await request.response()
        return Array(response.items)
    }
}

#Preview {
    Artists()
}
