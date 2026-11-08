import ActivityKit
import SwiftUI

/// Қосымша мен виджетке ортақ: Live Activity деректері және күй түстері.
struct AlikhanAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var state: String      // sleep, listen, think, speak, error
        var heard: String      // соңғы естілген
        var said: String       // соңғы айтылған
        var banner: String     // «Тыңдап тұрмын, сэр» сияқты қысқа мәтін
    }
    var name: String = "Алихан"
}

enum OrbState: String, CaseIterable {
    case sleep, listen, think, speak, error

    /// Ноутбуктағы шардың түстері: (ашық, қою, жарқыл)
    var palette: (light: Color, dark: Color, glow: Color) {
        switch self {
        case .sleep: return (Color(hex: 0x3a4656), Color(hex: 0x1c232d), Color(hex: 0x5eead4))
        case .listen: return (Color(hex: 0x4ade80), Color(hex: 0x047857), Color(hex: 0x34d399))
        case .think: return (Color(hex: 0xa78bfa), Color(hex: 0x5b21b6), Color(hex: 0x8b5cf6))
        case .speak: return (Color(hex: 0x7dd3fc), Color(hex: 0x1d4ed8), Color(hex: 0x38bdf8))
        case .error: return (Color(hex: 0xfb7185), Color(hex: 0x9f1239), Color(hex: 0xf43f5e))
        }
    }

    /// Dynamic Island белгісінің түсі
    var accent: Color {
        switch self {
        case .sleep: return Color(hex: 0x4a6a9a)
        case .listen: return Color(hex: 0x34d399)
        case .think: return Color(hex: 0xa78bfa)
        case .speak: return Color(hex: 0x38bdf8)
        case .error: return Color(hex: 0xf43f5e)
        }
    }

    var symbol: String {
        switch self {
        case .sleep: return "moon.zzz.fill"
        case .listen: return "waveform"
        case .think: return "ellipsis"
        case .speak: return "speaker.wave.2.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .sleep: return "«Алихан» деңіз"
        case .listen: return "Тыңдап тұр"
        case .think: return "Ойланып жатыр"
        case .speak: return "Сөйлеп тұр"
        case .error: return "Қате"
        }
    }

    var dragon: String { "dragon_\(rawValue)" }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
