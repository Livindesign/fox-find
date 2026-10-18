import AppKit

/// All app-owned menus use a consistent symbol column. Explicit action icons
/// are retained; legacy target/action menus are completed recursively.
enum MenuIcons {
    static func decorate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if item.image == nil { item.image = Theme.symbol(symbol(for: item), size: 14, weight: .regular) }
            if let source = item.image {
                // Native menus on newer macOS versions may omit symbol-backed
                // images. A small template bitmap also gives SVG and SF glyphs
                // the same visual size instead of mixing two layout policies.
                let image = NSImage(size: NSSize(width: 14, height: 14))
                image.lockFocus()
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    let size = source.size
                    let scale = 14 / max(1, max(size.width, size.height))
                    let width = size.width * scale, height = size.height * scale
                    source.draw(in: NSRect(x: (14 - width) / 2, y: (14 - height) / 2, width: width, height: height))
                }
                image.unlockFocus(); image.isTemplate = true; item.image = image
            }
            if let submenu = item.submenu { decorate(submenu) }
        }
    }
    private static func symbol(for item: NSMenuItem) -> String {
        let selector = item.action.map(NSStringFromSelector) ?? ""
        switch selector {
        case "undo:": return "arrow.uturn.backward"
        case "redo:": return "arrow.uturn.forward"
        case "cut:": return "scissors"
        case "copy:": return "doc.on.doc"
        case "paste:": return "doc.on.clipboard"
        case "selectAll:": return "selection.pin.in.out"
        case "terminate:": return "power"
        case "selectScope:", "selectProject:": return "folder"
        case "chooseScope", "addProject": return "folder.badge.plus"
        case "removeProject:", "clearSearchHistory": return "trash"
        case "restoreSearch:": return "clock.arrow.circlepath"
        case "toggleSavedSearch": return "bookmark"
        case "editDimensions": return "arrow.up.left.and.arrow.down.right"
        case "clearRefinement": return "xmark.circle"
        case "selectTag:": return "tag"
        case "selectMedia:": return "photo.on.rectangle"
        case "typeSelected:": return kind(item.tag)
        case "sortSelected:": return ["sparkle", "textformat.abc", "calendar", "internaldrive"].indices.contains(item.tag) ? ["sparkle", "textformat.abc", "calendar", "internaldrive"][item.tag] : "arrow.up.arrow.down"
        default: break
        }
        // Submenu labels are localized, so compare against the same localization
        // keys used to construct them rather than guessing English/Chinese text.
        for (key, icon) in [("filter.type", "square.grid.2x2"), ("filter.location", "folder"), ("filter.capture", "calendar"),
                            ("asset.tags", "tag"), ("asset.project", "folder"),
                            ("tools.library", "bookmark"), ("tools.more", "ellipsis.circle"),
                            ("workspace.dimensions", "arrow.up.left.and.arrow.down.right")] {
            if item.title.hasPrefix(L10n.text(key)) { return icon }
        }
        return item.submenu != nil ? "line.3.horizontal.decrease.circle" : item.isEnabled ? "circle.grid.2x2" : "info.circle"
    }
    static func kind(_ index: Int) -> String {
        let icons = ["square.grid.2x2.fill", "folder", "app", "doc.text", "photo", "film", "music.note", "chevron.left.forwardslash.chevron.right", "archivebox"]
        return icons.indices.contains(index) ? icons[index] : "square.grid.2x2"
    }
}
