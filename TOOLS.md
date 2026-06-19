# Tool surface al LLM final — Bismark RAG

Define la **superficie de tools** que el LLM final invoca para responder preguntas
del catálogo. Es la capa pública que envuelve el pipeline de [SOLUCION.md §7](SOLUCION.md)
(extractor NLU + filter-then-rank) y consume el catálogo de intents de
[PREGUNTAS.md](PREGUNTAS.md).

**Relación con el resto del pipeline:**

```
Pregunta usuario
    │
    ▼
[Extractor NLU §7]  ──── produce el contrato JSON (intent_id, filters, info_types, ...)
    │
    ▼
[LLM final con tool-use]  ──── usa el contrato para elegir y parametrizar tools
    │
    ▼
[Tools de este documento]  ──── ejecutan SQL/embeddings y devuelven payloads tipados
    │
    ▼
[LLM final]  ──── compone la respuesta natural
```

El NLU **no es una tool** del LLM final: es un paso previo que normaliza la pregunta
al contrato del §1 de [PREGUNTAS.md](PREGUNTAS.md). Las tools consumen ese contrato
como argumentos estructurados.

---

**Implementación:** cada tool es una **función PL/pgSQL** expuesta vía Supabase RPC. El LLM (o n8n) las invoca con `supabase.rpc(name, { filter, query_embedding? })`. La función valida el `filter jsonb`, aplica routing/prefiltrado y devuelve la data. No hay adapter intermedio en TS — la validación y la query viven juntas en plpgsql. Las 2 tools que requieren embedding reciben `query_embedding vector(3072)` ya computado afuera de Postgres (por n8n llamando a Gemini `gemini-embedding-001` antes del RPC).

---

## 0. Quick reference para el LLM

Las 6 tools disponibles y cómo invocarlas. Cada una recibe `filter jsonb`. Las 2 con embedding reciben además `query_embedding vector(3072)` calculado por el caller.

| Tool | Cuándo usarla | Input mínimo | Output |
|------|---------------|--------------|--------|
| `search_products` | El usuario pide productos por categoría/marca/`is_new`/atributos/nombre fuzzy | `{ }` (todos opcionales) | `Array<{id, slug, name, brand, category_id, is_new, match_score?}>` |
| `filter_products_by_specs` | El usuario menciona umbral numérico, booleano, rango, compatibilidad | `{ category_id, spec_filters: [...] }` | `Array<{id, slug, name, brand, metric_values}>` |
| `get_recommendations` | El usuario pregunta por "recomendado", "acompañar", "complementos", "más vendido" | `{ mode, product_slug? \| category_id? }` | `{ mode, data: [...] }` |
| `get_product_narrative` | El usuario quiere descripción/specs/features de UN producto o software puntual | `{ product_slug \| software_id, info_types: [...] }` | `{ product \| software, chunks: [...] }` |
| `semantic_search` | Búsqueda abierta por caso de uso o "alternativa a X" sin nombre concreto | `(query_embedding, { category_id?, info_types?, mode? })` | `Array<{product_id, slug, name, brand, similarity, best_chunk}>` |
| `get_catalog_metadata` | El usuario o el LLM necesita metadata del catálogo (categorías, marcas, filtros, claves de specs, sinónimos) | `{ type, ... }` (discriminado por type) | `{ type, data: ... }` |

**Reglas duras para el LLM:**

1. **Antes** de llamar `filter_products_by_specs` con un `spec_key`, llamar `get_catalog_metadata({type:"list_spec_keys", category_id, prefix?})` para validar que la clave exista. Si no existe, no inventes — usa la lista devuelta para reformular.
2. **Antes** de armar `attribute_filters`, si el usuario usó un sinónimo ("móvil", "industrial"), llamar `get_catalog_metadata({type:"resolve_alias", term})` para resolverlo al `option_slug` correcto.
3. **Para preguntas semánticas abiertas** (D5), llamar `semantic_search` con `query_embedding` precomputado. **No** inventes embeddings.
4. **Para comparar 2 productos** (E1): llamar `get_product_narrative` por cada slug.
5. **Para caso de uso + criterios duros** (E2): primero `filter_products_by_specs` → tomar los `id` → pasar a `semantic_search.filter.product_ids_shortlist`.
6. **Categorías siempre por `category_id`**, nunca por nombre/slug.
7. Si una función devuelve error (`RAISE EXCEPTION`), leer el `message + HINT` y reformular. No reintentar el mismo input.

---

## 1. Decisión: ~6 tools agrupadas por mecanismo de retrieval

| Alternativa | Por qué se descarta |
|---|---|
| **Una sola tool `answer(query)`** | Opaca, sin trazabilidad, imposibilita componer híbridas (E1–E4), fallbacks quedan como if-else gigante. |
| **Una tool por intent (30+)** | El LLM se confunde entre intents casi idénticos (`A1` vs `A2` con `is_new=true`), surface enorme, system prompt costoso. |
| **6 tools por mecanismo** ✅ | Mapea 1:1 a los grupos A/B/C/D/F/G del catálogo. Composición natural para híbridas. Fallbacks encapsulados por tool. |

### Mapeo grupos → tools

| Tool | Cubre intents | Mecanismo subyacente |
|---|---|---|
| `search_products` | A1, A2, A4, A5, A10 | SQL puro sobre `products` + `product_attribute_values` |
| `filter_products_by_specs` | B1–B6 | SQL JSONB sobre `product_specs.specs_normalized` / `compatibility` |
| `get_recommendations` | C1–C4 | SQL puro sobre `product_recommendations` |
| `get_product_narrative` | D1–D4, A4b | RAG con filtro duro por `product_id` o `software_id` |
| `semantic_search` | D5, D6 | RAG con embedding + prefiltrado + dedup |
| `get_catalog_metadata` | A3, A6, A7, A8, A9, F1–F3 | SQL puro sobre tablas de catálogo |

Las **híbridas E1–E4 no tienen tool propia** — el LLM las compone llamando 2-3 de las
anteriores. Ver §3.

**G* (operación)** no es tool del LLM — son queries de operador que viven en [PREGUNTAS.md §G](PREGUNTAS.md) y se ejecutan directo contra la BD.

---

## 2. Firmas concretas

Sintaxis TypeScript del input/output porque mapea 1:1 a JSON Schema para tool-use de la API. Debajo de cada firma va la **implementación SQL real** de la función PL/pgSQL. Los fallbacks (cuando aplican) los maneja el caller (n8n), no la función — ver [PREGUNTAS.md §4](PREGUNTAS.md).

