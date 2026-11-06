import Foundation

/// The search's calculator: arithmetic, percentages, units and currencies, typed the way one says them
/// ("10+10", "10 eur to uah", "20% off 500" is later, "5 km в мили"). Pure and synchronous; rates come from `Rates`.
/// Silent unless the input is clearly maths: a lone number or word stays an app search.
enum Calculator {
    struct Answer: Equatable {
        /// Shown large: "455,00 UAH", "2,524 m", "20".
        var result: String
        /// What ↵ copies.
        var copy: String
        /// Under the result: "Евро → Украинская гривна · ExchangeRate-API", "Длина".
        var detail: String
        /// What ⌘↵ puts into the field to go on calculating (canonical: "455 UAH").
        var chain: String
        var isError = false
    }

    static func evaluate(_ input: String, rates: Rates) -> Answer? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let tokens = Lexer.tokens(text) else { return nil }
        let parser = Parser(tokens: tokens, rates: rates)
        do {
            guard var value = try parser.run(), parser.looksLikeMaths else { return nil }
            var pair = parser.currencyPair
            // "10 eur": into the Mac's region currency; that one itself goes into dollars (dollars into euros).
            if case .currency(let code)? = value.unit, !parser.explicitTarget, parser.operatorCount == 0 {
                let region = Locale.current.currency?.identifier ?? "USD"
                let target = code != region ? region : (code == "USD" ? "EUR" : "USD")
                if let rate = try rates.rate(code, target) {
                    value = Value(number: value.number * rate, unit: .currency(target))
                    pair = (code, target)
                }
            }
            return answer(value, rates: rates, bare: parser.bareQuantity, pair: pair)
        } catch let error as Failure {
            return Answer(result: error.message, copy: error.message, detail: "Калькулятор", chain: text, isError: true)
        } catch {
            return nil
        }
    }

    // MARK: Values

    struct Measure: Equatable {
        enum Kind: String { case length, mass, time, temperature, volume, data, speed }
        let symbol: String
        let kind: Kind
        /// value × factor + offset = the value in the kind's base unit (metre, kilogram, second, kelvin…).
        let factor: Double
        var offset: Double = 0
    }

    enum Unit: Equatable {
        case measure(Measure)
        case currency(String)
    }

    struct Value {
        var number: Double
        var unit: Unit?
        var percent = false
    }

    struct Failure: Error {
        let message: String
    }

    // MARK: Answer

    private static func answer(_ value: Value, rates: Rates, bare: Bool, pair: (String, String)?) -> Answer? {
        var value = value
        var detail = "Калькулятор"
        if value.percent { value.number /= 100; value.percent = false }
        guard value.number.isFinite else { return nil }
        switch value.unit {
        case .currency(let code):
            let (shown, copy) = (format(value.number, currency: true) + " " + code, format(value.number, currency: true))
            let names = pair.map { name($0.0) + " → " + name($0.1) + " · " } ?? ""
            return Answer(result: shown, copy: copy, detail: names + rates.source, chain: canonical(value.number) + " " + code)
        case .measure(let measure):
            // "1 m" alone turns into feet and so on; a calculation keeps its unit.
            if bare, let other = Units.counterpart[measure.symbol], let target = Units.find(other) {
                let converted = Units.convert(value.number, from: measure, to: target)
                value = Value(number: converted, unit: .measure(target))
            }
            detail = Units.kindTitle[(value.unit.flatMap { if case .measure(let m) = $0 { m.kind } else { nil } }) ?? measure.kind] ?? detail
            guard case .measure(let shownUnit) = value.unit else { return nil }
            let shown = format(value.number, currency: false, digits: 6) + " " + shownUnit.symbol
            return Answer(result: shown, copy: shown, detail: detail, chain: canonical(value.number) + " " + shownUnit.symbol)
        case nil:
            let shown = format(value.number, currency: false)
            return Answer(result: shown, copy: shown, detail: detail, chain: canonical(value.number))
        }
    }

    /// "Евро", "Украинская гривна": in the system language.
    static func name(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forCurrencyCode: code) else { return code }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The person's number format (a decimal comma in ru, uk, de…), at most 12 significant digits (0.1 + 0.2 = 0.3).
    static func format(_ number: Double, currency: Bool, digits: Int = 12) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        if currency && (abs(number) >= 0.01 || number == 0) {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        } else if abs(number) >= 1e15 || (abs(number) < 1e-9 && number != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 6
        } else {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = currency ? 4 : digits
        }
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    static func canonical(_ number: Double) -> String {
        number.formatted(.number.precision(.significantDigits(1...12)).grouping(.never).locale(Locale(identifier: "en_US")))
    }

    // MARK: Lexer

    struct Token: Equatable {
        enum Kind: Equatable {
            case number(Double)
            case word(String)
            case symbol(Character)
            case currency(String)
        }
        let kind: Kind
        /// "10k" is ten thousand, "10 k" is kelvin.
        let spaced: Bool
        /// Written as 10k or 1e5: maths even when alone.
        var scaled = false
    }

    enum Lexer {
        static let signs: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₴": "UAH", "₽": "RUB", "¥": "JPY",
                                                 "₹": "INR", "₺": "TRY", "₸": "KZT", "₩": "KRW", "₪": "ILS"]

        static func tokens(_ text: String) -> [Token]? {
            let chars = Array(text)
            let comma = Locale.current.decimalSeparator == ","
            var result: [Token] = []
            var i = 0
            var spaced = false
            func push(_ kind: Token.Kind, scaled: Bool = false) {
                result.append(Token(kind: kind, spaced: spaced, scaled: scaled))
                spaced = false
            }
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { spaced = true; i += 1; continue }
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var digits = ""
                    var seenPoint = false
                    while i < chars.count {
                        let d = chars[i]
                        if d.isNumber, let ascii = d.wholeNumberValue {
                            digits.append(Character(String(ascii)))
                        } else if (d == "." || (d == "," && comma)) && !seenPoint && i + 1 < chars.count && chars[i + 1].isNumber {
                            digits.append(".")
                            seenPoint = true
                        } else if d == "," && !comma && Self.grouping(chars, i) {
                            // "1,000" with a decimal point locale: a thousands separator.
                        } else if (d == " " || d == "\u{00A0}") && comma && Self.grouping(chars, i) && !digits.contains(".") {
                            // "1 000" in ru/uk: grouping by space.
                        } else {
                            break
                        }
                        i += 1
                    }
                    var scaled = false
                    // Exponent: 1e5, 5e-3.
                    if i + 1 < chars.count, chars[i] == "e" || chars[i] == "E" {
                        var j = i + 1
                        var exponent = ""
                        if j < chars.count, chars[j] == "-" || chars[j] == "+" { exponent.append(chars[j]); j += 1 }
                        let start = j
                        while j < chars.count, chars[j].isASCII, chars[j].isNumber { exponent.append(chars[j]); j += 1 }
                        if j > start, j == chars.count || !chars[j].isLetter { digits += "e" + exponent; i = j; scaled = true }
                    }
                    guard var number = Double(digits) else { return nil }
                    // 10k = 10 000 (no space, nothing after it but the end, a space or an operator).
                    if i < chars.count, chars[i] == "k" || chars[i] == "K",
                       i + 1 == chars.count || !chars[i + 1].isLetter {
                        number *= 1000
                        i += 1
                        scaled = true
                    }
                    push(.number(number), scaled: scaled)
                    continue
                }
                if c.isLetter || c == "°" {
                    var word = ""
                    while i < chars.count, chars[i].isLetter || chars[i] == "°" || chars[i] == "²" || chars[i] == "³" {
                        word.append(chars[i])
                        i += 1
                    }
                    // km/h, m/s.
                    if i + 1 < chars.count, chars[i] == "/" {
                        var j = i + 1
                        var tail = ""
                        while j < chars.count, chars[j].isLetter { tail.append(chars[j]); j += 1 }
                        if Units.find(word + "/" + tail) != nil { word += "/" + tail; i = j }
                    }
                    push(.word(word.lowercased()))
                    continue
                }
                if let code = signs[c] { push(.currency(code)); i += 1; continue }
                if c == "-", i + 1 < chars.count, chars[i + 1] == ">" { push(.word("->")); i += 2; continue }
                let symbols: [Character: Character] = ["+": "+", "-": "-", "−": "-", "*": "*", "×": "*", "·": "*",
                                                       "/": "/", "÷": "/", "^": "^", "(": "(", ")": ")", "%": "%",
                                                       ",": ",", ";": ";"]
                guard let symbol = symbols[c] else { return nil }
                push(.symbol(symbol))
                i += 1
            }
            return result
        }

        /// A separator followed by exactly three digits and then no further digit.
        private static func grouping(_ chars: [Character], _ i: Int) -> Bool {
            guard i + 3 < chars.count else { return false }
            let next = chars[(i + 1)...].prefix(3)
            guard next.count == 3, next.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            return i + 4 >= chars.count || !chars[i + 4].isNumber
        }
    }

    // MARK: Parser

    final class Parser {
        private let tokens: [Token]
        private let rates: Rates
        private var i = 0
        /// An operator, function, unit, currency or conversion appeared: a lone "100" is not maths.
        private(set) var looksLikeMaths = false
        /// One number with one unit and nothing else ("1 m"): it converts by itself.
        private(set) var bareQuantity = false
        /// "… to uah" was typed.
        private(set) var explicitTarget = false
        /// The last money conversion, for "Евро → Гривна".
        private(set) var currencyPair: (String, String)?
        private var operators = 0
        var operatorCount: Int { operators }

        static let convertWords: Set<String> = ["to", "in", "->", "в", "into", "as", "во"]
        static let multipliers: [String: Double] = ["thousand": 1e3, "million": 1e6, "billion": 1e9, "тыс": 1e3,
                                                     "тысяч": 1e3, "тысячи": 1e3, "млн": 1e6, "миллион": 1e6,
                                                     "миллиона": 1e6, "миллионов": 1e6, "млрд": 1e9]

        init(tokens: [Token], rates: Rates) {
            self.tokens = tokens
            self.rates = rates
        }

        func run() throws -> Value? {
            guard let value = try conversion() else { return nil }
            // "10 +" keeps showing 10 while the next number is typed.
            while i < tokens.count, case .symbol(let s) = tokens[i].kind, "+-*/^".contains(s) { i += 1 }
            guard i == tokens.count else { return nil }
            bareQuantity = operators == 0 && !explicitTarget && value.unit != nil && tokens.count <= 3
            return value
        }

        private var peek: Token.Kind? { i < tokens.count ? tokens[i].kind : nil }

        private func word(_ offset: Int = 0) -> String? {
            guard i + offset < tokens.count, case .word(let w) = tokens[i + offset].kind else { return nil }
            return w
        }

        private func conversion() throws -> Value? {
            guard var value = try sum() else { return nil }
            if let w = word(), Self.convertWords.contains(w) {
                i += 1
                looksLikeMaths = true
                explicitTarget = true
                guard let target = try unit(allowBareCurrencyWord: true) else { return nil }
                value = try convert(value, to: target)
            }
            return value
        }

        private func sum() throws -> Value? {
            guard var left = try product() else { return nil }
            while case .symbol(let s)? = peek, s == "+" || s == "-" {
                i += 1
                looksLikeMaths = true
                guard let right = try product() else { return left }
                operators += 1
                left = try add(left, right, minus: s == "-")
            }
            return left
        }

        private func product() throws -> Value? {
            guard var left = try power() else { return nil }
            while true {
                if case .symbol(let s)? = peek, s == "*" || s == "/" {
                    i += 1
                    looksLikeMaths = true
                    guard let right = try power() else { return left }
                    left = try multiply(left, right, divide: s == "/")
                } else if word() == "x" || word() == "mod" {
                    let isMod = word() == "mod"
                    i += 1
                    guard let right = try power() else { return left }
                    if isMod {
                        guard left.unit == nil, right.unit == nil, right.number != 0 else { return nil }
                        // Like most calculators: the sign of the dividend (-10 mod 3 = -1).
                        left = Value(number: left.number.truncatingRemainder(dividingBy: right.number))
                    } else {
                        left = try multiply(left, right, divide: false)
                    }
                } else if startsImplicitFactor() {
                    // Implicit multiplication: 2pi, 4(2+3); never two plain numbers ("5 3" is not maths).
                    guard let right = try power() else { return left }
                    left = try multiply(left, right, divide: false)
                } else {
                    return left
                }
                operators += 1
                looksLikeMaths = true
            }
        }

        private func power() throws -> Value? {
            guard let base = try unary() else { return nil }
            if case .symbol("^")? = peek {
                i += 1
                guard let exponent = try power() else { return base }
                guard base.unit == nil, exponent.unit == nil else { throw Failure(message: "Степень только для чисел") }
                operators += 1
                looksLikeMaths = true
                return Value(number: pow(base.number, exponent.number))
            }
            return base
        }

        private func unary() throws -> Value? {
            if case .symbol(let s)? = peek, s == "-" || s == "+" {
                i += 1
                guard var value = try unary() else { return nil }
                if s == "-" { value.number = -value.number }
                return value
            }
            guard var value = try primary() else { return nil }
            if case .symbol("%")? = peek {
                i += 1
                looksLikeMaths = true
                value.percent = true
            }
            return value
        }

        private func startsImplicitFactor() -> Bool {
            switch peek {
            case .symbol("(")?: return true
            case .word(let w)?: return Functions.constants[w] != nil || Functions.unary[w] != nil || Functions.lists.contains(w)
            default: return false
            }
        }

        private func primary() throws -> Value? {
            switch peek {
            case .number(let n)?:
                if tokens[i].scaled { looksLikeMaths = true }
                i += 1
                var value = Value(number: n)
                // 1.5 million, 13 billion, 10 тыс.
                if let w = word(), let multiplier = Self.multipliers[w] {
                    i += 1
                    looksLikeMaths = true
                    value.number *= multiplier
                }
                try attachUnits(&value)
                return value
            case .currency(let code)?:
                // "$10", "€ 20".
                i += 1
                guard case .number(let n)? = peek else { return nil }
                i += 1
                looksLikeMaths = true
                return Value(number: n, unit: .currency(code))
            case .symbol("(")?:
                i += 1
                guard var value = try conversion() else { return nil }
                if case .symbol(")")? = peek { i += 1 }
                if value.unit == nil { try attachUnits(&value) }
                return value
            case .word(let w)?:
                if let constant = Functions.constants[w] {
                    i += 1
                    looksLikeMaths = true
                    return Value(number: constant)
                }
                if Functions.unary[w] != nil || Functions.lists.contains(w) { return try function(w) }
                // "eur to usd": one unit of it.
                if word(1).map(Self.convertWords.contains) == true, let target = try unit(allowBareCurrencyWord: true) {
                    looksLikeMaths = true
                    return Value(number: 1, unit: target)
                }
                return nil
            default:
                return nil
            }
        }

        /// "10 eur", "5 feet 3 inches", "20€".
        private func attachUnits(_ value: inout Value) throws {
            if case .currency(let code)? = peek {
                i += 1
                looksLikeMaths = true
                value.unit = .currency(code)
                return
            }
            // "10 in to cm" is inches; "10 eur in uah" is a conversion: "in" is a unit only at the end or before "to".
            if word() == "in" {
                let next = word(1)
                guard i + 1 == tokens.count || next == "to" || next == "->" || next == "в" else { return }
            }
            guard let first = try unit(allowBareCurrencyWord: false) else { return }
            looksLikeMaths = true
            value.unit = first
            // Side by side, one value: 5 feet 3 inches = 5.25 ft.
            while case .measure(let a) = value.unit, case .number(let n)? = peek, let w = word(1),
                  let b = Units.find(w), b.kind == a.kind {
                i += 2
                value.number += Units.convert(n, from: b, to: a)
            }
        }

        /// A unit or currency name at the cursor.
        private func unit(allowBareCurrencyWord: Bool) throws -> Unit? {
            switch peek {
            case .currency(let code)?:
                i += 1
                return .currency(code)
            case .word(let w)?:
                // A three-letter word right after an amount is a currency code only if it is one.
                if let measure = Units.find(w) {
                    i += 1
                    return .measure(measure)
                }
                if let code = Currencies.code(w) {
                    i += 1
                    return .currency(code)
                }
                return nil
            default:
                return nil
            }
        }

        private func function(_ name: String) throws -> Value? {
            i += 1
            looksLikeMaths = true
            var args: [Value] = []
            if case .symbol("(")? = peek {
                i += 1
                while true {
                    guard let arg = try conversion() else { break }
                    args.append(arg)
                    if case .symbol(let s)? = peek, s == "," || s == ";" { i += 1; continue }
                    break
                }
                if case .symbol(")")? = peek { i += 1 }
            } else if let arg = try power() {
                // "sqrt 25".
                args.append(arg)
            }
            guard !args.isEmpty else { return nil }
            if Functions.lists.contains(name) {
                let unit = args.first?.unit
                let numbers = try args.map { arg -> Double in
                    guard arg.unit == unit else { throw Failure(message: "Разные единицы в \(name)") }
                    return arg.number
                }
                let result: Double = switch name {
                case "min": numbers.min() ?? 0
                case "max": numbers.max() ?? 0
                case "sum": numbers.reduce(0, +)
                default: numbers.reduce(0, +) / Double(numbers.count)
                }
                return Value(number: result, unit: unit)
            }
            guard let f = Functions.unary[name] else { return nil }
            if name == "round", args.count == 2 {
                let scale = pow(10, args[1].number)
                return Value(number: (args[0].number * scale).rounded() / scale, unit: args[0].unit)
            }
            if name == "log", args.count == 2 { return Value(number: log(args[0].number) / log(args[1].number)) }
            if name == "root", args.count == 2 {
                let x = args[0].number, n = args[1].number
                return Value(number: x < 0 && n.truncatingRemainder(dividingBy: 2) == 1 ? -pow(-x, 1 / n) : pow(x, 1 / n))
            }
            if name == "pow", args.count == 2 { return Value(number: pow(args[0].number, args[1].number)) }
            if name == "hypot", args.count == 2 { return Value(number: hypot(args[0].number, args[1].number)) }
            guard args[0].unit == nil || ["round", "abs", "floor", "ceil"].contains(name) else { return nil }
            return Value(number: f(args[0].number), unit: args[0].unit)
        }

        // MARK: Arithmetic with units

        private func add(_ a: Value, _ b: Value, minus: Bool) throws -> Value {
            let sign: Double = minus ? -1 : 1
            // 450 + 20%: a percentage of the left side.
            if b.percent && !a.percent { return Value(number: a.number * (1 + sign * b.number / 100), unit: a.unit) }
            switch (a.unit, b.unit) {
            case (nil, nil): return Value(number: a.number + sign * b.number, percent: a.percent && b.percent)
            case (let unit?, nil): return Value(number: a.number + sign * b.number, unit: unit)
            case (nil, let unit?): return Value(number: a.number + sign * b.number, unit: unit)
            case (let ua?, let ub?):
                // The answer is in the unit typed last: 5 feet + 1 m = 2.524 m.
                let left = try convert(Value(number: a.number, unit: ua), to: ub)
                return Value(number: left.number + sign * b.number, unit: ub)
            }
        }

        private func multiply(_ a: Value, _ b: Value, divide: Bool) throws -> Value {
            if b.percent && !a.percent {
                // 10 kg * 3% = 0.3 kg.
                let factor = b.number / 100
                return Value(number: divide ? a.number / factor : a.number * factor, unit: a.unit)
            }
            switch (a.unit, b.unit) {
            case (_, nil):
                return Value(number: divide ? a.number / b.number : a.number * b.number, unit: a.unit)
            case (nil, let unit?) where !divide:
                return Value(number: a.number * b.number, unit: unit)
            case (let ua?, let ub?) where divide:
                // 10 km / 2 km = 5: same kind, a plain ratio.
                let left = try convert(Value(number: a.number, unit: ua), to: ub)
                return Value(number: left.number / b.number)
            default:
                throw Failure(message: "Так единицы не перемножить")
            }
        }

        private func convert(_ value: Value, to target: Unit) throws -> Value {
            switch (value.unit, target) {
            case (nil, _):
                return Value(number: value.number, unit: target)
            case (.measure(let from)?, .measure(let to)):
                guard from.kind == to.kind else {
                    let a = Units.kindTitle[from.kind]?.lowercased() ?? "", b = Units.kindTitle[to.kind]?.lowercased() ?? ""
                    throw Failure(message: "Разные величины: \(a) и \(b)")
                }
                return Value(number: Units.convert(value.number, from: from, to: to), unit: target)
            case (.currency(let from)?, .currency(let to)):
                guard let rate = try rates.rate(from, to) else { throw Failure(message: "Нет курса для \(from) или \(to)") }
                currencyPair = (from, to)
                return Value(number: value.number * rate, unit: target)
            case (.measure(let from)?, .currency(let to)) where from.symbol == "lb":
                // "10 pounds to euros": money, not weight.
                return try convert(Value(number: value.number, unit: .currency("GBP")), to: .currency(to))
            default:
                throw Failure(message: "Деньги и единицы не переводятся друг в друга")
            }
        }
    }

    // MARK: Tables

    enum Functions {
        static let unary: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "exp": { exp($0) }, "ln": { log($0) },
            "log": { log10($0) }, "log2": { log2($0) }, "round": { $0.rounded() }, "floor": { $0.rounded(.down) },
            "ceil": { $0.rounded(.up) }, "abs": { abs($0) }, "trunc": { $0.rounded(.towardZero) },
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) }, "asin": { asin($0) }, "acos": { acos($0) },
            "atan": { atan($0) }, "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
            "root": { $0.squareRoot() }, "pow": { $0 }, "hypot": { $0 }, "корень": { $0.squareRoot() },
        ]
        static let lists: Set<String> = ["min", "max", "sum", "avg", "average"]
        static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi, "phi": (1 + 5.squareRoot()) / 2]
    }

    enum Units {
        static let all: [String: Measure] = {
            var table: [String: Measure] = [:]
            func add(_ names: [String], _ symbol: String, _ kind: Measure.Kind, _ factor: Double, _ offset: Double = 0) {
                let measure = Measure(symbol: symbol, kind: kind, factor: factor, offset: offset)
                for name in names { table[name] = measure }
            }
            add(["mm", "millimeter", "millimeters", "мм"], "mm", .length, 0.001)
            add(["cm", "centimeter", "centimeters", "см"], "cm", .length, 0.01)
            add(["m", "meter", "meters", "metre", "metres", "м", "метр", "метра", "метров"], "m", .length, 1)
            add(["km", "kilometer", "kilometers", "kilometre", "kilometres", "км"], "km", .length, 1000)
            add(["in", "inch", "inches", "дюйм", "дюйма", "дюймов"], "in", .length, 0.0254)
            add(["ft", "foot", "feet", "фут", "фута", "футов"], "ft", .length, 0.3048)
            add(["yd", "yard", "yards", "ярд", "ярдов"], "yd", .length, 0.9144)
            add(["mi", "mile", "miles", "миля", "мили", "миль"], "mi", .length, 1609.344)
            add(["nmi"], "nmi", .length, 1852)
            add(["mg", "мг"], "mg", .mass, 0.000001)
            add(["g", "gram", "grams", "г", "грамм", "грамма"], "g", .mass, 0.001)
            add(["kg", "kilo", "kilos", "kilogram", "kilograms", "кг"], "kg", .mass, 1)
            add(["t", "tonne", "tonnes", "т", "тонна", "тонн"], "t", .mass, 1000)
            add(["oz", "ounce", "ounces", "унция", "унций"], "oz", .mass, 0.028349523125)
            add(["lb", "lbs", "pound", "pounds", "фунт", "фунта", "фунтов"], "lb", .mass, 0.45359237)
            add(["ms", "мс"], "ms", .time, 0.001)
            add(["s", "sec", "secs", "second", "seconds", "с", "сек", "секунд", "секунды"], "s", .time, 1)
            add(["min", "mins", "minute", "minutes", "мин", "минут", "минуты"], "min", .time, 60)
            add(["h", "hr", "hrs", "hour", "hours", "ч", "час", "часа", "часов"], "h", .time, 3600)
            add(["d", "day", "days", "дн", "день", "дня", "дней"], "d", .time, 86_400)
            add(["wk", "week", "weeks", "нед", "неделя", "недели", "недель"], "wk", .time, 604_800)
            add(["yr", "year", "years", "год", "года", "лет"], "yr", .time, 365.2425 * 86_400)
            add(["c", "°c", "celsius", "°с"], "°C", .temperature, 1, 273.15)
            add(["f", "°f", "fahrenheit"], "°F", .temperature, 5.0 / 9.0, 459.67 * 5.0 / 9.0)
            add(["k", "kelvin"], "K", .temperature, 1)
            add(["ml", "milliliter", "milliliters", "мл"], "ml", .volume, 0.001)
            add(["l", "liter", "liters", "litre", "litres", "л", "литр", "литра", "литров"], "l", .volume, 1)
            add(["gal", "gallon", "gallons", "галлон", "галлонов"], "gal", .volume, 3.785411784)
            add(["b", "byte", "bytes", "байт"], "B", .data, 1)
            add(["kb", "кб"], "KB", .data, 1e3)
            add(["mb", "мб"], "MB", .data, 1e6)
            add(["gb", "гб"], "GB", .data, 1e9)
            add(["tb", "тб"], "TB", .data, 1e12)
            add(["km/h", "kmh", "kph", "км/ч"], "km/h", .speed, 1000.0 / 3600)
            add(["mph"], "mph", .speed, 1609.344 / 3600)
            add(["m/s", "м/с"], "m/s", .speed, 1)
            add(["kn", "knot", "knots", "узлов"], "kn", .speed, 1852.0 / 3600)
            return table
        }()

        static func find(_ name: String) -> Measure? { all[name.lowercased()] }

        static func convert(_ number: Double, from: Measure, to: Measure) -> Double {
            (number * from.factor + from.offset - to.offset) / to.factor
        }

        /// What a bare quantity turns into.
        static let counterpart: [String: String] = [
            "m": "ft", "km": "mi", "cm": "in", "mm": "in", "mi": "km", "ft": "m", "in": "cm", "yd": "m",
            "kg": "lb", "g": "oz", "lb": "kg", "oz": "g", "t": "lb",
            "°C": "°F", "°F": "°C", "K": "°C", "l": "gal", "gal": "l", "ml": "oz",
            "km/h": "mph", "mph": "km/h", "m/s": "km/h", "kn": "km/h",
            "h": "min", "min": "h", "s": "min", "d": "h", "wk": "d", "yr": "d",
        ]

        static let kindTitle: [Measure.Kind: String] = [
            .length: "Длина", .mass: "Масса", .time: "Время", .temperature: "Температура", .volume: "Объём",
            .data: "Данные", .speed: "Скорость",
        ]
    }

    enum Currencies {
        static let codes = Set(Locale.commonISOCurrencyCodes)

        /// Words for money in English and Russian/Ukrainian; shared ones by hand ("dollars" → USD).
        static let names: [String: String] = [
            "euro": "EUR", "euros": "EUR", "евро": "EUR",
            "dollar": "USD", "dollars": "USD", "доллар": "USD", "доллара": "USD", "долларов": "USD", "баксов": "USD",
            "hryvnia": "UAH", "hryvnias": "UAH", "hryvnya": "UAH", "гривна": "UAH", "гривны": "UAH", "гривен": "UAH",
            "гривня": "UAH", "гривні": "UAH", "гривень": "UAH",
            "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "roubles": "RUB", "рубль": "RUB", "рубля": "RUB", "рублей": "RUB",
            "zloty": "PLN", "zlotys": "PLN", "злотый": "PLN", "злотых": "PLN", "zł": "PLN",
            "yen": "JPY", "иена": "JPY", "иен": "JPY", "yuan": "CNY", "юань": "CNY", "юаней": "CNY",
            "franc": "CHF", "francs": "CHF", "франк": "CHF", "франков": "CHF", "lira": "TRY", "лира": "TRY", "лир": "TRY",
            "tenge": "KZT", "тенге": "KZT", "sterling": "GBP", "стерлингов": "GBP",
        ]

        /// Any ISO code macOS knows or the rate feed quotes, in any case.
        static func code(_ word: String) -> String? {
            if let code = names[word] { return code }
            let upper = word.uppercased()
            guard word.count == 3, word.allSatisfy(\.isLetter) else { return nil }
            return codes.contains(upper) || Rates.shared.perDollar[upper] != nil ? upper : nil
        }
    }
}

