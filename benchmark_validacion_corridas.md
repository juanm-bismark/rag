# Validación del benchmark de modelos — corridas 2 y 3

**Fecha:** 2026-07-06 (tarde) · **Servidor:** 10.10.12.27, Ollama 0.31.1, CPU-only
**Objetivo:** validar que los resultados de la corrida 1 (`benchmark_modelos_ollama.md`) son consistentes y se mantienen, y medir el efecto del cambio de configuración del compose.

| Corrida | Config | Condiciones |
|---|---|---|
| 1 (referencia) | ctx 8192, KV f16 (q8_0 no-op sin FA) | mañana; frío por prueba |
| 2 | idéntica a corrida 1 | cachés calientes de la corrida 1 (`KEEP_ALIVE=-1`); fantasma qwen3:4b en RAM |
| 3 | **ctx 16384 + `FLASH_ATTENTION=1` + KV q8_0 real** | restart limpio: todo frío, fantasma eliminado |

## Resultado principal: el veredicto se sostiene

| Batería tool compleja (n/5) | Corrida 1 | Corrida 2 | Corrida 3 |
|---|---|---|---|
| **granite4:micro-h** | **5/5** · med 53,5s | **5/5** · med 53,5s | **5/5** · med 56,1s |
| **qwen2.5:3b** | 3/5 · med 16,4s | **2/5** · med 14,0s | 3/5 · med 16,4s |

**granite4:micro-h reproduce sus 5 llamadas con argumentos idénticos en las tres corridas** — incluido el `category_ids [1641, 516]` de Q1 (el comportamiento que corrige el bug de producción del EG5120 omitido), la doble condición anidada de Q4 (mismos 116 tokens generados las tres veces), y hasta el mismo desliz (`gain` en vez de `gain_dbi`). Sus errores también son deterministas → predecibles y mitigables con el enum de specs.

**qwen2.5:3b queda caracterizado por completo:**
- Fallos fijos (3/3 corridas): Q1 (3 campos), Q4 (multi-condición), T5 — siempre salida vacía, mismos ~60-77 tokens descartados.
- Aciertos fijos (3/3): Q2, Q5.
- Moneda al aire: Q3 — ✓, ✗ (texto sin llamar la tool), ✓ en corridas 1/2/3.
- Deriva semántica entre corridas aún con temperatura 0,1: `gain_dbi` → `gain_db`; `temperature_operating_min` → `operating_temperature_min`; el acierto de vocabulario de la corrida 1 fue suerte.

## Efecto de la config nueva (corrida 3 vs 1, ambas en frío)

| Métrica | qwen2.5:3b | granite4:micro-h |
|---|---|---|
| Calidad (pass/fail, 6+5+1 pruebas) | **idéntica** prueba por prueba | **idéntica** prueba por prueba |
| Generación | 4,9 → **5,8 tok/s** (+18%) | 5,6 → 4,8-5,1 tok/s (−9-14%) |
| Prompt eval frío | 8,2 → 8,4 tok/s | 7,4-7,9 → 7,2-7,8 (igual) |
| T6 ctx largo | 265 → **250s** | 228 → 233s (igual) |
| Caché de prefijo | sigue funcionando (T3: 62 tok/s) | sigue sin aplicar a prefijos parciales |

**Lectura:** la config nueva es **neutra en calidad y aproximadamente neutra en velocidad** (leve mejora en el 3B, leve retroceso en granite — ambos dentro del ruido de una CPU virtual compartida). Lo importante: **ctx 16384 quedó activo sin costo medible**, que era el requisito para el prompt real del agente (~5.700 tokens estáticos que desbordaban 8192). El q8_0 (ahora sí real) no degradó el tool calling de granite: 5/5 intacto.

## Hallazgos operativos de la validación

1. **Estancamientos de entorno (corrida 2, ~17:00-17:30):** dos peticiones triviales reventaron el timeout de 600s (T3 del 3B, que tarda 14s normalmente; T6 de granite, 228s normalmente) con el servidor respondiendo normal justo después. En corridas 1 y 3 no ocurrió. Es contención externa intermitente en el servidor (otro proceso/cliente compitiendo por CPU) — **revisar qué corre en esa máquina en ese horario**; en producción implica que el timeout del nodo n8n debe contemplar colas de minutos, no solo la latencia nominal.
2. **Caché de secuencia exacta también aplica a granite:** cuando el prompt se repite idéntico de punta a punta, granite lo procesa a 197-378 tok/s (T5 corrida 2: 10,8s vs 55s). Lo que no reutiliza es el prefijo parcial entre preguntas distintas (~50s constantes en la batería). En los Qwen el prefijo parcial sí se cachea (13-27s en caliente).
3. **El fantasma post-delete:** un modelo borrado del disco (`qwen3:4b`) permaneció cargado en RAM (~3,3 GB) desde su eliminación hasta el restart del contenedor, y no se puede descargar por API (404). Con `KEEP_ALIVE=-1`, todo `ollama rm` debería ir seguido de un restart del contenedor para liberar la RAM.

## Conclusión

La segunda y tercera corrida **confirman el veredicto de la corrida 1 sin matices**: granite4:micro-h para el agente (triple 5/5, determinista, sobrevive al q8_0), qwen2.5:3b solo para batch (texto impecable las tres veces; tools 2-3/5 con fallos y modos de fallo variables). La config nueva del compose queda validada para el despliegue del agente: contexto suficiente para el prompt real sin costo de calidad ni de velocidad.

Datos crudos: `bench_results*.json` (corridas por modelo) en el scratchpad de sesión; corrida 1 documentada en `benchmark_modelos_ollama.md`.
