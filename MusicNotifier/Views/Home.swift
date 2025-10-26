//
//  Main.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack {
            List {
                Section(header: Text("New")) {
                    HStack {
                        RoundedRectangle(cornerRadius: 20)
                            .frame(width: 100, height: 100)
                        //Image
                        VStack(alignment: .leading) {
                            Text("Album Name")
                                .font(.title2)
                                .bold()
                            Text("Artist Name")
                                .font(.title3)
                            HStack {
                                Text("Date")
                                    .font(.caption)
                                Divider()
                                    .frame(height: 15)
                                Text("Genre")
                                    .font(.caption)
                            }
                        }
                        .fontDesign(.rounded)
                    }
                }
                Section(header: Text("Seen")) {
                        
                }
            }
        }
    }
}



#Preview {
    HomeView()
}
