import SafariServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var a: Assistant
    @EnvironmentObject var settings: Settings
    @State private var showSettings = false
    @State private var browser: BrowserLink?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0b0f16), Color(hex: 0x151b26)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Text(a.orb.label).font(.subheadline).foregroundStyle(a.orb.accent)
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.title2).foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityLabel("Баптау")
                }
                .padding(.horizontal, 20)

                Spacer()
                OrbView(state: a.orb)
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

                if let card = a.card {
                    TaskCardView(card: card, open: { browser = BrowserLink(url: $0) }, done: { a.taskDone() })
                        .padding(.horizontal, 16)
                }

                if settings.pip {
                    PiPHost().frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottom) { Text("PiP").font(.caption2).foregroundStyle(.white.opacity(0.5)) }
                }
            }
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings).environmentObject(a) }
        .fullScreenCover(isPresented: .constant(!settings.configured)) { SettingsView(onboarding: true).environmentObject(settings).environmentObject(a) }
        .sheet(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
        .fullScreenCover(item: $a.capture) { req in
            CaptureView(video: req.video) { file, mime in a.captureFinished(file: file, mime: mime, request: req) }
                .ignoresSafeArea()
                .onAppear { a.captureStarted() }
        }
    }
}

struct BrowserLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Сервердегі агент күтіп тұр: сұрақ, «Ашу» (кіру беті) және «Жасадым».
/// Логин мен парольді қолданушы сол бетте өзі енгізеді: қосымша оны көрмейді.
struct TaskCardView: View {
    let card: TaskCard
    let open: (URL) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Тапсырма сізді күтіп тұр", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(Color(hex: 0xfbbf24))
            Text(card.text).font(.callout).foregroundStyle(.white)
            HStack {
                ForEach(card.links, id: \.absoluteString) { link in
                    Button { open(link) } label: { Label("Ашу", systemImage: "safari") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(action: done) { Label("Жасадым", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0x10b981))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
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
                    VStack(alignment: .leading) {
                        Text("Дауыс шегі: шудан \(settings.nearRatio, specifier: "%.2f") есе қатты")
                        Slider(value: $settings.nearRatio, in: 1.2...3.0, step: 0.05)
                    }
                    LabeledContent("Соңғы сағатта /wake/confirm", value: "\(a.wakeSendsLastHour) рет")
                } header: { Text("Тыңдау") } footer: {
                    Text("Наушник микрофоны өшірулі болса, телефонның өз микрофоны тыңдайды, ал музыка наушникке жоғары сапада шығады. Қосулы болса, AirPods сөйлесу режиміне ауысады да, музыка сапасы төмендейді.")
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
