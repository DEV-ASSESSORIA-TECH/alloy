#!/usr/bin/env python3
"""Notas de uma versao: a secao "## [X.Y.Z]" do CHANGELOG.md, sem o titulo.

Uso: python3 tests/release_notes.py X.Y.Z   (imprime as notas; erro se faltar)
     python3 tests/release_notes.py --check  (a versao do VERSION tem secao)

O workflow Release usa o primeiro modo; a CI usa o segundo, para que um PR que
sobe o VERSION ja traga as notas.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def notes(version):
    lines = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
    out, found = [], False
    for line in lines:
        if line.startswith(f"## [{version}]"):
            found = True
            continue
        if found and (line.startswith("## [") or re.match(r"^\[[^\]]+\]: ", line)):
            break
        if found:
            out.append(line)
    text = "\n".join(out).strip()
    return text if found and text else None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--check":
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?", version):
            sys.exit(f"::error file=VERSION::versao invalida: '{version}'")
        if not notes(version):
            sys.exit(f"::error file=CHANGELOG.md::sem a secao ## [{version}] (VERSION = {version})")
        print(f"ok: VERSION {version} tem notas no CHANGELOG.md")
        return
    text = notes(sys.argv[1])
    if not text:
        sys.exit(f"::error file=CHANGELOG.md::sem a secao ## [{sys.argv[1]}]")
    print(text)


if __name__ == "__main__":
    main()
