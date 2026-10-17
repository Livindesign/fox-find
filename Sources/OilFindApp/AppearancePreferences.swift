import AppKit
import SwiftUI

final class AppearancePreferences: ObservableObject {
    struct Preset: Identifiable {
        let id: String, zh: String, en: String, accent: String, surface: String
        var name: String { L10n.local(zh, en) }
    }
    static let presets = [
        Preset(id: "sand", zh: "沙金", en: "Sand", accent: "D6B28C", surface: "302C29"),
        Preset(id: "graphite", zh: "石墨", en: "Graphite", accent: "D7DCE5", surface: "2B2E34"),
        Preset(id: "mint", zh: "薄荷", en: "Mint", accent: "A7CDBF", surface: "27312D"),
        Preset(id: "lilac", zh: "雾紫", en: "Lilac", accent: "C3B5DB", surface: "2D2933"),
        Preset(id: "ocean", zh: "海蓝", en: "Ocean", accent: "9DB9D8", surface: "27303A")
    ]
    static let shared = AppearancePreferences()
    static let changed = Notification.Name("app.localfind.desktop.appearanceChanged")
    @Published private(set) var presetID: String
    @Published private(set) var accentHex: String
    @Published private(set) var surfaceHex: String
    private let defaults: UserDefaults
    var accent: NSColor { Self.color(accentHex)! }
    var surface: NSColor { Self.color(surfaceHex)! }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presetID = defaults.string(forKey: "appearance.preset") ?? "sand"
        accentHex = Self.normalized(defaults.string(forKey: "appearance.accent") ?? "") ?? "D6B28C"
        surfaceHex = Self.normalized(defaults.string(forKey: "appearance.surface") ?? "") ?? "302C29"
    }
    func select(_ preset: Preset) {
        presetID = preset.id; accentHex = preset.accent; surfaceHex = preset.surface; save()
    }
    @discardableResult func setAccent(_ value: String) -> Bool {
        guard let value = Self.normalized(value) else { return false }
        presetID = "custom"; accentHex = value; save(); return true
    }
    @discardableResult func setSurface(_ value: String) -> Bool {
        guard let value = Self.normalized(value) else { return false }
        presetID = "custom"; surfaceHex = value; save(); return true
    }
    private func save() {
        defaults.set(presetID, forKey: "appearance.preset"); defaults.set(accentHex, forKey: "appearance.accent")
        defaults.set(surfaceHex, forKey: "appearance.surface")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    static func normalized(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) else { return nil }
        return value
    }
    static func color(_ raw: String) -> NSColor? {
        guard let hex = normalized(raw), let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: NSColor) -> String? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double { let x = Double(value); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func foreground(on color: NSColor) -> NSColor {
        contrast(.black, color) > contrast(.white, color) ? .black : .white
    }
    func readableAccent(on background: NSColor) -> NSColor {
        let target = Self.foreground(on: background)
        for step in 0...20 {
            let candidate = accent.blended(withFraction: CGFloat(step) / 20, of: target) ?? target
            if Self.contrast(candidate, background) >= 4.5 { return candidate }
        }
        return target
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var model = AppearancePreferences.shared
    @State private var accentInput = ""
    @State private var surfaceInput = ""
    @State private var invalid = false
    var body: some View {
        Section(L10n.local("外观与按钮配色", "Appearance & Button Colors")) {
            Text(L10n.local("更大的按钮、更柔和的配色。修改后立即生效，并自动保存。", "Larger controls with softer colors. Changes apply immediately and are saved automatically."))
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(AppearancePreferences.presets) { preset in
                    Button { model.select(preset) } label: {
                        VStack(spacing: 5) {
                            Circle().fill(Color(nsColor: AppearancePreferences.color(preset.accent)!)).frame(width: 18, height: 18)
                            Text(preset.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(model.presetID == preset.id ? 0.12 : 0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.presetID == preset.id ? Color(nsColor: model.accent) : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).accessibilityLabel(preset.name)
                }
            }
            HStack {
                ColorPicker(L10n.local("选中按钮", "Selected button"), selection: Binding(get: { Color(nsColor: model.accent) }, set: { if let hex = AppearancePreferences.hex(NSColor($0)) { model.setAccent(hex) } }), supportsOpacity: false)
                TextField("#D6B28C", text: $accentInput).labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 104).onSubmit { invalid = !model.setAccent(accentInput) }
                    .accessibilityLabel(L10n.local("选中按钮十六进制颜色", "Selected button hex color"))
            }
            HStack {
                ColorPicker(L10n.local("普通按钮", "Normal button"), selection: Binding(get: { Color(nsColor: model.surface) }, set: { if let hex = AppearancePreferences.hex(NSColor($0)) { model.setSurface(hex) } }), supportsOpacity: false)
                TextField("#302C29", text: $surfaceInput).labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 104).onSubmit { invalid = !model.setSurface(surfaceInput) }
                    .accessibilityLabel(L10n.local("普通按钮十六进制颜色", "Normal button hex color"))
            }
            if invalid { Text(L10n.local("请输入 #RGB 或 #RRGGBB，例如 #D6B28C。", "Enter #RGB or #RRGGBB, such as #D6B28C.")).font(.footnote).foregroundStyle(.red) }
            Text(L10n.local("也可点击色块使用系统调色盘。按钮文字会自动选择黑色或白色，保持清晰。", "Click a color well for the system picker. Button text automatically uses black or white for readability."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(L10n.local("恢复沙金配色", "Restore Sand Palette")) { model.select(AppearancePreferences.presets[0]); invalid = false }
        }
        .onAppear { sync() }
        .onChange(of: model.accentHex) { sync() }
        .onChange(of: model.surfaceHex) { sync() }
    }
    private func sync() { accentInput = "#" + model.accentHex; surfaceInput = "#" + model.surfaceHex; invalid = false }
}
