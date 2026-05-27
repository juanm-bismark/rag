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

**G* (operación) va aparte** en `ops_health`, solo expuesta en contexto de operador.

---

## 2. Firmas concretas

Sintaxis TypeScript porque mapea 1:1 a JSON Schema para tool-use de la API. Cada tool
es una función pura: recibe params, devuelve payload tipado. El adapter de cada tool
hace su propio manejo de fallbacks según [PREGUNTAS.md §4](PREGUNTAS.md).

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

- Si `attribute_filters` trae aliases (ej. "móvil"), el adapter los resuelve vía A8
  contra `attribute_option_aliases` **antes** de armar el SQL. Si no resuelve,
  devuelve warning y omite el filtro.
- Si vienen ambos `name_query` y filtros estructurales, ambos se aplican (AND).

**Anti-patrón:** no aceptar `category_slug` o `category_name`. Solo `category_id`
(ver [PREGUNTAS.md §5](PREGUNTAS.md)).

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

- El adapter consulta F1 (claves reales de la categoría) y **rechaza** `spec_keys`
  no existentes con error explícito. No silenciar — el LLM debe reformular.
- Para `op` numéricos, usar `jsonb_typeof` guard como en [PREGUNTAS.md F2](PREGUNTAS.md)
  para no crashear con valores no numéricos.

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

type GetRecommendationsOutput = Array<{
  product_id: number;
  slug: string;
  name: string;
  brand: string | null;
  // solo en category_to_category:
  target_category_id?: number;
  target_category_name?: string;
  edges?: number;
}>;
```

**Anti-patrón:** no confundir con `semantic_search({mode:"similar_to_product"})`.
Recomendación es relación del catálogo (`product_recommendations`); similar es
similitud por embeddings de specs.

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

**Clave de diseño:** `query_text` es **opcional**.

- Si el usuario pregunta "qué es el EG5100" → no hace falta ranking (solo hay 1
  chunk `description` por producto). El adapter trae directo, sin embedding.
- Si el usuario pregunta "cuál es el throughput del EG5100" → el LLM pasa la
  pregunta como `query_text`, el adapter calcula embedding y ordena.

**Validación:** uno y solo uno de `product_slug` / `software_id` debe venir.

---

### 2.5 `semantic_search`

Cubre **D5, D6**. La única tool que calcula embedding de la query.

```typescript
type SemanticSearchInput = {
  mode: "open"                  // D5
      | "similar_to_product";   // D6
  query_text?: string;          // D5 — el adapter calcula el embedding
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
3. **El embedding lo calcula el adapter**, no el LLM. Nunca exponer vectores en
   la firma pública.

**Fallback interno (ver [PREGUNTAS.md §4.3](PREGUNTAS.md)):**

1. <3 productos con `similarity > 0.55` → expandir `info_types` a todos.
2. Sigue <3 → quitar `attribute_filters`.
3. Sigue <3 → quitar `category_id` y devolver `warnings: ["category_dropped"]`.

---

### 2.6 `get_catalog_metadata`

Cubre **A3, A6, A7, A8, A9, F1, F2, F3**. Tool "navaja suiza" para metadata —
los lookups que el LLM consulta **antes** de armar filtros.

```typescript
type GetCatalogMetadataInput =
  | { type: "list_categories" }                                                          // A9
  | { type: "list_brands_in_category"; category_id: number }                             // A3
  | { type: "list_attributes_for_category"; category_id: number; with_counts?: boolean } // A6, A7
  | { type: "resolve_alias"; term: string }                                              // A8
  | { type: "list_spec_keys"; category_id: number }                                      // F1
  | { type: "spec_distribution"; category_id: number; spec_key: string }                 // F2
  | { type: "categories_with_attribute"; taxonomy: string; option_slug: string };        // F3

// Output discriminado por `type` del input. Shapes:
// - list_categories: Array<{id, name, slug, product_count}>
// - list_brands_in_category: Array<{brand, products}>
// - list_attributes_for_category: Array<{attribute_id, name, taxonomy, options: Array<{id, name, slug, products?}>}>
// - resolve_alias: Array<{option_id, slug, taxonomy, attribute_name}>
// - list_spec_keys: Array<{spec_key: string}>
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

- **No** una tool `answer_with_rag(query)` que envuelva todo. Pierdes composición y
  trazabilidad.
- **No** tools por intent (`a1_new_products`, `a2_attr_combo`…). El LLM se confunde
  y el surface crece.
- **No** exponer `embedding`/`vector` en ninguna firma pública. Lo calcula el adapter
  cuando recibe `query_text`.
- **No** mezclar G* (operación) con las tools del usuario final. Va en
  `ops_health` aislada, expuesta solo en contexto de operador.
- **No** aceptar `category_slug`/`category_name` como filtros — solo `category_id`
  (ver [PREGUNTAS.md §5](PREGUNTAS.md): `categories.name`/`slug` pueden ser placeholders).

---

## 5. Errores y warnings — contrato común

Todas las tools devuelven, además del payload tipado, un canal de warnings opcional:

```typescript
type ToolResult<T> = {
  data: T;
  warnings?: Array<
    | { code: "alias_unresolved"; term: string }
    | { code: "spec_key_unknown"; spec_key: string; category_id: number; valid_keys_hint?: string[] }
    | { code: "fallback_applied"; relaxed: string[] }   // ej. ["category_dropped"]
    | { code: "low_confidence_results"; reason: string }
  >;
};
```

Errores que **abortan** la llamada (no warnings):

- `spec_filters` con `spec_key` inexistente y sin candidato cercano → error
  `SPEC_KEY_NOT_FOUND` con la lista de claves válidas en el detalle. El LLM debe
  reformular.
- `product_slug` no resuelto en `get_product_narrative` → error `PRODUCT_NOT_FOUND`
  con sugerencias top-3 de `pg_trgm` sobre `search_text`.

---

## 6. Implementación — checklist

Cuando llegue el momento de codear el adapter de cada tool:

- [ ] Cada tool es una función pura `(input) => Promise<ToolResult<T>>`.
- [ ] Validación de input con JSON Schema (o Zod si TS). Rechazar antes de pegar a DB.
- [ ] Reuso de queries de [PREGUNTAS.md](PREGUNTAS.md) (ya tienen anti-patrones documentados).
- [ ] `category_id` y `spec_keys` se validan **siempre** contra el catálogo antes de
      armar SQL — no confiar en que el LLM no alucina.
- [ ] Fallbacks de [PREGUNTAS.md §4](PREGUNTAS.md) viven **dentro** del adapter, no en
      el LLM. El LLM solo ve el resultado final + warnings.
- [ ] Logging por tool call con `intent_id` inferido (si el NLU lo emitió),
      duración, `fallback_relaxations` y tamaño del resultado — alimenta el
      golden set de [SOLUCION.md §9](SOLUCION.md).

---

## 7. Referencias cruzadas

- Contrato del extractor NLU que produce los params de estas tools: [SOLUCION.md §7](SOLUCION.md).
- Catálogo completo de intents con SQL ejecutable: [PREGUNTAS.md](PREGUNTAS.md).
- Schema de DB que sustenta cada tool: [schema.sql](schema.sql).
- Políticas globales de fallback: [PREGUNTAS.md §4](PREGUNTAS.md).
- Reglas de inclusión/exclusión del retrieval (dedup, exclusión de `software`
  chunks, etc.): [PREGUNTAS.md §5](PREGUNTAS.md).
