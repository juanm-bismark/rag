# Catálogo de preguntas — Bismark RAG

Referencia operativa del **extractor NLU + router de retrieval**. Cada entrada describe:

1. Qué pregunta del usuario resuelve.
2. Patrones de lenguaje natural que la disparan.
3. Qué entidades debe extraer el NLU.
4. Qué ruta de retrieval ejecutar (SQL puro, RAG, híbrido).
5. SQL o pipeline ejecutable contra el esquema actual de [schema.sql](schema.sql).
6. Criterios de fallback y anti-patrones.

**Premisas:**

- Esquema fuente: [schema.sql](schema.sql). Solo se usan columnas/índices que existen ahí.
- Volumen: 74 productos, 8 categorías, 13 marcas, 92 opciones de atributo, 80 recomendaciones, 7 grupos canónicos de software.
- Embedding model: `text-embedding-3-large` (3072 dims). Sin índice vectorial: seq scan + prefiltrado.
- `product_recommendations` es **mono-tipo** (solo `recommended_product`); no hay columna `relation_type`.
- `categories.name`/`slug` pueden ser placeholders si el ETL no tiene lookup a Woo; preferir `category_id` en filtros.

---

## 1. Contrato del extractor NLU

Toda pregunta del usuario debe convertirse en este objeto antes del retrieval:

```json
{
  "intent_id":          "B1_specs_numeric_threshold",
  "category_id":        516,
  "is_new":             null,
  "brand":              null,
  "product_refs":       ["robustel-eg5100"],
  "attribute_filters":  [
    {"taxonomy": "pa_red-celular", "option_slugs": ["5g"]}
  ],
  "spec_filters":       [
    {"spec_key": "throughput_lte_dl_mbps", "op": ">=", "value": 1000}
  ],
  "info_types":         ["specs", "description"],
  "structured_lookups": ["relations"],
  "confidence":         0.85
}
```

| Campo | Significado | Origen en el schema |
|---|---|---|
| `intent_id` | Pregunta canónica de este catálogo (ej. `A2_attr_combination`) | — |
| `category_id` | Filtro duro de categoría | `products.category_id`, `rag_chunks.category_id` |
| `is_new` | Filtro duro de novedad | `products.is_new`, `rag_chunks.is_new` |
| `brand` | Filtro duro de marca | `products.brand`, `rag_chunks.brand` |
| `product_refs` | Slugs ya resueltos a productos concretos | `products.slug` |
| `attribute_filters` | Filtros taxonómicos Woo | `attribute_option_aliases` -> `attribute_options` |
| `spec_filters` | Filtros numéricos / enum sobre JSONB | `product_specs.specs_normalized` |
| `info_types` | Subconjunto de `{overview, description, features, specs, spec_section, software, compatibility, variants}` | `rag_chunks.chunk_type` |
| `structured_lookups` | Subconjunto de `{relations, available_filters, category_info, specs_structured, software_lookup, compatibility_lookup}` | tablas relacionales / JSONB |
| `confidence` | [0,1]. < 0.6 dispara fallback | — |

---

## 2. Taxonomía rápida

| Grupo | Mecanismo | Cuándo aplica |
|---|---|---|
| **A. Filtros estructurales** | SQL puro sobre tablas relacionales | Pregunta enumera atributos / marca / categoría / `is_new` |
| **B. Filtros numéricos** | SQL sobre `specs_normalized` JSONB | Pregunta contiene umbral numérico u operador comparativo |
| **C. Recomendaciones** | SQL sobre `product_recommendations` | Pregunta menciona "recomendado", "acompañar", "complementario" |
| **D. Narrativa / semántica** | Embeddings `rag_chunks` + prefiltrado | Pregunta abierta: "qué hace", "para qué", "compara", "explícame" |
| **E. Híbridas** | A/B/C que reduce IDs -> D que narra | Pregunta mezcla criterios duros con explicación |
| **F. Metadata / UI** | SQL sobre `categories`, `attributes`, `category_attributes` | Pregunta sobre el propio catálogo (filtros, opciones, categorías) |
| **G. Operación** | SQL sobre `ingestion_runs`, sanity checks | Para el operador, no para el usuario final |

---

## 3. Preguntas — referencia detallada

### A1 — Productos nuevos en una categoría

- **Ejemplos:** "qué hay de nuevo en routers", "novedades en gateways industriales", "lo último que entró".
- **Triggers:** `nuevo|novedad|reciente|último|acaba de llegar`.
- **Entidades obligatorias:** `category_id` (puede inferirse del producto o pedirse).
- **Entidades opcionales:** `brand`.
- **Ruta:** SQL puro (sin RAG).
- **`info_types`:** `[]`. **`structured_lookups`:** `[]`.

```sql
SELECT id, name, brand, slug
FROM products
WHERE category_id = $1
  AND is_new
  AND ($2::text IS NULL OR brand = $2)
ORDER BY name;
```

