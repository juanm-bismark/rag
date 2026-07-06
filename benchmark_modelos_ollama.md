# Benchmark de modelos locales para RAG — servidor 10.10.12.27

**Fecha:** 2026-07-06 · **Ollama:** 0.31.1 (Docker) · **Hardware:** CPU-only (QEMU virtual, `size_vram: 0`)
**Config:** `OLLAMA_CONTEXT_LENGTH=8192`, `NUM_PARALLEL=1`, `KEEP_ALIVE=-1`, KV cache q8_0
**Criterio de decisión:** la prueba de **tool compleja** (arrays + objetos anidados, la forma de las tools del agente RAG de n8n) es la única decisiva; el resto son de confirmación. Intermitente = fallo.

## Velocidad base medida

| Modelo | Generación | Prompt frío | Prompt con caché |
|---|---|---|---|
| qwen2.5:3b | ~5-6 tok/s | ~8 tok/s | 40-60 tok/s |
| qwen3:4b | ~4,4 tok/s | ~6 tok/s | 32-42 tok/s |
| qwen2.5:7b | ~2,7-2,9 tok/s | ~3,6-4 tok/s | 13-30 tok/s |
| granite4:micro-h | ~5,4-6,6 tok/s | ~7,7 tok/s | **sin beneficio** (~7,7 constante) † |

† El estado recurrente mamba-2 no se cachea como KV transformer: velocidad constante y predecible, sin premio en caliente ni castigo extra en frío. Excepción: continuar la misma conversación (T5b) sí reutilizó estado parcialmente (26,8 tok/s).

## Resultados por prueba

| Prueba | qwen2.5:3b | qwen3:4b † | qwen2.5:7b | granite4:micro-h |
|---|---|---|---|---|
| T1 JSON extracción | ✅ 21s | ❌ thinking | ✅ 89s | ✅ **19s** |
| T2 ≤5 bullets solo contexto | ✅ 3 bullets, 55s | ❌ thinking | ✅ 3 bullets, 104s | ✅ 3 bullets, 54s |
| T3 lead prioritario | ✅ 14s | ❌ thinking | ✅ 34s | ✅ 46s (sin caché) |
| T4 anti-alucinación | ✅ **exacta**, 7s | ✅ con /no_think, 86s | ✅ no literal, 16s | ✅ no literal, 35s |
| **T5 tool compleja** | ❌ **salida vacía** ×2 | ❌ ×1 + timeout >7min | ✅ **perfecta**, 112s | ✅ perfecta, 55s |
| T5b ciclo agente completo | (no aplica, falló T5) | — | ✅ 67s | ✅ 30s |
| T6 aguja en ctx largo (~1.900 tok) | ✅ 4,4 min | ✅ 6,5 min | ❌ **timeout >10 min** | ✅ **3,8 min (mejor)** |
| Tool simple (`buscar_lead`, 1 param) | ✅ 27s, 25 tok | ✅ 69s, 170 tok | ✅ 60s, 25 tok | ✅ 33s, 24 tok |
| **Batería tool compleja (n/5)** | **3/5** · med 16,4s | no aplica | **4/5** · med 27,6s | **5/5** · med 53,5s |

† qwen3:4b: el modo thinking **no se puede desactivar** en Ollama 0.31.1 (`think:false` filtra el razonamiento al campo de respuesta en `/api/generate`; `/no_think` no evita los ~150-300 tokens de razonamiento, solo los reubica). A ~4,4 tok/s eso añade 40-90 s por respuesta. **Eliminado del servidor 2026-07-06.**

## Tool call de referencia (T5, qwen2.5:7b — único acierto hasta ahora)

```json
{"name": "buscar_productos",
 "args": {"query": "routers 5G wifi",
          "category_ids": [1641],
          "spec_filters": [{"spec": "ethernet_ports", "op": ">=", "value": "4"}]}}
```

## Batería tool compleja — detalle por pregunta (2026-07-06)

| # | Pregunta (resumen) | qwen2.5:7b | qwen2.5:3b | granite4:micro-h |
|---|---|---|---|---|
| Q1 | routers 5G + WiFi + ≥4 eth (3 campos) | ✅ perfecta, 113s | ❌ vacía (3er fallo en esta pregunta) | ✅ 75s · **única con cat [1641,516]** (corrige el bug de producción que omite EG5120) |
| Q2 | antenas ganancia >6 dBi | ✅ 24s pero `gain_db` (spec inventada), sin categoría | ✅ 13,5s **mejor semántica**: cat 1554 + `gain_dbi` correcto | ✅ 53s, `gain` (spec inventada) |
| Q3 | gateways temp -30° o menos | ❌ **vacía** (valor negativo + ≤) | ✅ 40s estructura OK, pero `>=` invertido (iba `<=`) | ✅ 54s — esquivó el filtro anidado (constraint en query texto) |
| Q4 | routers celulares GPS + ≥2 seriales | ✅ 33s, cat 516 + filtro OK | ❌ vacía (multi-condición) | ✅ 68s · **mejor llamada de la sesión**: 2 filtros anidados (`gps=true` + `serial_ports>=2`) + cat 516 |
| Q5 | ¿qué productos 5G hay? | ✅ 17s, cat OK pero query vacía | ✅ 8s, cat OK pero query vacía | ✅ 48s, query "5G" mínima correcta |