### 2.1 `search_products`

Cubre **A1, A2, A4, A5, A10**. Encuentra productos por filtros duros.

```typescript
type SearchProductsInput = {
  category_id?: number;          // A1, A2, A10
  brand?: string;                // A10, A1, A2
  is_new?: boolean;              // A1
  software_id?: number;          // A4
  attribute_filters?: Array<{    // A2 — AND entre grupos, OR dentro
    taxonomy: string;            // ej. "pa_red-celular"
    option_slugs: string[];      // ej. ["5g","4g"]
  }>;
  name_query?: string;           // A5 — fuzzy match contra search_text (search_aliases reservado, no activo)
  limit?: number;                // default 50
};

type SearchProductsOutput = Array<{
  id: number;
  slug: string;
  name: string;
  brand: string | null;
  category_id: number;
  is_new: boolean;
  match_score?: number;          // solo si vino name_query
}>;
```

**Validación interna:**

- Si `attribute_filters` trae aliases (ej. "móvil"), resolver vía `get_catalog_metadata({type:"resolve_alias",...})` **antes** de armar el filter. Si no resuelve, omitir y emitir warning.
- Si vienen ambos `name_query` y filtros estructurales, ambos se aplican (AND).

**Anti-patrón:** no aceptar `category_slug` o `category_name`. Solo `category_id`
(ver [PREGUNTAS.md §5](PREGUNTAS.md)).

**Implementación SQL:**

```sql
CREATE OR REPLACE FUNCTION public.search_products(filter jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  id          bigint,
  slug        text,
  name        text,
  brand       text,
  category_id int,
  is_new      boolean,
  match_score double precision
)
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter        jsonb := COALESCE(filter, '{}'::jsonb);
  v_category_id   int;
  v_brand         text;
  v_is_new        boolean;
  v_software_id   bigint;
  v_attr_filters  jsonb;
  v_name_query    text;
  v_limit         int;
BEGIN
  IF jsonb_typeof(v_filter) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'filter must be a json object';
  END IF;

  v_category_id  := NULLIF(v_filter->>'category_id', '')::int;
  v_brand        := NULLIF(trim(v_filter->>'brand'), '');
  v_is_new       := NULLIF(v_filter->>'is_new', '')::boolean;
  v_software_id  := NULLIF(v_filter->>'software_id', '')::bigint;
  v_attr_filters := v_filter->'attribute_filters';
  v_name_query   := LOWER(NULLIF(trim(v_filter->>'name_query'), ''));
  v_limit        := GREATEST(COALESCE((v_filter->>'limit')::int, 50), 1);

  RETURN QUERY
  WITH base AS (
    SELECT p.id, p.slug, p.name, p.brand, p.category_id, p.is_new, p.search_text
    FROM products p
    WHERE (v_category_id IS NULL OR p.category_id = v_category_id)
      AND (v_brand       IS NULL OR p.brand       = v_brand)
      AND (v_is_new      IS NULL OR p.is_new      = v_is_new)
      AND (v_software_id IS NULL OR p.software_id = v_software_id)
  ),
  attr_filtered AS (
    SELECT b.*
    FROM base b
    WHERE v_attr_filters IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM jsonb_array_elements(v_attr_filters) AS af
         WHERE NOT EXISTS (
           SELECT 1
           FROM product_attribute_values pav
           JOIN attribute_options ao ON ao.id = pav.attribute_option_id
           JOIN attributes a         ON a.id = ao.attribute_id
           WHERE pav.product_id = b.id
             AND a.taxonomy = af->>'taxonomy'
             AND ao.slug IN (SELECT jsonb_array_elements_text(af->'option_slugs'))
         )
       )
  )
  SELECT
    af.id, af.slug, af.name, af.brand, af.category_id, af.is_new,
    CASE WHEN v_name_query IS NULL THEN NULL
         ELSE similarity(af.search_text, v_name_query)::double precision
    END AS match_score
  FROM attr_filtered af
  WHERE v_name_query IS NULL OR af.search_text % v_name_query
  ORDER BY match_score DESC NULLS LAST, af.name
  LIMIT v_limit;
END;
$$;
```

---

### 2.2 `filter_products_by_specs`

Cubre **B1–B6**. Separada de `search_products` porque pega a
`product_specs.specs_normalized` JSONB y necesita validar `spec_key` contra F1.

```typescript
type SpecFilter =
  | { spec_key: string; op: ">=" | "<=" | ">" | "<" | "="; value: number }  // B1, B4
  | { spec_key: string; op: "between"; min: number; max: number }            // B2
  | { spec_key: string; op: "contains"; value: string }                      // B3
  | { spec_key: string; op: "is_true" };                                     // B5

type FilterProductsBySpecsInput = {
  category_id: number;            // obligatorio: spec_keys son category-specific
  spec_filters: SpecFilter[];
  compatibility_query?: {         // B6
    mode: "from_product" | "contains_term";
    product_slug?: string;        // B6a
    term?: string;                // B6b
  };
  brand?: string;
  is_new?: boolean;
  order_by?: { spec_key: string; dir: "asc" | "desc" };  // B4
  limit?: number;                 // default 10
};

type FilterProductsBySpecsOutput = Array<{
  id: number;
  slug: string;
  name: string;
  brand: string | null;
  metric_values: Record<string, number | string | boolean>;  // solo los spec_keys filtrados
}>;
```

**Pre-validación obligatoria (anti-alucinación):**

- La función consulta las claves reales de la categoría (F1) y **rechaza** `spec_keys`
  no existentes con `RAISE EXCEPTION`. No silenciar — el LLM debe reformular.
- Para `op` numéricos, usar `jsonb_typeof` guard como en [PREGUNTAS.md F2](PREGUNTAS.md)
  para no crashear con valores no numéricos.

**Implementación SQL:**

