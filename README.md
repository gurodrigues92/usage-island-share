# Usage Island

Uma ilha lateral nativa para macOS: barra preta encaixada à direita, anéis de progresso e cartão de detalhe expansível.

## O que já existe

- Janela flutuante, sem bordas e sem ícone no Dock.
- Botão na barra de menus para mostrar, ocultar ou encerrar.
- Cartões de Claude, Codex, SuperGrok e OpenCode, com um anel por conta Claude detectada.
- Animação de expansão, anel de consumo, barras de sessão/semana e horários de reset.
- Ilha compacta quando ociosa, com expansão ao passar o mouse e fechamento automático do cartão.
- Atualização independente por provedor: Codex, SuperGrok e OpenCode a cada minuto; Claude com intervalo mínimo de 15 minutos e espera adicional quando limitado pelo serviço.
- Repartição opcional de tokens entre Mac e VPS para Claude, Codex e OpenCode, identificada como estimativa derivada dos registros locais.

O app não exibe porcentagens inventadas: enquanto uma fonte não estiver disponível, mostra `—` e explica o estado no cartão expandido.

## Fontes de dados

- **Codex:** lê `account/rateLimits/read` do app-server local e mostra a porcentagem e o reset da janela semanal automaticamente.
- **Claude:** consulta `GET https://api.anthropic.com/api/oauth/usage` com a credencial do Claude Code no Keychain. O anel mostra a janela semanal geral; o cartão inclui sessão e limites por modelo. Detecta contas autenticadas em `~/.claude` e `~/.claude-<perfil>`.
- **OpenCode Go:** consulta `GET https://opencode.ai/zen/go/v1/usage` com a chave já armazenada pela CLI. Mostra as janelas móvel, semanal e mensal; o anel usa a maior porcentagem entre semanal e mensal. Há entrada manual no menu como alternativa.
- **SuperGrok:** consulta a cada minuto `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, autenticado pela CLI local. Mostra `creditUsagePercent` da cota semanal compartilhada (inclui Grok Build no VPS) e `currentPeriod.end`, conferidos com Settings → Usage. Falhas, respostas sem percentual e períodos vencidos mostram `—`, nunca 0% inventado. A renovação da credencial continua a cargo de `grok models`.

A cota semanal do SuperGrok não depende de cookies ou do navegador aberto. O limite separado do chat web permanece opcional, desativado por padrão, e usa a sessão do Arc quando habilitado.

## Executar

O projeto exige macOS 14 ou posterior e Xcode completo ou Command Line Tools com Swift 6. As integrações usam as credenciais das CLIs já autenticadas nesta máquina; cada pessoa precisa configurar suas próprias contas.

```zsh
cd "UsageIsland"
swift run
```

Para montar um `.app` depois de compilar:

```zsh
./Scripts/package-app.sh
open "$HOME/Applications/Usage Island.app"
```

O script instala o app em `~/Applications` e usa assinatura ad hoc por padrão. Para assinar com seu próprio Developer ID, defina `USAGE_ISLAND_SIGN_IDENTITY` antes de executar o script. O acesso ao Keychain pode pedir autorização novamente após recompilar com assinatura ad hoc. Abra a cópia instalada para evitar restrições de acesso a pastas como Documentos e iCloud.

Para abrir o aplicativo com o cartão Claude expandido:
`ISLAND_PREVIEW=Claude open "$HOME/Applications/Usage Island.app"`.

Para validar o código:

```zsh
swift test
swift build -c release
```

## Repartição Mac × VPS (opcional)

Os coletores opcionais estão em [`Scripts/host-split`](Scripts/host-split). O app lê apenas `~/.cache/usage-island/reparticao.json`; o coletor externo faz a conexão SSH com o host configurado por você e pode atualizar o arquivo a cada 15 minutos. Sem esse arquivo, os cartões continuam mostrando as cotas dos provedores, sem a repartição por máquina.

O diretório inclui instruções para adaptar os caminhos e o alias SSH a outra instalação. A repartição estima a proporção de tokens nos últimos sete dias; ela não representa um recorte oficial da cota por máquina.

## Créditos

Consulte [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) para as atribuições e a licença dos componentes reaproveitados. Cada instalação usa suas próprias contas; credenciais e dados de consumo não são distribuídos com o código.
