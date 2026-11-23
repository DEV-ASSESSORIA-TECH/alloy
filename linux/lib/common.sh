# shellcheck shell=bash
# shellcheck disable=SC2034  # constantes usadas pelos scripts que carregam esta lib
# Funcoes compartilhadas por alloy.sh e uninstall.sh: constantes, saida,
# confirmacoes e download dos arquivos do repositorio.

ALLOY_REPO_RAW=${ALLOY_REPO_RAW:-https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy}
ALLOY_REMOTE_DIR=linux
ALLOY_REF=${ALLOY_REF:-main}
# 1 quando executado a partir de um clone: nada e baixado.
ALLOY_LOCAL=${ALLOY_LOCAL:-0}

ETC_DIR=/etc/alloy
SECRET=$ETC_DIR/oauth-client-secret
ENV_FILE=/etc/default/alloy
DROPIN_DIR=/etc/systemd/system/alloy.service.d
DROPIN_FILE=$DROPIN_DIR/zz-assessoriatech-execution.conf
DATA_DIR=/var/lib/alloy
# Leitura dos backups (backup.alloy): pasta e grupo com escrita (mesmos valores
# do install.sh).
TEXTFILE_DIR=/var/lib/alloy-textfile
BACKUP_TEXTFILE_DIR=$TEXTFILE_DIR/backup
BACKUP_GROUP=alloy-backup
APT_SOURCE=/etc/apt/sources.list.d/grafana.list
APT_KEY=/etc/apt/keyrings/grafana.asc
READY_URL=http://127.0.0.1:12345/-/ready
# Comando alloyctl (mesmos valores do alloy.sh, que roda antes desta lib).
ALLOYCTL_DIR=/opt/alloyctl
ALLOYCTL_BIN=/usr/local/bin/alloyctl
# Assinatura propria nas chamadas a auth/mon (atras da Cloudflare).
USER_AGENT=AssessoriaTech-Alloy-Installer/1.0
# Heartbeat opcional (Uptime Kuma + Loki), ver heartbeat-setup.sh.
HEARTBEAT_DIR=$ETC_DIR/heartbeat
HEARTBEAT_URL_FILE=$HEARTBEAT_DIR/kuma-url
HEARTBEAT_LIB=/usr/local/libexec/alloy-heartbeat
HEARTBEAT_SCRIPT=$HEARTBEAT_LIB/heartbeat.py
HEARTBEAT_STATE=/var/lib/alloy-heartbeat
HEARTBEAT_UNIT=alloy-heartbeat
HEARTBEAT_SERVICE_FILE=/etc/systemd/system/$HEARTBEAT_UNIT.service
HEARTBEAT_TIMER_FILE=/etc/systemd/system/$HEARTBEAT_UNIT.timer
# Links do diagnostico. Datasource por nome ou UID, como cadastrado no Grafana.
GRAFANA_URL=https://mon.assessoriatech.com/grafana
GRAFANA_DS_METRICS=Prometheus
GRAFANA_DS_LOGS=Loki

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
  C_BOLD='' C_OK='' C_WARN='' C_ERR='' C_DIM='' C_RESET=''
fi

