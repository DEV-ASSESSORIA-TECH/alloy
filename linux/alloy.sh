#!/usr/bin/env bash
# Ponto de entrada unico do Grafana Alloy no Linux (Debian/Ubuntu).
# Sem comando: primeira instalacao guiada ou menu interativo.
#
# Executado a partir do download (comando do README), instala o comando
# alloyctl (/opt/alloyctl + /usr/local/bin/alloyctl) e segue por ele. O
# alloyctl se atualiza a cada execucao pelo canal acompanhado (padrao: a
# ultima release) e baixa sob demanda, presos a mesma versao, apenas os
# arquivos de cada operacao.
set -euo pipefail

usage() {
  cat <<'EOF'
Uso: alloyctl [comando] [opcoes]
     sudo bash alloy.sh [comando] [opcoes]   (instala o alloyctl e segue por ele)

Sem comando, abre o menu (ou a primeira instalacao guiada).
Sem root, pede elevacao com sudo.

Comandos:
  install [--modules docker|none] [--upgrade]
               credencial (se ausente) + instalacao/reaplicacao
  credentials  apenas o setup da credencial
  check        testa a credencial gravada (OAuth2 + Loki), sem alterar nada
  rotate       substitui a credencial e reinicia o Alloy
  modules docker|none
               ativa ou desativa o modulo Docker
  upgrade      atualiza o pacote Alloy
  status       diagnostico (servico, logs, conectividade, consultas)
  uninstall [--yes]
               remove o Alloy, mantendo credencial, configuracao e o alloyctl
  purge [--yes]
               limpeza completa (inclui a credencial e o alloyctl)
  heartbeat [--url URL]
               configura o heartbeat (Uptime Kuma Push + Loki)
  heartbeat-test
               executa o heartbeat agora e mostra o resultado
  heartbeat-remove [--yes]
               remove o heartbeat
  update       atualiza so o alloyctl e mostra a versao
  menu         abre o menu mesmo na primeira execucao

Opcoes globais:
  --ref REF    canal acompanhado pelo alloyctl: stable (padrao, ultima
               release), uma tag (v1.2.0, versao fixa), main ou outra branch;
               fica gravado para as proximas execucoes
  --no-update  nao atualiza o alloyctl antes de executar
  -h, --help   esta ajuda
EOF
}

# ---------------------------------------------------------------- argumentos
pass_args=()   # argumentos sem --ref/--no-update, repassados na reexecucao
command=''
cmd_args=()
ref_arg=''
no_update=false
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ref) (($# >= 2)) || { printf 'Falta valor para --ref.\n' >&2; exit 1; }; ref_arg=$2; shift 2; continue ;;
    --ref=*) ref_arg=${1#*=}; shift; continue ;;
    --no-update) no_update=true; shift; continue ;;
    --url) (($# >= 2)) || { printf 'Falta valor para --url.\n' >&2; exit 1; }
           cmd_args+=(--url "$2"); pass_args+=(--url "$2"); shift 2; continue ;;
    -*) cmd_args+=("$1") ;;
    *) if [[ -z $command ]]; then command=$1; else cmd_args+=("$1"); fi ;;
  esac
  pass_args+=("$1")
  shift
done
[[ -z $ref_arg && -n ${ALLOY_REF:-} ]] && ref_arg=$ALLOY_REF
unset ALLOYCTL_STATUS

# Sem root: reexecuta com sudo (o caminho real, nao o link do alloyctl).
self=$(readlink -f -- "${BASH_SOURCE[0]}")
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { printf '[Alloy] ERRO: execute como root.\n' >&2; exit 1; }
  elevated=("${pass_args[@]}")
  [[ -n $ref_arg ]] && elevated+=(--ref "$ref_arg")
  [[ $no_update == true ]] && elevated+=(--no-update)
  exec sudo -- bash "$self" "${elevated[@]}"
fi

