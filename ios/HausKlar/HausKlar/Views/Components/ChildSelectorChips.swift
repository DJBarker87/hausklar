import SwiftUI

/// A reusable horizontal scrolling child selector using capsule chips.
/// Used consistently across Medicine, Star Charts, Growth, Homework, Illness, and Naps views.
struct ChildSelectorChips<Child: Identifiable>: View where Child.ID == String {
    let children: [Child]
    @Binding var selectedChildId: String?
    let nameKeyPath: KeyPath<Child, String>
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        Group {
            if children.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(children) { child in
                            Button {
                                selectedChildId = child.id
                                onSelect?(child.id)
                            } label: {
                                Text(child[keyPath: nameKeyPath])
                                    .font(.subheadline)
                                    .fontWeight(selectedChildId == child.id ? .semibold : .regular)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 44)
                                    .background(
                                        selectedChildId == child.id
                                            ? Color.accentColor
                                            : Color(.systemGray5)
                                    )
                                    .foregroundStyle(
                                        selectedChildId == child.id
                                            ? .white
                                            : .primary
                                    )
                                    .clipShape(Capsule())
                            }
                            .accessibilityAddTraits(selectedChildId == child.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}
