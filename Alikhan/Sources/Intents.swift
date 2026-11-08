import AppIntents

/// «Алиханды аш», «Открой Алихан»: қосымша ашылып, сөйлесу басталады.
struct OpenAlikhanIntent: AppIntent {
    static var title: LocalizedStringResource = "Алиханды ашу"
    static var description = IntentDescription("Алиханды ашып, тыңдауды бастайды.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let a = Assistant.shared
        a.boot()
        if a.settings.configured { a.startTalk() }
        return .result()
    }
}

/// «Алиханды тоқтат», «Останови Алихан»: микрофон мен Live Activity жабылады, қосымша ашылмайды.
struct StopAlikhanIntent: AppIntent {
    static var title: LocalizedStringResource = "Алиханды тоқтату"
    static var description = IntentDescription("Тыңдауды тоқтатып, микрофонды жабады.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Assistant.shared.stopAll()
        return .result()
    }
}

struct AlikhanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAlikhanIntent(), phrases: [
            "\(.applicationName)ды аш",
            "\(.applicationName) аш",
            "Открой \(.applicationName)",
            "Запусти \(.applicationName)",
            "Включи \(.applicationName)",
        ], shortTitle: "Алиханды аш", systemImageName: "waveform")
        AppShortcut(intent: StopAlikhanIntent(), phrases: [
            "\(.applicationName)ды тоқтат",
            "\(.applicationName) тоқтат",
            "Останови \(.applicationName)",
            "Выключи \(.applicationName)",
        ], shortTitle: "Алиханды тоқтат", systemImageName: "mic.slash")
    }
}
