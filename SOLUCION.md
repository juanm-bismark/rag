# Solución de catálogo + RAG — Bismark

Documento de referencia con todas las decisiones tomadas. La fuente operativa actual
es [salida_completa.json](salida_completa.json), que ya consolida producto,
atributos, specs, software y recomendados. El esquema SQL completo vive en
[schema.sql](schema.sql); este texto es la guía operativa.

---

## 1. Enfoque general

El sistema separa **lo filtrable** (categorías, atributos taxonómicos, marca, `is_new`,
specs numéricas/enum) de **lo semántico** (descripción, specs narrativas, features,
software de gestión).

Sobre eso se monta un patrón **filter-then-rank** con dos rutas paralelas:

- **Ruta estructurada** — SQL puro sobre tablas normalizadas. Resuelve relaciones,
  filtros disponibles, filtros numéricos, taxonomía.
- **Ruta semántica** — similarity search sobre `rag_chunks` con metadata
  denormalizada para prefiltrar antes del cosine.

Un extractor NLU (LLM con tool-calling) clasifica la pregunta en filtros + tipos de
información, dispara ambas rutas y el LLM final compone la respuesta sobre el merge.

**Volumen objetivo:** <500 productos, ~2500 chunks. Snapshot actual. 74 productos, 8 `category_id`,
13 marcas, 19 productos nuevos, 36 atributos filtrables válidos, 92 opciones
válidas, 1607 specs crudas, 80 relaciones de recomendación y 7 grupos canónicos
de software. PostgreSQL + pgvector en una sola DB. Sin índice vectorial al inicio
(seq scan + prefiltrado <50ms).

---

## 2. Decisiones de diseño (cerradas)

| Decisión | Elegido | Justificación corta |
|---|---|---|
| Stack | PostgreSQL 15 + pgvector + pg_trgm | Una DB, todo cabe. |
| Modelo embeddings | `text-embedding-3-large` (3072 dims) | Pedido del usuario. Costo trivial al volumen. |
| Índice vectorial | Ninguno hasta ~10k chunks; luego IVFFlat | <2500 chunks no requiere índice. |
| Atributos taxonómicos (Woo `pa_*`) | EAV controlado | Multivalor + heterogéneo por categoría. |
| Specs técnicas | JSONB crudo + `specs_normalized` JSONB (LLM) | Catálogo manual de spec_keys es overkill a este volumen. |
| Software de gestión | Tabla canónica con embedding único | Evita 12 chunks idénticos (Robustel et al.). |
| Relaciones | Dirigidas siempre (bidireccionales se duplican) | Queries triviales, costo irrelevante. |
| Metadata en `rag_chunks` | Denormalizada (`category_id`, `is_new`, `brand`, `attribute_slugs`) | Filter-then-rank exige WHERE barato antes del cosine. `category_slug` queda opcional porque el JSON actual solo trae `category_id`. |
| Re-ingesta | Hash por chunk → skip si no cambió | Embeddings cuestan; idempotencia obligatoria. |
| Precio / stock | No modelado | Confirmado fuera de scope. |

---

## 3. Esquema de base de datos

12 tablas en total. DDL completo y comentado en [schema.sql](schema.sql).

**Núcleo del catálogo**

- `categories` — taxonomía base por `category_id` (8 filas hoy). El JSON actual
  no trae `name`/`slug`, pero el DDL los exige; el ETL debe completarlos desde
  WooCommerce o generar placeholders controlados.
- `attributes` — atributos Woo válidos (`pa_red-celular`, `pa_wifi`, …). El ETL
  ignora atributos sin `taxonomy` o con `id = 0`.
- `attribute_options` — opciones por atributo desde `attributes[].options[]`.
- `category_attributes` — qué atributos aplican a qué categoría (alimenta UI/NLU dinámico).
- `attribute_option_aliases` — sinónimos para el extractor NLU
  (`"móvil"`, `"4G/LTE"` → option correcta).
- `products` — producto canónico, con `search_text` generada para fuzzy match.
- `product_attribute_values` — asignación N:N producto ↔ option (multivalor).
- `product_specs` — `specs` (crudo JSONB) + `specs_normalized` (LLM) +
  `specs_text`/`features_text` (markdown a embeddear).
- `software` — software de gestión deduplicado (canónico),
  con FK circular `products.software_id` ↔ `software.canonical_product_id`.
- `product_relations` — dirigidas, con `relation_type`, `weight`.

**Capa RAG**

