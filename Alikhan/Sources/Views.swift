import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @EnvironmentObject var a: Assistant
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0b0f16), Color(hex: 0x151b26)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    Text(a.orb.label).font(.subheadline).foregroundStyle(a.orb.accent)
                    Spacer()
                    Button { a.openServerScreen() } label: {
                        Image(systemName: "display").font(.title2).foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("Сервер экраны")
                    Button { a.showTasks = true } label: {
                        Image(systemName: "checklist").font(.title2).foregroundStyle(.white.opacity(0.85))
                            .overlay(alignment: .topTrailing) {
                                if !a.asks.isEmpty {
                                    Text("\(a.asks.count)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(4).background(Circle().fill(Color(hex: 0xf43f5e))).offset(x: 8, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("Тапсырмаларым")
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.title2).foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityLabel("Баптау")
                }
                .padding(.horizontal, 20)

                Spacer()
                DragonView(state: a.orb, width: 350)
                    .onTapGesture { a.toggleTalk() }
                    .accessibilityLabel("Алихан: \(a.orb.label)")
                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    if !a.heard.isEmpty {
                        Text("Сіз: \(a.heard)").font(.callout).foregroundStyle(.white.opacity(0.65))
                    }
                    if !a.said.isEmpty {
                        Text(a.said).font(.body).foregroundStyle(.white)
                    }
                    if !a.status.isEmpty && a.orb == .error {
                        Text(a.status).font(.caption).foregroundStyle(Color(hex: 0xfb7185))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

                if let p = a.uploadProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Серверге жүктеліп жатыр: \(Int(p * 100))%").font(.footnote).foregroundStyle(.white.opacity(0.8))
                        ProgressView(value: p).tint(Color(hex: 0x38bdf8))
                    }
                    .padding(.horizontal, 20)
                }

                if let first = a.asks.first {
                    Button { a.showTasks = true } label: {
                        HStack {
                            Image(systemName: "hand.raised.fill").foregroundStyle(Color(hex: 0xfbbf24))
                            Text(first.heading).lineLimit(1).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                    }
                    .padding(.horizontal, 16)
                }

                if settings.pip {
                    PiPHost().frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings).environmentObject(a) }
        .sheet(isPresented: $a.showTasks) { TasksView().environmentObject(a) }
        .fullScreenCover(isPresented: .constant(!settings.configured)) { SettingsView(onboarding: true).environmentObject(settings).environmentObject(a) }
        .fullScreenCover(item: $a.serverScreen) { ServerScreenView(screen: $0).environmentObject(a) }
        .fullScreenCover(item: $a.capture) { req in
            CaptureView(video: req.video) { file, mime in a.captureFinished(file: file, mime: mime, request: req) }
                .ignoresSafeArea()
                .onAppear { a.captureStarted() }
        }
    }
}

/// «Тапсырмаларым»: қолданушы өз қолымен істейтін істер (GET /asks). Ең ескісі жоғарыда.
struct TasksView: View {
    @EnvironmentObject var a: Assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if a.asks.isEmpty {
                    Text("Қазір сізден күтетін ештеңе жоқ").foregroundStyle(.secondary)
                }
                ForEach(a.asks) { ask in
                    AskRow(ask: ask)
                }
            }
            .refreshable { await a.refreshAsks() }
            .navigationTitle("Тапсырмаларым")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Жабу") { dismiss() } } }
            .task {
                // Бет ашық тұрғанда 15 секунд сайын жаңарады
                while !Task.isCancelled {
                    await a.refreshAsks()
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
        }
    }
}

struct AskRow: View {
    @EnvironmentObject var a: Assistant
    let ask: Ask

    /// Бұл парақ жабылған соң ғана келесі толық экран ашылады
    private func afterClose(_ action: @escaping () -> Void) {
        a.showTasks = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.heading).font(.headline)
            if let q = ask.question, q != ask.heading { Text(q).font(.callout) }
            if let d = ask.created { Text(d, style: .relative).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                if ask.remote_browser_url != nil {
                    Button { afterClose { a.openServerScreen(for: ask) } } label: { Label("Ашу", systemImage: "display") }
                        .buttonStyle(.bordered)
                } else if ask.capture != nil {
                    Button { afterClose { a.startCapture(for: ask) } } label: { Label("Түсіру", systemImage: "camera") }
                        .buttonStyle(.bordered)
                } else if let s = ask.url, let url = URL(string: s) {
                    // Телефонның өз ісі (мысалы Kaspi-де растау)
                    Button { UIApplication.shared.open(url) } label: { Label("Сілтемені ашу", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Бас тарту", role: .destructive) { a.finishAsk(ask.ask_id, cancel: true) }
                    .buttonStyle(.borderless)
                Button { a.finishAsk(ask.ask_id) } label: { Label("Орындадым", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0x10b981))
            }
        }
        .padding(.vertical, 6)
    }
}

/// «Сервер экраны»: сервердегі браузер не терминал (noVNC), қосымшаның ішінде.
/// Логин мен парольді сіз осы экранда өзіңіз жазасыз. Бұл тек экран кадры: пароль қосымшадан өтпейді.
struct ServerScreenView: View {
    @EnvironmentObject var a: Assistant
    @Environment(\.dismiss) private var dismiss
    let screen: ServerScreen
    @StateObject private var web = WebHolder()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Жабу") { dismiss() }
                Text(screen.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                Button { web.showKeyboard() } label: { Text("⌨︎ Пернетақта") }
                    .buttonStyle(.bordered)
                if let id = screen.askId {
                    Button { a.finishAsk(id); dismiss() } label: { Label("Орындадым", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0x10b981))
                }
            }
            .padding(10)
            Divider()
            WebView(url: screen.url, holder: web)
        }
        .background(Color.black)
    }
}