/// Exchange rates per US dollar from ExchangeRate-API's open feed (free, no key, daily; its terms ask for the
/// credit shown on the answer). Cached for a day in the data folder, so the search keeps converting offline.
final class Rates {
    static let shared = Rates()

    private(set) var perDollar: [String: Double] = [:]
    private(set) var fetchedAt: Date?
    /// On the main thread, after new rates arrived.
    var onChange: (() -> Void)?

    private let file = supportDir.appendingPathComponent("currency-rates.json")
    private let queue = DispatchQueue(label: "nook.rates")
    private var loading = false

    var source: String {
        let when = fetchedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return "Курс ExchangeRate-API" + when
    }

    /// nil when the rates are not here yet; throws for a code the feed does not know.
    func rate(_ from: String, _ to: String) throws -> Double? {
        guard !perDollar.isEmpty else { throw Calculator.Failure(message: "Курсы валют ещё не загрузились") }
        guard let a = perDollar[from] else { throw Calculator.Failure(message: "Нет курса для \(from)") }
        guard let b = perDollar[to] else { throw Calculator.Failure(message: "Нет курса для \(to)") }
        return b / a
    }

    /// From the cache file first; from the network when older than a day.
    func refresh() {
        guard !loading else { return }
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            if self.perDollar.isEmpty, let data = try? Data(contentsOf: self.file), let cached = Self.parse(data) {
                DispatchQueue.main.async { self.apply(cached.rates, cached.at) }
            }
            let age = (try? self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard age.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else {
                DispatchQueue.main.async { self.loading = false }
                return
            }
            var request = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200, let fresh = Self.parse(data) else {
                    DispatchQueue.main.async { self.loading = false }
                    return
                }
                self.queue.async { try? data.write(to: self.file, options: .atomic) }
                DispatchQueue.main.async {
                    self.loading = false
                    self.apply(fresh.rates, fresh.at)
                }
            }.resume()
        }
    }

    private func apply(_ rates: [String: Double], _ at: Date?) {
        perDollar = rates
        fetchedAt = at
        onChange?()
    }

    private static func parse(_ data: Data) -> (rates: [String: Double], at: Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["result"] as? String == "success",
              let raw = json["rates"] as? [String: Any] else { return nil }
        var rates: [String: Double] = [:]
        for (code, value) in raw { if let number = (value as? NSNumber)?.doubleValue, number > 0 { rates[code] = number } }
        guard rates["USD"] != nil else { return nil }
        let at = (json["time_last_update_unix"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return (rates, at)
    }
}