- **Fallback:** si `category_id` no se pudo extraer y hay menos de 30 productos nuevos en total, devolver el listado global. Si hay más, pedir categoría.
- **Anti-patrón:** no usar RAG; "nuevo" es boolean duro.

---

### A2 — Productos por combinación de atributos taxonómicos

- **Ejemplos:** "routers 5G con WiFi", "antenas direccionales 5 dBi", "gateway con dual SIM y VPN".
- **Triggers:** combinación de tokens reconocidos en `attribute_option_aliases.alias`.
- **Entidades obligatorias:** `category_id` + `attribute_filters >= 1`.
- **Semántica:** AND entre atributos distintos, OR entre opciones del mismo atributo.
- **Ruta:** SQL puro.

```sql
SELECT p.id, p.name, p.brand, p.slug
FROM products p
WHERE p.category_id = $1
  AND ($2::bool IS NULL OR p.is_new = $2)
  AND ($3::text IS NULL OR p.brand = $3)
  -- repetir un EXISTS por cada attribute_filter
  AND EXISTS (
    SELECT 1 FROM product_attribute_values pav
    JOIN attribute_options ao ON ao.id = pav.attribute_option_id
    JOIN attributes a         ON a.id = ao.attribute_id
    WHERE pav.product_id = p.id
      AND a.taxonomy = 'pa_red-celular'
      AND ao.slug = ANY('{5g}'::text[])
  )
  AND EXISTS (
    SELECT 1 FROM product_attribute_values pav
    JOIN attribute_options ao ON ao.id = pav.attribute_option_id
    JOIN attributes a         ON a.id = ao.attribute_id
    WHERE pav.product_id = p.id
      AND a.taxonomy = 'pa_wifi'
      AND ao.slug = ANY('{si}'::text[])
  )
ORDER BY p.name;
```

- **Resolución de aliases:** convertir "móvil"/"celular"/"4G/LTE" -> option correcta vía `attribute_option_aliases` antes de armar la query.
- **Fallback escalonado** si devuelve 0:
  1. Quitar el filtro de menor prioridad (el último mencionado o el de menor selectividad histórica).
  2. Quitar `brand` si lo había.
  3. Quitar `is_new`.
  4. Si sigue en 0, escalar a D5 (RAG abierto en la categoría).
- **Anti-patrón:** no aceptar atributos no registrados en `attribute_option_aliases`; deben mapearse o ignorarse con warning.

---

### A3 — Marcas disponibles en una categoría

- **Ejemplos:** "qué marcas de routers tienen", "qué fabricantes manejan en IoT".
- **Triggers:** `marca|marcas|fabricante|fabricantes` + categoría.
- **Ruta:** SQL puro.

```sql
SELECT brand, COUNT(*) AS products
FROM products
WHERE category_id = $1 AND brand IS NOT NULL
GROUP BY brand
ORDER BY products DESC, brand;
```

---

### A4 — Productos que usan un software

- **Ejemplos:** "qué productos usan RobustOS", "dispositivos compatibles con Robustel Cloud Manager".
- **Triggers:** mención de un software canónico (resolver por `software.name` o `software_dedupe_group_id`).
- **Entidades obligatorias:** `software_id`.
- **Ruta:** SQL puro.

```sql
SELECT p.id, p.name, p.brand, p.slug
FROM products p
WHERE p.software_id = $1
ORDER BY p.name;
```

- **Combinable con D4** si la pregunta también quiere descripción del software.

---

### A4b — Software que usa un producto dado (dirección inversa de A4)

- **Ejemplos:** "qué software usa el EG5100", "qué plataforma de gestión trae el R1510", "con qué app se administra el X".
- **Triggers:** mención de un producto + `software|plataforma|app|gestión|administración|cloud manager`.
- **Entidades obligatorias:** `product_refs[0]`.
- **Ruta:** SQL puro (JOIN `products → software`).

```sql
SELECT s.id, s.name, s.dedupe_group_id, s.description_text
FROM products p
JOIN software s ON s.id = p.software_id
WHERE p.slug = $1;
```

- **Combinable con D4** si el usuario también pide "y explícame qué hace ese software" → tomar el `software.id` resultado y pasarlo a D4.
- **Fallback:** si `software_id` es NULL en el producto, responder "ese producto no tiene software de gestión canónico registrado" y, si aplica, ofrecer A4 invertido (buscar productos similares que sí lo tengan).

---

### A5 — Búsqueda de producto por nombre / modelo / alias

- **Ejemplos:** "tienen el EG5100", "tienen alguna antena modelo X300", "EG-5100".
- **Triggers:** strings con formato de modelo (regex: alfanumérico mixto, guiones), comillas, "tienen el ...".
- **Ruta:** SQL puro con fuzzy match.

```sql
-- search_text se materializa en minúscula (trigger en schema.sql).
-- pg_trgm es case-sensitive: hay que bajar $1 a minúscula para que matchee.
-- search_aliases no se usa por ahora (columna reservada para uso futuro).
SELECT id, name, brand, slug, category_id,
       similarity(search_text, lower($1)) AS sim
FROM products
WHERE search_text % lower($1)
ORDER BY sim DESC
LIMIT 5;
```