- `rag_chunks` — texto + embedding + **metadata denormalizada**.
  Un chunk pertenece a un producto **o** a un software (XOR check constraint).
  Tipos válidos: `description`, `specs`, `features`, `software`, `category_summary`.
- `ingestion_runs` — auditoría de cada corrida del ETL.

**Reglas de integridad clave**

- `chunk_owner_xor` en `rag_chunks` — un chunk no puede pertenecer a producto Y software a la vez.
- `relation_type` con CHECK enumerado en `product_relations`.
- FK circular `products` ↔ `software` cerrada con `ALTER TABLE` después de crear `products`.

### Incongruencias actuales en `schema.sql` frente a `salida_completa.json`

No se cambia el DDL automáticamente; estas son las diferencias que el ETL debe
resolver o que conviene corregir manualmente si se quiere trazabilidad completa:

| Punto | En `salida_completa.json` | En `schema.sql` | Impacto / decisión |
|---|---|---|---|
| Categorías | Solo existe `category_id` | `categories.name` y `categories.slug` son `NOT NULL` | El ETL necesita lookup externo de Woo o valores sintéticos (`categoria-516`) antes de insertar productos. |
| Atributos | Usa `attributes[].options[]` | Comentario viejo habla de `parent: 0` | El comentario está desactualizado; la lógica real debe iterar `options[]`. |
| Atributo inválido | 1 producto trae atributo `id = 0`, `taxonomy = null` | `attributes.taxonomy` es `NOT NULL` | Debe saltarse y registrarse como warning. |
| Category slug en chunks | No viene en el JSON | `rag_chunks.category_slug` existe | Puede quedar NULL o derivarse de lookup; retrieval debe preferir `category_id`. |
| Trazabilidad de chunks | Conviene saber si el chunk salió de `description`, `specs_text`, etc. | `rag_chunks` no tiene `source_file`/`source_fields` | Se puede inferir por `chunk_type`, pero no queda trazabilidad fina. |
| Fuente de relaciones | `productos_recomendados[]` viene del JSON actual | `product_relations` no tiene columna `source` | La fuente queda en `ingestion_runs.source`, no en cada edge. |

---

## 4. Flujo ETL — orden de carga

La fuente actual es un único arreglo JSON: [salida_completa.json](salida_completa.json).
El ETL respeta dependencias de FK y normaliza nombres de campos (`es_nuevo` →
`is_new`, `software_canonico_de` → vínculo al producto canónico, etc.):

| # | Tabla | Fuente | Notas |
|---|---|---|---|
| 1 | `categories` | `DISTINCT category_id` | Insertar 8 filas. Si no hay lookup de Woo, usar placeholders controlados para `name`/`slug` porque el DDL actual no permite NULL. |
| 2 | `attributes` + `attribute_options` | `attributes[].options[]` | Insertar solo atributos con `taxonomy` no NULL e `id != 0`. Snapshot: 36 atributos y 92 opciones válidas. |
| 3 | `category_attributes` | derivado del mismo JSON | Recorrer cada producto y registrar pares (`category_id`, `attribute_id`) únicos. |
| 4 | `software` (solo canónicos) | productos con `is_software_canonical = true` | Insertar 7 grupos canónicos usando `software_dedupe_group_id`, `software_nombre`, `software_texto`, `software_attributes`, `software_fragmentos`, `software_caracteres`. Aún sin `canonical_product_id`. |
| 5 | `products` | cada elemento del JSON | Mapear `id`, `slug`, `name`, `brand`, `model`, `category_id`, `source_url`, `description`, `es_nuevo`, `search_aliases`. Resolver `software_id` desde `software_dedupe_group_id`. |
| 6 | `software.canonical_product_id` | UPDATE | Cierre del bucle FK. |
| 7 | `product_attribute_values` | `attributes[].options[]` | Insertar una fila por producto-atributo-opción. Skipping explícito del atributo inválido detectado (`id = 0`, `taxonomy = null`) en `antena-magnetica-3-9-dbi-1-5-mts`. |
| 8 | `product_specs` (sin normalizado) | campos técnicos del producto | `specs`, `table_specs`, `variants`, `compatibility`, `specs_text`, `features_text`. |
| 9 | `product_specs.specs_normalized` | **LLM** sobre cada producto | Ver prompt en §5. |
| 10 | `product_relations` | `productos_recomendados[]` | Resolver cada slug contra `products.slug`; relación `recommended_product`. La fuente de la corrida queda en `ingestion_runs.source`. Snapshot: 80 edges. |
| 11 | `rag_chunks` + embeddings | derivado | Ver §6. |

