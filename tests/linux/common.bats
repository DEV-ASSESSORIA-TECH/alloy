#!/usr/bin/env bats
# lib/common.sh: versao fixada do Alloy e downloads sob demanda.

setup() {
  load helpers
  # shellcheck source=../../linux/lib/common.sh
  source "$REPO_ROOT/linux/lib/common.sh"
}

@test "read_alloy_version le o alloy.Dockerfile do repositorio" {
  run read_alloy_version "$REPO_ROOT/alloy.Dockerfile"
  [ "$status" -eq 0 ]
  [[ $output =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "read_alloy_version recusa tag sem versao e arquivo ausente" {
  printf 'FROM grafana/alloy:latest\n' >"$BATS_TEST_TMPDIR/f"
  run read_alloy_version "$BATS_TEST_TMPDIR/f"
  [ "$status" -ne 0 ]
  run read_alloy_version "$BATS_TEST_TMPDIR/nao-existe"
  [ "$status" -ne 0 ]
}

@test "pinned_alloy_version exige ALLOY_VERSION valida" {
  ALLOY_VERSION=1.19.2 run pinned_alloy_version
  [ "$output" = 1.19.2 ]
  ALLOY_VERSION=latest run pinned_alloy_version
  [ "$status" -ne 0 ]
}

@test "apt_package_version escolhe a versao exata do madison" {
  madison=$'     alloy |     1.19.3 | https://apt.grafana.com stable/main amd64 Packages\n     alloy |   1.19.2-1 | https://apt.grafana.com stable/main amd64 Packages\n     alloy |    1.9.2 | https://apt.grafana.com stable/main amd64 Packages'
  [ "$(apt_package_version 1.19.2 <<<"$madison")" = 1.19.2-1 ]
  [ "$(apt_package_version 1.9.2 <<<"$madison")" = 1.9.2 ]
  [ -z "$(apt_package_version 1.1.2 <<<"$madison")" ]
}

@test "fetch em clone local: arquivo ausente e erro, nada e baixado" {
  ALLOY_LOCAL=1
  run fetch "$BATS_TEST_TMPDIR" ops/install.sh
  [ "$status" -ne 0 ]
  [[ $output == *'Arquivo ausente no repositorio local: ops/install.sh'* ]]
}

@test "fetch baixa so o que falta, da mesma versao, mantendo subpastas" {
  ALLOY_LOCAL=0 ALLOY_REF=v1.0.0
  mkdir -p "$BATS_TEST_TMPDIR/ops"; echo x >"$BATS_TEST_TMPDIR/ops/install.sh"
  curl() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/args"; mkdir -p "$BATS_TEST_TMPDIR/modules"; echo y >"$BATS_TEST_TMPDIR/modules/config.alloy"; }
  fetch "$BATS_TEST_TMPDIR" ops/install.sh modules/config.alloy
  grep -qx 'https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/v1.0.0/linux/modules/config.alloy' "$BATS_TEST_TMPDIR/args"
  ! grep -q 'ops/install.sh' "$BATS_TEST_TMPDIR/args"
}

@test "apt_package_version le a entrada inteira (quem escreve nao recebe SIGPIPE)" {
  # Com gawk, sair na primeira linha mata o apt-cache com SIGPIPE; com
  # pipefail + set -e o install.sh parava sem mensagem.
  for impl in awk gawk mawk; do
    command -v "$impl" >/dev/null || continue
    run bash -c "set -euo pipefail; source '$REPO_ROOT/linux/lib/common.sh'
      awk() { command $impl \"\$@\"; }
      v=\$(perl -e '\$|=1; for \$m (reverse 0..22) { for \$p (3,2,1,0) { print \"     alloy | 1.\$m.\$p-1 | x\\n\"; select(undef,undef,undef,0.002) } }' | apt_package_version 1.19.2)
      echo \"\$v\""
    [ "$status" -eq 0 ]
    [ "$output" = 1.19.2-1 ]
  done
}

@test "trap_errors mostra o comando que falhou com set -e" {
  run bash -c "set -euo pipefail; source '$REPO_ROOT/linux/lib/common.sh'; trap_errors
    x=\$(false)
    echo nao-chega"
  [ "$status" -ne 0 ]
  [[ $output == *'ERRO: comando falhou'* ]]
  [[ $output != *nao-chega* ]]
}

@test "package_installed aceita pacote retido (apt-mark hold)" {
  # Com hold, ${Status} vira "hold ok installed"; o menu mostrava "nao instalado".
  dpkg-query() {
    case "$*" in
      *'${db:Status-Status}'*held*) printf installed ;;
      *'${db:Status-Status}'*normal*) printf installed ;;
      *'${db:Status-Status}'*removido*) printf config-files ;;
      *) return 1 ;;
    esac
  }
  package_installed held
  package_installed normal
  ! package_installed removido
  ! package_installed ausente
}