- **Fallback:** si `sim < 0.3` en todos los hits, escalar a D5 (RAG abierto) — puede ser que el usuario describa el producto sin nombrarlo.
- **Anti-patrón:** no usar RAG primero; los modelos son cadenas literales, embedding las pierde.

---

### A6 — Filtros disponibles para una categoría

- **Ejemplos:** "qué filtros puedo usar para routers", "qué opciones hay para antenas".
- **Uso típico:** alimentar UI dinámico o devolver al usuario qué dimensiones puede combinar.
- **Ruta:** SQL puro.

```sql
SELECT a.id, a.name, a.taxonomy,
       jsonb_agg(
         jsonb_build_object('id', ao.id, 'name', ao.name, 'slug', ao.slug)
         ORDER BY ao.name
       ) AS options
FROM category_attributes ca
JOIN attributes a         ON a.id = ca.attribute_id
JOIN attribute_options ao ON ao.attribute_id = a.id
WHERE ca.category_id = $1
GROUP BY a.id, a.name, a.taxonomy
ORDER BY a.name;
```

- Nota: `category_attributes` no tiene `display_order`; el orden lo decide el cliente.

---

### A7 — Filtros disponibles **con conteo de productos**

- **Ejemplos:** "cuántos routers 5G hay", "de las antenas, cuántas son omnidireccionales".
- **Ruta:** SQL puro.

```sql
-- FILTER asegura que solo cuenten productos dentro de la categoría pedida.
-- Sin el FILTER, productos de OTRAS categorías con la misma opción suman
-- al conteo porque pav.product_id no es NULL aunque p.id sí lo sea.
SELECT a.name AS attribute, ao.name AS option, ao.slug,
       COUNT(DISTINCT pav.product_id) FILTER (WHERE p.id IS NOT NULL) AS products
FROM category_attributes ca
JOIN attributes a         ON a.id = ca.attribute_id
JOIN attribute_options ao ON ao.attribute_id = a.id
LEFT JOIN product_attribute_values pav
       ON pav.attribute_option_id = ao.id
LEFT JOIN products p
       ON p.id = pav.product_id AND p.category_id = ca.category_id
WHERE ca.category_id = $1
GROUP BY a.id, a.name, ao.id, ao.name, ao.slug
ORDER BY a.name, products DESC, ao.name;
```

---

### A8 — Resolución de sinónimos (uso interno del NLU)

- **Ejemplos:** el usuario escribe "móvil", el NLU necesita resolverlo a `pa_red-celular:4g`.
- **Ruta:** SQL puro, paso previo a A2/E*.

```sql
-- Convención: aliases cargados en minúscula por el ETL. pg_trgm es
-- case-sensitive; bajar $1 a minúscula garantiza el match.
-- Si el ETL no normalizara, usar `lower(aoa.alias)` y crear un índice
-- GIN sobre `lower(alias) gin_trgm_ops` (no existe hoy en schema.sql).
SELECT ao.id, ao.slug, a.taxonomy, a.name AS attribute_name
FROM attribute_option_aliases aoa
JOIN attribute_options ao ON ao.id = aoa.attribute_option_id
JOIN attributes a         ON a.id = ao.attribute_id
WHERE aoa.alias % lower($1)
ORDER BY similarity(aoa.alias, lower($1)) DESC
LIMIT 5;
```

---

### A9 — Listado de categorías

- **Ejemplos:** "qué venden", "qué tipos de productos manejan", "qué hay en el catálogo".
- **Ruta:** SQL puro.

```sql
-- product_count se calcula on-the-fly: con 8 categorias y <500 productos no
-- justifica la denormalizacion (que ademas requeriria triggers para mantenerse
-- coherente). HAVING filtra categorias vacias.
SELECT c.id, c.name, c.slug, COUNT(p.id) AS product_count
FROM categories c
LEFT JOIN products p ON p.category_id = c.id
GROUP BY c.id, c.name, c.slug
HAVING COUNT(p.id) > 0
ORDER BY product_count DESC, c.name;
```

---

### A10 — Productos de una marca (con o sin categoría)

- **Ejemplos:** "qué tienen de Robustel", "todo lo de Teltonika en routers".
- **Ruta:** SQL puro.

```sql
SELECT id, name, slug, category_id, is_new
FROM products
WHERE brand = $1
  AND ($2::int IS NULL OR category_id = $2)
ORDER BY category_id, name;
```

---

### B1 — Filtro numérico con umbral

- **Ejemplos:** "routers con throughput mayor a 1 Gbps", "antenas de al menos 5 dBi", "gateways que soporten −40 °C".
- **Triggers:** número + unidad + operador (`mayor|menor|al menos|hasta|entre`).
- **Entidades obligatorias:** `category_id`, `spec_filters[]`.
- **Ruta:** SQL JSONB.
- **Vocabulario:** el extractor debe ofrecer al LLM la lista de `spec_keys` reales de la categoría (ver F1) antes de armar el filtro; nunca inventar claves.

