#!/usr/bin/env python3
"""Suite de tests unitarios de las funciones puras del simulador.

Uso:  python3 tests_simulador.py
No toca red ni archivos de resultados — seguro de correr en cualquier momento,
incluso con una corrida activa.
"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "sim", Path(__file__).parent / "simulador_worker.py")
sim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sim)

# --- calculadora segura (tool Calculator del agente) ---
assert sim.calculadora("1.2 * 1000") == "1200"
assert sim.calculadora("(75 - 32) * 5 / 9").startswith("23.88")
assert sim.calculadora("96 * 3600") == "345600"
assert "error" in sim.calculadora('__import__("os").system("id")')

# --- flatten specs (puerto del nodo n8n) ---
f = sim.flatten_specs([
    {"name": "Peso", "value": "1.2 kg", "section": "Fis"},
    {"name": "X", "items": ["a", "b"]},
    {"name": "", "value": "z"},
    {"name": "vacio", "value": "  "}])
assert f == [{"name": "Peso", "value": "1.2 kg", "section": "Fis"},
             {"name": "X", "value": "a | b"}], f

# --- higiene §10: colapso single-numeric, dedup, rechazo de mixtos/objetos ---
limpio, viol = sim.higiene_output(
    {"a_w": [125], "malo": [{"x": 1}], "b": None, "certs": ["CE", "CE"],
     "mixto": ["a", 1], "nums": [10, 100, 1000]})
assert limpio == {"a_w": 125, "certs": ["CE"], "nums": [10, 100, 1000]}, (limpio, viol)
assert any("array_tipo_invalido:malo" in v for v in viol), viol
assert any("array_tipo_invalido:mixto" in v for v in viol), viol

# --- parse laxo: fences y JSON embebido ---
assert sim.parse_laxo('```json\n{"output":{}}\n```') == {"output": {}}
assert sim.parse_laxo('bla {"a":1} bla') == {"a": 1}
assert sim.parse_laxo("sin json") is None

# --- post-proceso: contrato, recuperación segura, estados review ---
r = sim.post_proceso('{"audit_trace":{},"output":{"weight_g":100},'
                     '"keys_context":{"weight_g":{"shape":"scalar","desc":"w"}}}')
assert r["status"] == "ok" and r["specs_normalized"] == {"weight_g": 100}
r = sim.post_proceso('{"audit_trace":{"unmapped_specs":[]},"keys_context":{},'
                     '"respuesta":{"weight_g":100}}')
assert r["status"] == "ok" and r["specs_normalized"] == {"weight_g": 100}, r
assert any("output_recuperado" in x for x in r["auto_fixes"])
r = sim.post_proceso("no es json")
assert r["status"] == "review" and r["error_type"] == "invalid_json"
r = sim.post_proceso('{"audit_trace":{},"output":{},"keys_context":{}}')
assert r["status"] == "review" and r["error_type"] == "empty_normalization"

# --- derivación de shapes (como la vista category_keys_context) ---
assert sim.derivar_shape("t_min_c", -40, {"t_min_c", "t_max_c"}) == "range"
assert sim.derivar_shape("vswr_max", 2, {"vswr_max"}) == "scalar"
assert sim.derivar_shape("speeds_mbps", [10, 100], {"speeds_mbps"}) == "numeric_array"
assert sim.derivar_shape("_notes", ["a b c"], {"_notes"}) == "narrative"
assert sim.derivar_shape("certs", ["ce"], {"certs"}) == "enum"
assert sim.derivar_shape("has_wifi", True, {"has_wifi"}) == "boolean"

# --- diccionario evolutivo de la categoría ---
ctx = sim.ContextoCategoria()
nuevas = ctx.actualizar(1, {"weight_g": 100},
                        {"weight_g": {"shape": "scalar", "desc": "device weight"}})
assert nuevas == ["weight_g"] and ctx.claves["weight_g"]["n"] == 1
ctx.actualizar(2, {"weight_g": 200, "leds": ["power"]}, {})
assert ctx.claves["weight_g"]["n"] == 2 and ctx.claves["weight_g"]["example"] == 200
assert ctx.claves["weight_g"]["desc"] == "device weight"
assert len(ctx.historial) == 2

print("✓ todos los tests unitarios OK")
