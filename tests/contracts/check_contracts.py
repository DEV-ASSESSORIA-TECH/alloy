#!/usr/bin/env python3
"""Confere o que o Alloy produz contra os contratos do repositorio grafana.

Os contratos ficam no repositorio que os consome (DEV-ASSESSORIA-TECH/grafana,
contracts/): e la que alertas e paineis quebram se o formato mudar. Este
script nao copia nada: baixa os contratos da main do grafana (ou le de uma
pasta local com --contracts) e falha quando o produtor diverge:

1. job: cada contrato produzido pelo Alloy tem o job escrito nos .alloy
   correspondentes (PRODUCED abaixo).
2. metricas dos coletores: o que o coletor gera e o que o contrato descreve
   sao o mesmo conjunto de nomes.
3. heartbeat: linhas geradas pelo heartbeat.py (cenarios simulados) e os
   campos/rotulos do heartbeat.ps1 seguem contracts/loki/heartbeat.yml.
4. backups: o leitor (backup.alloy) usa o job e as pastas do contrato.

Uso: python3 tests/contracts/check_contracts.py [--contracts DIR] [--ref main]
"""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
RAW = "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/grafana/{ref}/contracts/{name}"

# Contrato -> arquivos do Alloy que publicam aquele job.
PRODUCED = {
    "loki/docker.yml": ["linux/modules/docker.alloy"],
    "loki/hyperv.yml": ["windows/modules/hyperv.alloy"],
    "loki/linux.yml": ["linux/modules/config.alloy"],
    "loki/mysql.yml": ["windows/modules/mysql.alloy"],
    "loki/windows-desktop.yml": ["windows/modules/desktop.alloy"],
    "loki/windows.yml": ["windows/modules/config.alloy"],
    "prometheus/backup.yml": ["linux/modules/backup.alloy", "windows/modules/backup.alloy"],
    "prometheus/docker.yml": ["linux/modules/docker.alloy"],
    "prometheus/hyperv.yml": ["windows/modules/hyperv.alloy"],
    "prometheus/hypervisor.yml": ["windows/modules/hyperv.alloy"],
    "prometheus/linux.yml": ["linux/modules/config.alloy"],
    "prometheus/mysql.yml": ["windows/modules/mysql.alloy"],
    "prometheus/sqlanywhere.yml": ["windows/modules/sqlanywhere.alloy"],
    "prometheus/windows-desktop.yml": ["windows/modules/desktop.alloy"],
    "prometheus/windows.yml": ["windows/modules/config.alloy"],
}
# Contrato -> (coletor, prefixo das metricas).
COLLECTORS = {
    "prometheus/sqlanywhere.yml": ("windows/collectors/sqlanywhere-collector.ps1", "sqlanywhere_"),
    "prometheus/hypervisor.yml": ("windows/collectors/hypervisor-inventory.ps1", "hypervisor_"),
}
HEARTBEAT = "loki/heartbeat.yml"
OLD_SOURCE = re.compile(r"scripts[/ ]+monitoring/alloy")

errors = []
warnings = []


def load(args, name):
    if args.contracts:
        text = (pathlib.Path(args.contracts) / name).read_text(encoding="utf-8")
    else:
        url = RAW.format(ref=args.ref, name=name)
        try:
            with urllib.request.urlopen(url, timeout=20) as response:
                text = response.read().decode("utf-8")
        except OSError as exc:
            errors.append(f"{name}: nao foi possivel ler o contrato ({exc})")
            return None
    if OLD_SOURCE.search(text):
        warnings.append(f"{name}: o texto ainda aponta para scripts/monitoring/alloy (agora DEV-ASSESSORIA-TECH/alloy)")
    return text


def metric_names(text, prefix):
    # Nomes terminados em "_" sao prefixos citados em comentario (ex. sqlanywhere_*).
    return {m for m in re.findall(rf"\b({re.escape(prefix)}[a-z0-9_]+)\b", text) if not m.endswith("_")}


def check_jobs(args):
    for name, files in PRODUCED.items():
        text = load(args, name)
        if text is None:
            continue
        job = (yaml.safe_load(text) or {}).get("job")
        if not job:
            errors.append(f"{name}: contrato sem job")
            continue
        for rel in files:
            if f'"{job}"' not in (ROOT / rel).read_text(encoding="utf-8"):
                errors.append(f"{rel}: job \"{job}\" do contrato {name} nao aparece")


