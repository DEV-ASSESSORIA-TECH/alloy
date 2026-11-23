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

Ninguém cria tag localmente: o workflow **Release** cria a tag e a release.

1. Num PR para a `main`:
   - escreva a versão nova no arquivo `VERSION` (`X.Y.Z`);
   - mova os itens de **[Não publicado]** do `CHANGELOG.md` para uma seção
     `## [X.Y.Z] - AAAA-MM-DD` e atualize os links do final;
   - diga se a versão exige **[1] Reaplicar configuração**.

   A CI confere que a versão do `VERSION` tem a seção no `CHANGELOG.md`.
2. Faça o merge e espere a CI da `main` ficar verde.
3. No GitHub: **Actions → Release → Run workflow**, branch `main`.
4. O workflow:
   - recusa outro branch que não a `main`, versão inválida e tag ou release
     que já existam;
   - tira as notas da seção do `CHANGELOG.md`;
   - roda a CI inteira no commit;
   - cria a tag `vX.Y.Z` nesse commit e a release com as notas, marcada como
     a mais recente.

   Em poucos minutos, toda execução do `alloyctl` no canal `stable` passa
   para a versão nova.

Versão com sufixo (`1.2.0-rc.1`) vira pre-release: não entra no `stable`, mas
pode ser testada com `alloyctl --ref v1.2.0-rc.1`.

A release é só a tag com as notas: nenhum pacote é anexado nem usado pelas
máquinas. Os arquivos continuam vindo de
`raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/vX.Y.Z/`.

## Atualizar a versão do Alloy

1. O Dependabot abre um PR mudando o `alloy.Dockerfile` (toda segunda-feira,
   quando houver versão nova). A CI valida os `.alloy` com a imagem nova.
2. Teste numa máquina de cada sistema com `alloyctl --ref <branch do PR>` e
   **[3] Atualizar Alloy**.
3. Merge e release PATCH (ou MINOR, se a versão do Alloy trouxer mudança de
   comportamento), com a nota **"exige [3] Atualizar Alloy"**.
4. As máquinas só mudam de versão quando alguém executa **[3] Atualizar
   Alloy** (ou `alloyctl upgrade`). O diagnóstico marca as que ficaram para
   trás.

## Voltar uma versão

- **Rápido**: na página da release anterior, *Edit* → marque **Set as the
  latest release**. O `stable` passa a apontar para ela na execução seguinte
  de cada máquina. Depois corrija e publique uma versão PATCH nova.
- **Uma máquina só**: `alloyctl --ref vX.Y.Z` fixa a versão até voltar com
  `alloyctl --ref stable`.

Não apague nem mova tags publicadas: máquinas com versão fixa e arquivos sob
demanda dependem delas.
