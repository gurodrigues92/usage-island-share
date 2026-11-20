import Foundation
import Testing
@testable import UsageIsland

struct HostSplitReaderTests {
    @Test func leAliasDoColetorLegado() throws {
        let url = try fixture("""
            {
              "dias": 7,
              "netcup_medido_em": "2024-01-15T12:00:00.123456+00:00",
              "provedores": {
                "Codex": {
                  "mac_tokens": 756,
                  "netcup_tokens": 244,
                  "fatia_mac": 75.6,
                  "fatia_netcup": 24.4
                }
              }
            }
            """)
        let saida = HostSplitReader.read(from: url)
        let codex = try #require(saida["Codex"])
        #expect(codex.macPercent == 75.6)
        #expect(codex.vpsPercent == 24.4)
        #expect(codex.macTokens == 756)
        #expect(codex.vpsTokens == 244)
        #expect(codex.dias == 7)
        #expect(codex.vpsMedidoEm != nil)
        #expect(codex.resumo == "Mac 76% · VPS 24%")
    }

    @Test func leChavesVpsDoColetor() throws {
        let url = try fixture("""
            {
              "dias": 7,
              "vps_medido_em": "2024-01-15T12:00:00Z",
              "provedores": {
                "Claude": {
                  "mac_tokens": 10,
                  "vps_tokens": 90,
                  "fatia_mac": 10.0,
                  "fatia_vps": 90.0
                }
              }
            }
            """)
        let saida = HostSplitReader.read(from: url)
        let claude = try #require(saida["Claude"])
        #expect(claude.macPercent == 10)
        #expect(claude.vpsPercent == 90)
        #expect(claude.vpsTokens == 90)
        #expect(claude.vpsMedidoEm != nil)
    }

    @Test func arquivoAusenteDevolveVazio() {
        let url = URL(fileURLWithPath: "/tmp/usage-island-nao-existe-\(UUID().uuidString).json")
        #expect(HostSplitReader.read(from: url).isEmpty)
    }

    private func fixture(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-split-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }
}
