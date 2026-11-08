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
                    Button { a.showTasks = true } label: {
                        Image(systemName: "checklist").font(.title2).foregroundStyle(.white.opacity(0.85))
                            .overlay(alignment: .topTrailing) {
                                let n = a.tasks.filter { !$0.done }.count
                                if n > 0 {
                                    Text("\(n)").font(.caption2.bold()).foregroundStyle(.white)
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

                if let next = a.tasks.last(where: { !$0.done }) {
                    Button { a.showTasks = true } label: {
                        HStack {
                            Image(systemName: "hand.raised.fill").foregroundStyle(Color(hex: 0xfbbf24))
                            Text(next.text).lineLimit(1).foregroundStyle(.white)
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
        .fullScreenCover(item: $a.capture) { req in
            CaptureView(video: req.video) { file, mime in a.captureFinished(file: file, mime: mime, request: req) }
                .ignoresSafeArea()
                .onAppear { a.captureStarted() }
        }
    }
}

/// «Тапсырмаларым»: сервердегі агент сізден күтетін істер.
/// Әрқайсысында «Орындадым»: басылса, серверге хабар кетеді.
struct TasksView: View {
    @EnvironmentObject var a: Assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let pending = a.tasks.filter { !$0.done }.reversed()
                let done = a.tasks.filter { $0.done }.reversed()
                Section {
                    if pending.isEmpty {
                        Text("Қазір сізден күтетін ештеңе жоқ").foregroundStyle(.secondary)
                    }
                    ForEach(Array(pending)) { task in
                        TaskRow(task: task)
                    }
                } header: { Text("Сізден күтеді") }

                if !done.isEmpty {
                    Section("Орындалды") {
                        ForEach(Array(done)) { task in
                            Label(task.text, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary).lineLimit(2)
                                .swipeActions { Button("Өшіру", role: .destructive) { a.removeTask(task) } }
                        }
                    }
                }
            }
            .navigationTitle("Тапсырмаларым")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Жабу") { dismiss() } } }
            .fullScreenCover(item: $a.webTask) { task in LoginView(task: task).environmentObject(a) }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var a: Assistant
    let task: UserTask

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.text).font(.callout)
            Text(task.created, style: .relative).font(.caption).foregroundStyle(.secondary)
            HStack {
                if !task.links.isEmpty {
                    Button { a.webTask = task } label: { Label("Ашу", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button { a.taskDone(task) } label: { Label("Орындадым", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0x10b981))
            }
        }
        .padding(.vertical, 6)
    }
}

/// Қосымша ішіндегі кіру беті. Логин мен парольді сіз осы бетте өзіңіз енгізесіз:
/// Алихан бет ішіне ештеңе жазбайды, ештеңе оқымайды, серверге жібермейді.
struct LoginView: View {
    @EnvironmentObject var a: Assistant
    @Environment(\.dismiss) private var dismiss
    let task: UserTask

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(task.text).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
                if let url = task.links.first { WebView(url: url) }
                Divider()
                Button { a.taskDone(task); dismiss() } label: {
                    Label("Орындадым", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Color(hex: 0x10b981)).padding(12)
            }
            .navigationTitle(task.links.first?.host ?? "Кіру")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Жабу") { dismiss() } }
                if let url = task.links.first {
                    ToolbarItem(placement: .primaryAction) {
                        Button { UIApplication.shared.open(url) } label: { Image(systemName: "safari") }
                            .accessibilityLabel("Safari-де ашу")
                    }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // Кіргеннен кейін cookie сақталады
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
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
