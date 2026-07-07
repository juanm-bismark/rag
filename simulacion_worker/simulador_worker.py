#!/usr/bin/env python3
"""Simulador del worker de normalización de specs (WORKER_CATEGORIAS_N8N).

Reproduce el flujo real del worker, por modelo:
  dispatcher → categorías en PARALELO → por categoría, producto a producto:
    flatten specs → build LLM input (con keys_context evolutivo) →
    agente LLM + tool Calculator (máx 20 iteraciones, como el nodo n8n) →
    post-proceso (parse laxo + contrato de 3 claves + higiene) →
    ok: actualiza el diccionario keys_context de la categoría (n/example
        derivados + shape recomputado + desc del LLM, como la vista
        category_keys_context) | review: se registra sin tocar el contexto.

Solo stdlib — corre en el servidor con python3 pelado. Sin LangChain:
el "agente" es este loop de ~40 líneas contra /api/chat de Ollama.

Uso:
  # correr (reanudable; escribe resultados_<modelo>.jsonl)
  python3 simulador_worker.py correr --modelos qwen2.5:3b,granite4:micro-h \
      [--categorias 1630,1599] [--limit N] [--paralelo 2] [--host URL]

  # comparar contra backup y entre modelos
  python3 simulador_worker.py comparar --modelos qwen2.5:3b,granite4:micro-h
"""
import argparse
import ast
import json
import operator
import re
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

AQUI = Path(__file__).parent
LOCK_PRINT = threading.Lock()


def log(*a):
    with LOCK_PRINT:
        print(*a, flush=True)


def leer_env(path):
    env = {}
    p = Path(path)
    if p.exists():
        for linea in p.read_text().splitlines():
            linea = linea.strip()
            if linea and not linea.startswith("#") and "=" in linea:
                k, _, v = linea.partition("=")
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ---------------------------------------------------------------- Calculator
OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
       ast.Div: operator.truediv, ast.Pow: operator.pow,
       ast.USub: operator.neg, ast.UAdd: operator.pos, ast.Mod: operator.mod}


def calculadora(expr):
    """Evalúa aritmética de forma segura (equivalente al toolCalculator de n8n)."""
    def ev(n):
        if isinstance(n, ast.Expression):
            return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return n.value
        if isinstance(n, ast.BinOp) and type(n.op) in OPS:
            return OPS[type(n.op)](ev(n.left), ev(n.right))
        if isinstance(n, ast.UnaryOp) and type(n.op) in OPS:
            return OPS[type(n.op)](ev(n.operand))
        raise ValueError(f"expresión no permitida: {ast.dump(n)}")
    try:
        r = ev(ast.parse(expr.strip(), mode="eval"))
        if isinstance(r, float) and r.is_integer():
            r = int(r)
        return str(r)
    except Exception as e:
        return f"error: {e}"


TOOL_CALCULATOR = [{
    "type": "function",
    "function": {
        "name": "calculator",
        "description": "Evaluates a plain arithmetic expression, e.g. '1.2 * 1000'. Returns the numeric result.",
        "parameters": {
            "type": "object",
            "properties": {"input": {"type": "string",
                                     "description": "arithmetic expression"}},
            "required": ["input"],
        },
    },
}]


# ------------------------------------------------------- nodos del worker n8n
def flatten_specs(raw):
    """Puerto fiel del nodo `flatten specs`."""
    out = []
    for s in raw or []:
        spec = None
        v = s.get("value")
        if v is not None and str(v).strip() != "":
            spec = {"name": str(s.get("name", "")).strip(),
                    "value": str(v).strip()}
        elif isinstance(s.get("items"), list) and s["items"]:
            spec = {"name": str(s.get("name", "")).strip(),
                    "value": " | ".join(x.strip() for x in s["items"]
                                        if isinstance(x, str) and x.strip())}
        if spec and spec["name"] and spec["value"]:
            sec = s.get("section")
            if sec is not None and str(sec).strip():
                spec["section"] = str(sec).strip()
            out.append(spec)
    return out


