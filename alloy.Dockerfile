# Versao do Grafana Alloy instalada pelo alloyctl (Linux e Windows).
#
# Fonte unica da versao: o alloy.sh / alloy.ps1 le a linha FROM abaixo e
# instala exatamente esta versao. O formato Dockerfile existe para o
# Dependabot abrir PR quando sair versao nova; a CI valida os .alloy com a
# mesma imagem. Nao e usado para construir imagem nenhuma.
#
# Mantenha uma unica linha FROM, no formato grafana/alloy:vX.Y.Z.
FROM grafana/alloy:v1.22.0