# ---------------------------------------------------------------- alloyctl
# >>> funcoes do alloyctl: tests/linux/alloyctl.bats carrega deste marcador
# ate o marcador de fim, sem executar o resto do script.
TOOL_DIR=/opt/alloyctl
TOOL_BIN=/usr/local/bin/alloyctl
TOOL_REPO=DEV-ASSESSORIA-TECH/alloy
TOOL_RAW=https://raw.githubusercontent.com/$TOOL_REPO
TOOL_API=https://api.github.com/repos/$TOOL_REPO
TOOL_WEB=https://github.com/$TOOL_REPO
TOOL_REMOTE_DIR=linux
TOOL_UA=AssessoriaTech-Alloy-Installer/1.0
# Canal padrao: a ultima release publicada.
TOOL_CHANNEL=stable
# Nucleo baixado a cada versao; o resto vem sob demanda (fetch).
TOOL_CORE=(alloy.sh lib/common.sh lib/state.sh lib/ui.sh)
# Versao do Alloy fixada (raiz do repositorio; formato que o Dependabot atualiza).
TOOL_VERSION_FILE=alloy.Dockerfile

TOOL_LOG=/var/log/alloyctl.log
TOOL_ERROR=''      # motivo da ultima falha (resolve_version/install_tool)
RESOLVED_VERSION=''

tool_log() { printf '[alloyctl] %s\n' "$*"; }
tool_warn() { printf '[alloyctl] AVISO: %s\n' "$*" >&2; }
valid_ref() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $1 != *..* ]]; }
is_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
is_tag() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; }
# Versao para exibir: commit encurtado, tag inteira.
short_version() { if is_sha "$1"; then printf '%s' "${1:0:7}"; else printf '%s' "${1:-?}"; fi; }

# Historico de instalacoes, atualizacoes e falhas do alloyctl (limitado a
# ~2000 linhas). Nunca interrompe a execucao.
tool_filelog() {
  {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$TOOL_LOG"
    if (($(wc -l <"$TOOL_LOG") > 4000)); then
      tail -n 2000 "$TOOL_LOG" >"$TOOL_LOG.tmp" && mv -f -- "$TOOL_LOG.tmp" "$TOOL_LOG"
    fi
  } 2>/dev/null || true
}

# Primeira linha de erro do curl, sem o prefixo "curl: (N) ".
curl_error() { sed -n '/./{s/^curl: ([0-9]*) //;p;q;}' "$1" 2>/dev/null; }

# http_get URL [ACCEPT]: uma requisicao sem seguir redirecionamento. Preenche
# HTTP_CODE, HTTP_BODY e HTTP_LOCATION; em falha de rede, TOOL_ERROR.
HTTP_CODE='' HTTP_BODY='' HTTP_LOCATION=''
http_get() {
  local out errf headers=()
  HTTP_CODE='' HTTP_BODY='' HTTP_LOCATION=''
  [[ -n ${2:-} ]] && headers=(-H "Accept: $2")
  errf=$(mktemp)
  if ! out=$(curl -sS --proto '=https' --connect-timeout 10 --max-time 20 -A "$TOOL_UA" "${headers[@]}" \
      -w '\n%{http_code} %{redirect_url}' "$1" 2>"$errf"); then
    TOOL_ERROR="falha ao consultar o GitHub: $(curl_error "$errf")"
    rm -f -- "$errf"
    return 1
  fi
  rm -f -- "$errf"
  HTTP_BODY=${out%$'\n'*}
  out=${out##*$'\n'}
  HTTP_CODE=${out%% *}
  HTTP_LOCATION=${out#* }
}

# Ultima release: primeiro pelo redirecionamento de /releases/latest (pagina
# do GitHub, fora do limite da API); se nao der, pela API (60/h por IP).
resolve_latest() {
  local tag
  if http_get "$TOOL_WEB/releases/latest" && [[ $HTTP_CODE == 30[12] ]]; then
    tag=${HTTP_LOCATION##*/releases/tag/}
    if [[ $HTTP_LOCATION == */releases/tag/* ]] && is_tag "$tag"; then
      RESOLVED_VERSION=$tag
      return 0
    fi
    # Sem release, o GitHub redireciona para a lista de releases.
    if [[ $HTTP_LOCATION == */releases ]]; then
      TOOL_ERROR="nenhuma release publicada em $TOOL_REPO (use --ref main)"
      return 1
    fi
  fi
  TOOL_ERROR=''
  http_get "$TOOL_API/releases/latest" 'application/vnd.github+json' || return 1
  case "$HTTP_CODE" in
    200) ;;
    404) TOOL_ERROR="nenhuma release publicada em $TOOL_REPO (use --ref main)"; return 1 ;;
    403|429) TOOL_ERROR="GitHub recusou a consulta (HTTP $HTTP_CODE): limite da API (60/h por IP) ou bloqueio de rede"; return 1 ;;
    *) TOOL_ERROR="GitHub respondeu HTTP $HTTP_CODE"; return 1 ;;
  esac
  tag=$(printf '%s' "$HTTP_BODY" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  is_tag "$tag" || { TOOL_ERROR='resposta inesperada da API do GitHub'; return 1; }
  RESOLVED_VERSION=$tag
}