def build_llm_input(category_name, specs, keys_context):
    """Puerto fiel del nodo `build LLM input`."""
    llm_input = {}
    if category_name:
        llm_input["category_name"] = category_name
    if specs:
        llm_input["specs"] = specs
    llm_input["keys_context"] = keys_context if isinstance(keys_context, dict) else {}
    return json.dumps(llm_input, ensure_ascii=False)


def parse_laxo(texto):
    """Puerto de tryParseLoose del nodo post-OpenAI."""
    if not isinstance(texto, str):
        return None
    t = texto.strip()
    m = re.match(r"^```(?:json)?\s*([\s\S]*?)\s*```$", t, re.IGNORECASE)
    if m:
        t = m.group(1).strip()
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        pass
    a, b = t.find("{"), t.rfind("}")
    if a != -1 and b > a:
        try:
            return json.loads(t[a:b + 1])
        except json.JSONDecodeError:
            return None
    return None


def es_obj(x):
    return isinstance(x, dict)


def higiene_output(output):
    """Chequeos de §10 (versión lite del post-OpenAI): devuelve (limpio, violaciones)."""
    limpio, violaciones = {}, []
    if not es_obj(output):
        return {}, ["output_no_es_objeto"]
    for k, v in output.items():
        if not re.fullmatch(r"_?[a-z0-9_]+", str(k)):
            violaciones.append(f"clave_invalida:{k}")
            continue
        if v is None or v == "" or v == [] or es_obj(v):
            violaciones.append(f"valor_invalido:{k}")
            continue
        if isinstance(v, list):
            v = [x for x in v if x not in (None, "")]
            if not v:
                violaciones.append(f"array_vacio:{k}")
                continue
            tipos = {type(x) in (int, float) for x in v}
            if len(tipos) > 1:
                violaciones.append(f"array_mixto:{k}")
                continue
            vistos, dedup = set(), []
            for x in v:
                marca = json.dumps(x, ensure_ascii=False)
                if marca not in vistos:
                    vistos.add(marca)
                    dedup.append(x)
            v = dedup
            if len(v) == 1 and isinstance(v[0], (int, float)) and not isinstance(v[0], bool):
                v = v[0]  # colapso de array numérico de un elemento (§ex1)
        limpio[k] = v
    return limpio, violaciones


def derivar_shape(clave, valor, todas_las_claves):
    """Recomputa shape como lo hace la vista (downstream siempre recalcula)."""
    if isinstance(valor, bool):
        return "boolean"
    if isinstance(valor, (int, float)):
        m = re.match(r"^(.*)_(min|max)(_[a-z]+)?$", clave)
        if m:
            otro = f"{m.group(1)}_{'max' if m.group(2) == 'min' else 'min'}{m.group(3) or ''}"
            if otro in todas_las_claves:
                return "range"
        return "scalar"
    if isinstance(valor, list):
        if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in valor):
            return "numeric_array"
        return "narrative" if clave.startswith("_") else "enum"
    return "scalar"


class ContextoCategoria:
    """El diccionario evolutivo de claves de la categoría (vista category_keys_context)."""

    def __init__(self):
        self.claves = {}          # key -> {n, example, shape, desc}
        self.historial = []       # evolución: por producto, claves nuevas/actualizadas

    def actualizar(self, product_id, output, keys_context_llm):
        nuevas, tocadas = [], []
        for k, v in output.items():
            entrada = self.claves.get(k)
            if entrada is None:
                entrada = {"n": 0, "example": None}
                self.claves[k] = entrada
                nuevas.append(k)
            else:
                tocadas.append(k)
            entrada["n"] += 1
            entrada["example"] = v
            entrada["shape"] = derivar_shape(k, v, output.keys())
            desc = (keys_context_llm or {}).get(k, {}).get("desc")
            if isinstance(desc, str) and desc.strip() and len(desc.split()) <= 8:
                entrada["desc"] = desc.strip()
        self.historial.append({"product_id": product_id,
                               "claves_nuevas": nuevas,
                               "claves_actualizadas": tocadas,
                               "total_claves": len(self.claves)})
        return nuevas


