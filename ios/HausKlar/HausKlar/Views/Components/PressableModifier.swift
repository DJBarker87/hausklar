import SwiftUI

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
