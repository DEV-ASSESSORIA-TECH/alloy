# Carregado pelos testes bats (load helpers).
REPO_ROOT=$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)

# Carrega o bloco de funcoes do alloy.sh (entre os marcadores >>> e <<<),
# sem argumentos, elevacao nem o fluxo principal.
load_alloyctl_functions() {
  local block
  block=$(sed -n '/^# >>> funcoes do alloyctl/,/^# <<< funcoes do alloyctl/p' "$REPO_ROOT/linux/alloy.sh")
  [[ -n $block ]] || { echo 'marcadores do alloy.sh nao encontrados' >&2; return 1; }
  eval "$block"
}

# Respostas simuladas do curl: cada teste define CURL_RESPONSES como linhas
# "padrao-da-url|corpo|codigo|redirect". O primeiro padrao (glob)
# que casar com a URL responde no formato de -w '\n%{http_code} %{redirect_url}'.
curl() {
  local url=${*: -1} pattern body code location
  printf '%s\n' "$url" >>"$BATS_TEST_TMPDIR/curl.log"
  while IFS="|" read -r pattern body code location; do
    [[ -z $pattern ]] && continue
    # shellcheck disable=SC2053
    if [[ $url == $pattern ]]; then
      printf '%s\n%s %s' "$body" "$code" "$location"
      return 0
    fi
  done <<<"$CURL_RESPONSES"
  echo "curl: (6) Could not resolve host: $url" >&2
  return 6
}