# ------------------------------------------------------------------- agente
def llamar_ollama(host, payload, timeout):
    req = urllib.request.Request(
        f"{host}/api/chat", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def agente(host, modelo, system, user, timeout, max_iter=20):
    """El AI Agent de n8n: loop de tool-calling con Calculator hasta respuesta final."""
    mensajes = [{"role": "system", "content": system},
                {"role": "user", "content": user}]
    stats = {"iteraciones": 0, "llamadas_calculator": 0,
             "prompt_tokens": 0, "out_tokens": 0, "wall_s": 0.0}
    for _ in range(max_iter):
        stats["iteraciones"] += 1
        t0 = time.time()
        r = llamar_ollama(host, {
            "model": modelo, "messages": mensajes, "tools": TOOL_CALCULATOR,
            "stream": False,
            "options": {"temperature": 0, "num_ctx": 16384, "num_predict": 4096},
        }, timeout)
        stats["wall_s"] += time.time() - t0
        stats["prompt_tokens"] = r.get("prompt_eval_count", 0)
        stats["out_tokens"] += r.get("eval_count", 0)
        msg = r.get("message", {})
        llamadas = msg.get("tool_calls") or []
        if not llamadas:
            return msg.get("content") or "", stats
        mensajes.append(msg)
        for c in llamadas:
            args = c.get("function", {}).get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {"input": args}
            expr = str(args.get("input") or args.get("expression") or "")
            stats["llamadas_calculator"] += 1
            mensajes.append({"role": "tool", "content": calculadora(expr)})
    return "", stats  # agotó iteraciones


def post_proceso(texto):
    """Versión lite del nodo post-OpenAI: contrato + higiene + estado."""
    parsed = parse_laxo(texto)
    if not es_obj(parsed):
        return {"status": "review", "error_type": "invalid_json",
                "raw_preview": (texto or "")[:400]}
    fixes = []
    esperadas = {"audit_trace", "output", "keys_context"}
    if set(parsed.keys()) != esperadas:
        fixes.append("contract_deviation_recovered:" +
                     "+".join(sorted(parsed.keys())[:6]))
    output = parsed.get("output") if es_obj(parsed.get("output")) else None
    if output is None:  # recuperación: única clave-objeto que parezca specs
        candidatos = [v for v in parsed.values()
                      if es_obj(v) and v and not es_obj(next(iter(v.values()), None))]
        output = candidatos[0] if len(candidatos) == 1 else {}
        fixes.append("output_recuperado")
    limpio, violaciones = higiene_output(output)
    if not limpio:
        return {"status": "review", "error_type": "empty_normalization",
                "auto_fixes": fixes, "violaciones": violaciones,
                "raw_preview": (texto or "")[:400]}
    return {"status": "ok",
            "specs_normalized": limpio,
            "keys_context_llm": parsed.get("keys_context")
            if es_obj(parsed.get("keys_context")) else {},
            "audit_trace": parsed.get("audit_trace")
            if es_obj(parsed.get("audit_trace")) else {},
            "auto_fixes": fixes, "violaciones": violaciones}


# ------------------------------------------------------------------- corrida
def slug_modelo(modelo):
    return re.sub(r"[^a-z0-9]+", "-", modelo.lower())


def archivo_resultados(modelo):
    return AQUI / f"resultados_{slug_modelo(modelo)}.jsonl"


def exportar_normalizado(modelo):
    """Escribe normalizado_<modelo>.json: {product_id: specs_normalized},
    misma forma que backup_normalizado.json → comparable 1:1 con el backup
    y entre modelos. Las filas en review van aparte en *_review.json."""
    _, filas = cargar_hechos(modelo)
    ok, review = {}, {}
    for fila in filas:
        pid = str(fila["product_id"])
        if fila.get("status") == "ok":
            ok[pid] = fila["specs_normalized"]
        else:
            review[pid] = {"slug": fila.get("slug"),
                           "error_type": fila.get("error_type"),
                           "category_id": fila.get("category_id")}
    ruta = AQUI / f"normalizado_{slug_modelo(modelo)}.json"
    ruta.write_text(json.dumps(dict(sorted(ok.items(), key=lambda x: int(x[0]))),
                               ensure_ascii=False, indent=1))
    if review:
        (AQUI / f"normalizado_{slug_modelo(modelo)}_review.json").write_text(
            json.dumps(review, ensure_ascii=False, indent=1))
    return ruta, len(ok), len(review)


def cargar_hechos(modelo):
    """Para reanudar: product_ids ya procesados y filas previas por categoría."""
    hechos, filas = set(), []
    ruta = archivo_resultados(modelo)
    if ruta.exists():
        for linea in ruta.read_text().splitlines():
            try:
                fila = json.loads(linea)
            except json.JSONDecodeError:
                continue
            hechos.add(fila["product_id"])
            filas.append(fila)
    return hechos, filas


def correr_categoria(host, modelo, system, categoria, hechos, filas_previas,
                     limit, timeout, escribir):
    ctx = ContextoCategoria()
    # reconstruir contexto desde corrida previa (en orden) para reanudar fiel
    for fila in filas_previas:
        if fila.get("category_id") == categoria["category_id"] and fila.get("status") == "ok":
            ctx.actualizar(fila["product_id"], fila["specs_normalized"],
                           fila.get("keys_context_llm"))
    procesados = 0
    for prod in categoria["productos"]:
        if limit and procesados >= limit:
            break
        if prod["id"] in hechos:
            continue
        procesados += 1
        specs = flatten_specs(prod["specs"])
        entrada = build_llm_input(categoria["category_name"], specs, ctx.claves)
        t0 = time.time()
        try:
            texto, stats = agente(host, modelo, system, entrada, timeout)
            res = post_proceso(texto)
        except Exception as e:
            res = {"status": "review", "error_type": "excepcion", "error_detail": str(e)}
            stats = {}
        fila = {"modelo": modelo, "category_id": categoria["category_id"],
                "category_name": categoria["category_name"],
                "product_id": prod["id"], "slug": prod["slug"],
                "n_specs_crudas": len(specs),
                "wall_s": round(time.time() - t0, 1), **stats, **res}
        if res["status"] == "ok":
            nuevas = ctx.actualizar(prod["id"], res["specs_normalized"],
                                    res.get("keys_context_llm"))
            fila["claves_emitidas"] = len(res["specs_normalized"])
            fila["claves_nuevas_en_contexto"] = len(nuevas)
            fila["contexto_categoria_total"] = len(ctx.claves)
        escribir(fila)
        log(f"[{modelo}] cat {categoria['category_id']} {prod['slug']}: "
            f"{res['status']} | {fila['wall_s']}s | "
            f"claves={fila.get('claves_emitidas', '-')} | "
            f"ctx={len(ctx.claves)} | iter={stats.get('iteraciones', '-')} "
            f"calc={stats.get('llamadas_calculator', '-')}")
    # snapshot final del diccionario de la categoría
    ruta_ctx = AQUI / (f"contexto_{re.sub(r'[^a-z0-9]+', '-', modelo.lower())}"
                       f"_cat{categoria['category_id']}.json")
    ruta_ctx.write_text(json.dumps(
        {"claves": ctx.claves, "historial": ctx.historial},
        ensure_ascii=False, indent=1))


def cmd_correr(args):
    env = leer_env(args.env)
    host = (args.host or env.get("OLLAMA_REMOTE_HOST")
            or "http://localhost:11434").rstrip("/")
    if not host.startswith("http"):
        host = "http://" + host
    if not re.search(r":\d+$", host):
        host += ":11434"
    datos = json.loads((AQUI / "input_productos.json").read_text())
    system = Path(args.prompt).read_text()
    categorias = datos["categorias"]
    if args.categorias:
        quiero = {int(x) for x in args.categorias.split(",")}
        categorias = [c for c in categorias if c["category_id"] in quiero]
    log(f"Host: {host} | modelos: {args.modelos} | categorías: "
        f"{[c['category_id'] for c in categorias]} | limit/cat: {args.limit or '∞'}")
    for modelo in args.modelos.split(","):
        modelo = modelo.strip()
        hechos, filas_previas = cargar_hechos(modelo)
        if hechos:
            log(f"[{modelo}] reanudando: {len(hechos)} productos ya procesados")
        lock = threading.Lock()
        ruta = archivo_resultados(modelo)

        def escribir(fila):
            with lock:
                with ruta.open("a") as f:
                    f.write(json.dumps(fila, ensure_ascii=False) + "\n")

        t0 = time.time()
        with ThreadPoolExecutor(max_workers=args.paralelo) as pool:
            futuros = [pool.submit(correr_categoria, host, modelo, system, c,
                                   hechos, filas_previas, args.limit,
                                   args.timeout, escribir)
                       for c in categorias]
            for f in futuros:
                f.result()
        ruta_norm, n_ok, n_rev = exportar_normalizado(modelo)
        log(f"[{modelo}] listo en {round((time.time() - t0) / 60, 1)} min "
            f"→ {ruta.name} | exportado {ruta_norm.name} (ok={n_ok}, review={n_rev})")


# ---------------------------------------------------------------- comparación
def valores_iguales(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b or a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))
    if isinstance(a, list) and isinstance(b, list):
        na = sorted(json.dumps(x, ensure_ascii=False).lower() for x in a)
        nb = sorted(json.dumps(x, ensure_ascii=False).lower() for x in b)
        return na == nb
    return a == b


