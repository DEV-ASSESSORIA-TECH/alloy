#!/usr/bin/env bats
# install_tool (alloy.sh): troca da pasta do alloyctl a partir dos downloads.

setup() {
  load helpers
  load_alloyctl_functions
  TOOL_DIR=$BATS_TEST_TMPDIR/opt/alloyctl
  TOOL_BIN=$BATS_TEST_TMPDIR/bin/alloyctl
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # Sem root no teste.
  chown() { :; }
  # curl -o ARQ URL ...: grava o conteudo de FAKE_FILES/<caminho da URL>.
  curl() {
    local out='' arg
    for arg in "$@"; do
      if [[ $out == next ]]; then out=$arg; continue; fi
      [[ $arg == -o ]] && { out=next; continue; }
      if [[ $arg == https://* && -n $out ]]; then
        cp -- "$FAKE_FILES/${arg#https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/*/}" "$out" || return 22
        out=''
      fi
    done
  }
  FAKE_FILES=$BATS_TEST_TMPDIR/remote
  mkdir -p "$FAKE_FILES/linux/lib"
  printf '#!/usr/bin/env bash\necho novo\n' >"$FAKE_FILES/linux/alloy.sh"
  for f in common state ui; do printf '# lib\n' >"$FAKE_FILES/linux/lib/$f.sh"; done
  printf 'FROM grafana/alloy:v1.19.2\n' >"$FAKE_FILES/alloy.Dockerfile"
}

@test "instala o nucleo, a versao do Alloy, o canal e o comando" {
  install_tool stable v1.0.0
  [ "$(cat "$TOOL_DIR/channel")" = stable ]
  [ "$(cat "$TOOL_DIR/version")" = v1.0.0 ]
  [ -s "$TOOL_DIR/lib/state.sh" ]
  grep -q 'v1.19.2' "$TOOL_DIR/alloy.Dockerfile"
  [ "$(readlink "$TOOL_BIN")" = "$TOOL_DIR/alloy.sh" ]
}

@test "substitui a pasta inteira (arquivos sob demanda antigos saem)" {
  mkdir -p "$TOOL_DIR/ops"; touch "$TOOL_DIR/ops/install.sh" "$TOOL_DIR/ref"
  install_tool stable v1.0.0
  [ ! -e "$TOOL_DIR/ops/install.sh" ]
  [ ! -e "$TOOL_DIR/ref" ]
}

@test "recusa alloy.sh com erro de sintaxe e mantem a versao anterior" {
  mkdir -p "$TOOL_DIR"; echo antigo >"$TOOL_DIR/version"
  printf 'if then fi (\n' >"$FAKE_FILES/linux/alloy.sh"
  ! install_tool stable v1.0.1
  [[ $TOOL_ERROR == *'erro de sintaxe'* ]]
  [ "$(cat "$TOOL_DIR/version")" = antigo ]
}

@test "recusa alloy.Dockerfile sem a versao" {
  printf 'FROM grafana/alloy:latest\n' >"$FAKE_FILES/alloy.Dockerfile"
  ! install_tool stable v1.0.0
  [[ $TOOL_ERROR == *'sem a versao do Alloy'* ]]
  [ ! -e "$TOOL_DIR" ]
}

@test "falha de download nao deixa pasta temporaria" {
  rm "$FAKE_FILES/linux/lib/ui.sh"
  ! install_tool stable v1.0.0
  [ -z "$(find "$BATS_TEST_TMPDIR/opt" -maxdepth 1 -name 'alloyctl.new.*' 2>/dev/null)" ]
}