### Validaciones obligatorias de ETL

- Verificar que cada `productos_recomendados[]` resuelva a un `products.slug`; si
  no resuelve, registrar warning y no insertar FK rota.
- Verificar que `software_canonico_de` apunte a un producto existente y que su
  `software_dedupe_group_id` coincida con el grupo.
- Verificar que solo los productos canónicos generen chunk `software`; los demás
  se enlazan por `products.software_id`.
- Registrar como warning cualquier atributo con `taxonomy` vacío, `id = 0` u
  opción sin `slug`.
- Revisar manualmente nombres de software casi duplicados. En el snapshot existe
  `Robustel Coud Manager Service`, probablemente variante tipográfica de
  `Robustel Cloud Manager Service`; no fusionarlo automáticamente sin aprobación.

---

## 5. Prompt de normalización de specs (paso 9)

Se ejecuta una llamada LLM por producto. Modelo recomendado: `claude-sonnet-4-6`
o `gpt-4o-mini` (no necesita Opus). Costo total estimado para 74 productos (snapshot actual): <$1.

### Construcción del input

```sql
-- Claves ya vistas en la categoría del producto que estás procesando:
SELECT array_agg(DISTINCT key ORDER BY key)
FROM product_specs ps
JOIN products p ON p.id = ps.product_id
CROSS JOIN LATERAL jsonb_object_keys(ps.specs_normalized) AS key
WHERE p.category_id = $1;
```

La primera ejecución por categoría devuelve `[]`; el LLM crea el vocabulario.
A partir del 2º producto, ya hay base de reuso. Las claves convergen rápido
(10–15 productos por categoría son suficientes para estabilizar).

### Prompt

```
ROL
Eres un normalizador de specs técnicas de productos B2B (telecom, networking,
IoT industrial). Tu salida alimenta una base de datos para RAG.

ENTRADA
{
  "category_id": 516,
  "category_slug": null,
  "category_name": null,
  "product_name": "Robustel EG5100",
  "specs_raw": [
    {"name": "Throughput LTE", "value": "150 Mbps DL / 50 Mbps UL", "section": "Conectividad"},
    {"name": "Puertos LAN", "value": "4 x RJ45 10/100", "section": "Interfaces"}
  ],
  "known_keys_in_category": [
    "throughput_lte_dl_mbps","throughput_lte_ul_mbps","ports_lan",
    "wifi_standard","voltage_v","operating_temp_min_c","operating_temp_max_c"
  ]
}

REGLAS
1. Devuelve un objeto JSON PLANO (sin anidamiento). Cada clave es snake_case.
2. REUSA claves de "known_keys_in_category" siempre que la spec encaje
   semánticamente. Solo crea una clave nueva si ninguna existente aplica.
3. Valores numéricos como NUMBER (no string). Convierte a la unidad estándar
   implícita en el nombre de la clave:
     *_mbps -> Mbps,  *_v -> Volts,  *_c -> Celsius,  *_dbi -> dBi,
     *_mhz -> MHz,    *_mm -> mm,    *_g -> gramos,   *_w -> Watts.
4. Rangos ("-40 a 75 °C") -> dos claves: "<base>_min_<unit>" y "<base>_max_<unit>".
5. Listas discretas ("802.11b/g/n/ac") -> ARRAY de strings normalizados.
6. Booleanos para Si/No, presencia/ausencia: true/false.
7. Si no puedes parsear con confianza, OMITE la clave. No inventes.
8. NO incluyas claves con valor null, "", [] o "N/A".
9. NO incluyas marca, nombre, modelo, descripción ni URLs.
10. Salida = SOLO el objeto JSON. Sin explicaciones, sin markdown, sin código.

EJEMPLO
{
  "throughput_lte_dl_mbps": 150,
  "throughput_lte_ul_mbps": 50,
  "ports_lan": 4,
  "ports_lan_speed_mbps": 100,
  "voltage_v": 12,
  "operating_temp_min_c": -40,
  "operating_temp_max_c": 75,
  "wifi_standard": ["802.11b","802.11g","802.11n"],
  "has_serial": true
}
```

### Validación post-normalización

Query mensual para detectar claves huérfanas (candidatas a fusionar):

