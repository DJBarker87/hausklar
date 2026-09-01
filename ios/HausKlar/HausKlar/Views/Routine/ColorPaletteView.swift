import SwiftUI

/// A grid of color swatches for picking a routine item color.
struct ColorPaletteView: View {
    @Binding var selectedColor: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(RoutineViewModel.colorPalette, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .stroke(Color.primary, lineWidth: selectedColor == hex ? 3 : 0)
                    )
                    .onTapGesture {
                        selectedColor = hex
                    }
            }
        }
    }
}
