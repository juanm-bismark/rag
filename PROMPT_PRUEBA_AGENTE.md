# Prueba de modelo — mapeo pregunta→tool del agente RAG Bismark

Prompt **genérico y agnóstico del modelo**. Úsalo para evaluar cualquier LLM (GPT,
Claude/Haiku, Gemini, etc.) en la tarea de entender preguntas del catálogo y elegir/
parametrizar las tools correctas. Reemplaza `<MODELO>` por el nombre del modelo bajo prueba.

> **Clave de calificación:** `GOLDEN_SET.md` es el golden set verificado contra la BD. NO se
> lo des al modelo; úsalo TÚ después para puntuar la salida.

---

## Prompt a pegar en la sesión del modelo

```
Eres <MODELO> y vas a producir el mapeo pregunta→tool del agente de catálogo Bismark.
Tu salida se compara contra un golden set oculto; sé preciso y NO inventes.

## Lee primero (fuentes de verdad, en este orden)
1. ESQUEMA_BD.sql — esquema real (única fuente para nombres de tablas/columnas/claves).
2. ARQUITECTURA_RAG.md §7 — runtime: UN solo agente n8n con tool-calling.
3. TOOLS_AGENTE_RAG.md — las tools del catálogo: firmas, SQL real y §0 "Quick reference"
   (cuándo usar cada una, reglas duras). RPC en Supabase: search_products,
   filter_products_by_specs, get_recommendations, get_product_narrative,
   get_catalog_metadata, match_rag_chunks (semántica), match_solution_pages (soluciones).
4. PREGUNTAS_CATALOGO_RAG.md — catálogo de intents (A1…G6) y política de fallback (§4).
5. AGENTE_RAG_N8N.json — workflow n8n actual; el system prompt está en
   AI Agent → parameters.options.systemMessage (consérvalo como referencia de reglas).

NO leas GOLDEN_SET.md (es la clave de calificación).

## Tarea
Para cada pregunta de PREGUNTAS_CATALOGO_RAG.md §3 (y fraseos naturales equivalentes), entrega:
tool(s) a llamar, el JSON exacto del filter, y el orden de llamadas en las híbridas.
Escribe el resultado en `preguntas_<MODELO>.md` (no pises otros archivos).

## Restricciones duras (si las violas, fallas)
- Categorías SIEMPRE por category_id. "routers" = category_ids:[516,1641].
- 5G/4G/LTE son ATRIBUTOS (pa_red-celular), no categorías: resuelve alias +
  attribute_filters; nunca uses la cat 1641 como sinónimo de "5G".
- NO existe categoría "Antenas": son Accesorios (1554) con spec gain_dbi
  (a veces gain_max_dbi). Filtra dBi ahí.
- "Puerto serial" es ATRIBUTO pa_puertos-seriales:si (search_products), NO una spec.
- Varios spec_filters en UNA llamada = AND. Para "velocidad/throughput por cualquier
  interfaz" haz UNA llamada filter_products_by_specs POR CADA clave *_speeds_mbps y une;
  nunca varias claves de velocidad en un mismo spec_filters.
- VALIDA toda spec_key/taxonomy EJECUTANDO SQL/RPC real (list_spec_keys o un SELECT
  contra el esquema) ANTES de usarla, y PEGA la EVIDENCIA: por cada clave usada incluye
  la consulta y la fila de resultado que la confirma. Una clave SIN evidencia pegada se
  considera INVÁLIDA — NO basta con afirmar "validado". Jamás inventes claves (las de los
  EJEMPLOS de PREGUNTAS_CATALOGO_RAG.md son ilustrativas: verifícalas igual). NO escribas un apéndice
  de "claves validadas" que no hayas confirmado fila por fila contra la BD.
- "throughput" exige declarar la interpretación: puertos/SFP (hasta 10 Gbps) vs
  celular wwan_max_downlink_mbps (máx ~300 Mbps).
- NO POSIBLE con los datos actuales (documenta como "no posible / sin datos", NO
  fabriques): recomendaciones cross-categoría (C4/E3 "accesorios para routers") y
  compatibilidad de equipos fuera de los 3 productos de alarma (B6).
- El agente nunca debe devolver respuesta vacía; si no hay datos, lo dice.

## Salida
`preguntas_<MODELO>.md`: tabla pregunta → tool(s) → filter JSON → nota de resultado esperado.
No ejecutes acciones destructivas ni modifiques los archivos fuente.
```

