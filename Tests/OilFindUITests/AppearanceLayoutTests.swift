import AppKit
import XCTest
@testable import OilFindApp

final class AppearanceLayoutTests: XCTestCase {
    func testCategoryTitleRenderedInkIsCentered() throws {
        _ = NSApplication.shared
        for title in ["全部", "文件夹", "应用", "文档", "图片", "视频", "音频", "代码", "压缩包", "All", "Folders", "Apps", "Documents", "Images", "Video", "Audio", "Code", "Archives"] {
            let view = FilterTitleView(frame: NSRect(x: 0, y: 0, width: 100, height: 34))
            view.font = .systemFont(ofSize: 13.5, weight: .medium); view.stringValue = title; view.textColor = .white
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 68, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 68))
            context.cgContext.scaleBy(x: 2, y: 2); view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            var minX = 200, maxX = -1, minY = 68, maxY = -1
            for y in 0..<68 { for x in 0..<200 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            XCTAssertGreaterThan(maxX, minX, title)
            XCTAssertEqual(Double(minX + maxX + 1) / 2, 100, accuracy: 1, title)
            XCTAssertEqual(Double(minY + maxY + 1) / 2, 34, accuracy: 1, title)
        }
    }
    func testFooterHintsStayVisibleAndFitIdleResultsAndWarnings() {
        _ = NSApplication.shared; defer { L10n.snapshotChinese = nil }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            for width: CGFloat in [720, 900, 1200] {
                let footer = FooterBar(frame: NSRect(x: 0, y: 0, width: width, height: 34))
                for actionable in [false, true] { for warning in [false, true] { for space in [false, true] {
                    footer.actionable = actionable; footer.warning = warning; footer.spacePreview = space
                    footer.text = String(repeating: "Long status / 提示文字 ", count: 10)
                    footer.layoutSubtreeIfNeeded(); footer.layout()
                    let hints = footer.subviews.filter { !($0 is NSTextField) }
                    XCTAssertEqual(hints.count, 4)
                    for hint in hints {
                        XCTAssertFalse(hint.isHidden)
                        XCTAssertGreaterThanOrEqual(hint.frame.minX, 22)
                        XCTAssertLessThanOrEqual(hint.frame.maxX, width - 18)
                        XCTAssertEqual(hint.frame.midY, footer.bounds.midY)
                    }
                    for pair in zip(hints, hints.dropFirst()) { XCTAssertLessThan(pair.0.frame.maxX, pair.1.frame.minX) }
                    let status = footer.subviews.compactMap { $0 as? NSTextField }.first!
                    XCTAssertLessThanOrEqual(status.frame.maxX, hints[0].frame.minX)
                    XCTAssertEqual(status.toolTip, footer.text)
                } } }
            }
        }
    }
    func testCustomColorsPersistAndInvalidInputKeepsPreviousColor() throws {
        let suite = "FoxFindAppearanceTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppearancePreferences(defaults: defaults)
        model.select(AppearancePreferences.presets[2])
        XCTAssertEqual(AppearancePreferences(defaults: defaults).presetID, "mint")
        XCTAssertTrue(model.setAccent(" #aBc ")); XCTAssertTrue(model.setSurface("#123456"))
        XCTAssertEqual(model.accentHex, "AABBCC"); XCTAssertEqual(model.presetID, "custom")
        XCTAssertFalse(model.setAccent("#ZZ2233")); XCTAssertFalse(model.setSurface("12345678"))
        let restored = AppearancePreferences(defaults: defaults)
        XCTAssertEqual(restored.accentHex, "AABBCC"); XCTAssertEqual(restored.surfaceHex, "123456")
        XCTAssertEqual(AppearancePreferences.hex(restored.accent), "AABBCC")
    }
    func testThemeChangesNotifyOpenViews() throws {
        let suite = "FoxFindNotificationTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppearancePreferences(defaults: defaults)
        let changed = expectation(forNotification: AppearancePreferences.changed, object: model)
        model.select(AppearancePreferences.presets[1])
        wait(for: [changed], timeout: 1)
    }
    func testCustomColorsAlwaysHaveReadableButtonAndHighlightText() throws {
        let suite = "FoxFindContrastTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppearancePreferences(defaults: defaults)
        for hex in ["000000", "FFFFFF", "777777", "FF0000", "00FF00", "0000FF"] + AppearancePreferences.presets.map(\.accent) {
            let color = try XCTUnwrap(AppearancePreferences.color(hex))
            XCTAssertGreaterThanOrEqual(AppearancePreferences.contrast(color, AppearancePreferences.foreground(on: color)), 4.5)
            model.setAccent(hex)
            for background in ["383633", "F4F3F1"] {
                let bg = try XCTUnwrap(AppearancePreferences.color(background))
                XCTAssertGreaterThanOrEqual(AppearancePreferences.contrast(bg, model.readableAccent(on: bg)), 4.5)
            }
        }
    }
    func testHighlightResolvesAgainstDrawingAppearanceEvenBeforeViewIsAttached() throws {
        _ = NSApplication.shared
        let view = NSView(); view.appearance = NSAppearance(named: .darkAqua)
        let ink = Theme.accentText(view)
        for (name, background) in [(NSAppearance.Name.aqua, "F4F3F1"), (.darkAqua, "383633")] {
            var resolved: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance { resolved = ink.usingColorSpace(.sRGB) }
            XCTAssertGreaterThanOrEqual(AppearancePreferences.contrast(try XCTUnwrap(resolved), try XCTUnwrap(AppearancePreferences.color(background))), 4.5)
        }
    }
    func testToolbarFitsBothLanguagesAndSmallScreenWidth() {
        _ = NSApplication.shared
        defer { L10n.snapshotChinese = nil }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            for width: CGFloat in [720, 900, 1200] {
                let toolbar = SearchToolsBar(frame: NSRect(x: 0, y: 0, width: width, height: Theme.toolsHeight))
                toolbar.layoutSubtreeIfNeeded(); toolbar.layout()
                let buttons = [toolbar.scope, toolbar.refine, toolbar.match, toolbar.list, toolbar.grid, toolbar.more]
                for button in buttons {
                    XCTAssertGreaterThanOrEqual(button.frame.height, 36)
                    XCTAssertLessThanOrEqual(button.frame.maxX, width - 16)
                    XCTAssertGreaterThanOrEqual(button.frame.minX, 16)
                }
                for pair in zip(buttons, buttons.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX) }
                toolbar.mode = .contents
                XCTAssertTrue(toolbar.match.active); XCTAssertTrue(toolbar.match.title.contains(L10n.text("tools.contents")))
            }
        }
    }
    func testSearchAccessoriesAndTextLineStayCenteredAfterClearAndResize() throws {
        _ = NSApplication.shared
        let search = SearchField(frame: NSRect(x: 0, y: 0, width: 900, height: Theme.searchHeight))
        for width: CGFloat in [900, 800, 900] {
            search.frame.size.width = width
            for text in ["", "看看", "Fox Find 2026", "很长的输入文字".repeating(20)] {
                search.text = text; search.layoutSubtreeIfNeeded(); search.layout()
                XCTAssertEqual(search.clear.frame.midY, search.bounds.midY, accuracy: 0.5)
                XCTAssertEqual(search.settings.frame.midY, search.bounds.midY, accuracy: 0.5)
                XCTAssertEqual(search.input.frame.midY, search.bounds.midY, accuracy: 0.5)
                let cell = try XCTUnwrap(search.input.cell)
                XCTAssertEqual(cell.drawingRect(forBounds: search.input.bounds).midY, search.input.bounds.midY, accuracy: 0.5)
                XCTAssertLessThan(search.input.frame.maxX, search.clear.frame.minX)
                XCTAssertEqual(search.clear.frame.size, search.settings.frame.size)
            }
        }
        search.text = "看看"; var cleared = false; search.onChange = { cleared = search.text.isEmpty }
        search.clear.performClick(nil); XCTAssertTrue(cleared)
        var settingsOpened = false; search.onSettings = { settingsOpened = true }; search.settings.performClick(nil)
        XCTAssertTrue(settingsOpened)
    }
}

private extension String {
    func repeating(_ count: Int) -> String { String(repeating: self, count: count) }
}
