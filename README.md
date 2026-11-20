# Usage Island

Widget de macOS que mostra as cotas das suas IAs na borda da tela. Passe o mouse sobre um ícone para ver o consumo, a próxima renovação e as sessões daquele provedor.

## Baixar para Mac

[Baixar Usage Island 0.4.3 para macOS](https://github.com/gurodrigues92/usage-island-share/releases/download/v0.4.3/Usage-Island-0.4.3-macOS-universal-notarized.zip) · [Todas as versões](https://github.com/gurodrigues92/usage-island-share/releases)

Requer **macOS 14 ou posterior**, em Mac com Apple Silicon ou Intel. Descompacte o ZIP, arraste **Usage Island.app** para **Aplicativos** e abra o app. O ícone de três anéis aparece na barra de menus. A engrenagem da ilha abre as configurações.

A versão 0.4.3 é assinada com Developer ID e notarizada pela Apple. O download acima inclui o ticket para que o Gatekeeper possa verificar a notarização também offline. Para conferir a integridade do ZIP, baixe o [arquivo SHA-256](https://github.com/gurodrigues92/usage-island-share/releases/download/v0.4.3/Usage-Island-0.4.3-macOS-universal-notarized.zip.sha256) na mesma pasta e execute `shasum -a 256 -c Usage-Island-0.4.3-macOS-universal-notarized.zip.sha256`.

Cada integração usa a conta que você configurou no seu Mac. Em **Configurações → Barra**, escolha quais provedores mostrar. Em **Ajustar tamanho**, você pode configurar separadamente a barra em repouso e ao passar o mouse.

## Dock e movimentação

A alça em arco aberto, encaixada ao lado da curva inferior da barra, permite arrastar o Usage Island para cima ou para baixo. Ela acompanha a borda escolhida. A posição fica limitada à área útil da tela e é salva ao soltar; Escape cancela. As setas e ações de acessibilidade também ajustam a altura.

Em **Configurações → Aparência → Dock** é possível mostrar/ocultar a dock, manter sobre outros apps ou somente com as janelas do Usage Island, habilitar a alça e ocultar automaticamente. Em **Configurações → Ajustar tamanho**, os dois controles ajustam a dock expandida e em repouso de 50% a 150%, em passos de 1%. Arrastar o controle mostra o tamanho escolhido na própria dock. A faixa opcional na borda revela a barra ao aproximar o ponteiro e sinaliza sessões esperando o usuário, respeitando a redução de movimento. Tela, borda, altura, opacidade e tempos continuam configuráveis.

Os ícones continuam por IA. O cartão lista até três sessões, priorizando as que esperam por você, e permite abrir sua aplicação ou a lista completa no painel. Uma conclusão confirmada observada mostra um aviso local por oito segundos. Provedores configurados, habilitados e ocultos podem aparecer temporariamente com novidades (até sessenta segundos para conclusão, enquanto durar uma espera), sem alterar a escolha de visibilidade. Remoção, pausa, estado desconhecido, desaparecimento e atividade apenas estimada não fabricam conclusão. Não há novas chamadas a modelos, envios ou respostas automáticas; o aviso registra o estado da sessão, não valida a entrega do trabalho. Quando o leitor não fornece conteúdo de resposta, o cartão não inventa um resultado textual.

## O que já existe

- Janela flutuante, sem bordas e sem ícone no Dock.
- Botão na barra de menus para mostrar, ocultar ou encerrar.
- Cartões de Claude, Codex, SuperGrok e OpenCode, com um anel por conta Claude detectada.
- Animação de expansão, anel de consumo, barras de sessão/semana e horários de reset.
- Ilha compacta quando ociosa, com expansão ao passar o mouse e fechamento automático do cartão.
- Atualização independente por provedor: Codex a cada 30 segundos; SuperGrok e OpenCode a cada minuto; Claude com intervalo mínimo de 15 minutos e espera adicional quando limitado pelo serviço.
- Repartição opcional de tokens entre Mac e VPS para Claude, Codex e OpenCode, identificada como estimativa derivada dos registros locais.

O app não exibe porcentagens inventadas: enquanto uma fonte não estiver disponível, mostra `—` e explica o estado no cartão expandido.

## Configurações e painel

Abra **Configurações…** pelo ícone de três anéis na barra de menus ou pela engrenagem que aparece ao expandir a ilha. A janela vem para o espaço ativo e reabre mesmo se estiver minimizada. As preferências são aplicadas e salvas automaticamente.

- **Barra:** arraste os ícones ou use as setas para reordenar; mostrar/ocultar, pausar a consulta, renomear, trocar o símbolo e escolher a janela principal. Remover preserva login e histórico. Adicionar restaura provedores, permite outra pasta Codex autenticada, um indicador manual ou uma chave OpenRouter no Keychain.
- **Aparência:** velocidade da animação (0,25×–3×), espera para recolher a barra (0–15 s) e espera com cartão aberto (0–60 s), com restauração desses padrões. Também permite usado/restante como padrão geral, com escolha individual em **Barra → Porcentagem**, números sempre visíveis, contraste, economia de animações, tela, borda, posição, largura e opacidade. Atalho global opcional: Control + Option + U.
- **Alertas:** limiares personalizados, recuperação confirmada, previsão de bloqueio, eventos de sessões e horário silencioso. Notificações começam desativadas; o macOS solicita autorização ao ativá-las.
- **Dados:** retenção de cotas, exportação CSV/JSON e preços personalizados por modelo. Limpar histórico preserva uma cópia de recuperação.
- **Diagnóstico:** estado e tempo das consultas, próxima tentativa, coleta remota e incidentes do provedor. A exportação omite credenciais, nomes de contas, caminhos e conteúdo das conversas.

**Histórico e projetos…** abre o painel com disponibilidade atual, histórico de cotas, tokens por projeto/modelo/provedor/máquina e sessões. A previsão aparece somente depois de amostras recentes suficientes da mesma conta/janela; lacunas e novas concessões não são extrapoladas como consumo medido.

A análise local usa Python 3 existente no Mac e um coletor incremental incluído no pacote. Guarda apenas contadores e metadados, com deduplicação, separação de cache e leitura limitada por ciclo. Os períodos dos relatórios de tokens usam UTC para comparar máquinas. Preços padrão verificados em 14/10/2026 para Sonnet 4.5/4.6, Opus 4.6 e Haiku 4.5: [fonte oficial](https://platform.claude.com/docs/en/about-claude/pricing). Valores em US$ são equivalentes em API; modelos sem preço ficam marcados e podem receber preços explícitos nas configurações.

Integração opcional de sessões OpenCode: no painel **Sessões**, instale o monitor local para as próximas sessões. Ele usa os [eventos documentados de plugins](https://opencode.ai/docs/plugins/), sem aprovar ferramentas nem registrar argumentos ou prompts. Atividade do Codex/Grok é identificada como estimada quando não há evento conclusivo; o clique abre a aplicação quando houver um destino conhecido.

Cotas: `~/Library/Application Support/Usage Island/quota-history.json`. Contadores incrementais: `~/.cache/usage-island/analytics.sqlite3`. Nenhum histórico é enviado ao GitHub ou a outro serviço.

## Análise, assinaturas e conversas locais

O painel inclui **Recibo**, **Assinaturas** e **Conversas**, inspirados nas funções públicas do [MUR](https://mur.lendario.ai/). Implementação própria em Swift/AppKit; nenhuma dependência do aplicativo MUR.

Na aba **Agora**, barras e números seguem juntos a escolha de cota usada/restante de cada ícone, inclusive indicadores manuais. O rótulo e o tooltip identificam a direção. Histórico e alertas continuam baseados no consumo usado. Configurações antigas preservam o padrão global. Cada janela mostra sua própria previsão e a data e a hora locais da renovação quando o provedor informa esse instante; resets vencidos continuam aguardando confirmação. O histórico resolve a seleção de conta/janela uma vez por atualização para continuar responsivo com arquivos grandes. Seu gráfico não é recalculado quando a aba está inativa, e a seleção é preservada ao trocar de aba.

- **Recibo:** equivalente em API dos registros, pagamentos confirmados e custo proporcional das assinaturas aparecem separados. O proporcional usa os dias reais de cada ciclo mensal/anual. Moedas diferentes nunca são somadas ou convertidas automaticamente; valores e datas desconhecidos ficam a confirmar. Sem tarifa, o custo aparece como não apurado ou parcial. O múltiplo só aparece com preços de assinatura confirmados e moedas comparáveis.
- **Assinaturas:** contas ou grupos, quantidade, moeda, ciclos, períodos de preço, renovação prevista e pagamentos com data. Encerrar um período preserva os pagamentos. Desmarcar renovação apenas muda a previsão local; não cancela o contrato no provedor.
- **Projetos:** filtros compartilhados com Recibo por período UTC, provedor, modelo, máquina e busca. Detalhamento por modelo/provedor e exportação CSV do recorte. Chamadas não são apresentadas como número de conversas.
- **Outros Macs:** exportação de sete dias deste Mac e importação de pacotes JSON. Exige coleta local completa, sem avisos e feita há no máximo dez minutos; usa a data real da coleta. A identidade da máquina e a revisão de cada dia evitam dupla contagem; a coleta mais recente substitui a anterior. Pacotes não incluem mensagens e não reexportam dados importados ou da VPS. As coletas importadas cobrem somente os dias do pacote. Uma coleta parcial pode ser consultada ou exportada em CSV, mas não substitui dados completos em outro Mac.
- **Conversas:** leitura sob demanda de até 100 arquivos locais recentes do Claude Code e Codex; busca por título, projeto ou modelo. Conteúdo fica em memória e pode ser limpo. O replay mostra mensagens, ferramentas e resultados registrados com pausa, velocidade e posição. Resultados ausentes permanecem desconhecidos; reasoning/thinking não são exibidos. Padrões conhecidos de credenciais são ocultados antes de chegar à interface. O recorte é limitado a 16 MiB ou 600 eventos por sessão, com aviso de omissões ou truncamento. Limpar a memória invalida resultados pendentes; uma leitura já iniciada pode terminar em segundo plano até seu prazo de 35 segundos.
- **Tema:** Sistema, Claro ou Escuro em Aparência; a ilha lateral mantém seu fundo preto.

Assinaturas e pagamentos ficam em `~/Library/Application Support/Usage Island/subscriptions.json`; importações em `imported-usage.json`, no mesmo diretório. Arquivos privados, sem envio ao servidor. Não preenchemos planos, preços ou pagamentos automaticamente. Leitores de outros agentes, atualização automática assinada e versões para outros sistemas dependem de trabalho específico e não são anunciados como disponíveis.

## Fontes de dados

- **OpenRouter (opcional):** consulta somente `GET /api/v1/key` com uma chave configurada no Keychain; mostra orçamento de API separado das assinaturas. Sem teto informado, não inventa um percentual. [Documentação oficial](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key).
- **Codex:** lê `account/rateLimits/read` do app-server local e mostra a porcentagem e o reset da janela semanal automaticamente.
- **Claude:** consulta `GET https://api.anthropic.com/api/oauth/usage` com a credencial do Claude Code no Keychain. O anel mostra a janela semanal geral; o cartão inclui sessão e limites por modelo. Detecta contas autenticadas em `~/.claude` e `~/.claude-<perfil>`.
- **OpenCode Go:** consulta `GET https://opencode.ai/zen/go/v1/usage` com a chave já armazenada pela CLI. Mostra as janelas móvel, semanal e mensal; o anel usa a maior porcentagem entre semanal e mensal. Há entrada manual no menu como alternativa.

Se o OpenCode indicar **chave expirada**, crie uma nova chave no [console oficial](https://opencode.ai/auth) e substitua a chave em `/connect` → **OpenCode Go** na interface do OpenCode. Entrar de novo não renova uma chave expirada. O widget relê o arquivo da CLI na próxima consulta; **Diagnóstico → Atualizar** permite conferir na hora. Falhas de autenticação, rede, limite de consultas e formato da resposta são identificadas separadamente; a última leitura válida conserva sua data e aparece como antiga.

- **SuperGrok:** consulta a cada minuto `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, autenticado pela CLI local. Mostra `creditUsagePercent` da cota semanal compartilhada (inclui Grok Build no VPS) e `currentPeriod.end`, conferidos com Settings → Usage. A API da CLI pode retornar percentuais inteiros diferentes da tela do Grok Bot; a fonte fica identificada e nenhum valor é incrementado para forçar igualdade. Quando há casas decimais, a apresentação Grok arredonda ao inteiro mais próximo, preservando o valor coletado. Falhas, respostas sem percentual e períodos vencidos mostram `—`, nunca 0% inventado. A renovação da credencial continua a cargo de `grok models`.

A cota semanal do SuperGrok não depende de cookies ou do navegador aberto. O limite separado do chat web permanece opcional, desativado por padrão, e usa a sessão do Arc quando habilitado.

## Compilar a partir do código

O projeto exige macOS 14 ou posterior e Xcode completo ou Command Line Tools com Swift 6. As integrações usam as credenciais das CLIs já autenticadas nesta máquina; cada pessoa precisa configurar suas próprias contas.

```zsh
git clone https://github.com/gurodrigues92/usage-island-share.git
cd usage-island-share
swift run
```

Para montar um `.app` depois de compilar:

```zsh
./Scripts/package-app.sh
open "$HOME/Applications/Usage Island.app"
```

O script instala o app em `~/Applications`. Ele usa um certificado Developer ID Application disponível no Keychain ou, na ausência dele, uma assinatura ad hoc. Para escolher o certificado, defina `USAGE_ISLAND_SIGN_IDENTITY`. O acesso ao Keychain pode pedir autorização novamente após recompilar com assinatura ad hoc.

Para gerar um ZIP universal separado da instalação local, execute `./Scripts/package-app.sh --archive /tmp/Usage-Island.zip --universal`. Para notarizar os pacotes desse checkout, salve a credencial com `xcrun notarytool store-credentials` no Chaveiro e registre o nome do perfil com `git config --local usageisland.notaryProfile NOME_DO_PERFIL`. Também é possível escolher o perfil por execução com `USAGE_ISLAND_NOTARY_PROFILE`.

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
