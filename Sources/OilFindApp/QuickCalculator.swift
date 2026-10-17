import Foundation

struct Calculation: Equatable {
    let expression: String
    let value: String?
    let unit: String
    let errorKey: String?
    var output: String { [value ?? "", unit].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// A bounded arithmetic grammar, never an expression evaluator or a shell.
enum QuickCalculator {
    static func evaluate(_ input: String) -> Calculation? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 512 else { return nil }
        let explicit = text.hasPrefix("=")
        if explicit { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if let conversion = convert(text) { return conversion }
        // Dates and file patterns remain file searches unless explicitly prefixed with '='.
        if !explicit && text.range(of: #"^\d{4}[-/]\d{1,2}[-/]\d{1,2}$"#, options: .regularExpression) != nil { return nil }
        let normalized = text.lowercased().replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "√", with: "sqrt ")
            .replacingOccurrences(of: #"\bof\b"#, with: "*", options: .regularExpression)
        guard explicit || normalized.contains(where: { "+-*/^%()".contains($0) }) || normalized.hasPrefix("sqrt ") else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.eabcdefghijklmnopqrstuvwxyz+-*/^%() \t").contains($0) }) else { return nil }
        do {
            var parser = try Parser(normalized)
            let number = try parser.expression()
            guard parser.atEnd else { throw Failure.syntax }
            guard number.isFinite else { throw Failure.domain }
            return Calculation(expression: text, value: format(number), unit: "", errorKey: nil)
        } catch let failure as Failure {
            // Unrecognized words and unfinished typing should not replace file results.
            if failure == .unknown || (!explicit && failure == .syntax) { return nil }
            return Calculation(expression: text, value: nil, unit: "", errorKey: failure == .zero ? "quick.divideZero" : failure == .domain ? "quick.domain" : "quick.incomplete")
        } catch { return nil }
    }
    static func format(_ value: Double) -> String {
        String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value).lowercased()
    }
    private enum Failure: Error { case syntax, unknown, zero, domain }
    private enum Token { case number(Double), name(String), symbol(Character) }
    private struct Parser {
        var tokens: [Token] = [], cursor = 0, depth = 0
        var atEnd: Bool { cursor == tokens.count }
        init(_ text: String) throws {
            let chars = Array(text); var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c.isNumber || c == "." {
                    let start = i; i += 1
                    while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                    if i < chars.count && chars[i] == "e" {
                        i += 1
                        if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                        while i < chars.count && chars[i].isNumber { i += 1 }
                    }
                    guard let number = Double(String(chars[start..<i])), number.isFinite else { throw Failure.syntax }
                    tokens.append(.number(number))
                } else if c.isLetter {
                    let start = i; i += 1
                    while i < chars.count && chars[i].isLetter { i += 1 }
                    let name = String(chars[start..<i])
                    guard ["pi", "e", "sqrt", "abs", "sin", "cos", "tan", "log", "ln", "exp", "floor", "ceil", "round"].contains(name) else { throw Failure.unknown }
                    tokens.append(.name(name))
                } else { tokens.append(.symbol(c)); i += 1 }
                guard tokens.count <= 256 else { throw Failure.syntax }
            }
        }
        mutating func take(_ c: Character) -> Bool {
            guard cursor < tokens.count, case .symbol(c) = tokens[cursor] else { return false }
            cursor += 1; return true
        }
        mutating func expression() throws -> Double {
            depth += 1; defer { depth -= 1 }; guard depth <= 32 else { throw Failure.syntax }
            var value = try product()
            while true {
                if take("+") { value += try product() }
                else if take("-") { value -= try product() }
                else { return value }
            }
        }
        mutating func product() throws -> Double {
            var value = try unary()
            while true {
                if take("*") { value *= try unary() }
                else if take("/") { let divisor = try unary(); guard divisor != 0 else { throw Failure.zero }; value /= divisor }
                else { return value }
            }
        }
        mutating func unary() throws -> Double {
            depth += 1; defer { depth -= 1 }; guard depth <= 32 else { throw Failure.syntax }
            if take("+") { return try unary() }
            if take("-") { return -(try unary()) }
            var value = try atom()
            while take("%") { value /= 100 }
            if take("^") { value = pow(value, try unary()) }
            guard value.isFinite else { throw Failure.domain }
            return value
        }
        mutating func atom() throws -> Double {
            if take("(") { let value = try expression(); guard take(")") else { throw Failure.syntax }; return value }
            guard cursor < tokens.count else { throw Failure.syntax }
            let token = tokens[cursor]; cursor += 1
            switch token {
            case .number(let value): return value
            case .name(let name):
                if name == "pi" { return .pi }; if name == "e" { return exp(1) }
                let value: Double
                if take("(") { value = try expression(); guard take(")") else { throw Failure.syntax } }
                else if name == "sqrt" { value = try unary() }
                else { throw Failure.syntax }
                switch name {
                case "sqrt": return sqrt(value)
                case "abs": return abs(value)
                case "sin": return sin(value)
                case "cos": return cos(value)
                case "tan": return tan(value)
                case "log": return log10(value)
                case "ln": return log(value)
                case "exp": return exp(value)
                case "floor": return floor(value)
                case "ceil": return ceil(value)
                default: return value.rounded()
                }
            default: throw Failure.syntax
            }
        }
    }
    private struct Unit {
        let group: String, symbol: String
        let scale: Double, offset: Double
    }
    private static let units: [String: Unit] = {
        var values: [String: Unit] = [:]
        func add(_ group: String, _ symbol: String, _ scale: Double, _ names: String, offset: Double = 0) {
            for name in names.split(separator: "|") { values[String(name).lowercased()] = Unit(group: group, symbol: symbol, scale: scale, offset: offset) }
        }
        add("length", "mm", 0.001, "mm|毫米"); add("length", "cm", 0.01, "cm|厘米")
        add("length", "m", 1, "m|meter|meters|米"); add("length", "km", 1000, "km|kilometer|kilometers|公里|千米")
        add("length", "in", 0.0254, "in|inch|inches|英寸"); add("length", "ft", 0.3048, "ft|foot|feet|英尺")
        add("length", "yd", 0.9144, "yd|yard|yards|码"); add("length", "mi", 1609.344, "mi|mile|miles|英里")
        add("mass", "g", 1, "g|gram|grams|克"); add("mass", "kg", 1000, "kg|kilogram|kilograms|千克|公斤")
        add("mass", "mg", 0.001, "mg|毫克"); add("mass", "lb", 453.59237, "lb|lbs|pound|pounds|磅")
        add("mass", "oz", 28.349523125, "oz|ounce|ounces|盎司"); add("mass", "斤", 500, "斤")
        add("time", "s", 1, "s|sec|second|seconds|秒"); add("time", "min", 60, "min|mins|minute|minutes|分钟")
        add("time", "h", 3600, "h|hr|hour|hours|小时"); add("time", "d", 86400, "d|day|days|天")
        add("temperature", "°C", 1, "c|°c|℃|摄氏度", offset: 273.15)
        add("temperature", "°F", 5/9, "f|°f|℉|华氏度", offset: 273.15 - 32 * 5/9)
        add("temperature", "K", 1, "k|开尔文")
        for (i, symbol) in ["B", "KB", "MB", "GB", "TB"].enumerated() { add("data", symbol, pow(1000, Double(i)), symbol) }
        for (i, symbol) in ["KiB", "MiB", "GiB", "TiB"].enumerated() { add("data", symbol, pow(1024, Double(i + 1)), symbol) }
        return values
    }()
    private static let conversion = try! NSRegularExpression(pattern: #"^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Z°℃℉\p{Han}]+?)\s*(?:to|in|转换成|转换为|换算成|转|到)\s*([a-zA-Z°℃℉\p{Han}]+)$"#, options: [.caseInsensitive])
    private static func convert(_ text: String) -> Calculation? {
        let source = text as NSString
        guard let match = conversion.firstMatch(in: text, range: NSRange(location: 0, length: source.length)),
              let number = Double(source.substring(with: match.range(at: 1))), number.isFinite,
              let from = units[source.substring(with: match.range(at: 2)).lowercased()],
              let to = units[source.substring(with: match.range(at: 3)).lowercased()] else { return nil }
        guard from.group == to.group else { return Calculation(expression: text, value: nil, unit: "", errorKey: "quick.unitMismatch") }
        let base = number * from.scale + from.offset
        guard base.isFinite, from.group != "temperature" || base >= -1e-10 else { return Calculation(expression: text, value: nil, unit: "", errorKey: "quick.domain") }
        let result = (base - to.offset) / to.scale
        guard result.isFinite else { return Calculation(expression: text, value: nil, unit: "", errorKey: "quick.domain") }
        let roundedZero = from.group == "temperature" && abs(result) < 1e-12
        return Calculation(expression: text, value: format(roundedZero ? 0 : result), unit: to.symbol, errorKey: nil)
    }
}