# resolve_version CANAL: versao a baixar em RESOLVED_VERSION. stable = ultima
# release; tag vX.Y.Z = ela mesma (sem consulta; tags nao mudam); branch ou
# commit = commit atual (uma requisicao a API). Em falha, motivo em
# TOOL_ERROR. Sem subshell, para que as variaveis cheguem a quem chamou.
resolve_version() {
  RESOLVED_VERSION='' TOOL_ERROR=''
  if [[ $1 == stable ]]; then resolve_latest; return; fi
  if is_tag "$1"; then RESOLVED_VERSION=$1; return 0; fi
  http_get "$TOOL_API/commits/$1" 'application/vnd.github.sha' || return 1
  case "$HTTP_CODE" in
    200) ;;
    404|422) TOOL_ERROR="ref '$1' nao existe no repositorio (HTTP $HTTP_CODE)"; return 1 ;;
    403|429) TOOL_ERROR="GitHub recusou a consulta (HTTP $HTTP_CODE): limite da API (60/h por IP) ou bloqueio de rede"; return 1 ;;
    *) TOOL_ERROR="GitHub respondeu HTTP $HTTP_CODE"; return 1 ;;
  esac
  is_sha "$HTTP_BODY" || { TOOL_ERROR='resposta inesperada da API do GitHub'; return 1; }
  RESOLVED_VERSION=$HTTP_BODY
}

