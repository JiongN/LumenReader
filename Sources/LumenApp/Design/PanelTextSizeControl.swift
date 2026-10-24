import SwiftUI
import LumenKit

struct PanelTextSizeControl: View {
    @Binding var size: Double
    let label: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "textformat.size")
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(Int(size)) pt").monospacedDigit()
                }
                Slider(value: $size, in: UISettings.TextSize.range, step: 1)
                    .accessibilityLabel(label)
                Button("恢复默认") { size = UISettings.TextSize.defaultValue }
            }
            .font(DS.Typo.callout)
            .padding(DS.Space.m)
            .frame(width: 220)
        }
    }
}