final class WebHolder: ObservableObject {
    weak var view: WKWebView?
    func showKeyboard() {
        view?.evaluateJavaScript("var b=document.getElementById('noVNC_keyboard_button'); if (b) { b.click(); }")
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    var holder: WebHolder? = nil

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 4
        view.load(URLRequest(url: url))
        holder?.view = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var a: Assistant
    @Environment(\.dismiss) private var dismiss
    var onboarding = false
    @State private var check = ""
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Сервер", text: $settings.server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Токен", text: $settings.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(checking ? "Тексеріп жатыр…" : "Байланысты тексеру") { Task { await test() } }
                        .disabled(checking)
                    if !check.isEmpty { Text(check).font(.footnote) }
                } header: { Text("Сервер") } footer: {
                    Text("Сервер тек Tailscale желісінде: iPhone-да Tailscale қосулы болсын. Токен тек осы телефонның Keychain-ында сақталады.")
                }

                Section {
                    Toggle("Үнемі тыңдау («Алихан» сөзін күту)", isOn: $settings.alwaysListen)
                    Toggle("Наушник микрофоны", isOn: $settings.headsetMic)
                    Toggle("Picture-in-Picture айдаһар", isOn: $settings.pip)
                    Toggle("Шу басу (Voice Processing, сынақ)", isOn: $settings.voiceProcessing)
                    VStack(alignment: .leading) {
                        Text("Сөз соңы: \(settings.endSilence, specifier: "%.1f") с үнсіздік")
                        Slider(value: $settings.endSilence, in: 0.5...1.5, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text("Дауыс шегі: шудан \(settings.nearRatio, specifier: "%.2f") есе қатты")
                        Slider(value: $settings.nearRatio, in: 1.2...3.0, step: 0.05)
                    }
                    LabeledContent("Соңғы сағатта /wake/confirm", value: "\(a.wakeSendsLastHour) рет")
                    if !a.lastWakeHeard.isEmpty {
                        LabeledContent("Сервер соңғы естігені", value: a.lastWakeHeard).font(.footnote)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Микрофон: \(Int(a.micLevelDB)) dB")
                            Spacer()
                            Text("сөз: \(Int(a.speechConfidence * 100))%")
                                .foregroundStyle(a.speechConfidence >= 0.5 ? Color.green : Color.secondary)
                        }
                        .font(.footnote.monospacedDigit())
                        // −70 dB … −10 dB шкаласы: ақырын сөйлегенде де жолақ қозғалса, сөз ұсталып жатыр
                        ProgressView(value: Double(min(max((a.micLevelDB + 70) / 60, 0), 1)))
                            .tint(a.speechConfidence >= 0.5 ? .green : .blue)
                        Text(a.audio.diagnostics).font(.caption2).foregroundStyle(.secondary)
                    }
                } header: { Text("Тыңдау") } footer: {
                    Text("Наушник микрофоны өшірулі болса, телефонның өз микрофоны тыңдайды, ал музыка наушникке жоғары сапада шығады. Қосулы болса, AirPods сөйлесу режиміне ауысады да, музыка сапасы төмендейді.")
                }

                Section {
                    Button("Сервер экранын ашу") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { a.openServerScreen() }
                    }
                } header: { Text("Сервер экраны") } footer: {
                    Text("Сайттарға не бағдарламаларға алдын ала кіріп қою үшін. Мәтін қою: экранның сол жағындағы панельде «Clipboard» өрісіне мәтінді салсаңыз, ол сервердің алмасу буферіне өтеді, сосын сол жерде қоясыз.")
                }

                Section("Рұқсаттар") {
                    Button("Микрофон, контактілер, еске салулар") { Task { await a.requestPermissions() } }
                    Button("iOS баптауын ашу") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                if onboarding {
                    Section {
                        Button("Сақтау және бастау") {
                            Task {
                                await a.requestPermissions()
                                settings.configured = true
                                a.afterSetup()
                                a.startTalk()
                            }
                        }
                        .disabled(settings.token.isEmpty || settings.baseURL == nil)
                    }
                }
            }
            .navigationTitle(onboarding ? "Алихан: баптау" : "Баптау")
            .toolbar {
                if !onboarding {
                    ToolbarItem(placement: .confirmationAction) { Button("Дайын") { dismiss() } }
                }
            }
            .onChange(of: settings.alwaysListen) { _, _ in a.settingsChanged() }
            .onChange(of: settings.pip) { _, _ in a.settingsChanged() }
            .onChange(of: settings.nearRatio) { _, _ in a.settingsChanged() }
            .onChange(of: settings.headsetMic) { _, _ in a.headsetChanged() }
            .onChange(of: settings.voiceProcessing) { _, _ in a.headsetChanged() }
            .onChange(of: settings.endSilence) { _, _ in a.settingsChanged() }
        }
    }

    private func test() async {
        checking = true
        defer { checking = false }
        do {
            _ = try await API.shared.notifications(ack: false, wait: 0)
            check = "✅ Сервер жауап берді, токен дұрыс"
        } catch {
            check = "❌ \(error.localizedDescription)"
        }
    }
}

/// Тапсырма үшін видео не фото: түсірілгенді серверге жүктейді.
struct CaptureView: UIViewControllerRepresentable {
    let video: Bool
    let finish: (URL?, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            DispatchQueue.main.async { finish(nil, "") }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (URL?, String) -> Void
        init(finish: @escaping (URL?, String) -> Void) { self.finish = finish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                finish(movie, "video/quicktime")
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
                try? data.write(to: url)
                finish(url, "image/jpeg")
            } else {
                finish(nil, "")
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil, "") }
    }
}