```sql
CREATE OR REPLACE FUNCTION public.filter_products_by_specs(filter jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE (
  id            bigint,
  slug          text,
  name          text,
  brand         text,
  metric_values jsonb
)
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter       jsonb := COALESCE(filter, '{}'::jsonb);
  v_category_id  int;
  v_brand        text;
  v_is_new       boolean;
  v_spec_filters jsonb;
  v_compat_mode  text;
  v_compat_slug  text;
  v_compat_term  text;
  v_limit        int;
  v_valid_keys   text[];
  sf jsonb; sk text;
BEGIN
  IF jsonb_typeof(v_filter) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'filter must be a json object';
  END IF;

  v_category_id  := NULLIF(v_filter->>'category_id', '')::int;
  IF v_category_id IS NULL THEN
    RAISE EXCEPTION 'category_id is required';
  END IF;

  v_brand        := NULLIF(trim(v_filter->>'brand'), '');
  v_is_new       := NULLIF(v_filter->>'is_new', '')::boolean;
  v_spec_filters := v_filter->'spec_filters';
  v_limit        := GREATEST(COALESCE((v_filter->>'limit')::int, 10), 1);

  v_compat_mode  := LOWER(COALESCE(NULLIF(trim(v_filter#>>'{compatibility_query,mode}'), ''), ''));
  v_compat_slug  := NULLIF(trim(v_filter#>>'{compatibility_query,product_slug}'), '');
  v_compat_term  := NULLIF(trim(v_filter#>>'{compatibility_query,term}'), '');
  IF v_compat_mode <> '' AND v_compat_mode NOT IN ('from_product','contains_term') THEN
    RAISE EXCEPTION 'compatibility_query.mode must be from_product or contains_term';
  END IF;

  -- Anti-alucinación: validar spec_keys contra las realmente presentes en la categoría
  IF jsonb_typeof(v_spec_filters) = 'array' THEN
    SELECT array_agg(DISTINCT key) INTO v_valid_keys
    FROM product_specs ps
    JOIN products p ON p.id = ps.product_id,
    LATERAL jsonb_object_keys(ps.specs_normalized) AS key
    WHERE p.category_id = v_category_id;

    FOR sf IN SELECT * FROM jsonb_array_elements(v_spec_filters) LOOP
      sk := sf->>'spec_key';
      IF NOT (sk = ANY(v_valid_keys)) THEN
        RAISE EXCEPTION 'spec_key % not found in category %', sk, v_category_id
          USING HINT = 'Valid keys: ' || array_to_string(v_valid_keys, ', ');
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT p.id, p.slug, p.name, p.brand, ps.specs_normalized, ps.compatibility
    FROM products p
    JOIN product_specs ps ON ps.product_id = p.id
    WHERE p.category_id = v_category_id
      AND (v_brand  IS NULL OR p.brand  = v_brand)
      AND (v_is_new IS NULL OR p.is_new = v_is_new)
  ),
  by_specs AS (
    SELECT b.*
    FROM base b
    WHERE v_spec_filters IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_spec_filters) AS f
         WHERE jsonb_typeof(b.specs_normalized->(f->>'spec_key')) <> 'null'
           AND CASE f->>'op'
             WHEN '>='      THEN (b.specs_normalized->>(f->>'spec_key'))::numeric < (f->>'value')::numeric
             WHEN '<='      THEN (b.specs_normalized->>(f->>'spec_key'))::numeric > (f->>'value')::numeric
             WHEN '>'       THEN (b.specs_normalized->>(f->>'spec_key'))::numeric <= (f->>'value')::numeric
             WHEN '<'       THEN (b.specs_normalized->>(f->>'spec_key'))::numeric >= (f->>'value')::numeric
             WHEN '='       THEN (b.specs_normalized->>(f->>'spec_key'))::numeric <> (f->>'value')::numeric
             WHEN 'between' THEN (b.specs_normalized->>(f->>'spec_key'))::numeric NOT BETWEEN (f->>'min')::numeric AND (f->>'max')::numeric
             WHEN 'is_true' THEN COALESCE((b.specs_normalized->>(f->>'spec_key'))::boolean, false) = false
             WHEN 'contains'THEN NOT (b.specs_normalized->(f->>'spec_key') @> to_jsonb(f->>'value'))
           END
       )
  ),
  by_compat AS (
    SELECT b.*
    FROM by_specs b
    WHERE v_compat_mode = ''
       OR (v_compat_mode = 'contains_term' AND b.compatibility::text ILIKE '%' || v_compat_term || '%')
       OR (v_compat_mode = 'from_product'  AND b.slug = v_compat_slug AND b.compatibility <> '[]'::jsonb)
  )
  SELECT
    b.id, b.slug, b.name, b.brand,
    COALESCE(
      (SELECT jsonb_object_agg(sf->>'spec_key', b.specs_normalized->(sf->>'spec_key'))
       FROM jsonb_array_elements(COALESCE(v_spec_filters, '[]'::jsonb)) AS sf),
      '{}'::jsonb
    ) AS metric_values
  FROM by_compat b
  LIMIT v_limit;
END;
$$;
```

---

### 2.3 `get_recommendations`

Cubre **C1, C2, C3, C4**. Una sola tool con discriminador `mode` evita 4 tools
casi idénticas.

```typescript
type GetRecommendationsInput = {
  mode: "from_product"          // C1
      | "to_product"            // C3 (inversa)
      | "top_in_category"       // C2
      | "category_to_category"; // C4
  product_slug?: string;        // C1, C3
  category_id?: number;         // C2, C4
  limit?: number;               // default 10
};

type GetRecommendationsOutput = {
  mode: "from_product" | "to_product" | "top_in_category" | "category_to_category";
  data:
    | Array<{ product_id: number; slug: string; name: string; brand: string | null }>                                       // from_product, to_product
    | Array<{ product_id: number; slug: string; name: string; brand: string | null; times_recommended: number }>            // top_in_category
    | Array<{ target_category_id: number; target_category_name: string; edges: number }>;                                   // category_to_category
};
```

**Anti-patrón:** no confundir con `semantic_search({mode:"similar_to_product"})`.
Recomendación es relación del catálogo (`product_recommendations`); similar es
similitud por embeddings de specs.

**Implementación SQL:**

