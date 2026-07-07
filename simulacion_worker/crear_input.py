#!/usr/bin/env python3
"""Crea los archivos de entrada para el simulador del worker de normalización.

1. `input_productos.json`  — productos SIN normalizar (specs crudas) agrupados
   por categoría, tal como los recibiría el dispatcher del worker.
2. `backup_normalizado.json` — objetivo de comparación, parseado del backup SQL
   (specs_normalized por product_id).

Lee credenciales de un .env (por defecto el del repo, un nivel arriba):
  SUPABASE_URL=...
  SUPABASE_SERVICE_ROLE_KEY=...

Uso:
  python3 crear_input.py [--env ../.env] [--backup ../backup_product_specs_normalized_2026-07-06.sql]
"""
import argparse
import json
import re
import ssl
import sys
import urllib.request
from pathlib import Path

AQUI = Path(__file__).parent


def contexto_ssl_inicial():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


CTX = {"ssl": contexto_ssl_inicial()}


def leer_env(path):
    env = {}
    for linea in Path(path).read_text().splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            k, _, v = linea.partition("=")
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def rest_get(base, key, recurso, params):
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    req = urllib.request.Request(
        f"{base}/rest/v1/{recurso}?{qs}",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Range": "0-9999", "Prefer": "count=exact"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60, context=CTX["ssl"]) as r:
            return json.load(r)
    except urllib.error.URLError as e:
        if isinstance(getattr(e, "reason", None), ssl.SSLCertVerificationError):
            print("AVISO: certificados no disponibles; reintentando sin verificación TLS",
                  file=sys.stderr)
            CTX["ssl"] = ssl._create_unverified_context()
            with urllib.request.urlopen(req, timeout=60, context=CTX["ssl"]) as r:
                return json.load(r)
        raise


def parsear_backup(path):
    """Extrae product_id -> specs_normalized del backup SQL."""
    objetivo = {}
    patron = re.compile(
        r"UPDATE product_specs SET specs_normalized = '(.*?)'::jsonb "
        r"WHERE product_id = (\d+);", re.DOTALL)
    for m in patron.finditer(Path(path).read_text()):
        objetivo[int(m.group(2))] = json.loads(m.group(1).replace("''", "'"))
    return objetivo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=str(AQUI.parent / ".env"))
    ap.add_argument("--backup", default=str(
        AQUI.parent / "backup_product_specs_normalized_2026-07-06.sql"))
    args = ap.parse_args()

    env = leer_env(args.env)
    base, key = env["SUPABASE_URL"].rstrip("/"), env["SUPABASE_SERVICE_ROLE_KEY"]

    print("Consultando Supabase...", flush=True)
    categorias = {c["id"]: c["name"] for c in rest_get(
        base, key, "categories", {"select": "id,name"})}
    productos = {p["id"]: p for p in rest_get(
        base, key, "products", {"select": "id,slug,category_id"})}
    filas = rest_get(base, key, "product_specs", {
        "select": "product_id,specs", "specs": "not.is.null"})

    por_categoria = {}
    total = 0
    for fila in filas:
        specs = fila["specs"]
        if not specs:
            continue
        prod = productos.get(fila["product_id"])
        if not prod:
            continue
        cat_id = prod["category_id"]
        entrada = por_categoria.setdefault(cat_id, {
            "category_id": cat_id,
            "category_name": categorias.get(cat_id, f"cat-{cat_id}"),
            "productos": [],
        })
        entrada["productos"].append({
            "id": prod["id"],
            "slug": prod["slug"],
            "specs": specs,
        })
        total += 1

    for cat in por_categoria.values():
        cat["productos"].sort(key=lambda p: p["id"])

    salida = {"generado": "crear_input.py",
              "categorias": sorted(por_categoria.values(),
                                   key=lambda c: -len(c["productos"]))}
    ruta_input = AQUI / "input_productos.json"
    ruta_input.write_text(json.dumps(salida, ensure_ascii=False, indent=1))
    print(f"✓ {ruta_input.name}: {total} productos en {len(por_categoria)} categorías")
    for c in salida["categorias"]:
        print(f"   {c['category_id']:>5}  {c['category_name']:<40} {len(c['productos'])} productos")

    objetivo = parsear_backup(args.backup)
    ruta_backup = AQUI / "backup_normalizado.json"
    ruta_backup.write_text(json.dumps(
        {str(k): v for k, v in sorted(objetivo.items())},
        ensure_ascii=False, indent=1))
    print(f"✓ {ruta_backup.name}: {len(objetivo)} productos del backup")


if __name__ == "__main__":
    main()
