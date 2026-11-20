import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsTab { case bar, appearance, alerts, data, diagnostics }

struct SettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: UsageSettings
    @State private var selectedTab: SettingsTab = .bar
    @State private var adding = false
    @State private var message: String?
    init(model: IslandModel) { self.model = model; settings = model.settings }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBarIcon.make()).resizable().scaledToFit().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage Island").font(.title2.bold())
                    Text("Personalize sua barra e acompanhe o consumo").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abrir painel") { model.onDashboard?() }
            }.padding(20)
            TabView(selection: $selectedTab) {
                barTab.tabItem { Label("Barra", systemImage: "slider.horizontal.3") }.tag(SettingsTab.bar)
                AppearanceSettings(model: model, settings: settings)
                    .tabItem { Label("Aparência", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
                AlertSettings(model: model, settings: settings)
                    .tabItem { Label("Alertas", systemImage: "bell") }.tag(SettingsTab.alerts)
                HistorySettings(model: model, settings: settings)
                    .tabItem { Label("Dados", systemImage: "chart.xyaxis.line") }.tag(SettingsTab.data)
                DiagnosticSettings(model: model)
                    .tabItem { Label("Diagnóstico", systemImage: "stethoscope") }.tag(SettingsTab.diagnostics)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            if let message = message ?? settings.issue { Text(message).font(.caption).foregroundStyle(.orange).padding(8) }
            Divider()
            HStack {
                Text("As alterações são aplicadas e salvas automaticamente.").font(.caption).foregroundStyle(.secondary)
                Spacer(); Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2")).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 610, idealHeight: 700)
        .sheet(isPresented: $adding) { AddRingView(model: model, settings: settings) }
    }

    private var barTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ícones da barra").font(.headline)
                Spacer()
                Button("Ajustar tamanho") { selectedTab = .appearance }
                Button("Buscar contas") { model.discoverAccounts() }
                Button { adding = true } label: { Label("Adicionar ícone", systemImage: "plus") }
            }
            Text("Arraste para reordenar ou use as setas. Ocultar mantém a leitura; pausar interrompe a consulta.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(settings.value.rings) { entry in
                        RingSettingsRow(entry: entry, model: model, settings: settings)
                            .onDrag { NSItemProvider(object: entry.id as NSString) }
                            .onDrop(of: [UTType.text], delegate: RingDrop(destination: entry.id, settings: settings))
                    }
                    if settings.value.rings.isEmpty {
                        ContentUnavailableView("Sua barra está vazia", systemImage: "circle.grid.2x2",
                                               description: Text("Use Adicionar ícone para escolher as IAs que quer acompanhar."))
                    }
                }.padding(2)
            }
            Text("Remover um ícone preserva o login e o histórico. Você pode adicioná-lo novamente.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

private struct RingDrop: DropDelegate {
    let destination: String
    let settings: UsageSettings
    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [UTType.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in settings.move(id, before: destination) }
        }
        return true
    }
}

private struct RingSymbolOption: Identifiable {
    let id: String
    let title: String
    static let all: [Self] = [
        .init(id: "sparkles", title: "Brilho"),
        .init(id: "brain", title: "Cérebro"),
        .init(id: "bolt.fill", title: "Raio"),
        .init(id: "terminal.fill", title: "Terminal"),
        .init(id: "cpu", title: "Processador"),
        .init(id: "cloud", title: "Nuvem"),
        .init(id: "server.rack", title: "Servidor"),
        .init(id: "star.fill", title: "Estrela"),
        .init(id: "circle.fill", title: "Círculo"),
        .init(id: "circle.grid.3x3.fill", title: "Pontos"),
        .init(id: "chart.bar.fill", title: "Gráfico"),
        .init(id: "flame", title: "Chama"),
        .init(id: "leaf", title: "Folha"),
        .init(id: "gearshape", title: "Engrenagem"),
        .init(id: "person.crop.circle", title: "Pessoa")
    ]
}