```sql
CREATE OR REPLACE FUNCTION public.get_recommendations(filter jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb  -- shape: { mode, data } — data varía según mode
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter      jsonb := COALESCE(filter, '{}'::jsonb);
  v_mode        text;
  v_slug        text;
  v_category_id int;
  v_limit       int;
  v_pid         bigint;
  v_data        jsonb;
BEGIN
  v_mode := LOWER(COALESCE(NULLIF(trim(v_filter->>'mode'), ''), ''));
  IF v_mode NOT IN ('from_product','to_product','top_in_category','category_to_category') THEN
    RAISE EXCEPTION 'mode must be from_product, to_product, top_in_category, or category_to_category';
  END IF;

  v_slug        := NULLIF(trim(v_filter->>'product_slug'), '');
  v_category_id := NULLIF(v_filter->>'category_id', '')::int;
  v_limit       := GREATEST(COALESCE((v_filter->>'limit')::int, 10), 1);

  IF v_mode IN ('from_product','to_product') AND v_slug IS NULL THEN
    RAISE EXCEPTION 'mode % requires product_slug', v_mode;
  END IF;
  IF v_mode IN ('top_in_category','category_to_category') AND v_category_id IS NULL THEN
    RAISE EXCEPTION 'mode % requires category_id', v_mode;
  END IF;

  IF v_mode IN ('from_product','to_product') THEN
    SELECT p.id INTO v_pid FROM products p WHERE p.slug = v_slug;
    IF v_pid IS NULL THEN
      RAISE EXCEPTION 'product_slug % not found', v_slug;
    END IF;
  END IF;

  IF v_mode = 'from_product' THEN
    SELECT jsonb_agg(jsonb_build_object(
             'product_id', sub.id, 'slug', sub.slug, 'name', sub.name, 'brand', sub.brand
           ) ORDER BY sub.name)
    INTO v_data
    FROM (SELECT p.id, p.slug, p.name, p.brand
          FROM product_recommendations pr
          JOIN products p ON p.id = pr.target_product_id
          WHERE pr.source_product_id = v_pid
          ORDER BY p.name LIMIT v_limit) sub;

  ELSIF v_mode = 'to_product' THEN
    SELECT jsonb_agg(jsonb_build_object(
             'product_id', sub.id, 'slug', sub.slug, 'name', sub.name, 'brand', sub.brand
           ) ORDER BY sub.name)
    INTO v_data
    FROM (SELECT p.id, p.slug, p.name, p.brand
          FROM product_recommendations pr
          JOIN products p ON p.id = pr.source_product_id
          WHERE pr.target_product_id = v_pid
          ORDER BY p.name LIMIT v_limit) sub;

  ELSIF v_mode = 'top_in_category' THEN
    SELECT jsonb_agg(jsonb_build_object(
             'product_id', sub.id, 'slug', sub.slug, 'name', sub.name, 'brand', sub.brand,
             'times_recommended', sub.cnt
           ) ORDER BY sub.cnt DESC, sub.name)
    INTO v_data
    FROM (SELECT p.id, p.slug, p.name, p.brand, COUNT(*)::bigint AS cnt
          FROM product_recommendations pr
          JOIN products p ON p.id = pr.target_product_id
          WHERE p.category_id = v_category_id
          GROUP BY p.id, p.slug, p.name, p.brand
          ORDER BY COUNT(*) DESC, p.name LIMIT v_limit) sub;

  ELSE  -- category_to_category
    SELECT jsonb_agg(jsonb_build_object(
             'target_category_id', sub.id, 'target_category_name', sub.name, 'edges', sub.cnt
           ) ORDER BY sub.cnt DESC)
    INTO v_data
    FROM (SELECT c.id, c.name, COUNT(*)::bigint AS cnt
          FROM product_recommendations pr
          JOIN products src ON src.id = pr.source_product_id
          JOIN products tgt ON tgt.id = pr.target_product_id
          JOIN categories c ON c.id = tgt.category_id
          WHERE src.category_id = v_category_id
          GROUP BY c.id, c.name
          ORDER BY COUNT(*) DESC LIMIT v_limit) sub;
  END IF;

  RETURN jsonb_build_object('mode', v_mode, 'data', COALESCE(v_data, '[]'::jsonb));
END;
$$;
```

---

### 2.4 `get_product_narrative`

Cubre **D1, D2, D3, D4, A4b**. "Dame info textual de UN producto/software".

```typescript
type GetProductNarrativeInput = {
  product_slug?: string;        // D1, D2, D3, A4b
  software_id?: number;         // D4
  info_types: Array<
    | "description"             // D1
    | "specs"                   // D2
    | "spec_section"            // D2
    | "features"                // D3
    | "software"                // D4
  >;
  query_text?: string;          // opcional: rankea chunks por embedding si viene
  limit_per_type?: number;      // default 3
};

type GetProductNarrativeOutput = {
  product?: {
    id: number;
    slug: string;
    name: string;
    brand: string;
    software_id: number | null;
  };
  software?: {
    id: number;
    name: string;
    dedupe_group_id: number;
  };
  chunks: Array<{
    chunk_type: string;
    section_name: string | null;
    content: string;
    similarity?: number;        // solo si vino query_text
  }>;
};
```

**Clave de diseño:** `query_embedding` es **opcional**.

- Si el usuario pregunta "qué es el EG5100" → no hace falta ranking (solo hay 1
  chunk `description` por producto). El caller invoca sin `query_embedding`, la función trae directo.
- Si el usuario pregunta "cuál es el throughput del EG5100" → el caller (n8n) calcula el embedding del query con Gemini (`gemini-embedding-001`) y lo pasa al RPC; la función ordena chunks por cosine.

**Validación:** uno y solo uno de `product_slug` / `software_id` debe venir.

**Implementación SQL:**

Esta tool recibe `query_embedding` **opcional**. Si viene, rankea los chunks por cosine; si no, trae los primeros por chunk_type. El embedding lo computa n8n con Gemini (`gemini-embedding-001`) antes del RPC cuando aplica.

