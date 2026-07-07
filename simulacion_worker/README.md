# Simulador del worker de normalización

Réplica fiel, fuera de n8n, del flujo `WORKER_CATEGORIAS_N8N`: normaliza las
specs crudas de los 71 productos con modelos locales de Ollama y compara el
resultado contra el backup de producción (generado con GPT) y entre modelos.
Solo librería estándar de Python — corre en el servidor con `python3` pelado,
sin LangChain ni dependencias.

**Qué replica del worker real:** categorías en paralelo → producto a producto
→ `flatten specs` → `build LLM input` con el **diccionario evolutivo de
claves** (`keys_context`, réplica de la vista `category_keys_context`: empieza
vacío por categoría y crece con cada producto OK) → agente LLM con tool
Calculator (máx 20 iteraciones) → post-proceso lite del nodo `post-OpenAI`
(parse laxo, contrato de 3 claves, higiene §10) → ok/review.

## Archivos

| Archivo | Qué es |
|---|---|
| `run_flow.sh` | **El único comando necesario**: verifica, corre todo y compara |
| `simulador_worker.py` | El simulador (subcomandos `correr` y `comparar`) |
| `crear_input.py` | Regenera los datos de entrada desde Supabase (necesita `../.env`) |
| `tests_simulador.py` | Suite de tests unitarios de las funciones puras |
| `input_productos.json` | 71 productos SIN normalizar (8 categorías), del atributo `product_specs.specs` |
| `backup_normalizado.json` | Objetivo de comparación, parseado del backup SQL (el `.sql` original no se toca) |
| `resultados_<modelo>.jsonl` | Salida cruda por intento: métricas, estado, salida del LLM |
| `normalizado_<modelo>.json` | Salida limpia `{product_id: specs}` — misma forma que el backup |
| `contexto_<modelo>_cat<id>.json` | Diccionario evolutivo final + historial por categoría |
| `comparacion_normalizacion.md` | Informe: cada modelo vs backup + modelos entre sí |
| `corrida.log` | Log acumulado (append) de todos los lanzamientos |

## Uso

```bash
./run_flow.sh --check   # verificar entorno sin lanzar (5 s)
./run_flow.sh           # TODO el flujo en background (nohup), reanudable
tail -f corrida.log     # pulso de la corrida

python3 simulador_worker.py comparar   # informe parcial o final, no interfiere
python3 tests_simulador.py             # tests unitarios (no toca la corrida)
```

Orden de ejecución: qwen2.5:3b completo primero, luego granite4:micro-h;
dentro de cada modelo, categorías en paralelo (4 hilos). El servidor atiende
una petición a la vez (`NUM_PARALLEL=1`), así que el paralelismo se encola —
es fiel al flujo, no más rápido.

## ¿Va bien o se colgó? — checklist

```bash
pgrep -af "run_flow|simulador_worker"  # debe haber UN bash (--fg) y UN python (correr)
wc -l resultados_*.jsonl               # el contador crece (repetir en 15 min)
tail -5 corrida.log                    # última línea reciente, sin Traceback
grep reanudando corrida.log            # al relanzar: cuántos retomó (una línea por lanzamiento)
```

**Vivo**: `llama-server` al ~100% CPU en htop y el `.jsonl` sumando líneas.
Cadencia normal: qwen ~5-15 min/producto (el 1º ~25 min, paga el prompt de
~12,6K tokens en frío), granite ~30-40 min/producto (mamba-2 no cachea
prefijo). **Media hora sin líneas nuevas NO es cuelgue.**
**Colgado**: proceso muerto, o >1 h sin línea nueva con llama-server ocioso,
o Traceback en el log.

Verificación remota (desde cualquier máquina de la LAN):

```bash
curl -s http://10.10.12.27:11434/api/ps   # modelo cargado; ctx debe ser 24576 con la config actual
```

## Desglose de estados por producto

```bash
python3 - <<'EOF'
import json
from collections import Counter
por = {}
for l in open('resultados_qwen2-5-3b.jsonl'):
    f = json.loads(l); por[f['product_id']] = f
print('productos únicos:', len(por))
print(Counter((f['status'], f.get('error_type')) for f in por.values()))
EOF
```

**Semántica de estados** (clave para leer el desglose):

- `ok` — normalizado; sus claves alimentaron el diccionario de la categoría.
- `review / excepcion` — error TRANSITORIO (timeout, red): **se reintenta
  solo** al reanudar; no cuenta como hecho.
- `review / invalid_json` o `empty_normalization` — fallo DEL MODELO:
  definitivo, no se reintenta. El campo `raw_preview` de la fila guarda el
  inicio de la salida cruda para diagnóstico.
- El `.jsonl` guarda una línea por INTENTO → puede haber más líneas que
  productos; la deduplicación se queda con la última fila por producto.

## Reintentar productos con fallo definitivo

Si hubo fallos `invalid_json` causados por configuración (no por el modelo) —
p. ej. corridas previas con ventana de contexto corta — conservar solo los OK
y relanzar:

```bash
pkill -f simulador_worker.py
python3 - <<'EOF'
import json
ok = [l for l in open('resultados_qwen2-5-3b.jsonl') if json.loads(l).get('status') == 'ok']
open('resultados_qwen2-5-3b.jsonl', 'w').writelines(ok)
print('conservadas', len(ok), 'filas ok — el resto se reintentará')
EOF
./run_flow.sh
```

⚠️ Nunca editar los `.jsonl` con la corrida activa (el proceso les hace
append): siempre `pkill` primero.

## Detener / reanudar

```bash
pkill -f simulador_worker.py   # detener (dispara la comparación con lo acumulado)
./run_flow.sh                  # reanudar donde iba
```

`corrida.log` es acumulativo: varias líneas "reanudando" = historial de
lanzamientos, no procesos duplicados (el guard de `run_flow.sh` impide correr
dos flujos a la vez).

## Notas de rendimiento (medidas en el servidor, CPU-only)

- Prompt del sistema ≈ 12,6K tokens → por eso `num_ctx=24576` y
  `num_predict=6144` por petición (con 16.384, Ollama recortaba el system
  prompt en silencio al desbordar).
- qwen2.5:3b reutiliza el prefijo cacheado entre productos (misma system
  prompt); granite4:micro-h no (estado recurrente mamba-2) — de ahí la
  asimetría de tiempos por producto.
- El timeout por llamada (10.800 s) incluye la espera en cola del servidor:
  con 4 categorías en paralelo y granite a ~30 min/producto, la cola puede
  superar las 2 h — no bajarlo.
- Contención externa: otros procesos del servidor (p. ej. tele2_monitoring)
  compiten por CPU y pueden duplicar los tiempos por rachas.

## Referencias

- Benchmark que eligió los modelos: `../benchmark_modelos_ollama.md` y
  `../benchmark_validacion_corridas.md`.
- Prompt bajo prueba: `../PROMPT_NORMALIZACION.md` (el system prompt real del
  worker de producción).
- Flujo replicado: `../WORKER_CATEGORIAS_N8N.json`.
