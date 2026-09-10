import Foundation

/// De onde saiu a cota: quanto veio deste Mac e quanto veio da VPS.
///
/// Nenhum endpoint de cota devolve recorte por maquina — o numero e sempre da CONTA, e nao
/// e divisivel. O que da para fazer, e o que se faz aqui, e contar os tokens do rastro local
/// de cada CLI nos dois hosts e mostrar a PROPORCAO. Por isso a linha do card vem sempre com
/// a etiqueta de deduzido: ela responde "onde eu gastei", nao "quanto o provedor contou".
///
/// Vale para Claude, Codex e OpenCode, que sao os que deixam rastro contavel nas duas
/// maquinas. O Grok fica de fora porque nao ha rastro local contavel para repartir sua
/// cota semanal compartilhada. Provedor sem token nenhum no periodo tambem nao entra: 0 de 0 nao e "meio a
/// meio", e sim "nao ha o que repartir", e a linha some do card.
///
/// Quem vai a rede e o agendador `org.usageisland.host-split` (a cada 15 min, por ssh),
/// nao o app: uma ilha de barra de menus nao pode esperar rede para desenhar. Aqui so se le
/// um arquivo local, o que custa microssegundos e nunca bloqueia.
struct HostSplit: Equatable {
    let macPercent: Double
    let vpsPercent: Double
    let macTokens: Int
    let vpsTokens: Int
    let dias: Int
    /// Nome do provedor a que esta repartição pertence — a mesma chave do card.
    /// Quando a medida da vps e velha porque o ssh falhou na ultima rodada. O coletor
    /// preserva a ultima medida boa em vez de zerar; sem esta marca, um numero de ontem
    /// passaria por numero de agora.
    let vpsMedidoEm: Date?

    var resumo: String {
        "Mac \(Int(macPercent.rounded()))% · VPS \(Int(vpsPercent.rounded()))%"
    }

    /// Idade da medida da VPS, em horas, quando ela ja passou de uma hora.
    var vpsAtrasoHoras: Int? {
        guard let vpsMedidoEm else { return nil }
        let horas = Int(Date().timeIntervalSince(vpsMedidoEm) / 3600)
        return horas >= 1 ? horas : nil
    }
}

enum HostSplitReader {
    static var caminho: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/usage-island/reparticao.json")
    }

    /// Le o arquivo uma vez e devolve a repartição de cada provedor, na chave do card.
    static func read() -> [String: HostSplit] {
        guard let dados = try? Data(contentsOf: caminho),
              let raiz = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let provedores = raiz["provedores"] as? [String: Any]
        else { return [:] }

        let dias = (raiz["dias"] as? Int) ?? 7
        var medido: Date? = nil
        if let texto = raiz["vps_medido_em"] as? String {
            let formato = ISO8601DateFormatter()
            formato.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            medido = formato.date(from: texto) ?? ISO8601DateFormatter().date(from: texto)
        }

        var saida: [String: HostSplit] = [:]
        for (nome, valor) in provedores {
            guard let bloco = valor as? [String: Any],
                  let mac = bloco["fatia_mac"] as? Double,
                  let vps = bloco["fatia_vps"] as? Double
            else { continue }
            saida[nome] = HostSplit(
                macPercent: mac, vpsPercent: vps,
                macTokens: (bloco["mac_tokens"] as? Int) ?? 0,
                vpsTokens: (bloco["vps_tokens"] as? Int) ?? 0,
                dias: dias, vpsMedidoEm: medido)
        }
        return saida
    }
}