```sql
CREATE OR REPLACE FUNCTION public.get_product_narrative(
  filter          jsonb           DEFAULT '{}'::jsonb,
  query_embedding vector(3072)    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter         jsonb := COALESCE(filter, '{}'::jsonb);
  v_product_slug   text;
  v_software_id    bigint;
  v_info_types     text[];
  v_limit_per_type int;
  v_product_id     bigint;
  v_product        jsonb;
  v_software       jsonb;
  v_chunks         jsonb;
BEGIN
  v_product_slug   := NULLIF(trim(v_filter->>'product_slug'), '');
  v_software_id    := NULLIF(v_filter->>'software_id', '')::bigint;
  v_limit_per_type := GREATEST(COALESCE((v_filter->>'limit_per_type')::int, 3), 1);

  IF (v_product_slug IS NULL AND v_software_id IS NULL)
     OR (v_product_slug IS NOT NULL AND v_software_id IS NOT NULL) THEN
    RAISE EXCEPTION 'exactly one of product_slug or software_id is required';
  END IF;

  IF jsonb_typeof(v_filter->'info_types') <> 'array' THEN
    RAISE EXCEPTION 'info_types must be an array';
  END IF;
  SELECT array_agg(value) INTO v_info_types
  FROM jsonb_array_elements_text(v_filter->'info_types');
  IF v_info_types IS NULL OR array_length(v_info_types, 1) = 0 THEN
    RAISE EXCEPTION 'info_types must have at least one type';
  END IF;

  IF v_product_slug IS NOT NULL THEN
    SELECT id INTO v_product_id FROM products WHERE slug = v_product_slug;
    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'product_slug % not found', v_product_slug;
    END IF;

    SELECT jsonb_build_object('id', p.id, 'slug', p.slug, 'name', p.name,
                              'brand', p.brand, 'software_id', p.software_id)
    INTO v_product
    FROM products p WHERE p.id = v_product_id;

    SELECT jsonb_agg(jsonb_build_object(
             'chunk_type',   chunk_type,
             'section_name', section_name,
             'content',      content,
             'similarity',   CASE WHEN query_embedding IS NOT NULL
                                  THEN (1 - (embedding <=> query_embedding))::double precision
                                  ELSE NULL END
           ))
    INTO v_chunks
    FROM (
      SELECT c.*,
             ROW_NUMBER() OVER (
               PARTITION BY c.chunk_type
               ORDER BY CASE WHEN query_embedding IS NOT NULL
                             THEN c.embedding <=> query_embedding
                             ELSE 0 END,
                        c.id
             ) AS rn
      FROM rag_chunks c
      WHERE c.product_id = v_product_id
        AND c.chunk_type = ANY(v_info_types)
        AND (query_embedding IS NULL OR c.embedding IS NOT NULL)
    ) ranked
    WHERE rn <= v_limit_per_type;

    RETURN jsonb_build_object('product', v_product, 'chunks', COALESCE(v_chunks, '[]'::jsonb));
  ELSE
    SELECT jsonb_build_object('id', s.id, 'name', s.name)
    INTO v_software
    FROM software s WHERE s.id = v_software_id;
    IF v_software IS NULL THEN
      RAISE EXCEPTION 'software_id % not found', v_software_id;
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
             'chunk_type',   chunk_type,
             'section_name', section_name,
             'content',      content,
             'similarity',   CASE WHEN query_embedding IS NOT NULL
                                  THEN (1 - (embedding <=> query_embedding))::double precision
                                  ELSE NULL END
           ))
    INTO v_chunks
    FROM (
      SELECT c.*,
             ROW_NUMBER() OVER (
               PARTITION BY c.chunk_type
               ORDER BY CASE WHEN query_embedding IS NOT NULL
                             THEN c.embedding <=> query_embedding
                             ELSE 0 END,
                        c.id
             ) AS rn
      FROM rag_chunks c
      WHERE c.software_id = v_software_id
        AND c.chunk_type = ANY(v_info_types)
        AND (query_embedding IS NULL OR c.embedding IS NOT NULL)
    ) ranked
    WHERE rn <= v_limit_per_type;

    RETURN jsonb_build_object('software', v_software, 'chunks', COALESCE(v_chunks, '[]'::jsonb));
  END IF;
END;
$$;
```

---

### 2.5 `semantic_search`

Cubre **D5, D6**. La única tool que calcula embedding de la query.

```typescript
type SemanticSearchInput = {
  mode: "open"                  // D5
      | "similar_to_product";   // D6
  query_text?: string;          // D5 — el caller (n8n) calcula el embedding antes del RPC
  reference_product_slug?: string; // D6
  category_id?: number;
  brand?: string;
  is_new?: boolean;
  attribute_filters?: Array<{
    taxonomy: string;
    option_slugs: string[];
  }>;
  info_types?: Array<"description" | "features" | "specs" | "spec_section">;
  product_ids_shortlist?: number[];  // E2: IDs pre-filtrados por otra tool
  limit?: number;               // default 5 productos (no chunks)
};

type SemanticSearchOutput = Array<{
  product_id: number;
  slug: string;
  name: string;
  brand: string;
  similarity: number;           // mejor chunk del producto (post-dedup)
  best_chunk: {
    chunk_type: string;
    content: string;
  };
}>;
```

**Tres puntos críticos del contrato:**

1. **`product_ids_shortlist` habilita las híbridas E***. `search_products` o
   `filter_products_by_specs` devuelven IDs, el LLM las pasa acá. Sin esto,
   E2 sería imposible de componer.
2. **Dedup por `product_id` dentro de la tool**, no en el LLM. Devolver "5 chunks
   del mismo producto" satura el contexto.
3. **El embedding lo calcula el caller (n8n)**, no el LLM. Nunca exponer vectores en
   la firma pública.

**Fallback interno (ver [PREGUNTAS.md §4.3](PREGUNTAS.md)):**

La función SQL **no implementa fallbacks** — devuelve lo que el filter permite. El caller (n8n / backend) detecta `<3 productos con similarity > 0.55` y reintenta con parámetros relajados:

1. Expandir `info_types` a todos.
2. Quitar `attribute_filters`.
3. Quitar `category_id` y registrar `warnings: ["category_dropped"]`.

Esto mantiene la función pura y la orquestación de fallback en el caller.

**Implementación SQL:**

