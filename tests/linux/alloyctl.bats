#!/usr/bin/env bats
# Resolucao de canais do alloyctl (alloy.sh) com curl simulado.

setup() {
  load helpers
  load_alloyctl_functions
  export -f curl
}

@test "stable: ultima release pelo redirecionamento, sem a API" {
  CURL_RESPONSES=$'https://github.com/*/releases/latest||302|https://github.com/DEV-ASSESSORIA-TECH/alloy/releases/tag/v1.2.3'
  resolve_version stable
  [ "$RESOLVED_VERSION" = v1.2.3 ]
  ! grep -q api.github.com "$BATS_TEST_TMPDIR/curl.log"
}

@test "stable: sem release publicada" {
  CURL_RESPONSES=$'https://github.com/*/releases/latest||302|https://github.com/DEV-ASSESSORIA-TECH/alloy/releases'
  ! resolve_version stable
  [[ $TOOL_ERROR == *'nenhuma release publicada'* ]]
}

@test "stable: redirecionamento bloqueado cai para a API" {
  CURL_RESPONSES=$'https://github.com/*/releases/latest|bloqueado|403|\nhttps://api.github.com/*/releases/latest|{"tag_name": "v2.0.0", "name": "x"}|200|'
  resolve_version stable
  [ "$RESOLVED_VERSION" = v2.0.0 ]
}

@test "stable: API no limite informa o motivo" {
  CURL_RESPONSES=$'https://github.com/*|x|500|\nhttps://api.github.com/*|x|403|'
  ! resolve_version stable
  [[ $TOOL_ERROR == *'limite da API'* ]]
}

@test "tag fixa nao consulta a rede" {
  CURL_RESPONSES=''
  resolve_version v1.4.0
  [ "$RESOLVED_VERSION" = v1.4.0 ]
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "branch: commit atual pela API" {
  CURL_RESPONSES=$'https://api.github.com/*/commits/main|0123456789abcdef0123456789abcdef01234567|200|'
  resolve_version main
  [ "$RESOLVED_VERSION" = 0123456789abcdef0123456789abcdef01234567 ]
}

@test "branch inexistente" {
  CURL_RESPONSES=$'https://api.github.com/*/commits/nope|{}|422|'
  ! resolve_version nope
  [[ $TOOL_ERROR == *"ref 'nope' nao existe"* ]]
}

@test "falha de rede" {
  CURL_RESPONSES=''
  ! resolve_version main
  [[ $TOOL_ERROR == 'falha ao consultar o GitHub: Could not resolve host'* ]]
}

@test "short_version: commit encurtado, tag inteira" {
  [ "$(short_version 0123456789abcdef0123456789abcdef01234567)" = 0123456 ]
  [ "$(short_version v1.10.12)" = v1.10.12 ]
  [ "$(short_version '')" = '?' ]
}

@test "valid_ref e is_tag" {
  valid_ref main
  valid_ref feature/x-1.2
  ! valid_ref '../x'
  ! valid_ref '-x'
  is_tag v1.0.0
  is_tag v1.2.0-rc.1
  ! is_tag 1.0.0
  ! is_tag stable
}