# install_tool CANAL VERSAO: baixa o nucleo da versao, troca o diretorio
# inteiro (descarta os arquivos sob demanda da versao anterior) e cria o
# comando. O bash continua lendo o script em execucao pelo descritor ja aberto.
install_tool() {
  local channel=$1 version=$2 stage old='' name args=() errf
  TOOL_ERROR=''
  if ! mkdir -p -- "$(dirname -- "$TOOL_DIR")" || ! stage=$(mktemp -d "$TOOL_DIR.new.XXXXXX" 2>/dev/null); then
    TOOL_ERROR="sem permissao para criar $TOOL_DIR"
    return 1
  fi
  for name in "${TOOL_CORE[@]}"; do
    mkdir -p -- "$stage/$(dirname -- "$name")"
    args+=(-o "$stage/$name" "$TOOL_RAW/$version/$TOOL_REMOTE_DIR/$name")
  done
  args+=(-o "$stage/$TOOL_VERSION_FILE" "$TOOL_RAW/$version/$TOOL_VERSION_FILE")
  errf=$(mktemp)
  if ! curl -fsSL --proto '=https' --fail-early --connect-timeout 10 --retry 2 -A "$TOOL_UA" "${args[@]}" 2>"$errf"; then
    TOOL_ERROR="falha ao baixar o alloyctl ($(short_version "$version")): $(curl_error "$errf")"
    rm -f -- "$errf"; rm -rf -- "$stage"; return 1
  fi
  rm -f -- "$errf"
  for name in "${TOOL_CORE[@]}" "$TOOL_VERSION_FILE"; do
    [[ -s $stage/$name ]] || { TOOL_ERROR="download vazio: $name"; rm -rf -- "$stage"; return 1; }
  done
  if ! grep -qE '^[[:space:]]*FROM[[:space:]]+grafana/alloy:v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' "$stage/$TOOL_VERSION_FILE"; then
    TOOL_ERROR="$TOOL_VERSION_FILE de $(short_version "$version") sem a versao do Alloy"
    rm -rf -- "$stage"; return 1
  fi
  if ! bash -n "$stage/alloy.sh" 2>/dev/null; then
    TOOL_ERROR="alloy.sh de $(short_version "$version") com erro de sintaxe"
    rm -rf -- "$stage"; return 1
  fi
  printf '%s\n' "$channel" >"$stage/channel"
  printf '%s\n' "$version" >"$stage/version"
  chown -R root:root -- "$stage"
  find "$stage" -type d -exec chmod 0755 {} +
  find "$stage" -type f -exec chmod 0644 {} +
  chmod 0755 "$stage/alloy.sh"
  if [[ -e $TOOL_DIR ]]; then
    old=$TOOL_DIR.old.$$
    mv -- "$TOOL_DIR" "$old"
  fi
  mv -- "$stage" "$TOOL_DIR"
  if [[ -n $old ]]; then rm -rf -- "$old"; fi
  ln -sfn "$TOOL_DIR/alloy.sh" "$TOOL_BIN"
}

# Reexecuta a versao instalada, sem nova verificacao.
exec_tool() { exec bash "$TOOL_DIR/alloy.sh" "${pass_args[@]}" --no-update; }
# <<< funcoes do alloyctl

self_dir=$(dirname -- "$self")
if [[ $self_dir == "$TOOL_DIR" ]]; then
  mode=installed
elif [[ -f $self_dir/ops/install.sh && -f $self_dir/lib/common.sh ]]; then
  mode=local   # clone do repositorio: usa os arquivos locais
else
  mode=bootstrap
fi
if [[ -n $ref_arg ]] && ! valid_ref "$ref_arg"; then
  printf '[Alloy] ERRO: referencia invalida: %s\n' "$ref_arg" >&2; exit 1
fi

