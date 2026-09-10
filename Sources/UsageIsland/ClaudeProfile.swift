import CryptoKit
import Foundation

/// Uma pasta de configuracao do Claude Code, e portanto uma conta.
///
/// O Claude Code guarda tudo de uma conta debaixo de uma pasta so: `~/.claude` por padrao,
/// ou onde o `CLAUDE_CONFIG_DIR` apontar. Quem separa a conta de trabalho da pessoal faz
/// isso apelidando a segunda para `~/.claude-trabalho` — cada uma com o proprio token no
/// keychain e a propria pasta `sessions`. Lendo so `~/.claude` a ilha via uma conta e era
/// cega para as outras.
///
/// Ideia e regra do sufixo copiadas do codenotch (MIT, github.com/vinzdg/codenotch —
/// `ClaudeProfile`). A descoberta exige um item no Keychain correspondente à pasta,
/// evitando identificar pastas de ferramentas auxiliares como contas autenticadas.
/// A consulta de atributos não solicita o conteúdo da credencial.
struct ClaudeProfile: Equatable, Hashable {
    /// Nil para `~/.claude`; a parte depois de `.claude-` nas outras.
    let slug: String?

    static let directoryPrefix = ".claude"
    static let defaultKeychainService = "Claude Code-credentials"

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static let padrao = ClaudeProfile(slug: nil)

    /// O id do anel desta conta — igual ao `UsageSnapshot.id`, para os dois se acharem.
    static func ringID(slug: String?) -> String {
        slug.map { "\(UsageSource.claude.rawValue)-\($0)" } ?? UsageSource.claude.rawValue
    }

    var configDirectory: URL {
        Self.homeDirectory.appendingPathComponent(slug.map { "\(Self.directoryPrefix)-\($0)" }
                                                  ?? Self.directoryPrefix)
    }

    var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions") }

    /// O `service` sob o qual o token dessa pasta e arquivado.
    ///
    /// A pasta padrao usa o nome puro. Qualquer outro `CLAUDE_CONFIG_DIR` ganha um sufixo:
    /// os oito primeiros digitos hex do SHA-256 do caminho absoluto, sem barra no fim. A
    /// regra e do Claude Code, nao nossa — e o que torna `Claude Code-credentials-<hash>`
    /// localizavel.
    var keychainService: String {
        guard slug != nil else { return Self.defaultKeychainService }
        return "\(Self.defaultKeychainService)-\(Self.keychainSuffix(forPath: configDirectory.path))"
    }

    static func keychainSuffix(forPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
            .description
    }

    /// A pasta padrao primeiro, depois cada `~/.claude-<slug>` que tenha token no keychain,
    /// em ordem alfabetica — para os aneis nunca trocarem de lugar entre um lancamento e
    /// outro.
    static func discover() -> [ClaudeProfile] {
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: homeDirectory.path)) ?? []
        let extras = nomes
            .compactMap { nome -> ClaudeProfile? in
                let prefixo = directoryPrefix + "-"
                guard nome.hasPrefix(prefixo) else { return nil }
                let slug = String(nome.dropFirst(prefixo.count))
                guard !slug.isEmpty else { return nil }
                var isDir: ObjCBool = false
                let perfil = ClaudeProfile(slug: slug)
                guard FileManager.default.fileExists(atPath: perfil.configDirectory.path, isDirectory: &isDir),
                      isDir.boolValue,
                      ClaudeOAuthReader.newestItem(service: perfil.keychainService) != nil
                else { return nil }
                return perfil
            }
            .sorted { $0.slug! < $1.slug! }
        return [padrao] + extras
    }
}