log() { printf '[Alloy] %s\n' "$*"; }
ok() { printf '[Alloy] %s%s%s\n' "$C_OK" "$*" "$C_RESET"; }
warn() { printf '[Alloy] %sAVISO:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
fail() { printf '[Alloy] %sERRO:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

# Versao do Alloy fixada nesta versao do alloyctl. Fonte unica: o
# alloy.Dockerfile na raiz do repositorio ("FROM grafana/alloy:vX.Y.Z"), no
# formato que o Dependabot atualiza. O alloy.sh le o arquivo e repassa a versao
# em ALLOY_VERSION para os scripts filhos.
read_alloy_version() {
  local version
  [[ -f $1 ]] || { printf 'Arquivo de versao do Alloy ausente: %s\n' "$1" >&2; return 1; }
  version=$(grep -m 1 -E '^[[:space:]]*FROM[[:space:]]+grafana/alloy:v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' "$1" |
    sed -E 's/.*:v([0-9.]+).*/\1/') || true
  [[ -n $version ]] || { printf 'Versao do Alloy nao encontrada em %s (esperado: FROM grafana/alloy:vX.Y.Z).\n' "$1" >&2; return 1; }
  printf '%s\n' "$version"
}

# Versao repassada pelo alloy.sh; erro se ausente ou invalida.
pinned_alloy_version() {
  [[ ${ALLOY_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { warn "Versao do Alloy ausente ou invalida (ALLOY_VERSION='${ALLOY_VERSION:-}'). Execute pelo alloyctl."; return 1; }
  printf '%s\n' "$ALLOY_VERSION"
}

# apt_package_version VERSAO: le "apt-cache madison alloy" na entrada e devolve
# a versao do pacote que corresponde a VERSAO (ex.: 1.21.3 ou 1.21.3-1).
# Le a entrada ate o fim: sair na primeira linha (exit) fecha o pipe, e quem
# escreve (apt-cache) morre com SIGPIPE; com pipefail + set -e, o script para
# sem mensagem (gawk sai na hora; mawk le tudo, por isso so falha com gawk).
apt_package_version() {
  awk -F'|' -v want="$1" '
    { gsub(/[[:space:]]/, "", $2) }
    !found && ($2 == want || index($2, want "-") == 1) { print $2; found = 1 }'
}

# package_installed PACOTE: instalado, retido (apt-mark hold) ou nao. O campo
# Status vira "hold ok installed" com o pacote retido; db:Status-Status diz so
# "installed", com ou sem hold.
package_installed() {
  [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true) == installed ]]
}

# trap_errors: com set -e, um comando que falha encerra o script sem dizer
# qual foi. Mostra o comando, a linha e o codigo antes de sair.
trap_errors() {
  set -E
  trap 'printf "[Alloy] ERRO: comando falhou (codigo %s, %s linha %s): %s\n" "$?" "$(basename -- "${BASH_SOURCE[0]:-$0}")" "$LINENO" "$BASH_COMMAND" >&2' ERR
}

# confirm "Pergunta" [S|N]: retorna 0 para sim. O segundo argumento e o padrao.
confirm() {
  local default=${2:-S} hint='[S/n]' answer
  [[ $default == N ]] && hint='[s/N]'
  read -r -p "$1 $hint: " answer || return 1
  answer=${answer:-$default}
  [[ $answer =~ ^([sS]|[sS][iI][mM]|[yY]|[yY][eE][sS])$ ]]
}

validate_ref() {
  [[ $ALLOY_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ALLOY_REF != *..* ]] ||
    fail "Referencia invalida: $ALLOY_REF"
}

# fetch DESTINO ARQUIVO...: baixa apenas os arquivos ausentes, todos na mesma
# chamada do curl (uma conexao). Em modo local, um arquivo ausente e erro.
fetch() {
  local dest=$1 name args=()
  shift
  for name in "$@"; do
    [[ -s $dest/$name ]] && continue
    if [[ $ALLOY_LOCAL == 1 ]]; then
      warn "Arquivo ausente no repositorio local: $name"
      return 1
    fi
    mkdir -p -- "$(dirname -- "$dest/$name")"
    args+=(-o "$dest/$name" "$ALLOY_REPO_RAW/$ALLOY_REF/$ALLOY_REMOTE_DIR/$name")
  done
  ((${#args[@]})) || return 0
  if ! curl -fsSL --proto '=https' --fail-early --connect-timeout 10 --retry 2 "${args[@]}"; then
    warn "Falha ao baixar arquivos do repositorio (ref $ALLOY_REF)."
    return 1
  fi
  for name in "$@"; do
    [[ -s $dest/$name ]] || { warn "Download vazio: $name"; return 1; }
  done
}