case "$mode" in
  bootstrap)
    # Comando do README: instala (ou atualiza) o alloyctl e segue por ele.
    ref=${ref_arg:-$TOOL_CHANNEL}
    first=true; [[ -x $TOOL_DIR/alloy.sh ]] && first=false
    if resolve_version "$ref" && install_tool "$ref" "$RESOLVED_VERSION"; then
      if [[ $first == true ]]; then
        tool_filelog "instalado: $ref @ $(short_version "$RESOLVED_VERSION")"
        tool_log "comando instalado: $TOOL_BIN (acompanha $ref). Daqui em diante, use: alloyctl"
      else
        tool_filelog "atualizado pelo comando do README: $ref @ $(short_version "$RESOLVED_VERSION")"
      fi
      exec_tool
    fi
    tool_filelog "FALHA ao instalar ($ref): $TOOL_ERROR"
    # Interativo: o motivo fica na tela e a decisao e de quem executa.
    # Automacao (sem terminal): segue com arquivos temporarios, com aviso.
    if [[ -t 0 && -t 1 ]]; then
      printf '\n  \e[1;31mALLOYCTL NAO INSTALADO\e[0m\n'
      printf '  Motivo: %s\n' "$TOOL_ERROR"
      printf '  Log:    %s\n\n' "$TOOL_LOG"
      printf '  Sem o alloyctl, esta execucao usa arquivos temporarios; o menu\n'
      printf '  funciona, mas o comando alloyctl nao fica disponivel.\n\n'
      read -r -p '  Continuar sem o alloyctl? [s/N]: ' answer || answer=''
      [[ $answer =~ ^([sS]|[sS][iI][mM]|[yY]|[yY][eE][sS])$ ]] || { printf '  Cancelado.\n'; exit 1; }
    else
      tool_warn "nao foi possivel instalar o alloyctl ($TOOL_ERROR); seguindo com arquivos temporarios."
    fi
    export ALLOYCTL_STATUS="nao instalado: $TOOL_ERROR"
    ;;
  installed)
    # Instalacao anterior a separacao do repositorio (arquivo "ref", sem
    # "channel"): passa para o canal padrao.
    tracked=$(cat -- "$TOOL_DIR/channel" 2>/dev/null) || tracked=$TOOL_CHANNEL
    valid_ref "$tracked" || tracked=$TOOL_CHANNEL
    version=$(cat -- "$TOOL_DIR/version" 2>/dev/null) || version=''
    # --ref diferente troca o canal; so vale se a atualizacao der certo.
    wanted=$tracked force=false
    if [[ -n $ref_arg && $ref_arg != "$tracked" ]]; then wanted=$ref_arg; force=true; fi
    if [[ ! -f $TOOL_DIR/channel ]]; then force=true; fi
    if [[ $no_update != true || $force == true ]]; then
      if resolve_version "$wanted"; then
        new=$RESOLVED_VERSION
        if [[ $new != "$version" || $force == true ]]; then
          if install_tool "$wanted" "$new"; then
            tool_filelog "atualizado: $(short_version "$version") -> $(short_version "$new") ($wanted)"
            tool_log "atualizado: $(short_version "$version") -> $(short_version "$new") ($wanted)"
            exec_tool
          fi
        fi
      fi
      if [[ -n $TOOL_ERROR ]]; then
        # A versao instalada continua valendo; o motivo aparece no cabecalho.
        tool_filelog "sem atualizacao ($wanted): $TOOL_ERROR"
        tool_warn "sem atualizacao ($TOOL_ERROR); usando $tracked @ $(short_version "$version"). Log: $TOOL_LOG"
        export ALLOYCTL_STATUS="sem atualizacao: $TOOL_ERROR"
      fi
    fi
    ;;
esac

case "$mode" in
  installed)
    { is_sha "$version" || is_tag "$version"; } ||
      { printf '[Alloy] ERRO: %s/version invalido; rode o comando do README.\n' "$TOOL_DIR" >&2; exit 1; }
    # Tudo o que for baixado daqui em diante vem da mesma versao.
    export ALLOY_REF=$version ALLOY_LOCAL=0 ALLOYCTL_REF=$tracked
    src=$TOOL_DIR ;;
  local)
    export ALLOY_REF=${ref_arg:-main} ALLOY_LOCAL=1
    src=$self_dir ;;
  bootstrap)
    # Sem alloyctl: a versao resolvida, se houver; senao a ref pedida (stable
    # nao e uma ref do git: cai para main).
    ALLOY_REF=${RESOLVED_VERSION:-${ref_arg:-main}}
    [[ $ALLOY_REF == stable ]] && ALLOY_REF=main
    export ALLOY_REF ALLOY_LOCAL=0
    src=$(mktemp -d)
    trap 'rm -rf -- "$src"' EXIT
    mkdir -p -- "$src/lib"
    curl -fsSL --proto '=https' --fail-early --connect-timeout 10 --retry 2 \
      -o "$src/lib/common.sh" "$TOOL_RAW/$ALLOY_REF/$TOOL_REMOTE_DIR/lib/common.sh" \
      -o "$src/lib/state.sh" "$TOOL_RAW/$ALLOY_REF/$TOOL_REMOTE_DIR/lib/state.sh" \
      -o "$src/lib/ui.sh" "$TOOL_RAW/$ALLOY_REF/$TOOL_REMOTE_DIR/lib/ui.sh" \
      -o "$src/$TOOL_VERSION_FILE" "$TOOL_RAW/$ALLOY_REF/$TOOL_VERSION_FILE" ||
      { printf '[Alloy] ERRO: falha ao baixar as bibliotecas (ref %s).\n' "$ALLOY_REF" >&2; exit 1; } ;;