```sql
SELECT p.id, p.name, p.brand, p.slug,
       (ps.specs_normalized->>$2)::numeric AS metric
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND ps.specs_normalized ? $2
  AND (ps.specs_normalized->>$2)::numeric >= $3
ORDER BY metric DESC
LIMIT 10;
```

- **Fallback:** si `spec_key` no existe en la categoría, devolver A6/A7 ("estos son los filtros válidos para esta categoría") y pedir reformulación.

---

### B2 — Rango cerrado

- **Ejemplos:** "antenas entre 5 y 9 dBi", "productos que operen entre −20 y 60 °C".
- **Ruta:** SQL JSONB; dos comparaciones.

```sql
SELECT p.id, p.name, p.brand,
       (ps.specs_normalized->>$2)::numeric AS metric
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND ps.specs_normalized ? $2
  AND (ps.specs_normalized->>$2)::numeric BETWEEN $3 AND $4
ORDER BY metric;
```

- **Para rangos de operación (min/max):** generar dos `spec_filters` (`*_min_<unit>` y `*_max_<unit>`).

---

### B3 — Pertenencia a lista enum (array contains)

- **Ejemplos:** "productos con WiFi 802.11ac", "antenas con conector SMA".
- **Ruta:** SQL JSONB con `@>`.

```sql
SELECT p.id, p.name, p.brand
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND ps.specs_normalized -> $2 @> to_jsonb($3::text);
```

- **Anti-patrón:** no confundir con A2; los enums duros viven en `product_attribute_values` (Woo), las listas heterogéneas viven en `specs_normalized`.

---

### B4 — Top-N por una spec (ranking)

- **Ejemplos:** "cuál es el router más rápido", "el de mayor ganancia".
- **Ruta:** SQL JSONB con `ORDER BY`.

```sql
SELECT p.id, p.name, p.brand,
       (ps.specs_normalized->>$2)::numeric AS metric
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND ps.specs_normalized ? $2
ORDER BY metric DESC NULLS LAST
LIMIT $3;
```

---

### B5 — Featurización binaria

- **Ejemplos:** "qué routers tienen puerto serial", "cuáles soportan VPN nativo".
- **Triggers:** `tiene|soporta|incluye|trae|cuenta con` + feature.
- **Ruta:** preferir A2 si la feature está en atributos taxonómicos; si no, SQL JSONB sobre clave booleana.

```sql
SELECT p.id, p.name, p.brand
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND (ps.specs_normalized->>$2)::boolean = true;
```

---

### B6 — Compatibilidad con otro equipo/accesorio

- **Ejemplos:** "qué antenas son compatibles con el EG5100", "con qué paneles funciona el X", "el R1510 es compatible con qué".
- **Triggers:** `compatible|funciona con|trabaja con|se acopla|admite|soporta` + otro producto/equipo.
- **Entidades obligatorias:** `product_refs[0]` (o token a buscar) y/o `category_id`.
- **Fuente:** `product_specs.compatibility` (JSONB array; estructura depende del crawler).
- **Ruta:** SQL puro sobre JSONB.

**B6a — Listar compatibilidades declaradas por un producto dado:**

```sql
SELECT ps.compatibility
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.slug = $1
  AND ps.compatibility <> '[]'::jsonb;
```

**B6b — Productos cuya compatibility contiene un término (texto libre o slug):**

```sql
SELECT p.id, p.name, p.brand
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE ($1::int IS NULL OR p.category_id = $1)
  AND ps.compatibility::text ILIKE '%' || $2 || '%'
ORDER BY p.name
LIMIT 20;
```

- **Anti-patrón:** no usar RAG sobre `description` para compatibilidad — el dato vive estructurado en `compatibility` JSONB. Solo escalar a D5 si `compatibility = '[]'` en todos los candidatos y el usuario insiste.
- **Fallback:** si B6b devuelve 0, intentar match difuso con `pg_trgm` sobre `compatibility::text`, o escalar a D5 con `info_types=['compatibility','description']`.

---

### C1 — Productos recomendados desde un producto

- **Ejemplos:** "qué se recomienda con el EG5100", "qué necesito para acompañar X", "complementos para Y".
- **Triggers:** `recomienda|acompañar|complemento|necesito para|con qué va`.
- **Entidades obligatorias:** `product_refs[0]`.
- **Ruta:** SQL puro.

```sql
SELECT p.id, p.name, p.brand, p.slug
FROM product_recommendations pr
JOIN products p ON p.id = pr.target_product_id
WHERE pr.source_product_id = (SELECT id FROM products WHERE slug = $1)
ORDER BY p.name;
```

- **Combinar con D1** si el usuario también pidió "y explícame por qué" (RAG sobre los `description` de los recomendados).