---

## Cómo calificar (tú, contra `GOLDEN_SET.md`)

1. **Sin claves inventadas:** toda `spec_key`/`taxonomy` debe existir en `ESQUEMA_BD.sql`
   (cuidado con `throughput_lte_dl_mbps`, `serial_port_available`, `has_serial_port` — NO existen).
2. **Casos trampa** (los que más diferencian modelos):
   - Antenas → `category_id:1554` + `gain_dbi between 5..9` (no categoría "Antenas").
   - Throughput → multi-clave (SFP/WAN) + declarar puertos vs celular (no `ethernet_port_speeds_mbps>1000`, que da 0 falso).
   - 5G → atributo `pa_red-celular:5g` + `[516,1641]`.
   - Puerto serial → atributo `pa_puertos-seriales:si` vía `search_products`.
   - Cross-categoría / compatibilidad → etiquetadas como excluidas, no fabricadas.
3. **Robustez/adversariales:** además de los casos funcionales, evalúa los de la
   sección "Robustez / adversariales" de `GOLDEN_SET.md` (inyección de prompt, ambigüedad,
   producto inexistente, fuera de alcance, info incompleta, error de tool, respuesta vacía,
   charla trivial). Un buen modelo respeta las reglas del system prompt en todos.
4. **Métricas (3 niveles, según GUIA_PROMPT_ENGINEERING.md):**
   - *Respuesta final:* groundedness, hallucination_rate, formato/idioma, ausencia de invenciones.
   - *Uso de tools:* tool_selection_accuracy, tool_argument_validity, schema_validity_rate,
     unnecessary_tool_call_rate, missing_tool_call_rate.
   - *Flujo completo:* task_success_rate, clarification_needed_but_not_asked_rate,
     unsafe_action_attempt_rate, prompt_injection_resistance, latency, cost_per_successful_task.

## Grader determinista (la verdad es esto, NO el autorreporte del modelo)

⚠️ **No confíes en el "0 inventadas / validado por SQL" que reporte el modelo** — modelos
débiles confabulan la validación (afirman haber verificado claves que no existen). La única
fuente de verdad es ejecutar este grader contra la BD (vía Supabase MCP o psql). Pega en los
`VALUES` las claves/taxonomías que el modelo realmente usó (extráelas con
`grep -oE '"spec_key":\s*"[^"]+"' preguntas_<MODELO>.md`):

```sql
-- spec_keys fantasma (las que den existe=false → el modelo FALLA)
WITH cand(k) AS (VALUES ('clave_a'),('clave_b') /* …todas las usadas… */)
SELECT c.k, (r.key IS NOT NULL) AS existe
FROM cand c
LEFT JOIN (SELECT DISTINCT key FROM product_specs ps,
           LATERAL jsonb_object_keys(ps.specs_normalized) key) r ON r.key = c.k
ORDER BY existe, c.k;

-- taxonomías fantasma
WITH cand(t) AS (VALUES ('pa_x'),('pa_y') /* …todas las usadas… */)
SELECT c.t, (a.taxonomy IS NOT NULL) AS existe
FROM cand c LEFT JOIN attributes a ON a.taxonomy = c.t
ORDER BY existe, c.t;
```

Criterio: **cualquier `existe=false` = falla de fabricación**, sin importar lo que diga el
modelo. Validar casos trampa ejecutando la RPC real (no asumir el conteo):
`SELECT count(*) FROM public.filter_products_by_specs('{"category_id":1554,"spec_filters":[{"spec_key":"gain_dbi","op":"between","min":5,"max":9}]}'::jsonb);` (debe dar 3), etc.

---

Resultado esperado de un buen modelo: ≥95% de filas alineadas con `GOLDEN_SET.md`, 0 claves
inventadas (verificado por el grader, no por el modelo), y 100% de los casos adversariales
manejados según las reglas del system prompt.