**Lectura:** los Qwen no son estructuralmente incapaces — **son intermitentes** y tropiezan con preguntas distintas. "Estructuralmente OK" esconde errores semánticos que en producción devuelven 0 resultados en silencio: nombres de spec inventados (7B, granite), operadores invertidos (3B — mismo perfil del AND-bug documentado), queries vacías (Qwen ambos). Criterio acordado: intermitente = fallo → 3B descalificado como agente; 7B aprueba raspando (4/5 con n=5 es frágil); **granite4:micro-h 5/5 — cero salidas vacías: cuando la estructura se complica, o la arma bien o la simplifica con gracia, nunca emite basura que el parser descarte**.

**Nota de latencia granite:** velocidad bruta igual al qwen 3B (gen 5,6 tok/s, prompt 7,9 tok/s), pero **no se beneficia del caché de prefijo** (mediana 53,5s clavada vs Qwen 13-27s en caliente con el mismo system prompt) — coherente con el estado recurrente mamba-2, que no se cachea como un KV transformer. Con system prompt estable, los Qwen recuperan velocidad entre llamadas; granite paga tarifa completa cada vez.

## Hallazgos clave

1. **Causa raíz del "output empty no-determinista" del agente n8n**: los modelos 3-4B emiten tool-calls malformados ante esquemas con arrays de objetos anidados; Ollama los descarta en silencio → salida vacía. Reproducible: qwen2.5:3b 2/2 fallos con la tool compleja, 2/2 aciertos con tool de 1 parámetro escalar.
2. **El fallo no es de tamaño sino de entrenamiento en function calling** (un 3B y un 4B fallaron igual; el 7B de la misma familia acertó a la primera).
3. **El cuello de botella del servidor es el prompt eval**, no la generación: T6 (~1.900 tokens) = 4,4 min en 3B, >10 min en 7B. Contextos RAG largos son inviables sin caché de prefijo estable.
4. El caché de prefijo de Ollama (system prompt estable) multiplica ×5-7 la velocidad de prompt — argumento para system prompts fijos en el agente.

## Estado final del servidor (2026-07-06)

- **granite4:micro-h** (1,9 GB) — modelo de agente. Único que pasó todas las pruebas.
- **qwen2.5:3b** (1,9 GB) — motor batch (aprovecha caché de prefijo con prompts estables).
- Eliminados: qwen3:4b (thinking inapagable), qwen2.5:7b (sin nicho: granite lo supera en fiabilidad, el 3B en velocidad).
- `granite4:micro` (fallback transformer) no fue necesario: mamba-2 corre sin problemas en QEMU.
- `docker-compose.ollama.yml` actualizado: `ollama-init` hace pull de qwen2.5:3b + granite4:micro-h.

## Veredicto final

**granite4:micro-h es el modelo de agente local.** 5/5 en la batería de tool compleja (único), cero salidas vacías en 6 llamadas complejas, único que incluyó ambas categorías de routers (corrige el bug de producción que omite el EG5120), mejor tiempo de contexto largo (3,8 min donde el 7B murió), y velocidad de 3B denso. El entrenamiento de IBM en tool calling estructurado hace la diferencia exacta que esta carga necesita.

**qwen2.5:3b queda como motor batch**: resúmenes, extracción JSON plana, normalización — 5/6 impecable, el más rápido, y con caché de prefijo hace 13-27s por llamada repetida.

**Reservas que siguen vivas (para el e2e con n8n):**
1. La latencia de agente sigue siendo de **cola asíncrona, no chat en vivo**: ~50s por tool call (granite no cachea prefijo) → pregunta con 2-3 tools ≈ 2-4 min. Si el caso de uso exige segundos → agente a Gemini.
2. Errores semánticos persisten en todos los locales: nombres de spec inventados (`gain` vs `gain_dbi`), operadores dudosos. Mitigación: listar los nombres reales de specs en el system prompt / descripciones de tools, y mantener los alias en la DB.
3. El guard IF tras el AI Agent sigue siendo obligatorio como red de seguridad.
4. n=5 es una muestra chica; el e2e con las preguntas reales del check es la validación definitiva.

**Siguiente paso**: apuntar el nodo Ollama Chat Model de n8n a `http://10.10.12.27:11434` con `granite4:micro-h` y correr el set real de preguntas del check contra Supabase.
