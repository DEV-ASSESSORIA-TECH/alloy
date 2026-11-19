# Publicar uma versão

As máquinas acompanham o canal `stable` (a última release). Um merge na `main`
**não** chega a elas: só a release. Use `--ref main` numa máquina de teste
para validar antes de publicar.

## Número da versão (SemVer)

| Parte | Quando | Exemplo |
|-------|--------|---------|
| MAJOR (`2.0.0`) | exige ação manual em todas as máquinas ou muda o comando de instalação | novo repositório, comando removido |
| MINOR (`1.1.0`) | novo módulo, nova opção ou coleta nova | módulo PostgreSQL |
| PATCH (`1.0.1`) | correção sem mudança de comportamento esperado | falha num caso de borda |

## Passos

1. Na `main`, mova os itens de **[Não publicado]** do `CHANGELOG.md` para uma
   seção `## [X.Y.Z] - AAAA-MM-DD` e atualize os links do final. Diga se a
   versão exige **[1] Reaplicar configuração**.
2. Faça o merge e espere a CI ficar verde.
3. Crie e envie a tag a partir da `main`:

   ```bash
   git checkout main && git pull
   ```

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   ```

   ```bash
   git push origin vX.Y.Z
   ```

4. O workflow **Release** roda a CI de novo na tag, confere se o
   `CHANGELOG.md` tem a seção da versão e cria a release com essas notas. Em
   poucos minutos, toda execução do `alloyctl` no canal `stable` passa para a
   versão nova.

A release é só a tag com as notas: nenhum pacote é anexado nem usado pelas
máquinas. Os arquivos continuam vindo de
`raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/vX.Y.Z/`.

## Voltar uma versão

- **Rápido**: na página da release anterior, *Edit* → marque **Set as the
  latest release**. O `stable` passa a apontar para ela na execução seguinte
  de cada máquina. Depois corrija e publique uma versão PATCH nova.
- **Uma máquina só**: `alloyctl --ref vX.Y.Z` fixa a versão até voltar com
  `alloyctl --ref stable`.

Não apague nem mova tags publicadas: máquinas com versão fixa e arquivos sob
demanda dependem delas.
