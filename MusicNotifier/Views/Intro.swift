//
//  Intro.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import MusicKit

struct Intro: View {
    @State private var selectedItem: String = "AM"
    @State private var isAuthorized = false
    
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("Select Your Music Service")
                    .font(.title)
                    .bold()
                    .fontDesign(.rounded)
                HStack {
                    Spacer()
                    Button(action: {
                        selectedItem = "AM"
                    }, label: {
                        VStack {
                            Image("AppleMusicIcon")
                                .resizable(resizingMode: .stretch)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 100, height: 100)
                            
                            Text("Apple Music")
                        }
                        .border(selectedItem=="AM" ? .black : .clear)
                    })
                    Spacer()
                    Button(action: {
                        selectedItem = "Spotify"
                    }, label:{
                        VStack {
                            Image("SpotifyIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 100, height: 100)
                            Text("Spotify")
                        }
                        .border(selectedItem=="Spotify" ? .black : .clear)
                    })
                    Spacer()
                }
                .padding()
                Spacer()
                
                
                
                Button(action: {
                    Task { await authorize() }
                    
                }, label: {
                    Text("Continue")
                    Image(systemName: "arrow.forward")
                })
                .navigationDestination(isPresented: $isAuthorized, destination: {HomeView()})
                .padding()
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                
            }
        }
        
    }
        
    private func authorize() async {
        let auth = await MusicAuthorization.request()
        // Update navigation state if authorized
        if auth == .authorized {
            isAuthorized = true
        }
        // Handle denied/failed as needed
    }
}

#Preview {
    Intro()
}
