import Foundation

enum ANSITextNormalizer {
    private enum ParserState {
        case normal
        case esc
        case csi
        case osc
        case oscEsc
        case stString
        case stEsc
    }

    static func normalize(_ text: String) -> String {
        let stripped = stripTerminalControlSequences(from: text)
        let normalizedCR = normalizeCarriageReturns(in: stripped)
        return applyBackspaces(in: normalizedCR)
    }

    private static func stripTerminalControlSequences(from text: String) -> String {
        var state: ParserState = .normal
        var scalars = String.UnicodeScalarView()

        for scalar in text.unicodeScalars {
            let value = scalar.value

            switch state {
            case .normal:
                switch value {
                case 0x1B:
                    state = .esc
                case 0x9B:
                    state = .csi
                case 0x9D:
                    state = .osc
                case 0x90, 0x98, 0x9E, 0x9F:
                    state = .stString
                default:
                    if shouldKeepScalar(value) {
                        scalars.append(scalar)
                    }
                }

            case .esc:
                switch value {
                case 0x5B: // [
                    state = .csi
                case 0x5D: // ]
                    state = .osc
                case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
                    state = .stString
                default:
                    state = .normal
                }

            case .csi:
                if (0x40...0x7E).contains(value) {
                    state = .normal
                }

            case .osc:
                if value == 0x07 || value == 0x9C {
                    state = .normal
                } else if value == 0x1B {
                    state = .oscEsc
                }

            case .oscEsc:
                state = value == 0x5C ? .normal : .osc // ESC \

            case .stString:
                if value == 0x9C {
                    state = .normal
                } else if value == 0x1B {
                    state = .stEsc
                }

            case .stEsc:
                state = value == 0x5C ? .normal : .stString // ESC \
            }
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private static func shouldKeepScalar(_ value: UInt32) -> Bool {
        if value == 0x09 || value == 0x0A || value == 0x0D || value == 0x08 {
            return true
        }
        if value < 0x20 || value == 0x7F {
            return false
        }
        return true
    }

    private static func normalizeCarriageReturns(in text: String) -> String {
        // In non-emulated terminals, stray carriage-returns usually mean line refresh.
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func applyBackspaces(in text: String) -> String {
        var buffer: [Character] = []
        buffer.reserveCapacity(text.count)

        for char in text {
            if char == "\u{08}" {
                if !buffer.isEmpty {
                    buffer.removeLast()
                }
            } else {
                buffer.append(char)
            }
        }

        return String(buffer)
    }
}
