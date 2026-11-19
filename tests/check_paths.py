#!/usr/bin/env python3
"""Confere se todo arquivo que o alloyctl baixa sob demanda existe no repositorio.

O alloyctl baixa os arquivos pelo caminho relativo (ex.: ops/install.sh) a
partir de linux/ ou windows/. Um caminho errado so apareceria numa maquina,
na hora da operacao; aqui falha na CI.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = re.compile(r"""['"]?((?:lib|ops|heartbeat|modules|collectors)/[A-Za-z0-9._-]+\.(?:sh|py|ps1|alloy))['"]?""")
errors = []


def check(os_dir: str, rel: str, origin: str) -> None:
    if not (ROOT / os_dir / rel).is_file():
        errors.append(f"{origin}: {os_dir}/{rel} nao existe")


def scan(os_dir: str, files: list[str]) -> int:
    count = 0
    for name in files:
        text = (ROOT / os_dir / name).read_text(encoding="utf-8")
        for rel in REL.findall(text):
            check(os_dir, rel, f"{os_dir}/{name}")
            count += 1
    return count


total = scan("linux", ["alloy.sh"]) + scan("windows", ["alloy.ps1"])

# Linux: module_file NOME (install.sh) -> modules/NOME
install_sh = (ROOT / "linux/ops/install.sh").read_text(encoding="utf-8")
for name in re.findall(r"^\s*module_file\s+([A-Za-z0-9._-]+)\s*$", install_sh, re.M):
    check("linux", f"modules/{name}", "linux/ops/install.sh")
    total += 1

# Windows: Copy-ModuleFile 'NOME' ou $Variavel (install.ps1) -> modules/ ou collectors/
install_ps1 = (ROOT / "windows/ops/install.ps1").read_text(encoding="utf-8")
variables = dict(re.findall(r"^\$(\w+)\s*=\s*'([A-Za-z0-9._-]+\.(?:ps1|alloy))'", install_ps1, re.M))
for arg in re.findall(r"Copy-ModuleFile\s+('[^']+'|\$\w+)", install_ps1):
    name = arg.strip("'") if arg.startswith("'") else variables.get(arg[1:])
    if not name:
        errors.append(f"windows/ops/install.ps1: Copy-ModuleFile {arg} sem valor conhecido")
        continue
    folder = "modules" if name.endswith(".alloy") else "collectors"
    check("windows", f"{folder}/{name}", "windows/ops/install.ps1")
    total += 1

# Perfis base (install.ps1 le modules\<perfil>.alloy)
for name in re.findall(r"(?:servidor|estacao)\s*=\s*'([A-Za-z0-9._-]+\.alloy)'", install_ps1):
    check("windows", f"modules/{name}", "windows/ops/install.ps1 (perfil)")
    total += 1

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"ok: {total} referencias conferidas")