---

### C2 — Productos más recomendados de una categoría

- **Ejemplos:** "los más recomendados en gateways", "el más popular".
- **Ruta:** SQL puro.

```sql
SELECT p.id, p.name, p.brand, COUNT(*) AS times_recommended
FROM product_recommendations pr
JOIN products p ON p.id = pr.target_product_id
WHERE p.category_id = $1
GROUP BY p.id, p.name, p.brand
ORDER BY times_recommended DESC, p.name
LIMIT 10;
```

---

### C3 — Productos que recomiendan a uno dado (inversa)

- **Ejemplos:** "con qué productos se vende típicamente el X", "quién apunta al X como complemento".
- **Ruta:** SQL puro.

```sql
SELECT p.id, p.name, p.brand
FROM product_recommendations pr
JOIN products p ON p.id = pr.source_product_id
WHERE pr.target_product_id = (SELECT id FROM products WHERE slug = $1)
ORDER BY p.name;
```

---

### C4 — Recomendaciones cruzando categorías (qué se vende con qué)

- **Ejemplos:** "qué accesorios suelen ir con routers", "qué tipo de antena va con módems 5G".
- **Ruta:** SQL puro con JOIN doble a `categories`.

```sql
SELECT c.id AS target_category_id, c.name AS target_category,
       COUNT(*) AS edges
FROM product_recommendations pr
JOIN products src ON src.id = pr.source_product_id
JOIN products tgt ON tgt.id = pr.target_product_id
JOIN categories c ON c.id = tgt.category_id
WHERE src.category_id = $1
GROUP BY c.id, c.name
ORDER BY edges DESC;
```

---

### D1 — "¿Qué es / para qué sirve `<producto>`?"

- **Ejemplos:** "qué es el EG5100", "para qué sirve la antena X", "cuéntame del Robustel R1510".
- **Entidades obligatorias:** `product_refs[0]`.
- **`info_types`:** `["description"]`.
- **Ruta:** RAG con filtro duro por `product_id`.

```sql
SELECT id, content
FROM rag_chunks
WHERE product_id = (SELECT id FROM products WHERE slug = $1)
  AND chunk_type = 'description'
  AND embedding IS NOT NULL
ORDER BY embedding <=> $2::vector
LIMIT 3;
```

- En la práctica, si solo hay 1 chunk `description` por producto, traerlo directo sin ORDER BY embedding.

---

### D2 — Specs en lenguaje natural

- **Ejemplos:** "explícame las specs del EG5100", "qué interfaces tiene el R1510", "cuál es la conectividad del X".
- **`info_types`:** `["specs", "spec_section"]`.
- **Ruta:** RAG con filtro duro por `product_id` y `chunk_type IN ('specs','spec_section')`.

```sql
SELECT id, section_name, content,
       1 - (embedding <=> $2::vector) AS similarity
FROM rag_chunks
WHERE product_id = (SELECT id FROM products WHERE slug = $1)
  AND chunk_type IN ('specs','spec_section')
  AND embedding IS NOT NULL
ORDER BY embedding <=> $2::vector
LIMIT 5;
```

- **Si la pregunta es numérica** ("cuánto throughput tiene"), combinar con B1/B4 antes para devolver el dato exacto, y RAG solo si el LLM final lo necesita para contextualizar.

---

### D3 — Features narrativas

- **Ejemplos:** "qué tiene de especial el X", "qué destaca del Y", "ventajas del Z".
- **`info_types`:** `["features"]`.

```sql
SELECT id, content
FROM rag_chunks
WHERE product_id = (SELECT id FROM products WHERE slug = $1)
  AND chunk_type = 'features'
  AND embedding IS NOT NULL
ORDER BY embedding <=> $2::vector
LIMIT 3;
```

---

### D4 — Software de gestión

- **Ejemplos:** "qué hace Robustel Cloud Manager", "para qué sirve RCMS", "explícame la plataforma de gestión".
- **`info_types`:** `["software"]`.
- **Ruta:** RAG con `software_id`.

```sql
SELECT id, content
FROM rag_chunks
WHERE software_id = $1
  AND chunk_type = 'software'
  AND embedding IS NOT NULL
ORDER BY embedding <=> $2::vector
LIMIT 2;
```

- **Combinar con A4** si el usuario también pidió "y qué productos lo usan".

---

### D5 — Búsqueda semántica abierta dentro de una categoría

- **Ejemplos:** "necesito algo para conectar máquinas industriales a la nube", "quiero un router robusto para túneles".
- **Sin nombre de producto, pero con intención clara.**
- **Triggers:** descripción de caso de uso, ausencia de modelo concreto.
- **`info_types`:** `["description", "features"]` (preferir narrativa sobre specs).
- **Ruta:** RAG con prefiltrado.

