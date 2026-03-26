import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("DemoReel")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("v\(coreVersion())")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Rust bridge is working!")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 400, height: 200)
    }
}