```sql
SELECT key, COUNT(*) AS products_with_key
FROM product_specs ps
CROSS JOIN LATERAL jsonb_object_keys(ps.specs_normalized) AS key
GROUP BY key
HAVING COUNT(*) < 3
ORDER BY products_with_key, key;
```

Si una clave aparece en 1–2 productos, probablemente es variante de una existente
y conviene refactorizar (renombrar + re-normalizar el producto huérfano).

---

## 6. Generación de `rag_chunks` (paso 11)

### Reglas de chunking

| Fuente | Estrategia | Tamaño objetivo | `chunk_type` |
|---|---|---|---|
| `products.description` | 1 chunk | <300 tokens | `description` |
| `product_specs.features_text` | 1 chunk si <500 t; split por headers `##` si más | 200–500 t | `features` |
| `product_specs.specs_text` | 1 chunk por `section` del JSON; merge si <100 t, split si >500 t | 200–500 t | `specs` |
| `software.description_text` | 1 chunk por software canónico | <500 t | `software` |
| (opcional) `categories` | 1 chunk descriptivo por categoría | <300 t | `category_summary` |

**Regla dura:** ningún chunk excede 500 tokens.

### Por cada chunk insertado

1. Calcular `content_hash = sha256(content)`.
2. Si existe en `rag_chunks` con mismo `content_hash` y misma metadata
   denormalizada → **skip embedding** (incrementar `chunks_skipped` en `ingestion_runs`).
3. Si cambió solo metadata → UPDATE de columnas; **no regenerar embedding**.
4. Si cambió `content` → embeddear y UPSERT.
5. Denormalizar metadata desde `products` (o `software`) en el momento del INSERT/UPDATE.

### Construcción de `attribute_slugs`

```sql
-- Para un producto dado, materializa el array de filtros
SELECT array_agg(DISTINCT a.taxonomy || ':' || ao.slug)
FROM product_attribute_values pav
JOIN attribute_options ao ON ao.id = pav.attribute_option_id
JOIN attributes a         ON a.id = pav.attribute_id
WHERE pav.product_id = $1;
```

### Chunks de software

- `product_id IS NULL`, `software_id IS NOT NULL`.
- Sin metadata de categoría/marca (un mismo software puede pertenecer a varios productos
  de marcas distintas, aunque hoy típicamente coincide).
- Resolución de "qué productos usan este software" se hace por JOIN
  (`products.software_id = software.id`), no por similarity.

---

## 7. Patrón de retrieval

### Output del extractor NLU (en query time)

```json
{
  "category_id":     516,
  "category_slug":   null,
  "is_new":          true,
  "brand":           null,
  "attribute_filters": [
    {"taxonomy": "pa_red-celular", "option_slugs": ["5g"]}
  ],
  "spec_filters": [
    {"spec_slug": "throughput_lte_dl_mbps", "operator": ">=", "value": 1000}
  ],
  "info_types":         ["description", "specs"],
  "structured_lookups": ["relations"],
  "confidence": 0.85
}
```

### Mapeo `info_types` / `structured_lookups`

| Tipo | Fuente | Mecanismo |
|---|---|---|
| `description` | `rag_chunks` (chunk_type='description') | Embeddings + filtros |
| `specs` | `rag_chunks` (chunk_type='specs') | Embeddings + filtros |
| `features` | `rag_chunks` (chunk_type='features') | Embeddings + filtros |
| `software` | `rag_chunks` (chunk_type='software', software_id) | Embeddings + JOIN |
| `relations` | `product_relations` | SQL puro |
| `available_filters` | `category_attributes` + `attribute_options` | SQL puro |
| `category_info` | `categories` | SQL puro |
| `specs_structured` (filtros numéricos) | `product_specs.specs_normalized` | SQL puro JSONB |

### Política de fallback

1. Si `confidence < 0.6` → ignorar `attribute_filters` y `spec_filters`,
   conservar solo `category_id`/producto detectado e `info_types`.
2. Si la query estructurada devuelve 0 resultados → relajar en este orden:
   `spec_filters` → `attribute_filters` → `is_new` → `category_id`.
3. Si la similarity devuelve <3 chunks → expandir `info_types` a
   `["description","specs","features"]`.

### Heurísticas de clasificación de `info_types`

| Patrón en pregunta | `info_types` | `structured_lookups` |
|---|---|---|
| "qué es X", "para qué sirve" | `description` | — |
| "specs de X", "qué throughput tiene" | `specs` (+ `specs_structured` si es numérica) | — |
| "router con throughput > 1Gbps" | `specs_structured`, `description` | — |
| "qué se recomienda con X" | — | `relations` |
| "qué software tiene X" | `software` | — |
| "qué filtros hay para routers" | — | `available_filters` |
| "compara X con Y" | `description`, `specs`, `features` | `relations` |