```sql
-- $1: vector, $2: category_id, $3: is_new, $4: brand, $5: chunk_types[].
-- Atributos: el backend agrega un AND c.attribute_slugs && ARRAY[...]
-- por cada grupo de `attribute_filters` del NLU.
--
-- Ejemplo: attribute_filters = [
--   {"taxonomy":"pa_red-celular","option_slugs":["5g","4g"]},
--   {"taxonomy":"pa_wifi","option_slugs":["si"]}
-- ]
-- =>
--   AND c.attribute_slugs && ARRAY['pa_red-celular:5g','pa_red-celular:4g']
--   AND c.attribute_slugs && ARRAY['pa_wifi:si']
--
-- AND entre grupos (semántica esperada del usuario); OR dentro del grupo
-- via el contenido del array. NO aplanar todos los slugs en un único array
-- con && porque eso colapsa a OR global y devuelve falsos positivos.
SELECT c.id, c.product_id, c.chunk_type, c.content,
       1 - (c.embedding <=> $1::vector) AS similarity
FROM rag_chunks c
WHERE c.product_id IS NOT NULL
  AND c.embedding IS NOT NULL
  AND ($2::int    IS NULL OR c.category_id = $2)
  AND ($3::bool   IS NULL OR c.is_new      = $3)
  AND ($4::text   IS NULL OR c.brand       = $4)
  AND ($5::text[] IS NULL OR c.chunk_type  = ANY($5))
  -- + N cláusulas `c.attribute_slugs && ARRAY[...]` (una por grupo del NLU)
ORDER BY c.embedding <=> $1::vector
LIMIT 20;
```

- **Deduplicación obligatoria post-retrieval:** por `product_id` (no devolver 5 chunks del mismo producto al LLM final). Quedarse con el mejor por producto.
- **Fallback:**
  - <3 chunks por encima de `similarity > 0.55` -> expandir `info_types` a todos.
  - Sigue <3 -> quitar `attribute_filters`.
  - Sigue <3 -> quitar `category_id` y devolver lo mejor con disclaimer.

---

### D6 — Productos similares por specs

- **Ejemplos:** "alternativas al EG5100", "algo parecido al X pero más barato/robusto/...", "equivalente al Y".
- **Triggers:** `alternativa|parecido|similar|equivalente|en lugar de`.
- **Entidades obligatorias:** `product_refs[0]`.
- **Ruta:** RAG con similarity entre chunks técnicos (`specs`/`spec_section`) dentro de la misma categoría.

```sql
SELECT p.id, p.name, p.brand,
       AVG(1 - (c2.embedding <=> c1.embedding)) AS avg_sim
FROM rag_chunks c1
JOIN rag_chunks c2
  ON c2.product_id <> c1.product_id
 AND c2.chunk_type IN ('specs','spec_section')
 AND c2.category_id = c1.category_id
 AND c2.embedding IS NOT NULL
JOIN products p ON p.id = c2.product_id
WHERE c1.product_id = (SELECT id FROM products WHERE slug = $1)
  AND c1.chunk_type IN ('specs','spec_section')
  AND c1.embedding IS NOT NULL
GROUP BY p.id, p.name, p.brand
ORDER BY avg_sim DESC
LIMIT 5;
```

- **Anti-patrón:** no confundir con C1; "alternativa a" es similitud, "recomendado con" es complemento.

---

### E1 — Comparación entre dos productos

- **Ejemplos:** "compara EG5100 con R1510", "diferencia entre X y Y".
- **Entidades obligatorias:** `product_refs` con al menos 2 slugs.
- **`info_types`:** `["description", "specs", "features"]`.
- **Pipeline:**
  1. Resolver ambos slugs -> IDs.
  2. Por cada ID y cada `info_type`, traer top-1 chunk (sin ORDER BY embedding si solo hay un chunk por tipo).
  3. (Opcional) Cargar `specs_normalized` de ambos para tabla comparativa estructurada.
  4. Pasar todo al LLM final para que arme la comparación.

```sql
-- chunks de ambos productos
SELECT product_id, chunk_type, content
FROM rag_chunks
WHERE product_id IN (SELECT id FROM products WHERE slug IN ($1, $2))
  AND chunk_type IN ('description','specs','features')
ORDER BY product_id, chunk_type;

-- specs normalizadas (para tabla side-by-side)
SELECT p.slug, ps.specs_normalized
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.slug IN ($1, $2);
```

---

### E2 — Recomendación por caso de uso con criterios duros

- **Ejemplos:** "necesito un router para una flota de buses con throughput de al menos 300 Mbps y WiFi", "gateway industrial con dual SIM para minería".
- **Pipeline:** A2 + B1 -> shortlist de IDs -> D5 limitado a esos IDs.

