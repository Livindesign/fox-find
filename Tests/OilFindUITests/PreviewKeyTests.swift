import AppKit
import PDFKit
import XCTest
@testable import OilFindApp

final class PreviewKeyTests: XCTestCase {
    private func key(_ code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "y",
                        charactersIgnoringModifiers: code == 49 ? " " : "y", isARepeat: false, keyCode: code)!
    }
    func testSpaceClosesImagePDFAndReadOnlyTextButPreservesFindInputAndOtherWindows() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        var closed = 0
        let keys = PreviewKeys(window: window) { closed += 1; window.orderOut(nil) }
        let text = NSTextView(); text.isEditable = false
        for content in [NSImageView(), PDFView(), text] as [NSView] {
            window.contentView = content; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(content)
            XCTAssertFalse(keys.handle(key(49, window: other)))
            XCTAssertFalse(keys.handle(key(49, window: window, flags: .shift)))
            XCTAssertTrue(keys.handle(key(49, window: window))); XCTAssertFalse(window.isVisible)
        }
        XCTAssertEqual(closed, 3)
        let input = NSTextView(); input.isEditable = true
        window.contentView = input; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(input)
        XCTAssertFalse(keys.handle(key(49, window: window))); XCTAssertTrue(window.isVisible)
        XCTAssertTrue(keys.handle(key(53, window: window))); XCTAssertFalse(window.isVisible)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(keys.handle(key(16, window: window, flags: .command)))
        XCTAssertEqual(closed, 5)
    }
}