def check_collectors(args):
    for name, (rel, prefix) in COLLECTORS.items():
        text = load(args, name)
        if text is None:
            continue
        # Metricas descritas: listas metrics_* de metric_groups (o resto do
        # texto cita nomes como valores, ex. instance_means).
        groups = (yaml.safe_load(text) or {}).get("metric_groups") or {}
        documented = {
            metric for group in groups.values() if isinstance(group, dict)
            for key, values in group.items() if key.startswith("metrics_") and isinstance(values, list)
            for metric in values if isinstance(metric, str) and metric.startswith(prefix)
        }
        produced = metric_names((ROOT / rel).read_text(encoding="utf-8"), prefix)
        for metric in sorted(produced - documented):
            errors.append(f"{rel}: {metric} nao esta no contrato {name}")
        for metric in sorted(documented - produced):
            errors.append(f"{name}: {metric} nao e gerada por {rel}")


def load_heartbeat_py():
    path = ROOT / "linux/heartbeat/heartbeat.py"
    spec = importlib.util.spec_from_file_location("heartbeat", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def heartbeat_scenarios(hb):
    """Linhas logfmt do heartbeat.py para cada estado, sem systemd nem rede."""
    metrics = "\n".join([
        "prometheus_remote_storage_queue_highest_sent_timestamp_seconds{x=\"a\"} 1700000000",
        "prometheus_remote_storage_samples_failed_total 3",
        "loki_write_sent_entries_total 10",
        "loki_write_dropped_entries_total 0",
    ])
    scenarios = {
        "ausente": ({"LoadState": "not-found"}, {}),
        "parado": ({"LoadState": "loaded", "active": "inactive"}, {}),
        "ok": ({"LoadState": "loaded", "active": "active"},
               {"/-/ready": (200, ""), "/-/healthy": (200, ""), "/metrics": (200, metrics)}),
        "degradado": ({"LoadState": "loaded", "active": "active"},
                      {"/-/ready": (200, ""), "/-/healthy": (500, "unhealthy components: loki.write.central"),
                       "/metrics": (200, metrics)}),
        "nao_pronto": ({"LoadState": "loaded", "active": "active"},
                       {"/-/ready": (503, ""), "/-/healthy": (200, ""), "/metrics": (200, "")}),
    }
    lines = {}
    for expected, (systemd, http) in scenarios.items():
        def run(*args, systemd=systemd):
            if args[:2] == ("systemctl", "show"):
                return systemd["LoadState"]
            if args[:2] == ("systemctl", "is-active"):
                return systemd["active"]
            if args[0] == "dpkg-query":
                return "1.19.2"
            return ""
        hb.run = run
        hb.local_get = lambda path, http=http: http.get(path, (0, ""))
        hb.time.time = lambda: 1700000100.0
        lines[expected] = hb.logfmt(hb.collect_state())
    return lines


def parse_logfmt(line):
    return dict(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\S*)', line))


def check_heartbeat(args):
    text = load(args, HEARTBEAT)
    if text is None:
        return
    contract = yaml.safe_load(text)
    fields = contract["expected_configuration"]["fields"]
    allowed = {
        name: set(spec["values"]) if isinstance(spec.get("values"), (list, dict)) else None
        for name, spec in fields.items()
    }
    always = {name for name, spec in fields.items() if spec.get("always")}
    job = contract["job"]
    os_values = set(contract["identity"]["label_values"]["os"])
    required_labels = set(contract["identity"]["required_labels"])

    # Linux: comportamento real do heartbeat.py.
    hb = load_heartbeat_py()
    for expected, line in heartbeat_scenarios(hb).items():
        where = f"heartbeat.py (cenario {expected})"
        if not line.isascii():
            errors.append(f"{where}: linha fora do ASCII: {line}")
        values = parse_logfmt(line)
        for name in sorted(set(values) - set(fields)):
            errors.append(f"{where}: campo {name} nao esta no contrato")
        for name in sorted(always - set(values)):
            errors.append(f"{where}: campo obrigatorio {name} ausente")
        for name, value in values.items():
            if allowed.get(name) is not None and value.strip('"') not in allowed[name]:
                errors.append(f"{where}: {name}={value} fora dos valores do contrato")
        if values.get("alloy") != expected:
            errors.append(f"{where}: esperado alloy={expected}, gerado {values.get('alloy')}")
    captured = {}
    secret = tempfile.NamedTemporaryFile("w", delete=False)
    secret.write("x")
    secret.close()
    hb.SECRET_FILE = secret.name
    hb.access_token = lambda fresh: ("token", "")
    hb.http = lambda opener, url, data=None, headers=None, timeout=10: (captured.update(body=data) or (204, ""))
    hb.send_loki("srv-exemplo", "alloy=ok service=running")
    os.unlink(secret.name)
    stream = json.loads(captured["body"])["streams"][0]["stream"]
    if set(stream) != required_labels or stream.get("job") != job or stream.get("os") not in os_values:
        errors.append(f"heartbeat.py: rotulos do stream {stream} divergem do contrato ({sorted(required_labels)}, job={job})")

    # Windows: campos e rotulos lidos do heartbeat.ps1.
    ps = (ROOT / "windows/heartbeat/heartbeat.ps1").read_text(encoding="utf-8")
    ps_fields = set(re.findall(r"\$state\.([a-z_]+)\s*=", ps)) | set(re.findall(r"@\('([a-z_]+)',\s*'[a-z_]+'\)", ps))
    for name in sorted(ps_fields - set(fields)):
        errors.append(f"heartbeat.ps1: campo {name} nao esta no contrato")
    for name, value in re.findall(r"\$state\.(alloy|service)\s*=\s*'([a-z_]+)'", ps):
        if value not in allowed[name]:
            errors.append(f"heartbeat.ps1: {name}='{value}' fora dos valores do contrato")
    match = re.search(r"stream\s*=\s*\[ordered\]@\{([^}]*)\}", ps)
    labels = dict(re.findall(r"(\w+)\s*=\s*'?([\w$-]+)'?", match.group(1))) if match else {}
    if set(labels) != required_labels or labels.get("job") != job or labels.get("os") not in os_values:
        errors.append(f"heartbeat.ps1: rotulos do stream {labels} divergem do contrato")


def check_backup_reader(args):
    text = load(args, "prometheus/backup.yml")
    if text is None:
        return
    contract = yaml.safe_load(text)
    collection = contract["source"]["collection"]
    write_access = contract["source"]["write_access"]
    common_sh = (ROOT / "linux/lib/common.sh").read_text(encoding="utf-8")
    common_ps = (ROOT / "windows/lib/Common.ps1").read_text(encoding="utf-8")
    linux_dir = re.search(r"^TEXTFILE_DIR=(\S+)", common_sh, re.M).group(1) + "/backup"
    linux_group = re.search(r"^BACKUP_GROUP=(\S+)", common_sh, re.M).group(1)
    windows_group = re.search(r"^\$BackupWritersGroup\s*=\s*'([^']+)'", common_ps, re.M).group(1)
    if linux_dir not in collection["linux"]:
        errors.append(f"linux/lib/common.sh: pasta de backups {linux_dir} difere do contrato ({collection['linux']})")
    if "textfile\\backup" not in collection["windows"]:
        errors.append(f"windows: pasta textfile\\backup ausente do contrato ({collection['windows']})")
    for group, where in ((linux_group, "linux/lib/common.sh"), (windows_group, "windows/lib/Common.ps1")):
        if group not in write_access:
            errors.append(f"{where}: grupo de escrita '{group}' nao aparece no contrato")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--contracts", help="pasta contracts/ local (padrao: baixar do GitHub)")
    parser.add_argument("--ref", default="main", help="ref do repositorio grafana (padrao: main)")
    args = parser.parse_args()
    check_jobs(args)
    check_collectors(args)
    check_heartbeat(args)
    check_backup_reader(args)
    for message in sorted(set(warnings)):
        print(f"::warning::{message}")
    if errors:
        for message in errors:
            print(f"::error::{message}")
        sys.exit(1)
    print("ok: produtores do Alloy conferem com os contratos")


if __name__ == "__main__":
    main()