```sql
-- paso 1: filtrar IDs por estructurado (combinar A2 y B1)
WITH filtered AS (
  SELECT p.id
  FROM products p
  JOIN product_specs ps ON ps.product_id = p.id
  WHERE p.category_id = $1
    AND (ps.specs_normalized->>'throughput_lte_dl_mbps')::numeric >= $2
    AND EXISTS (
      SELECT 1 FROM product_attribute_values pav
      JOIN attribute_options ao ON ao.id = pav.attribute_option_id
      JOIN attributes a         ON a.id = ao.attribute_id
      WHERE pav.product_id = p.id
        AND a.taxonomy = 'pa_wifi' AND ao.slug = 'si'
    )
)
-- paso 2: rankear narrativamente sobre esos IDs
SELECT c.product_id, c.chunk_type, c.content,
       1 - (c.embedding <=> $3::vector) AS similarity
FROM rag_chunks c
JOIN filtered f ON f.id = c.product_id
WHERE c.chunk_type IN ('description','features')
  AND c.embedding IS NOT NULL
ORDER BY c.embedding <=> $3::vector
LIMIT 10;
```

- **Si paso 1 devuelve 0:** fallback escalonado (B1 antes que A2; ver §4).

---

### E3 — "Qué accesorios necesito para `<producto>`"

- **Ejemplos:** "qué necesito para instalar el EG5100", "qué accesorios van con el X".
- **Pipeline:** C1 -> agrupar por categoría de los recomendados -> RAG sobre `description` para narrar.

---

### E4 — Brand-level overview

- **Ejemplos:** "qué tienen de Robustel", "cuéntame qué marcas manejan en routers y qué destaca de cada una".
- **Pipeline:** A10 -> por cada brand top, D5 abierto con `brand` filtrado y top-3 chunks `description`.

---

### F1 — Claves de specs disponibles en una categoría

- **Uso:** el NLU consulta esto **antes** de armar `spec_filters` para B*. Evita alucinar claves.

```sql
SELECT DISTINCT key
FROM product_specs ps
JOIN products p ON p.id = ps.product_id,
LATERAL jsonb_object_keys(ps.specs_normalized) AS key
WHERE p.category_id = $1
ORDER BY key;
```

---

### F2 — Distribución de una spec en una categoría

- **Uso:** "qué rango de throughput hay en routers" (orienta al usuario antes de filtrar).

```sql
-- jsonb_typeof guard: si la clave existe con valor no numérico (string
-- "Variable", booleano, array), el cast directo a numeric lanza error y
-- el query entero falla. Filtrar por type='number' lo previene.
WITH typed AS (
  SELECT CASE WHEN jsonb_typeof(ps.specs_normalized->$2) = 'number'
              THEN (ps.specs_normalized->>$2)::numeric
              ELSE NULL END AS metric,
         (ps.specs_normalized ? $2) AS has_key
  FROM products p
  JOIN product_specs ps ON ps.product_id = p.id
  WHERE p.category_id = $1
)
SELECT MIN(metric) AS min,
       MAX(metric) AS max,
       AVG(metric) AS avg,
       COUNT(*) FILTER (WHERE has_key) AS with_key,
       COUNT(*) AS total
FROM typed;
```

---

### F3 — Categorías que tienen un atributo dado

- **Uso:** "en qué categorías hay productos 5G".

```sql
SELECT DISTINCT c.id, c.name, c.slug
FROM products p
JOIN categories c                ON c.id = p.category_id
JOIN product_attribute_values pav ON pav.product_id = p.id
JOIN attribute_options ao        ON ao.id = pav.attribute_option_id
JOIN attributes a                ON a.id = ao.attribute_id
WHERE a.taxonomy = $1 AND ao.slug = $2;
```

---

### G1 — Salud de la última ingesta

```sql
SELECT id, started_at, finished_at,
       products_seen, chunks_created, chunks_updated, chunks_skipped,
       jsonb_array_length(errors) AS error_count
FROM ingestion_runs
ORDER BY started_at DESC
LIMIT 1;
```

---

### G2 — Productos sin embeddings (huecos del RAG)

```sql
SELECT p.id, p.slug, p.name
FROM products p
LEFT JOIN rag_chunks rc ON rc.product_id = p.id
WHERE rc.id IS NULL
ORDER BY p.id;
```

---

### G3 — Productos sin specs normalizadas (huecos del paso 9 LLM)

```sql
SELECT p.id, p.slug, p.name, p.category_id
FROM products p
LEFT JOIN product_specs ps ON ps.product_id = p.id
WHERE ps.specs_normalized IS NULL
   OR ps.specs_normalized = '{}'::jsonb
ORDER BY p.category_id, p.name;
```

---

### G4 — Claves de specs huérfanas (candidatas a fusionar)

```sql
SELECT key, COUNT(*) AS products_with_key,
       array_agg(p.slug ORDER BY p.slug) AS sample_slugs
FROM product_specs ps
JOIN products p ON p.id = ps.product_id,
LATERAL jsonb_object_keys(ps.specs_normalized) AS key
GROUP BY key
HAVING COUNT(*) < 3
ORDER BY products_with_key, key;
```

---

### G5 — Software canónico sin productos vinculados