esac
export ALLOYCTL_MODE=$mode
# shellcheck source=lib/common.sh
source "$src/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$src/lib/ui.sh"
# shellcheck source=lib/state.sh
source "$src/lib/state.sh"

# Versao do Alloy fixada nesta versao do alloyctl: a pasta do alloyctl e a
# temporaria guardam o arquivo ao lado do alloy.sh; o clone, na raiz.
if [[ $mode == local ]]; then version_file=$src/../$TOOL_VERSION_FILE; else version_file=$src/$TOOL_VERSION_FILE; fi
ALLOY_VERSION=$(read_alloy_version "$version_file") || fail 'Versao do Alloy indisponivel; rode o comando do README.'
export ALLOY_VERSION

command -v apt-get >/dev/null || fail 'APT obrigatorio (Debian/Ubuntu).'
command -v python3 >/dev/null || fail 'python3 ausente; instale antes de executar.'

# ---------------------------------------------------------------- operacoes
# Cada operacao retorna 0/1 sem encerrar o menu. Os scripts filhos rodam em
# processos proprios, com seus proprios controles de erro e rollback.

run_credentials() {
  fetch "$src" ops/setup-credentials.py || return 1
  python3 "$src/ops/setup-credentials.py" "$@"
}

run_installer() {
  fetch "$src" ops/install.sh modules/config.alloy modules/backup.alloy || return 1
  bash "$src/ops/install.sh" "$@"
}

do_install() {
  if ! credential_present; then
    # Uma unica chamada de download para as duas etapas.
    fetch "$src" ops/setup-credentials.py ops/install.sh modules/config.alloy modules/backup.alloy || return 1
    ui_section 'ETAPA 1/2 - CREDENCIAL'
    run_credentials || return 1
    ui_section 'ETAPA 2/2 - INSTALACAO'
  fi
  run_installer "$@"
}

do_setup_credentials() {
  if credential_present; then
    warn 'Credencial ja existe. Use "rotate" para substituir.'
    return 1
  fi
  run_credentials
}

do_check() {
  credential_present || { warn 'Nenhuma credencial gravada.'; return 1; }
  run_credentials --check
}

do_rotate() {
  credential_present || { warn 'Nenhuma credencial gravada; use o setup de credencial.'; return 1; }
  run_credentials --rotate || return 1
  if alloy_installed && service_active; then
    log 'Reiniciando o Alloy para carregar a nova credencial...'
    systemctl restart alloy || return 1
    if ! wait_ready; then
      warn 'Alloy nao ficou pronto apos a rotacao. Consulte o diagnostico.'
      return 1
    fi
    ok 'Alloy pronto com a nova credencial.'
  fi
}

do_modules() {
  case "${1:-}" in
    docker|none) ;;
    *) warn 'Use: modules docker|none'; return 1 ;;
  esac
  credential_present || { warn 'Credencial ausente; execute a instalacao primeiro.'; return 1; }
  run_installer --modules "$1"
}

do_upgrade() {
  credential_present || { warn 'Credencial ausente; execute a instalacao primeiro.'; return 1; }
  run_installer --upgrade
}

do_uninstall() {
  fetch "$src" ops/uninstall.sh || return 1
  bash "$src/ops/uninstall.sh" "$@"
}

# A limpeza completa remove tambem o alloyctl: nada mais a executar.
after_purge() {
  if [[ $ALLOYCTL_MODE == installed && ! -d $TOOL_DIR ]]; then
    log 'alloyctl removido. Para instalar de novo, use o comando do README.'
    exit 0
  fi
}

do_update() {
  if [[ $ALLOYCTL_MODE != installed ]]; then
    warn 'alloyctl nao instalado; execute sem --no-update a partir do comando do README.'
    return 1
  fi
  ok "alloyctl $ALLOYCTL_REF @ $(short_version "$ALLOY_REF") ($TOOL_BIN)"
}