---

## 8. Queries SQL de referencia

```sql
-- 1) Productos nuevos de una categoría
SELECT p.id, p.name, p.brand
FROM products p
WHERE p.category_id = $1 AND p.is_new;

-- 2) Combinación de filtros taxonómicos (5G + WiFi=Si)
SELECT p.* FROM products p
WHERE p.category_id = $1
  AND EXISTS (
    SELECT 1 FROM product_attribute_values pav
    JOIN attribute_options ao ON ao.id = pav.attribute_option_id
    JOIN attributes a         ON a.id = pav.attribute_id
    WHERE pav.product_id = p.id
      AND a.taxonomy = 'pa_red-celular' AND ao.slug = '5g')
  AND EXISTS (
    SELECT 1 FROM product_attribute_values pav
    JOIN attribute_options ao ON ao.id = pav.attribute_option_id
    JOIN attributes a         ON a.id = pav.attribute_id
    WHERE pav.product_id = p.id
      AND a.taxonomy = 'pa_wifi' AND ao.slug = 'si');

-- 3) Filtro numérico sobre specs normalizadas
SELECT p.id, p.name,
       (ps.specs_normalized->>'throughput_lte_dl_mbps')::numeric AS throughput
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND (ps.specs_normalized->>'throughput_lte_dl_mbps')::numeric >= 1000
ORDER BY throughput DESC;

-- 4) Recomendados desde un producto
SELECT p.* FROM product_relations pr
JOIN products p ON p.id = pr.target_product_id
WHERE pr.source_product_id = (SELECT id FROM products WHERE slug = $1)
  AND pr.relation_type = 'recommended_product'
ORDER BY pr.weight DESC;

-- 5) Más recomendados dentro de una categoría
SELECT p.id, p.name, COUNT(*) AS times_recommended
FROM product_relations pr
JOIN products p ON p.id = pr.target_product_id
WHERE p.category_id = $1
  AND pr.relation_type = 'recommended_product'
GROUP BY p.id, p.name
ORDER BY times_recommended DESC LIMIT 10;

-- 6) Filtros disponibles para una categoría con conteo
SELECT a.name AS attribute, ao.name AS option,
       COUNT(DISTINCT pav.product_id) AS products
FROM category_attributes ca
JOIN attributes a         ON a.id = ca.attribute_id
JOIN attribute_options ao ON ao.attribute_id = a.id
LEFT JOIN product_attribute_values pav ON pav.attribute_option_id = ao.id
LEFT JOIN products p
       ON p.id = pav.product_id AND p.category_id = ca.category_id
WHERE ca.category_id = $1
GROUP BY a.id, a.name, ao.id, ao.name
ORDER BY a.name, ao.name;

-- 7) Retrieval RAG con prefiltrado (núcleo del backend del chatbot)
--    $1: vector de la query, $2: category_id, $3: is_new, $4: brand,
--    $5: attribute_slugs[], $6: chunk_types[]
SELECT c.id, c.product_id, c.software_id, c.chunk_type, c.content,
       1 - (c.embedding <=> $1::vector) AS similarity
FROM rag_chunks c
WHERE ($2::int    IS NULL OR c.category_id   = $2)
  AND ($3::bool   IS NULL OR c.is_new        = $3)
  AND ($4::text   IS NULL OR c.brand         = $4)
  AND ($5::text[] IS NULL OR c.attribute_slugs && $5)
  AND ($6::text[] IS NULL OR c.chunk_type    = ANY($6))
ORDER BY c.embedding <=> $1::vector
LIMIT 20;

-- 8) Claves disponibles de specs en una categoría (alimenta al extractor NLU)
SELECT DISTINCT jsonb_object_keys(ps.specs_normalized) AS spec_key
FROM product_specs ps
JOIN products p ON p.id = ps.product_id
WHERE p.category_id = $1
ORDER BY 1;

-- 9) Productos similares por specs (similarity entre embeddings de chunks 'specs')
SELECT p.id, p.name,
       AVG(1 - (c2.embedding <=> c1.embedding)) AS avg_sim
FROM rag_chunks c1
JOIN rag_chunks c2
  ON c2.product_id <> c1.product_id
 AND c2.chunk_type = 'specs'
 AND c2.category_id = c1.category_id
JOIN products p ON p.id = c2.product_id
WHERE c1.product_id = (SELECT id FROM products WHERE slug = $1)
  AND c1.chunk_type = 'specs'
GROUP BY p.id, p.name
ORDER BY avg_sim DESC LIMIT 5;
```

