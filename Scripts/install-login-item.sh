#!/bin/zsh
# Faz o Usage Island subir junto com o login e voltar sozinho se ele cair.
#
# Por que LaunchAgent e nao Itens de Inicio do Ajustes: o painel do sistema so
# liga/desliga, enquanto o agente reinicia o app se ele morrer e da um lugar pra
# ler o erro. O app e LSUIElement, entao nao aparece no Dock nem rouba foco.
#
# Duas armadilhas de launchd ja medidas nesta maquina:
#   - o job NAO herda o PATH do shell, entao todo caminho aqui e absoluto;
#   - `launchctl load` TRAVA segurando o stdout do job — carregamos com
#     `bootstrap` e redirecionando as tres pontas.
set -euo pipefail

label=org.usageisland.agent
app="$HOME/Applications/Usage Island.app"
binary="$app/Contents/MacOS/UsageIsland"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/UsageIsland"

if [[ ! -x "$binary" ]]; then
  print -u2 "Nao achei o app instalado em $app — rode Scripts/package-app.sh primeiro."
  exit 1
fi

mkdir -p "$log_dir" "$HOME/Library/LaunchAgents"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary</string>
    </array>
    <!-- O launchd entrega so /usr/bin:/bin:/usr/sbin:/sbin. O app dispara o
         \`codex app-server\`, que precisa do PATH real pra achar as dependencias
         dele; sem isso o helper morre e a leitura do Codex volta vazia. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <!-- Volta sozinho se cair, mas respeita o Sair do menu: com SuccessfulExit
         false, uma saida limpa (codigo 0) nao e reiniciada. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <!-- Sem isso o launchd reinicia em rajada quando algo esta quebrado. -->
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$log_dir/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/stderr.log</string>
</dict>
</plist>
PLIST

domain="gui/$(id -u)"
launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist" </dev/null >/dev/null 2>&1
launchctl enable "$domain/$label"
launchctl kickstart -k "$domain/$label" </dev/null >/dev/null 2>&1

print "Instalado: $plist"
print "Logs:      $log_dir"
print "Parar:     launchctl bootout $domain/$label"
