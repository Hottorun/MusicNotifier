//
//  ContentView.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    var intropassed = false
    
    var body: some View {/*
        if !intropassed {
            Intro()
        } else {*/
            
            TabView {
                HomeView()
                    .tabItem {
                        Label("Home", systemImage: "music.note")
                        //tabItem, accepts text, image, label
                    }
                Artists()
                    .tabItem {
                        Label("Artists", systemImage: "person")
                    }
                
                
            }
        }
    }
//}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