# Como abrir de novo: pelo alloyctl quando instalado.
reopen_hint() {
  if [[ $ALLOYCTL_MODE == installed ]]; then
    printf '  Para gerenciar este servidor depois, execute: alloyctl\n'
  else
    printf '  Para gerenciar este servidor depois, execute o mesmo comando.\n'
  fi
}

# Heartbeat opcional: nunca sugerido na instalacao, so pelo menu [9] ou comando.
do_heartbeat() {
  fetch "$src" heartbeat/heartbeat-setup.sh heartbeat/heartbeat.py || return 1
  bash "$src/heartbeat/heartbeat-setup.sh" "$@"
}

# ---------------------------------------------------------------- interativo
need_tty() { [[ -t 0 ]] || fail 'Sem terminal interativo: informe um comando (veja --help).'; }

first_install() {
  ui_clear
  ui_banner "$(host_name)"
  printf '  Primeira instalacao neste servidor.\n\n'
  printf '  %s[1/2] Credencial%s   conta alloy-<hostname> + senha de aplicativo,\n' "$C_BOLD" "$C_RESET"
  printf '                     validada (OAuth2 + Loki) antes de gravar\n'
  printf '  %s[2/2] Instalacao%s   Alloy + configuracao, com validacao e rollback\n\n' "$C_BOLD" "$C_RESET"
  confirm '  Continuar?' || { log 'Cancelado; nada foi alterado.'; return 0; }
  do_install || return 1
  printf '\n'
  LAST_STATUS=ok LAST_ACTION="Primeira instalacao - concluida ($(date +%H:%M))"
  print_header
  reopen_hint
}

# run_screen TITULO FUNCAO [ARGS...]: tela propria, resultado e "ultima acao".
run_screen() {
  local title=$1
  shift
  ui_clear
  ui_section "$(tr '[:lower:]' '[:upper:]' <<<"$title")"
  printf '\n'
  if "$@"; then
    LAST_STATUS=ok LAST_ACTION="$title - concluido ($(date +%H:%M))"
    printf '\n  %s Concluido.\n' "$(ui_badge ok)"
  else
    LAST_STATUS=err LAST_ACTION="$title - falhou ($(date +%H:%M))"
    printf '\n  %s A operacao nao foi concluida.\n' "$(ui_badge err)"
  fi
  ui_pause
}

view_screen() {
  ui_clear
  ui_banner "$(host_name)"
  "$@"
  ui_pause
}

heartbeat_menu() {
  local frame
  while heartbeat_configured; do
    # Estado calculado antes de limpar a tela: sem tela em branco nem
    # desenho em pedacos enquanto systemctl/dpkg/curl respondem.
    frame=$(print_header)
    ui_clear
    printf '%s\n' "$frame"
    ui_columns 'HEARTBEAT' "$C_BOLD" '' ''
    ui_columns ' [1] Testar agora' '' ' [3] Remover' "$C_ERR"
    ui_columns ' [2] Reconfigurar' '' '' ''
    ui_rule -
    printf '  Tecle a opcao (0 volta): '
    ui_readkey || { printf '\n'; return 0; }
    [[ $UI_KEY == ESC ]] || printf '%s' "$UI_KEY"
    printf '\n'
    case "$UI_KEY" in
      1) run_screen 'Testar heartbeat' do_heartbeat --test ;;
      2) run_screen 'Reconfigurar heartbeat' do_heartbeat ;;
      3) run_screen 'Remover heartbeat' do_heartbeat --remove ;;
      0|q|Q|ESC) return 0 ;;
      *) ;;
    esac
  done
}