---

## 9. Plan de implementación por fases

| Fase | Trabajo | Salida | Esfuerzo |
|---|---|---|---|
| 1 | Crear DB y ejecutar `schema.sql` | DB lista | <1 h |
| 2 | ETL pasos 1–3 (taxonomía + atributos) | `categories`, `attributes`, `attribute_options`, `category_attributes` | medio día |
| 3 | ETL pasos 4–7 (software + productos + atributos por producto) | `software`, `products`, `product_attribute_values` | 1 día |
| 4 | ETL paso 8 (specs crudas) | `product_specs` con JSONB crudo | medio día |
| 5 | ETL paso 9 (normalización LLM de specs) | `specs_normalized` poblado | 1 día (incluye revisión claves huérfanas) |
| 6 | ETL paso 10 (relaciones) | `product_relations` | medio día |
| 7 | ETL paso 11 (chunks + embeddings) | `rag_chunks` poblado | 1 día |
| 8 | Diccionario inicial de `attribute_option_aliases` | sinónimos cargados | medio día |
| 9 | Endpoint de retrieval con la query 7 + extractor NLU | API funcional | 2–3 días |
| 10 | Métricas de operación y diccionario de huérfanos | dashboard mínimo | 1 día |

**Total estimado:** 8–10 días de trabajo enfocado para tener el RAG funcionando
end-to-end con prefiltrado real.

---

## 10. Operación y métricas

### Métricas mínimas a instrumentar desde día 1

- `% queries con filtros extraídos` por el NLU vs solo rank por similarity.
- `% queries con fallback activado` (señal de NLU fallando o vocabulario incompleto).
- `latencia P50/P95` de extract_filters y de la query 7.
- `chunks devueltos por chunk_type` — confirma que el filtrado por `info_types` funciona.
- `% claves nuevas creadas por producto en specs_normalized` — converge a 0 con el tiempo.

### Mantenimiento periódico

- **Mensual:** correr query de claves huérfanas de §5 y consolidar.
- **Mensual:** revisar log del NLU para sumar sinónimos a `attribute_option_aliases`.
- **Cuando el catálogo crezca >500 productos:** evaluar IVFFlat sobre `rag_chunks.embedding`.
- **Cuando llegue producto nuevo:** correr el ETL incremental (los hashes garantizan
  re-embeddear solo lo que cambió).

### Re-ingesta incremental

El sistema es idempotente por diseño:

1. `products.attributes_hash` y `products.specs_hash` detectan cambios estructurales.
2. `rag_chunks.content_hash` decide si re-embeddear cada chunk.
3. `software.content_hash` igual para software canónico.
4. `ingestion_runs` registra cada corrida con conteos
   (`chunks_created`, `chunks_updated`, `chunks_skipped`, `errors`).

Una re-corrida sin cambios reales cuesta 0 USD en embeddings y <30s de wall time.

---

## 11. Riesgos identificados

| Riesgo | Mitigación |
|---|---|
| Inconsistencia de claves entre productos en `specs_normalized` | Reuso de `known_keys_in_category` en el prompt + query mensual de huérfanas. |
| Extractor NLU saca filtros incorrectos | `confidence` umbral + fallback escalonado + log obligatorio. |
| Specs sin parsear (`raw_text` ambiguo) | Quedan en `specs` crudo; no se pierden. El LLM final puede leerlas vía retrieval por chunk `specs`. |
| Cambios en WooCommerce no se reflejan | ETL incremental con hashes corre periódicamente o por webhook. |
| Software huérfano (canónico borrado) | FK `ON DELETE SET NULL` en `software.canonical_product_id`; queries deben tolerar NULL. |
| Crecimiento que invalide el "sin índice vectorial" | Métrica de latencia P95; cuando supere umbral, una sola sentencia `CREATE INDEX` resuelve. |

---

## 12. Lo que NO está aquí (decisiones explícitamente fuera de scope)

- **Catálogo formal de `spec_keys`.** Reemplazado por `specs_normalized` JSONB autorregulado.
- **HNSW.** Se evalúa solo cuando `rag_chunks` supere ~10k filas.
- **Particionado de `rag_chunks`.** Solo a 100k+ filas.
