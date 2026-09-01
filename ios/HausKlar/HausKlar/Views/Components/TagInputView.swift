import SwiftUI

struct TagInputView: View {
    @Binding var tags: [String]
    @State private var inputText = ""

    private let commonTags = ["quick", "vegetarian", "vegan", "kids", "healthy", "comfort", "batch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption)
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(.tint)
                        .cornerRadius(6)
                    }
                }
            }

            HStack {
                TextField("Add tag...", text: $inputText)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        addTag()
                    }

                Button("Add") {
                    addTag()
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add tag")
            }

            let suggestions = commonTags.filter { !tags.contains($0) }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                if !tags.contains(tag) {
                                    tags.append(tag)
                                }
                            } label: {
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.tertiarySystemFill))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add suggested tag \(tag)")
                        }
                    }
                }
            }
        }
    }

    private func addTag() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        inputText = ""
    }
}
