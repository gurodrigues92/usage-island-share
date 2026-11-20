# Coletores de repartição por máquina

Coletores opcionais para comparar tokens entre um Mac e um servidor. Exigem Python 3, zsh no Mac e acesso SSH ao segundo host.

- `conta-uso`: lê registros locais das CLIs em modo de leitura e imprime contagens agregadas em JSON; aceita `--dias=7`.
- `reparticao-uso`: executa o contador no Mac e no host definido por `USAGE_ISLAND_REMOTE_HOST`, preserva a última leitura remota em caso de falha e grava `~/.cache/usage-island/reparticao.json`.
- `org.usageisland.host-split.plist`: exemplo de LaunchAgent com execução no login e a cada 900 segundos.

Para reproduzir a instalação:

1. Copie `conta-uso` e `reparticao-uso` para `~/.local/bin/` no Mac, mantendo a permissão de execução.
2. Instale `conta-uso` no `PATH` do host remoto, por exemplo em `/usr/local/bin/conta-uso`.
3. Configure seu próprio alias SSH. O acesso precisa funcionar com `BatchMode=yes`.
4. Execute `USAGE_ISLAND_REMOTE_HOST=your-server ~/.local/bin/reparticao-uso`, substituindo `your-server` pelo seu alias, e confira o arquivo de saída antes de ativar o agendamento.
5. No plist, substitua `your-server` pelo seu alias. Copie o plist para `~/Library/LaunchAgents/` e carregue-o com `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.usageisland.host-split.plist"`.

O contador usa os diretórios padrão das CLIs e conta tokens, não o consumo oficial de cota. Contas em diretórios alternativos não são agregadas automaticamente. Não há credenciais, registros de conversas nem cache de consumo neste diretório.

## Análise por projeto na VPS (opcional)

Instale `Sources/UsageIsland/Resources/usage-analytics.py` do mesmo pacote em `~/.local/share/usage-island/usage-analytics.py` no host configurado. O coletor de repartição consulta esse script em uma etapa independente e preserva a última captura quando houver falha. A saída fica em `~/.cache/usage-island/analytics-vps.json` no Mac. O script é somente leitura dos registros das CLIs e guarda seu próprio ledger privado; não lê credenciais ou envia prompts. O painel identifica a máquina, horário e coleta parcial.

A repartição do cartão usa a definição histórica do coletor de sete dias (sem tokens de leitura de cache); os relatórios de projetos incluem leitura de cache separadamente e agrupam dias em UTC. As duas medidas são identificadas na interface e não representam a fórmula oficial de cota do provedor.
