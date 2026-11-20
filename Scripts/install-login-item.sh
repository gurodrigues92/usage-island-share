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

app="$HOME/Applications/Usage Island.app"
binary="$app/Contents/MacOS/UsageIsland"
label=org.usageisland.agent
matched_labels=()
matched_plists=()
# Reuse an existing agent only when it targets this exact installed executable.
for candidate_plist in "$HOME/Library/LaunchAgents/"*.plist(N); do
  if [[ -f "$candidate_plist" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$candidate_plist" 2>/dev/null)" == "$binary" ]]; then
    candidate="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$candidate_plist")"
    matched_labels+=("$candidate")
    matched_plists+=("$candidate_plist")
  fi
done
if (( ${#matched_labels} )); then
  label="${matched_labels[1]}"
fi
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/UsageIsland"

if [[ ! -x "$binary" ]]; then
  print -u2 "Nao achei o app instalado em $app — rode Scripts/package-app.sh primeiro."
  exit 1
fi

mkdir -p "$log_dir" "$HOME/Library/LaunchAgents"
if [[ -f "$plist" ]]; then
  backup_dir="${USAGE_ISLAND_BACKUP_DIR:-$HOME/.local/share/usage-island-backups}"
  mkdir -p "$backup_dir"
  cp "$plist" "$backup_dir/$label-$(date +%Y%m%d-%H%M%S)-$$.plist"
fi

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
for ((index = 1; index <= ${#matched_labels}; index++)); do
  candidate="${matched_labels[index]}"
  candidate_plist="${matched_plists[index]}"
  launchctl bootout "$domain/$candidate" 2>/dev/null || true
  if [[ "$candidate" != "$label" ]]; then
    mv "$candidate_plist" "$candidate_plist.disabled-$(date +%Y%m%d-%H%M%S)"
  fi
done
launchctl enable "$domain/$label"
# bootout can return before launchd finishes tearing down the old job.
# Retry the registration briefly and keep the final error visible.
bootstrap_error="$(mktemp "${TMPDIR:-/tmp}/usage-island-bootstrap-XXXXXX")"
registered=0
for attempt in {1..5}; do
  if launchctl bootstrap "$domain" "$plist" </dev/null >/dev/null 2>"$bootstrap_error"; then
    registered=1
    break
  fi
  sleep 0.3
done
if [[ "$registered" -ne 1 ]]; then
  cat "$bootstrap_error" >&2
  rm -f "$bootstrap_error"
  exit 1
fi
rm -f "$bootstrap_error"
launchctl kickstart "$domain/$label" </dev/null >/dev/null 2>&1

print "Instalado: $plist"
running=0
for attempt in {1..30}; do
  running=$( { pgrep -f "^${binary}$" || true; } | wc -l | tr -d ' ')
  [[ "$running" -eq 1 ]] && break
  sleep 0.1
done
if [[ "$running" -ne 1 ]]; then
  print -u2 "Erro: esperado um processo do app instalado; encontrados $running."
  exit 1
fi
print "Logs:      $log_dir"
print "Parar:     launchctl bootout $domain/$label"
