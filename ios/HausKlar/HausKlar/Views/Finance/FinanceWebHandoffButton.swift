import SwiftUI

/// Opens the Finance PWA only after explaining that app and browser sessions differ.
struct FinanceWebHandoffButton<Label: View>: View {
    @Environment(\.openURL) private var openURL
    @State private var isConfirming = false

    private let destination: URL
    private let label: Label

    init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button {
            HapticManager.selection()
            isConfirming = true
        } label: {
            label
        }
        .confirmationDialog(
            "Open Finance in your browser?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Open in browser") {
                openURL(destination)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The browser uses a separate HausKlar sign-in, so it may ask you to sign in again.")
        }
    }
}