```sql
CREATE OR REPLACE FUNCTION public.semantic_search(
  query_embedding vector(3072),
  filter          jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  product_id bigint,
  slug       text,
  name       text,
  brand      text,
  similarity double precision,
  best_chunk jsonb
)
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter        jsonb := COALESCE(filter, '{}'::jsonb);
  v_mode          text;
  v_category_id   int;
  v_brand         text;
  v_is_new        boolean;
  v_info_types    text[];
  v_attr_filters  jsonb;
  v_shortlist     bigint[];
  v_ref_slug      text;
  v_ref_id        bigint;
  v_limit         int;
BEGIN
  IF query_embedding IS NULL THEN
    RAISE EXCEPTION 'query_embedding cannot be null';
  END IF;

  v_mode := LOWER(COALESCE(NULLIF(trim(v_filter->>'mode'), ''), 'open'));
  IF v_mode NOT IN ('open','similar_to_product') THEN
    RAISE EXCEPTION 'mode must be open or similar_to_product';
  END IF;

  v_category_id := NULLIF(v_filter->>'category_id', '')::int;
  v_brand       := NULLIF(trim(v_filter->>'brand'), '');
  v_is_new      := NULLIF(v_filter->>'is_new', '')::boolean;
  v_limit       := GREATEST(COALESCE((v_filter->>'limit')::int, 5), 1);
  v_ref_slug    := NULLIF(trim(v_filter->>'reference_product_slug'), '');

  IF jsonb_typeof(v_filter->'info_types') = 'array' THEN
    SELECT array_agg(value) INTO v_info_types
    FROM jsonb_array_elements_text(v_filter->'info_types');
  END IF;

  IF jsonb_typeof(v_filter->'product_ids_shortlist') = 'array' THEN
    SELECT array_agg((value)::bigint) INTO v_shortlist
    FROM jsonb_array_elements_text(v_filter->'product_ids_shortlist');
  END IF;

  v_attr_filters := v_filter->'attribute_filters';

  IF v_mode = 'similar_to_product' THEN
    SELECT id INTO v_ref_id FROM products WHERE slug = v_ref_slug;
    IF v_ref_id IS NULL THEN
      RAISE EXCEPTION 'reference_product_slug % not found', v_ref_slug;
    END IF;
  END IF;

  RETURN QUERY
  WITH ranked AS (
    SELECT c.product_id, c.chunk_type, c.content,
           p.slug, p.name, p.brand,
           (1 - (c.embedding <=> query_embedding))::double precision AS sim,
           ROW_NUMBER() OVER (
             PARTITION BY c.product_id
             ORDER BY c.embedding <=> query_embedding
           ) AS rn
    FROM rag_chunks c
    JOIN products p ON p.id = c.product_id   -- prefiltro por JOIN; descarta chunks software (product_id NULL)
    WHERE c.embedding  IS NOT NULL
      AND (v_category_id IS NULL OR p.category_id = v_category_id)
      AND (v_is_new      IS NULL OR p.is_new      = v_is_new)
      AND (v_brand       IS NULL OR p.brand       = v_brand)
      AND (v_info_types  IS NULL OR c.chunk_type  = ANY(v_info_types))
      AND (v_shortlist   IS NULL OR c.product_id  = ANY(v_shortlist))
      AND (v_ref_id      IS NULL OR c.product_id <> v_ref_id)
      -- attribute_filters: AND entre grupos, OR dentro del grupo. Un EXISTS por
      -- grupo sobre product_attribute_values (mismo patrón que search_products,
      -- §2.1), que es la fuente de verdad de los atributos.
      AND (
        v_attr_filters IS NULL
        OR NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_attr_filters) AS af
          WHERE NOT EXISTS (
            SELECT 1 FROM product_attribute_values pav
            JOIN attribute_options ao ON ao.id = pav.attribute_option_id
            JOIN attributes a         ON a.id = ao.attribute_id
            WHERE pav.product_id = c.product_id
              AND a.taxonomy = af->>'taxonomy'
              AND ao.slug IN (SELECT jsonb_array_elements_text(af->'option_slugs'))
          )
        )
      )
  )
  SELECT r.product_id, r.slug, r.name, r.brand, r.sim,
         jsonb_build_object('chunk_type', r.chunk_type, 'content', r.content) AS best_chunk
  FROM ranked r
  WHERE r.rn = 1
  ORDER BY r.sim DESC
  LIMIT v_limit;
END;
$$;
```

---

### 2.6 `get_catalog_metadata`

Cubre **A3, A6, A7, A8, A9, F1, F2, F3**. Tool "navaja suiza" para metadata —
los lookups que el LLM consulta **antes** de armar filtros.

```typescript
type GetCatalogMetadataInput =
  | { type: "list_categories" }                                                                                       // A9
  | { type: "list_brands_in_category"; category_id: number }                                                          // A3
  | { type: "list_attributes_for_category"; category_id: number; with_counts?: boolean }                              // A6, A7
  | { type: "resolve_alias"; term: string }                                                                           // A8
  | { type: "list_spec_keys"; category_id: number; prefix?: string; with_counts?: boolean; limit?: number }           // F1
  | { type: "spec_distribution"; category_id: number; spec_key: string }                                              // F2
  | { type: "categories_with_attribute"; taxonomy: string; option_slug: string };                                     // F3

// Output: { type, data } discriminado por `type`. Shapes de `data`:
// - list_categories: Array<{id, name, slug, product_count}>
// - list_brands_in_category: Array<{brand, products}>
// - list_attributes_for_category: Array<{attribute_id, name, taxonomy, options: Array<{id, name, slug, products?}>}>
// - resolve_alias: Array<{option_id, slug, taxonomy, attribute_name, similarity}>
// - list_spec_keys:
//     • with_counts=false (default): Array<string>                        — solo nombres
//     • with_counts=true:            Array<{key, products}>               — ordenado por cobertura desc
//     • prefix:"wifi_": filtra keys que empiezan con ese prefijo (caso típico: el LLM ya sabe qué grupo busca)
//     • limit (default 100): cap superior; la cat 516 tiene ~200 keys, sin prefix se trunca
// - spec_distribution: {min, max, avg, with_key, total}
// - categories_with_attribute: Array<{id, name, slug}>
```

Aceptable como navaja suiza porque los outputs son pequeños y el LLM rara vez encadena
más de un lookup en la misma respuesta.

**Cuándo el LLM llama esto:**

- Antes de `filter_products_by_specs` → `list_spec_keys` para no alucinar claves.
- Antes de `search_products` con aliases → `resolve_alias` (aunque
  `search_products` también lo hace internamente; redundante pero seguro).