def cmd_comparar(args):
    backup = {int(k): v for k, v in json.loads(
        (AQUI / "backup_normalizado.json").read_text()).items()}
    lineas = ["# Comparación normalización local vs backup (GPT producción)", ""]
    resumen_modelos = {}
    for modelo in args.modelos.split(","):
        modelo = modelo.strip()
        _, filas = cargar_hechos(modelo)
        if not filas:
            log(f"[{modelo}] sin resultados aún")
            continue
        exportar_normalizado(modelo)  # regenera normalizado_<modelo>.json (aun parcial)
        agg = {"productos": 0, "ok": 0, "review": 0, "claves_backup": 0,
               "claves_sim": 0, "comunes": 0, "valor_igual": 0}
        detalles = []
        for fila in filas:
            pid = fila["product_id"]
            agg["productos"] += 1
            if fila["status"] != "ok":
                agg["review"] += 1
                detalles.append((pid, fila.get("slug", ""), "REVIEW",
                                 fila.get("error_type", ""), "", ""))
                continue
            agg["ok"] += 1
            obj = backup.get(pid, {})
            sim = fila["specs_normalized"]
            comunes = set(obj) & set(sim)
            iguales = sum(1 for k in comunes if valores_iguales(obj[k], sim[k]))
            agg["claves_backup"] += len(obj)
            agg["claves_sim"] += len(sim)
            agg["comunes"] += len(comunes)
            agg["valor_igual"] += iguales
            detalles.append((
                pid, fila.get("slug", ""),
                f"{len(comunes)}/{len(obj)} claves del backup presentes",
                f"{iguales}/{len(comunes) or 1} valores idénticos",
                f"solo_backup={sorted(set(obj) - set(sim))[:8]}",
                f"solo_sim={sorted(set(sim) - set(obj))[:8]}"))
        cob = agg["comunes"] / agg["claves_backup"] * 100 if agg["claves_backup"] else 0
        exact = agg["valor_igual"] / agg["comunes"] * 100 if agg["comunes"] else 0
        resumen_modelos[modelo] = (agg, cob, exact)
        lineas += [f"## {modelo}", "",
                   f"- Productos: {agg['productos']} (ok={agg['ok']}, review={agg['review']})",
                   f"- Cobertura de claves del backup: {agg['comunes']}/{agg['claves_backup']} = **{cob:.1f}%**",
                   f"- Valores idénticos en claves comunes: {agg['valor_igual']}/{agg['comunes']} = **{exact:.1f}%**",
                   f"- Claves emitidas vs backup: {agg['claves_sim']} vs {agg['claves_backup']}", "",
                   "| producto | slug | cobertura | exactitud | solo backup | solo sim |",
                   "|---|---|---|---|---|---|"]
        for d in detalles:
            lineas.append("| " + " | ".join(str(x) for x in d) + " |")
        lineas.append("")
    # ------- comparación entre modelos (pares) -------
    modelos = [m.strip() for m in args.modelos.split(",")]
    normalizados = {}
    for m in modelos:
        _, filas = cargar_hechos(m)
        normalizados[m] = {f["product_id"]: f["specs_normalized"]
                           for f in filas if f.get("status") == "ok"}
    for i in range(len(modelos)):
        for j in range(i + 1, len(modelos)):
            a, b = modelos[i], modelos[j]
            comunes_pid = set(normalizados.get(a, {})) & set(normalizados.get(b, {}))
            if not comunes_pid:
                continue
            tot_a = tot_b = tot_comunes = tot_igual = 0
            divergencias = []
            for pid in sorted(comunes_pid):
                sa, sb = normalizados[a][pid], normalizados[b][pid]
                comunes = set(sa) & set(sb)
                iguales = sum(1 for k in comunes if valores_iguales(sa[k], sb[k]))
                tot_a += len(sa); tot_b += len(sb)
                tot_comunes += len(comunes); tot_igual += iguales
                distintas = [k for k in comunes if not valores_iguales(sa[k], sb[k])]
                if distintas or set(sa) != set(sb):
                    divergencias.append(
                        f"| {pid} | {len(comunes)} | {len(distintas)} "
                        f"| {sorted(set(sa) - set(sb))[:5]} | {sorted(set(sb) - set(sa))[:5]} |")
            acuerdo = tot_igual / tot_comunes * 100 if tot_comunes else 0
            lineas += [f"## Entre modelos: {a} vs {b}", "",
                       f"- Productos comparables (ok en ambos): {len(comunes_pid)}",
                       f"- Claves emitidas: {a}={tot_a} | {b}={tot_b} | en común={tot_comunes}",
                       f"- Acuerdo de valores en claves comunes: {tot_igual}/{tot_comunes} = **{acuerdo:.1f}%**", "",
                       f"| producto | claves comunes | valores distintos | solo {a} | solo {b} |",
                       "|---|---|---|---|---|"] + divergencias + [""]
    ruta = AQUI / "comparacion_normalizacion.md"
    ruta.write_text("\n".join(lineas))
    log(f"✓ {ruta.name}")
    for m, (agg, cob, exact) in resumen_modelos.items():
        log(f"  {m}: ok={agg['ok']}/{agg['productos']} | cobertura {cob:.1f}% | exactitud {exact:.1f}%")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("correr")
    c.add_argument("--modelos", default="qwen2.5:3b,granite4:micro-h")
    c.add_argument("--categorias", help="ids separados por coma")
    c.add_argument("--limit", type=int, help="máx productos por categoría")
    c.add_argument("--paralelo", type=int, default=2)
    c.add_argument("--host")
    c.add_argument("--env", default=str(AQUI.parent / ".env"))
    c.add_argument("--prompt", default=str(AQUI.parent / "PROMPT_NORMALIZACION.md"))
    c.add_argument("--timeout", type=int, default=3000)
    c.set_defaults(fn=cmd_correr)
    d = sub.add_parser("comparar")
    d.add_argument("--modelos", default="qwen2.5:3b,granite4:micro-h")
    d.set_defaults(fn=cmd_comparar)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