struct RingSettingsRow: View {
    let entry: RingPreference
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: UsageSettings
    private func binding<T>(_ path: WritableKeyPath<RingPreference, T>) -> Binding<T> {
        Binding(get: { settings.value.rings.first { $0.id == entry.id }?[keyPath: path] ?? entry[keyPath: path] },
                set: { value in settings.editRing(entry.id) { $0[keyPath: path] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Arraste para reordenar")
                ProviderMark(source: entry.source, customSymbol: entry.symbol.isEmpty ? nil : entry.symbol)
                    .frame(width: 24, height: 24).frame(width: 32)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(entry.symbol.isEmpty ? "Logo de \(entry.source.displayName)" : "Símbolo personalizado de \(entry.displayName)")
                VStack(alignment: .leading, spacing: 3) {
                    TextField(entry.displayName, text: binding(\.name), prompt: Text(entry.displayName).foregroundStyle(.secondary))
                        .foregroundStyle(.primary).textFieldStyle(.roundedBorder)
                    Text(model.allSnapshots.first { $0.id == entry.id }?.statusText() ?? "Aguardando leitura")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity)
                Toggle("Mostrar", isOn: binding(\.visible)).toggleStyle(.checkbox).help("Mostrar este ícone na barra")
                Toggle("Ler", isOn: binding(\.enabled)).toggleStyle(.checkbox).disabled(entry.source == .custom).help("Ativar consultas deste provedor")
                Button { settings.move(entry.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Mover \(entry.displayName) para cima")
                Button { settings.move(entry.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Mover \(entry.displayName) para baixo")
                Button { settings.remove(entry.id) } label: { Image(systemName: "trash") }.help("Remover \(entry.displayName) da barra")
            }
            HStack {
                Menu {
                    Button { settings.editRing(entry.id) { $0.symbol = "" } } label: {
                        Label {
                            Text(entry.source == .custom ? "Ícone padrão" : "Logo de \(entry.source.displayName)")
                        } icon: {
                            if let logo = ProviderMark.menuImage(for: entry.source) {
                                Image(nsImage: logo)
                            } else {
                                Image(systemName: entry.source.symbol)
                            }
                        }
                    }
                    Divider()
                    ForEach(RingSymbolOption.all) { option in
                        Button { settings.editRing(entry.id) { $0.symbol = option.id } } label: { Label(option.title, systemImage: option.id) }
                    }
                } label: { Label("Trocar ícone", systemImage: "square.grid.2x2") }
                if let snapshot = model.allSnapshots.first(where: { $0.id == entry.id }), !snapshot.windows.isEmpty {
                    Picker("Anel", selection: binding(\.preferredWindow)) {
                        Text("Janela padrão").tag(Optional<String>.none)
                        ForEach(snapshot.windows) { window in Text(window.title).tag(Optional(window.id)) }
                    }.frame(maxWidth: 270)
                }
                if entry.source == .custom {
                    TextField("Uso %", value: binding(\.manualPercent), format: .number).frame(width: 80)
                        .onSubmit { settings.editRing(entry.id) { $0.manualUpdatedAt = .now } }
                    Text("Digite 0–100 e pressione Return").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.source != .custom { Button("Atualizar") { model.refreshOne(entry.id) }.disabled(!entry.enabled || model.health[entry.id]?.inFlight == true) }
            }.font(.callout)
            Picker("Porcentagem", selection: binding(\.remainingOverride)) {
                Text("Padrão geral").tag(Optional<Bool>.none)
                Text("Cota usada").tag(Optional(false))
                Text("Cota restante").tag(Optional(true))
            }
            .frame(maxWidth: 310)
            .help("Escolha usado ou restante somente para \(entry.displayName).")
        }
        .padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AddRingView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: UsageSettings
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var name = ""
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adicionar ícone").font(.title2.bold())
            Text("Escolha uma fonte disponível ou crie um indicador manual.").foregroundStyle(.secondary)
            ForEach(model.availableRings) { entry in
                Button { settings.add(entry); model.refreshOne(entry.id); dismiss() } label: {
                    Label { Text(entry.displayName) } icon: {
                        ProviderMark(source: entry.source, customSymbol: entry.symbol.isEmpty ? nil : entry.symbol).frame(width: 18, height: 18)
                    }
                }
            }
            Divider()
            Button("Adicionar outra conta Codex…") {
                let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
                picker.message = "Selecione uma pasta CODEX_HOME já autenticada, com auth.json próprio."
                if picker.runModal() == .OK, let url = picker.url {
                    if model.addCodexFolder(url) { dismiss() } else { issue = "Escolha uma conta distinta com auth.json. Contas já listadas não são duplicadas." }
                }
            }
            TextField("Nome do novo ícone", text: $name).textFieldStyle(.roundedBorder)
            Button("Criar indicador manual") {
                settings.add(.init(id: "manual-" + UUID().uuidString, source: .custom, name: name.isEmpty ? "Minha IA" : name))
                dismiss()
            }
            Divider()
            Text("OpenRouter").font(.headline)
            SecureField("Chave de API (armazenada no Keychain)", text: $key).textFieldStyle(.roundedBorder)
            Text("Consulta somente o orçamento desta chave. Nenhum prompt é enviado.").font(.caption).foregroundStyle(.secondary)
            Button("Adicionar OpenRouter") {
                let id = "OpenRouter-" + UUID().uuidString
                do {
                    try IslandSecrets.save(key, account: id)
                    settings.add(.init(id: id, source: .openrouter, name: name.isEmpty ? "OpenRouter" : name))
                    key = ""; model.refreshOne(id); dismiss()
                } catch { issue = "Não foi possível guardar a chave no Keychain." }
            }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 460)
    }
}

@MainActor private func settingsBinding<T>(_ settings: UsageSettings, _ path: WritableKeyPath<UsagePreferences, T>) -> Binding<T> {
    Binding(get: { settings.value[keyPath: path] }, set: { value in settings.edit { $0[keyPath: path] = value } })
}

struct AppearanceSettings: View {
    let model: IslandModel
    @ObservedObject var settings: UsageSettings
    @State private var presetPreview: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Tamanho da dock") {
                sizeSlider("Ao passar o mouse", mode: .hover, path: \.dock.hoverScale)
                HStack {
                    Text("Ajuste rápido do hover")
                    Spacer()
                    ForEach([70, 80, 100], id: \.self) { percent in
                        Button("\(percent)%") {
                            settings.edit { $0.dock.hoverScale = Double(percent) / 100 }
                            previewPreset()
                        }
                        .accessibilityLabel("Aplicar \(percent)% ao passar o mouse")
                    }
                }.controlSize(.small)
                sizeSlider("Em repouso", mode: .compact, path: \.dock.scale)
            }
            Section("Tema das janelas") {
                Picker("Aparência", selection: settingsBinding(settings, \.theme)) { ForEach(IslandTheme.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Section("Dock") {
                Toggle("Mostrar a dock", isOn: settingsBinding(settings, \.dock.enabled))
                Picker("Posição da dock", selection: settingsBinding(settings, \.dock.presentation)) {
                    ForEach(DockPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Mostrar alça de arraste", isOn: settingsBinding(settings, \.dock.dragHandle))
                Toggle("Ocultar quando não estiver em uso", isOn: settingsBinding(settings, \.dock.autoHide))
                if settings.value.dock.autoHide {
                    Toggle("Mostrar uma faixa na borda", isOn: settingsBinding(settings, \.dock.edgeHint))
                    Text("Aproxime o ponteiro da borda para mostrar a dock. A faixa destaca sessões que precisam de você.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Mostrar avisos de sessões concluídas", isOn: settingsBinding(settings, \.dock.showCompleted))
                Toggle("Mostrar IAs ocultas com novidades", isOn: settingsBinding(settings, \.dock.showNewActivity))
                Text("Avisos usam o estado disponível de cada sessão. Abrir a aplicação não envia mensagens nem responde ao agente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Animação e recolhimento") {
                MotionSlider(title: "Velocidade da animação", value: settingsBinding(settings, \.animationSpeed), range: 0.25...3, step: 0.05, suffix: "×")
                Text("Quanto maior a velocidade, mais rápido a barra aumenta e diminui.").font(.caption).foregroundStyle(.secondary)
                MotionSlider(title: "Espera para recolher", value: settingsBinding(settings, \.collapseDelay), range: 0...15, step: 0.05, suffix: " s")
                MotionSlider(title: "Com cartão aberto", value: settingsBinding(settings, \.cardCollapseDelay), range: 0...60, step: 0.5, suffix: " s")
                Text("A espera começa ao tirar o mouse da barra ou do cartão. Voltar com o mouse cancela o recolhimento.").font(.caption).foregroundStyle(.secondary)
                Button("Restaurar estes padrões") {
                    settings.edit { $0.animationSpeed = 1; $0.collapseDelay = 0.65; $0.cardCollapseDelay = 15 }
                }
            }
            Section("Leitura") {
                Toggle("Mostrar porcentagem restante", isOn: settingsBinding(settings, \.remaining))
                Text("Padrão para os ícones. Em Barra, você pode escolher usado ou restante por provedor.").font(.caption).foregroundStyle(.secondary)
                Toggle("Manter os números visíveis", isOn: settingsBinding(settings, \.alwaysShowNumbers))
                Toggle("Alto contraste", isOn: settingsBinding(settings, \.highContrast))
                Toggle("Economizar animações", isOn: settingsBinding(settings, \.lowPower))
                Toggle("Atalho global Control + Option + U", isOn: settingsBinding(settings, \.shortcutEnabled))
                Text("O modo de baixo consumo do macOS também reduz as animações.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Posição e opacidade") {
                Picker("Borda", selection: settingsBinding(settings, \.edge)) { Text("Direita").tag(IslandEdge.right); Text("Esquerda").tag(IslandEdge.left) }
                Picker("Tela", selection: settingsBinding(settings, \.screenID)) {
                    Text("Tela ativa").tag(Optional<String>.none)
                    ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(IslandScreen.id(screen)) }
                }
                HStack { Text("Altura na tela"); Slider(value: settingsBinding(settings, \.verticalPosition), in: 0...1); Text("\(Int(settings.value.verticalPosition * 100))%").monospacedDigit().frame(width: 45) }
                Text("Você também pode arrastar a alça abaixo da barra para cima ou para baixo. A posição é salva ao soltar.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Text("Opacidade em repouso"); Slider(value: settingsBinding(settings, \.compactOpacity), in: 0.25...1); Text("\(Int(settings.value.compactOpacity * 100))%").monospacedDigit().frame(width: 45) }
                Text("Se a tela escolhida for desconectada, a ilha usa uma tela disponível.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { endPreview() }
    }

    private func sizeSlider(_ title: String, mode: DockSizeMode,
                            path: WritableKeyPath<UsagePreferences, Double>) -> some View {
        let percent = Binding<Double>(
            get: { (settings.value[keyPath: path] * 100).rounded() },
            set: { newValue in settings.edit { $0[keyPath: path] = newValue.rounded() / 100 } })
        return HStack(spacing: 12) {
            Text(title).frame(width: 148, alignment: .leading)
            Slider(value: percent, in: 50...150, step: 1, onEditingChanged: { editing in
                if editing {
                    presetPreview?.cancel()
                    model.previewDockSize = mode
                } else {
                    endPreview()
                }
            })
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(percent.wrappedValue))%")
            Text("\(Int(percent.wrappedValue))%")
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func previewPreset() {
        presetPreview?.cancel()
        model.previewDockSize = .hover
        presetPreview = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            model.previewDockSize = nil
        }
    }

    private func endPreview() {
        presetPreview?.cancel()
        model.previewDockSize = nil
    }
}

private struct MotionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack {
            Text(title).frame(width: 172, alignment: .leading)
            Slider(value: $value, in: range, step: step).accessibilityLabel(title)
            Text(value.formatted(.number.precision(.fractionLength(0...2))) + suffix)
                .monospacedDigit().frame(width: 68, alignment: .trailing)
        }
    }
}

struct AlertSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: UsageSettings
    @State private var thresholds = ""
    @State private var issue: String?
    var body: some View {
        Form {
            Section("Avisos no Mac") {
                Toggle("Ativar notificações", isOn: Binding(get: { settings.value.notifications }, set: { enabled in
                    if !enabled { settings.edit { $0.notifications = false }; return }
                    Task { let allowed = await model.notifications.authorize(); settings.edit { $0.notifications = allowed }; issue = model.notifications.issue }
                }))
                HStack {
                    Text("Avisar quando o uso atingir")
                    TextField("80, 90, 100", text: $thresholds).frame(width: 130)
                    Button("Aplicar") {
                        let parts = thresholds.split(separator: ",", omittingEmptySubsequences: false)
                        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        guard values.count == parts.count, !values.isEmpty, values.allSatisfy({ (1...100).contains($0) }) else { issue = "Use porcentagens entre 1 e 100, separadas por vírgula."; return }
                        settings.edit { $0.thresholds = values }; issue = nil
                    }
                }
                Toggle("Avisar quando a leitura confirmar que a cota voltou", isOn: settingsBinding(settings, \.notifyRecovery))
                Toggle("Avisar quando a previsão indicar bloqueio antes do reset", isOn: settingsBinding(settings, \.notifyForecast))
                Toggle("Avisar quando uma sessão terminar ou precisar de mim", isOn: settingsBinding(settings, \.notifySessions))
                Text("Avisos de cota usam leituras recentes do provedor. Valores manuais e falhas não geram alerta. Cada conta e janela têm seu próprio ciclo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Horário silencioso") {
                Toggle("Silenciar durante este período", isOn: settingsBinding(settings, \.quietHours))
                HStack {
                    Picker("Das", selection: settingsBinding(settings, \.quietFrom)) { ForEach(0..<24) { Text("\($0)h").tag($0) } }
                    Picker("Até", selection: settingsBinding(settings, \.quietUntil)) { ForEach(0..<24) { Text("\($0)h").tag($0) } }
                }
            }
            if let issue { Text(issue).foregroundStyle(.orange).font(.caption) }
        }.formStyle(.grouped).onAppear { thresholds = settings.value.thresholds.map(String.init).joined(separator: ", ") }
    }
}

struct HistorySettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: UsageSettings
    @State private var clearing = false
    @State private var message: String?
    @State private var modelName = ""
    @State private var input = 0.0
    @State private var output = 0.0
    @State private var read = 0.0
    @State private var write = 0.0
    var body: some View {
        Form {
            Section("Histórico de cotas") {
                Picker("Guardar leituras por", selection: settingsBinding(settings, \.retentionDays)) { ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) dias").tag($0) } }
                Toggle("Mostrar previsão quando houver dados suficientes", isOn: settingsBinding(settings, \.forecast))
                HStack {
                    Button("Exportar CSV…") { save(Data(model.history.exportCSV().utf8), name: "usage-island-cotas.csv", type: .commaSeparatedText) }
                    Button("Exportar JSON…") { if let data = try? model.history.exportJSON() { save(data, name: "usage-island-cotas.json", type: .json) } }
                    Button("Limpar histórico…", role: .destructive) { clearing = true }
                }
                Text("Só números, datas e identificação das janelas. A limpeza guarda uma cópia de recuperação.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Preços personalizados — US$ por milhão de tokens") {
                Text("O custo exibido é um equivalente em API. Modelos sem preço ficam identificados como não precificados.").font(.caption).foregroundStyle(.secondary)
                ForEach(settings.value.prices) { price in
                    HStack {
                        Text(price.model).lineLimit(1); Spacer()
                        Text("Entrada \(price.input, specifier: "%.2f") · Saída \(price.output, specifier: "%.2f")").font(.caption).monospacedDigit()
                        Button { settings.edit { $0.prices.removeAll { $0.model == price.model } } } label: { Image(systemName: "trash") }
                    }
                }
                TextField("Nome exato do modelo", text: $modelName)
                HStack {
                    priceField("Entrada", $input); priceField("Saída", $output)
                    priceField("Cache lido", $read); priceField("Cache criado (5 min)", $write)
                }
                Button("Salvar preço") {
                    let price = ModelPrice(model: modelName.trimmingCharacters(in: .whitespaces), input: input, output: output, cacheRead: read, cacheWrite: write)
                    guard price.valid else { message = "Informe um nome e preços válidos."; return }
                    settings.edit { $0.prices.removeAll { $0.model == price.model }; $0.prices.append(price) }; modelName = ""; message = nil
                }
                Text("Cache Claude de 1h usa 1,6× o preço de criação de 5 min. Modificadores como batch e residência regional não são inferidos dos registros.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.orange).font(.caption) }
        }.formStyle(.grouped)
            .alert("Limpar histórico de cotas?", isPresented: $clearing) {
                Button("Cancelar", role: .cancel) {}
                Button("Limpar", role: .destructive) { Task { do { try await model.history.clear() } catch { message = "Não foi possível limpar o histórico." } } }
            } message: { Text("Uma cópia de recuperação será guardada antes da limpeza. O consumo atual e os logins são preservados.") }
    }
    private func priceField(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) { Text(label).font(.caption); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
    private func save(_ data: Data, name: String, type: UTType) {
        do { try IslandExport.save(data, name: name, type: type) } catch { message = "Não foi possível salvar a exportação." }
    }
}

struct DiagnosticSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var services: ServiceStatus
    @State private var message: String?
    init(model: IslandModel) { self.model = model; services = model.services }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Estado das integrações").font(.headline); Spacer()
                    Button("Atualizar todas") { model.refreshNow() }
                    Button("Exportar diagnóstico…") {
                        do { try IslandExport.save(model.diagnosticData(), name: "usage-island-diagnostico.json", type: .json) }
                        catch { message = "Não foi possível exportar o diagnóstico." }
                    }
                }
                Text("A exportação contém estados e tempos de consulta. Nomes de contas, caminhos, credenciais e conversas ficam fora dela.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.allSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(snapshot.displayName).bold(); Spacer(); Button("Atualizar") { model.refreshOne(snapshot.id) }.disabled(snapshot.paused || model.health[snapshot.id]?.inFlight == true) }
                        Text(snapshot.statusText()).foregroundStyle(snapshot.syncState == .failed ? .orange : .secondary)
                        if snapshot.openCodeFailure?.needsConnection == true { OpenCodeConnectionHelp() }
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(snapshot.lastReadText + nextText(snapshot.id, now: context.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let duration = model.health[snapshot.id]?.duration { Text("Última consulta: \(duration, specifier: "%.1f") s").font(.caption).foregroundStyle(.secondary) }
                        if let split = snapshot.hostSplit {
                            Text(split.resumo + (split.warning.map { " · " + $0 } ?? "")).font(.caption)
                            if let date = split.vpsMedidoEm { Text("VPS medida em " + date.formatted()).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let status = services.values[snapshot.source] { Text(status.summary + " · " + status.capturedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(status.incident ? .orange : .secondary) }
                    }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(16)
        }
    }
    private func nextText(_ id: String, now: Date) -> String {
        guard let next = model.health[id]?.nextAttempt else { return "" }
        let seconds = max(0, Int(next.timeIntervalSince(now)))
        return seconds > 0 ? " · próxima tentativa em \(seconds / 60)min \(seconds % 60)s" : " · aguardando próxima consulta"
    }
}

enum IslandExport {
    @MainActor static func save(_ data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