```sql
SELECT s.id, s.dedupe_group_id, s.name
FROM software s
LEFT JOIN products p ON p.software_id = s.id
WHERE p.id IS NULL;
```

---

### G6 — Atributos sin opciones o opciones sin productos (basura del catálogo)

```sql
-- atributos huérfanos
SELECT a.id, a.taxonomy
FROM attributes a
LEFT JOIN attribute_options ao ON ao.attribute_id = a.id
WHERE ao.id IS NULL;

-- opciones sin uso
SELECT a.taxonomy, ao.slug, ao.name
FROM attribute_options ao
JOIN attributes a ON a.id = ao.attribute_id
LEFT JOIN product_attribute_values pav ON pav.attribute_option_id = ao.id
WHERE pav.product_id IS NULL
ORDER BY a.taxonomy, ao.slug;
```

---

## 4. Política global de fallback

Aplicada **después** de ejecutar la ruta principal y **antes** de devolver al LLM final.

1. **NLU `confidence < 0.6`:** descartar `attribute_filters` y `spec_filters`. Conservar `category_id`, `product_refs` y `info_types`. Si tampoco hay nada de eso, escalar a D5 global.
2. **Ruta estructurada (A*/B*/C*) devuelve 0 filas:** relajar en este orden:
   1. `spec_filters` (numéricos suelen ser muy estrictos).
   2. `attribute_filters` (último mencionado primero).
   3. `brand`.
   4. `is_new`.
   5. `category_id` (último recurso).
3. **Ruta RAG (D*) devuelve <3 chunks con `similarity > 0.55`:**
   1. Expandir `info_types` a `{description, specs, features}`.
   2. Quitar `attribute_filters`.
   3. Quitar `category_id` y avisar al LLM final ("resultados fuera de la categoría inferida").
4. **Híbrida (E*) con 0 IDs en el paso estructurado:** relajar el paso estructurado como en (2) y reintentar; si sigue vacío, escalar a D5 puro.

---

## 5. Reglas de inclusión/exclusión del retrieval

| Regla | Cuándo | Razón |
|---|---|---|
| Excluir chunks `software` del top-k de productos | siempre, salvo si `info_types` incluye `software` | Evita que el LLM final mezcle "el software hace X" con "el producto hace X". |
| Devolver máximo 1 chunk por `product_id` en D5 | siempre | Dedup post-retrieval; evita que un producto con muchos chunks domine. |
| Si `is_new=true` viene del NLU, es **duro** | siempre | El usuario pidió novedad explícita; no se relaja en fallback. |
| Excluir productos sin `product_specs` cuando la pregunta es técnica (B*, D2) | siempre | Devolver un producto sin specs en respuesta técnica es ruido. |
| Filtrar siempre por `category_id`, nunca por nombre/slug de categoría | siempre | `rag_chunks.category_id` está denormalizado e indexado; los nombres pueden ser placeholders. |

---

## 6. Anti-patrones explícitos

- **Usar RAG para "productos nuevos".** `is_new` es boolean; SQL puro (A1).
- **Usar RAG para "marca X".** `brand` es columna indexada; SQL puro (A10).
- **Usar RAG para buscar un modelo concreto.** `search_text` con pg_trgm cubre fuzzy (A5).
- **Construir `spec_filters` con claves inventadas.** Siempre validar contra F1 antes.
- **Devolver chunks `software` cuando la pregunta es sobre un producto.** Filtrar por `chunk_type` en función de `info_types`.
- **Tratar "recomendado" y "similar" como sinónimos.** C1/C2 son relaciones del catálogo; D6 es similitud por specs. Tienen orígenes y semánticas distintas.
- **Asumir `display_order` en `category_attributes` o `type` en `attributes`.** No existen en el schema.

---

## 7. Plantilla de salida para el LLM final

Después del retrieval, pasar al LLM final un payload con esta forma:

```json
{
  "user_question": "<texto original>",
  "intent_id": "E2_use_case_with_hard_criteria",
  "filters_applied": {
    "category": {"id": 516, "name": "Modems y Routers"},
    "attributes": [{"taxonomy": "pa_wifi", "options": ["si"]}],
    "spec_filters": [{"key": "throughput_lte_dl_mbps", "op": ">=", "value": 300}],
    "is_new": null,
    "brand": null,
    "fallback_relaxations": []
  },
  "structured_results": [
    {"product_id": 123, "slug": "robustel-eg5100", "metric": 450}
  ],
  "rag_chunks": [
    {
      "product_id": 123,
      "slug": "robustel-eg5100",
      "chunk_type": "description",
      "similarity": 0.78,
      "content": "..."
    }
  ],
  "warnings": []
}
```

- `filters_applied.fallback_relaxations`: array de strings con qué se relajó (ej. `["dropped:spec_filters"]`). El LLM final debe mencionarlo en su respuesta si el usuario fue muy específico.
- `warnings`: cosas que el LLM final debe saber pero el usuario no necesariamente (ej. "respuesta basada en 2 chunks por debajo de similarity 0.55").