menu() {
  local default label1 label2 color2 docker_target label5 label9 prompt frame
  while :; do
    default=''
    if ! alloy_installed || ! service_active; then default=1; fi
    if alloy_installed; then label1='Reaplicar configuracao'; else label1='Instalar Alloy'; fi
    color2=''
    if docker_module; then
      label2='Desativar Docker'; docker_target=none
    else
      label2='Ativar Docker'; docker_target=docker
      if ! docker_available; then label2+=' (ausente)'; color2=$C_DIM; fi
    fi
    if credential_present; then label5='Rotacionar'; else label5='Configurar'; fi

    # Estado calculado antes de limpar a tela: sem tela em branco nem
    # desenho em pedacos enquanto systemctl/dpkg/curl respondem.
    frame=$(print_header)
    ui_clear
    printf '%s\n' "$frame"
    ui_columns 'INSTALACAO' "$C_BOLD" 'CREDENCIAL' "$C_BOLD"
    ui_columns " [1] $label1" "${default:+$C_OK}" ' [4] Testar' ''
    ui_columns " [2] $label2" "$color2" " [5] $label5" ''
    ui_columns ' [3] Atualizar Alloy' '' '' ''
    printf '\n'
    ui_columns 'DIAGNOSTICO' "$C_BOLD" 'REMOCAO' "$C_BOLD"
    if heartbeat_configured; then label9='Heartbeat'; else label9='Configurar heartbeat'; fi
    ui_columns ' [6] Ver diagnostico' '' ' [7] Desinstalar' "$C_ERR"
    ui_columns " [9] $label9" '' ' [8] Limpeza completa' "$C_ERR"
    ui_rule -
    prompt='Tecle a opcao (0 sai)'
    [[ -n $default ]] && prompt="Tecle a opcao (Enter = $default, 0 sai)"
    printf '  %s: ' "$prompt"
    ui_readkey || { printf '\n'; return 0; }
    [[ -z $UI_KEY ]] && UI_KEY=$default
    [[ $UI_KEY == ESC ]] || printf '%s' "$UI_KEY"
    printf '\n'
    case "$UI_KEY" in
      1) run_screen "$label1" do_install ;;
      2) run_screen "$label2" do_modules "$docker_target" ;;
      3) run_screen 'Atualizar Alloy' do_upgrade ;;
      4) run_screen 'Testar credencial' do_check ;;
      5) if credential_present; then
           run_screen 'Rotacionar credencial' do_rotate
         else
           run_screen 'Configurar credencial' do_setup_credentials
         fi ;;
      6) view_screen diagnose ;;
      7) run_screen 'Desinstalar' do_uninstall ;;
      8) run_screen 'Limpeza completa' do_uninstall --purge; after_purge ;;
      9) if heartbeat_configured; then
           heartbeat_menu
         else
           run_screen 'Configurar heartbeat' do_heartbeat
         fi ;;
      0|q|Q)
        ui_clear
        print_summary
        if [[ $ALLOYCTL_MODE == installed ]]; then
          printf '  Para abrir o menu de novo, execute: alloyctl\n'
        else
          printf '  Para abrir o menu de novo, execute o mesmo comando.\n'
        fi
        return 0 ;;
      *) ;;
    esac
  done
}

# ---------------------------------------------------------------- despacho
case "$command" in
  '')
    need_tty
    if first_run; then first_install; else menu; fi ;;
  menu) need_tty; menu ;;
  install) do_install "${cmd_args[@]}" ;;
  credentials) do_setup_credentials ;;
  check) do_check ;;
  rotate) do_rotate ;;
  modules) do_modules "${cmd_args[@]}" ;;
  upgrade) do_upgrade ;;
  status) ui_banner "$(host_name)"; print_summary; diagnose ;;
  uninstall) do_uninstall "${cmd_args[@]}" ;;
  purge) do_uninstall --purge "${cmd_args[@]}" ;;
  heartbeat) do_heartbeat "${cmd_args[@]}" ;;
  heartbeat-test) do_heartbeat --test ;;
  heartbeat-remove) do_heartbeat --remove "${cmd_args[@]}" ;;
  update) do_update ;;
  *) usage >&2; fail "Comando desconhecido: $command" ;;
esac