- Cuando el usuario pregunta directamente por metadata ("qué marcas hay", "qué
  categorías venden", "qué filtros puedo usar").

**Implementación SQL:**

Esta tool devuelve `jsonb` con shape discriminado por `type`. Eso evita una `RETURNS TABLE` con 20 columnas mayormente NULL.

```sql
CREATE OR REPLACE FUNCTION public.get_catalog_metadata(filter jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = public, extensions
AS $$
DECLARE
  v_filter      jsonb := COALESCE(filter, '{}'::jsonb);
  v_type        text;
  v_category_id int;
  v_spec_key    text;
  v_term        text;
  v_taxonomy    text;
  v_option_slug text;
  v_with_counts boolean;
  v_prefix      text;
  v_limit_keys  int;
  v_result      jsonb;
BEGIN
  v_type := LOWER(COALESCE(NULLIF(trim(v_filter->>'type'), ''), ''));
  IF v_type NOT IN (
    'list_categories','list_brands_in_category','list_attributes_for_category',
    'resolve_alias','list_spec_keys','spec_distribution','categories_with_attribute'
  ) THEN
    RAISE EXCEPTION 'type must be one of the supported metadata types';
  END IF;

  v_category_id := NULLIF(v_filter->>'category_id', '')::int;
  v_spec_key    := NULLIF(trim(v_filter->>'spec_key'), '');
  v_term        := NULLIF(trim(v_filter->>'term'), '');
  v_taxonomy    := NULLIF(trim(v_filter->>'taxonomy'), '');
  v_option_slug := NULLIF(trim(v_filter->>'option_slug'), '');
  v_with_counts := COALESCE((v_filter->>'with_counts')::boolean, false);
  v_prefix      := NULLIF(trim(v_filter->>'prefix'), '');           -- usado solo en list_spec_keys
  v_limit_keys  := GREATEST(COALESCE((v_filter->>'limit')::int, 100), 1);

  IF v_type = 'list_categories' THEN
    SELECT jsonb_agg(jsonb_build_object(
             'id', id, 'name', name, 'slug', slug, 'product_count', p_count
           ) ORDER BY p_count DESC, name)
    INTO v_result
    FROM (
      SELECT c.id, c.name, c.slug, COUNT(p.id) AS p_count
      FROM categories c
      LEFT JOIN products p ON p.category_id = c.id
      GROUP BY c.id, c.name, c.slug
      HAVING COUNT(p.id) > 0
    ) c;

  ELSIF v_type = 'list_brands_in_category' THEN
    IF v_category_id IS NULL THEN RAISE EXCEPTION 'category_id required'; END IF;
    SELECT jsonb_agg(jsonb_build_object('brand', brand, 'products', products) ORDER BY products DESC, brand)
    INTO v_result
    FROM (
      SELECT brand, COUNT(*) AS products
      FROM products
      WHERE category_id = v_category_id AND brand IS NOT NULL
      GROUP BY brand
    ) b;

  ELSIF v_type = 'list_attributes_for_category' THEN
    IF v_category_id IS NULL THEN RAISE EXCEPTION 'category_id required'; END IF;
    SELECT jsonb_agg(jsonb_build_object(
             'attribute_id', a.id, 'name', a.name, 'taxonomy', a.taxonomy,
             'options', opts
           ) ORDER BY a.name)
    INTO v_result
    FROM category_attributes ca
    JOIN attributes a ON a.id = ca.attribute_id,
    LATERAL (
      SELECT CASE WHEN v_with_counts THEN
        jsonb_agg(jsonb_build_object('id', ao.id, 'name', ao.name, 'slug', ao.slug,
                                     'products', (
                                       SELECT COUNT(DISTINCT pav.product_id)
                                       FROM product_attribute_values pav
                                       JOIN products p ON p.id = pav.product_id
                                       WHERE pav.attribute_option_id = ao.id
                                         AND p.category_id = ca.category_id
                                     )) ORDER BY ao.name)
      ELSE
        jsonb_agg(jsonb_build_object('id', ao.id, 'name', ao.name, 'slug', ao.slug)
                  ORDER BY ao.name)
      END AS opts
      FROM attribute_options ao
      WHERE ao.attribute_id = a.id
    ) o
    WHERE ca.category_id = v_category_id;

  ELSIF v_type = 'resolve_alias' THEN
    IF v_term IS NULL THEN RAISE EXCEPTION 'term required'; END IF;
    SELECT jsonb_agg(jsonb_build_object(
             'option_id', ao.id, 'slug', ao.slug,
             'taxonomy', a.taxonomy, 'attribute_name', a.name,
             'similarity', similarity(aoa.alias, LOWER(v_term))
           ) ORDER BY similarity(aoa.alias, LOWER(v_term)) DESC)
    INTO v_result
    FROM attribute_option_aliases aoa
    JOIN attribute_options ao ON ao.id = aoa.attribute_option_id
    JOIN attributes a         ON a.id = ao.attribute_id
    WHERE aoa.alias % LOWER(v_term)
    LIMIT 5;

  ELSIF v_type = 'list_spec_keys' THEN
    -- prefix opcional + limit default 100 + with_counts opcional para priorizar keys cubiertas
    IF v_category_id IS NULL THEN RAISE EXCEPTION 'category_id required'; END IF;
    IF v_with_counts THEN
      SELECT jsonb_agg(jsonb_build_object('key', key, 'products', cnt) ORDER BY cnt DESC, key)
      INTO v_result
      FROM (
        SELECT key, COUNT(DISTINCT ps.product_id) AS cnt
        FROM product_specs ps
        JOIN products p ON p.id = ps.product_id,
        LATERAL jsonb_object_keys(ps.specs_normalized) AS key
        WHERE p.category_id = v_category_id
          AND (v_prefix IS NULL OR key LIKE v_prefix || '%')
        GROUP BY key
        ORDER BY cnt DESC, key
        LIMIT v_limit_keys
      ) k;
    ELSE
      SELECT jsonb_agg(key ORDER BY key)
      INTO v_result
      FROM (
        SELECT DISTINCT key
        FROM product_specs ps
        JOIN products p ON p.id = ps.product_id,
        LATERAL jsonb_object_keys(ps.specs_normalized) AS key
        WHERE p.category_id = v_category_id
          AND (v_prefix IS NULL OR key LIKE v_prefix || '%')
        ORDER BY key
        LIMIT v_limit_keys
      ) k;
    END IF;

  ELSIF v_type = 'spec_distribution' THEN
    IF v_category_id IS NULL OR v_spec_key IS NULL THEN
      RAISE EXCEPTION 'category_id and spec_key required';
    END IF;
    SELECT jsonb_build_object(
      'min', MIN(metric), 'max', MAX(metric), 'avg', AVG(metric),
      'with_key', COUNT(*) FILTER (WHERE has_key), 'total', COUNT(*)
    )
    INTO v_result
    FROM (
      SELECT CASE WHEN jsonb_typeof(ps.specs_normalized->v_spec_key) = 'number'
                  THEN (ps.specs_normalized->>v_spec_key)::numeric
                  ELSE NULL END AS metric,
             (ps.specs_normalized ? v_spec_key) AS has_key
      FROM products p
      JOIN product_specs ps ON ps.product_id = p.id
      WHERE p.category_id = v_category_id
    ) t;

  ELSE  -- categories_with_attribute
    IF v_taxonomy IS NULL OR v_option_slug IS NULL THEN
      RAISE EXCEPTION 'taxonomy and option_slug required';
    END IF;
    SELECT jsonb_agg(DISTINCT jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug))
    INTO v_result
    FROM products p
    JOIN categories c                ON c.id = p.category_id
    JOIN product_attribute_values pav ON pav.product_id = p.id
    JOIN attribute_options ao        ON ao.id = pav.attribute_option_id
    JOIN attributes a                ON a.id = ao.attribute_id
    WHERE a.taxonomy = v_taxonomy AND ao.slug = v_option_slug;
  END IF;

  RETURN jsonb_build_object('type', v_type, 'data', COALESCE(v_result, '[]'::jsonb));
END;
$$;
```

---

## 3. Composición de híbridas (E1–E4)

Las E* **no tienen tool propia** — el LLM las compone:

| Intent | Composición |
|---|---|
| **E1** comparar 2 productos | `get_product_narrative({slug: a, info_types:[description,specs,features]})` + `get_product_narrative({slug: b, ...})` |
| **E2** caso de uso + criterios duros | `filter_products_by_specs({...})` → toma `ids` → `semantic_search({product_ids_shortlist: ids, query_text})` |
| **E3** accesorios para X | `get_recommendations({mode:"from_product", product_slug:X})` → opcionalmente `get_product_narrative` por cada recomendado |
| **E4** brand overview | `search_products({brand:X})` → `semantic_search({brand:X, info_types:["description"]})` |

El valor de tener tools separadas es exactamente este: el LLM ve el resultado
intermedio y decide el siguiente paso. Una mega-tool tendría que hardcodear todo el
árbol de decisión.

---

## 4. Lo que queda fuera (a propósito)

- **No** una tool `answer_with_rag(query)` que envuelva todo. Pierdes composición y trazabilidad.
- **No** tools por intent (`a1_new_products`, `a2_attr_combo`…). El LLM se confunde y el surface crece.
- **No** exponer `embedding`/`vector` en interfaces hacia el LLM. El `query_embedding` lo calcula el caller (n8n) con Gemini (`gemini-embedding-001`) antes del RPC; el LLM nunca ve vectores.
- **No** mezclar G* (operación) con las tools. Las queries G1–G6 viven en [PREGUNTAS.md](PREGUNTAS.md) y se ejecutan directo contra la BD por el operador.
- **No** aceptar `category_slug`/`category_name` como filtros — solo `category_id` (ver [PREGUNTAS.md §5](PREGUNTAS.md): `categories.name`/`slug` pueden ser placeholders).

---

## 5. Errores y warnings — contrato común

Las funciones PL/pgSQL comunican fallas de dos formas:

**1. Errores que abortan (`RAISE EXCEPTION`)** — el caller los recibe como excepción Postgres con `message` + `HINT`:

| Trigger | Mensaje | HINT |
|---------|---------|------|
| `filter` no es objeto | `filter must be a json object` | — |
| `category_id` faltante donde es obligatorio | `category_id is required` | — |
| `spec_key` inexistente en la categoría | `spec_key <X> not found in category <N>` | `Valid keys: <lista>` |
| `product_slug` no resuelve | `product_slug <X> not found` | — |
| `reference_product_slug` no resuelve | `reference_product_slug <X> not found` | — |
| `software_id` no existe | `software_id <N> not found` | — |
| `mode` inválido en `get_recommendations` | `mode must be from_product, to_product, ...` | — |
| `type` inválido en `get_catalog_metadata` | `type must be one of the supported metadata types` | — |
| `query_embedding NULL` en `semantic_search` | `query_embedding cannot be null` | — |
| XOR violado en `get_product_narrative` | `exactly one of product_slug or software_id is required` | — |

El LLM lee `message + HINT` y **reformula** — no reintenta con el mismo input.

**2. Resultados "vacíos" o degradados** — la función devuelve estructura válida con data vacía:

| Caso | Resultado | Acción del caller |
|------|-----------|-------------------|
| `semantic_search` < 3 productos con `similarity > 0.55` | Array corto o vacío | Reintentar relajando filtros (expandir `info_types` → quitar `attribute_filters` → quitar `category_id`). Acumular `warnings`. |
| `get_product_narrative` sin chunks | `{product, chunks: []}` | El LLM responde con descripción del producto + advertencia de "sin material narrativo". |
| `resolve_alias` sin match | `{type, data: []}` | El LLM informa "no entiendo el término" y pide reformulación. |
| `search_products` 0 productos | `[]` | Relajar `attribute_filters` o `is_new`. |

**Quién aplica los fallbacks:** el caller (n8n), no la función. La función expone un solo SELECT; el caller decide la cascada según [PREGUNTAS.md §4](PREGUNTAS.md).

---

## 6. Implementación — checklist

Cada tool es una función PL/pgSQL en Supabase. El cuerpo SQL completo está inline en §2.x. Antes de desplegar:

**Funciones SQL (§2.x):**

- [ ] Desplegar las 6 funciones vía `apply_migration` o migración manual.
- [ ] Verificar que `STABLE` y `SET search_path = public, extensions` estén en cada una.
- [ ] Permisos: `GRANT EXECUTE ON FUNCTION ... TO authenticated, anon` según corresponda.
- [ ] Smoke test por función contra el catálogo real (74 productos): que cada modo/branch retorne data.

**Capa caller (n8n / backend):**

- [ ] Cómputo de `query_embedding` con Gemini (`gemini-embedding-001`) **antes** del RPC en `semantic_search` y `get_product_narrative` (cuando aplica). Nunca se delega ese costo a la DB.
- [ ] Fallback escalonado de `semantic_search` ([PREGUNTAS.md §4.3](PREGUNTAS.md)) vive **en el caller**, no en la función. La función expone un solo SELECT; el caller reintenta con parámetros relajados y acumula `warnings`.
- [ ] Mapear `RAISE EXCEPTION` de plpgsql a `errors` estructurados del contrato §5. El mensaje + HINT contiene la info útil (claves válidas, modos válidos).
- [ ] Logging por RPC call con `intent_id` (si el NLU lo emitió), duración, params del filter, tamaño del resultado y fallbacks aplicados — alimenta el golden set de [SOLUCION.md §9](SOLUCION.md).
- [ ] No exponer `query_embedding` en interfaces públicas hacia el LLM final — siempre se inyecta del lado del caller.

**Anti-patrones a evitar en plpgsql:**

- [ ] No usar `SECURITY DEFINER` salvo necesidad explícita; mantener `SECURITY INVOKER` (default) para que RLS aplique.
- [ ] No hacer `EXCEPTION WHEN OTHERS` genérico — eso esconde errores reales. Dejar que la excepción de plpgsql burbujee al caller.
- [ ] No introducir lógica de orquestación (reintentos, fallbacks multi-step) dentro de la función — eso vive en el caller.

---

## 7. Referencias cruzadas

- Contrato del extractor NLU que produce los params de estas tools: [SOLUCION.md §7](SOLUCION.md).
- Catálogo completo de intents con SQL ejecutable: [PREGUNTAS.md](PREGUNTAS.md).
- Schema de DB que sustenta cada tool: [schema.sql](schema.sql).
- Políticas globales de fallback: [PREGUNTAS.md §4](PREGUNTAS.md).
- Reglas de inclusión/exclusión del retrieval (dedup, exclusión de `software`
  chunks, etc.): [PREGUNTAS.md §5](PREGUNTAS.md).
