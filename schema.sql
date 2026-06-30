-- =============================================================================
-- RAG-ready Catalog Schema
-- PostgreSQL 15+ con pgvector y pg_trgm
-- Diseño: filter-then-rank; el prefiltro de la ruta semántica se resuelve por
--         JOIN rag_chunks→products (sin metadata denormalizada en rag_chunks).
-- Embeddings: gemini-embedding-001 (3072 dims), generados por n8n (Gemini + LangChain).
-- Volumen objetivo: <500 productos, ~2500 chunks. Sin índice vectorial al inicio.
-- =============================================================================

DROP VIEW IF EXISTS category_keys_context, category_key_drift, category_enum_value_drift, reference_bundle CASCADE;

DROP TABLE IF EXISTS
  product_recommendations,
  rag_chunks,
  ingestion_runs,
  product_specs,
  product_attribute_values,
  category_attributes,
  attribute_option_aliases,
  reference_alias_candidates,
  reference_aliases,
  attribute_options,
  attributes,
  products,
  software,
  categories
CASCADE;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- =============================================================================
-- 1. Taxonomía base
-- =============================================================================

CREATE TABLE categories (
  id            INT PRIMARY KEY,
  name          TEXT NOT NULL,
  slug          TEXT NOT NULL UNIQUE
);

-- =============================================================================
-- 2. Atributos taxonómicos (filtros tipo Woo: pa_red-celular, pa_wifi, ...)
-- =============================================================================

CREATE TABLE attributes (
  id        INT PRIMARY KEY,
  name      TEXT NOT NULL,
  taxonomy  TEXT NOT NULL UNIQUE
);

CREATE TABLE attribute_options (
  id            INT PRIMARY KEY,
  attribute_id  INT NOT NULL REFERENCES attributes(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  slug          TEXT NOT NULL,
  UNIQUE (attribute_id, slug)
);

CREATE TABLE category_attributes (
  category_id   INT REFERENCES categories(id) ON DELETE CASCADE,
  attribute_id  INT REFERENCES attributes(id) ON DELETE CASCADE,
  PRIMARY KEY (category_id, attribute_id)
);

-- Sinónimos para el extractor NLU: "móvil"/"celular"/"4G/LTE" -> option correcta
CREATE TABLE attribute_option_aliases (
  attribute_option_id INT NOT NULL REFERENCES attribute_options(id) ON DELETE CASCADE,
  alias               TEXT NOT NULL,
  PRIMARY KEY (attribute_option_id, alias)
);

-- =============================================================================
-- 2b. Datos de referencia GLOBALES para normalización de specs (code.js)
-- =============================================================================
-- Reemplaza los mapas hardcodeados de code.js (CERT_MAP, VALUE_TRANSLATIONS,
-- EXACT_KEY_MAP, IDENTITY_KEYS) por datos editables sin tocar código.
-- GLOBAL, no per-category: un watt es un watt, RoHS es RoHS en toda categoría.
-- Las UNIDADES NO van aquí (otra forma: magnitud + conversión + grafías regex)
-- -> siguen en code.js (CANONICAL_UNITS/unitPatterns) + §4 del prompt.
--
-- code.js hace MERGE sobre sus *_FALLBACK in-code: bundle vacío/ausente =>
-- comportamiento IDÉNTICO al hardcodeado. La autoridad de APLICACIÓN sigue en
-- code.js; el prompt conserva sus listas como guía/ejemplos. SEGMENT_MAP NO se
-- externaliza (aplicar equivalencias por-segmento de forma genérica es inseguro;
-- solo el EXACT_KEY_MAP de clave completa es data-driven).
--
-- Seed inicial (reproduce el hardcode de code.js): reference_aliases_seed.sql
-- (archivo ~150 filas; en BD hoy 142 tras gobernanza: cert 50, identity_discard 34,
--  key_equivalence 33, value_translation 25).
CREATE TABLE reference_aliases (
  kind       TEXT NOT NULL
             CHECK (kind IN ('cert','value_translation','key_equivalence','identity_discard')),
  alias      TEXT NOT NULL,      -- token de entrada en minúsculas ('raee','aluminio','voltaje')
  canonical  TEXT,               -- salida canónica; NULL para identity_discard (solo descarta)
  source     TEXT NOT NULL DEFAULT 'seed',    -- 'seed' | 'promoted' | 'manual' (gobernanza)
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (kind, alias)
);

-- n8n lee esta vista UNA vez por batch y la pasa al Code node como filas {kind, map}.
-- code.js: const CERT_MAP = { ...CERT_MAP_FALLBACK, ...bundle.cert }, etc.
CREATE VIEW reference_bundle AS
SELECT kind, jsonb_object_agg(alias, canonical) AS map
FROM reference_aliases
GROUP BY kind;

-- Staging de tokens desconocidos detectados en ingesta (code.js emite
-- unknown_certification_token / unmapped_specs cuando ve algo fuera del bundle).
-- n8n hace UPSERT incrementando occurrences; un humano/LLM revisa y promueve las
-- filas 'approved' a reference_aliases (que el siguiente batch aplica solo).
-- NO se auto-inserta al canon: el mapa alias->canonical es una DECISIÓN, no una
-- derivación. Aquí solo se DETECTA y acumula; la promoción es el gate.
-- sample_product_id es referencia blanda (sin FK) — la cola es independiente del
-- ciclo de vida del producto.
CREATE TABLE reference_alias_candidates (
  kind              TEXT NOT NULL
                    CHECK (kind IN ('cert','value_translation','key_equivalence','identity_discard')),
  raw_token         TEXT NOT NULL,             -- token crudo en minúsculas, como lo ve code.js
  suggested         TEXT,                      -- canónico sugerido (NULL si aún sin decidir)
  occurrences       INT NOT NULL DEFAULT 1,
  sample_product_id BIGINT,                    -- soft ref a products(id) — sin FK a propósito
  status            TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected')),
  first_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (kind, raw_token)
);

-- Cola de revisión: pendientes ordenados por frecuencia.
CREATE INDEX idx_ref_candidates_pending
  ON reference_alias_candidates (status, occurrences DESC)
  WHERE status = 'pending';

-- =============================================================================
-- 3. Software de gestión (deduplicado, embeddable independientemente)
-- =============================================================================

CREATE TABLE software (
  id                   BIGINT PRIMARY KEY,
  canonical_product_id BIGINT,                       -- FK a products: se agrega abajo
  name                 TEXT,
  description_text     TEXT,
  attributes           TEXT[] DEFAULT '{}',          -- ['vpn','sdwan','mqtt','modbus']
  content_fingerprint  TEXT,                         -- calculado y escrito por n8n
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 4. Productos
-- =============================================================================

CREATE TABLE products (
  id              BIGINT PRIMARY KEY,
  slug            TEXT NOT NULL UNIQUE,
  name            TEXT NOT NULL,
  brand           TEXT,
  model           TEXT,
  category_id     INT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  source_url      TEXT,
  description     TEXT,
  is_new          BOOLEAN NOT NULL DEFAULT FALSE,
  search_aliases  TEXT[] DEFAULT '{}',
  software_id     BIGINT REFERENCES software(id) ON DELETE SET NULL,
  content_fingerprint    TEXT,                  -- calculado y escrito por n8n
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  ingested_at     TIMESTAMPTZ DEFAULT NOW(),
  search_text     TEXT NOT NULL DEFAULT ''
);

-- Cierre de FK circular software -> products
ALTER TABLE software
  ADD CONSTRAINT software_canonical_product_fk
  FOREIGN KEY (canonical_product_id) REFERENCES products(id) ON DELETE SET NULL;

-- Reconciliación idempotente de products.software_id (repara drift en BD existentes).
-- Garantiza ON DELETE SET NULL: borrar un software pone en NULL el software_id de
-- sus productos en vez de bloquear. En bases creadas antes de añadir esta cláusula
-- la FK quedaba como NO ACTION y producía:
--   update or delete on table "software" violates foreign key constraint
--   "products_software_id_fkey" on table "products".
-- Seguro de re-ejecutar: en build limpio sólo reafirma la constraint ya creada.
ALTER TABLE products DROP CONSTRAINT IF EXISTS products_software_id_fkey;
ALTER TABLE products
  ADD CONSTRAINT products_software_id_fkey
  FOREIGN KEY (software_id) REFERENCES software(id) ON DELETE SET NULL;


CREATE OR REPLACE FUNCTION products_set_search_text()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.search_text :=
   lower(
    concat_ws(
      ' ',
      NEW.name,
      NEW.brand,
      NEW.model,
      array_to_string(NEW.search_aliases, ' ')
      )
    );
    RETURN NEW;
  END;
$$;

CREATE TRIGGER trg_products_set_search_text
BEFORE INSERT OR UPDATE OF name, brand, model, search_aliases
ON products
FOR EACH ROW EXECUTE FUNCTION products_set_search_text();

-- content_fingerprint calculado por n8n antes del upsert:
--   ['name:<v>','brand:<v>','model:<v>','desc:<v>','is_new:<v>','aliases:<v>','sw_id:<v>'].join('|')
-- n8n escribe el valor en el INSERT/UPDATE; el DB no lo recalcula.

-- =============================================================================
-- Trigger genérico updated_at
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_products_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_software_updated_at
BEFORE UPDATE ON software
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- 5. Asignación producto <-> atributos (multivalor)
-- =============================================================================

-- attribute_id NO se almacena aqui: es derivable via attribute_options.attribute_id.
-- Guardarlo violaria BCNF (dependencia transitiva) y abriria riesgo de inconsistencia
-- entre pav.attribute_id y attribute_options.attribute_id. Las queries que necesiten
-- filtrar por taxonomia hacen: JOIN attribute_options ao -> JOIN attributes a ON a.id = ao.attribute_id.
CREATE TABLE product_attribute_values (
  product_id          BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  attribute_option_id INT NOT NULL REFERENCES attribute_options(id) ON DELETE CASCADE,
  PRIMARY KEY (product_id, attribute_option_id)
);

-- =============================================================================
-- 6. Specs tecnicas (crudas + normalizadas por LLM)
-- =============================================================================

CREATE TABLE product_specs (
  product_id          BIGINT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  specs               JSONB,                           -- crudo: [{name, value, section?, items?}]
  specs_normalized    JSONB NOT NULL DEFAULT '{}',    -- snake_case + numerico (LLM)
  -- Contexto semántico POR CLAVE que el LLM emite junto a specs_normalized:
  --   { "<key>": { "shape": "scalar|range|enum|narrative|boolean", "desc": "<significado>" } }
  -- Solo lo NO derivable (shape/desc). unit/example/n se derivan en las vistas.
  -- Grano = producto: cada run lo sobreescribe entero -> sin merge, sin drift acumulado.
  keys_context        JSONB NOT NULL DEFAULT '{}',    -- semantica por clave (LLM)
  table_specs         JSONB,
  variants            JSONB,
  compatibility       JSONB,
  specs_text            TEXT,                          -- markdown -> embedding
  features_text         TEXT,                          -- markdown -> embedding
  -- Fingerprint de detección de cambios. Calculado y escrito por n8n antes del upsert.
  -- Cubre TODO el contenido de la fila EXCEPTO specs_normalized (derivado del LLM).
  -- Formato (n8n no tiene crypto, concatenación legible):
  --   'specs:<json>|table_specs:<json>|variants:<json>|compatibility:<json>|specs_text:<text>|features_text:<text>'
  -- Si cambia → re-correr LLM normalize + regenerar specs_text/features_text + invalidar chunks afectados.
  --
  -- Forzar re-normalización (cuando cambias el prompt del LLM):
  --   UPDATE product_specs SET specs_fingerprint = NULL;
  -- En el próximo run, n8n ve NULL/distinto y re-procesa todo.
  specs_fingerprint     TEXT,
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_product_specs_updated_at
BEFORE UPDATE ON product_specs
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- 6b. Fingerprints de detección de cambios
-- =============================================================================
--
-- Política unificada: UN fingerprint por tabla. Cubre TODO el contenido relevante
-- de la fila EXCEPTO los campos puramente derivados que estén gobernados por
-- prompt_version (caso de specs_normalized en product_specs).
--
--   products.content_fingerprint
--     'name:<v>|brand:<v>|model:<v>|desc:<v>|is_new:<v>|aliases:<v>|sw_id:<v>'
--
--   software.content_fingerprint
--     'name:<v>|desc:<v>|attrs:<v>'
--
--   product_specs.specs_fingerprint
--     'specs:<json>|table_specs:<json>|variants:<json>|compatibility:<json>|specs_text:<text>|features_text:<text>'
--     (specs_normalized y keys_context excluidos — derivados por LLM, gobernados por prompt_version)
--
-- Todos escritos por n8n antes del upsert. El DB no recalcula.
--
-- rag_chunks NO usa fingerprint: n8n compara `content` por chunk (por source_key)
-- ANTES del nodo Vector Store. Solo los chunks nuevos o con content cambiado pasan
-- por el embedding (Gemini) y entran a embedding_rag_chunk_upload; el trigger de §8b
-- hace el UPSERT por source_key (ON CONFLICT) dejando rag_chunks SIEMPRE con embedding.
-- Ya NO existe el camino "UPDATE content + SET embedding=NULL → recoger WHERE embedding
-- IS NULL": el embedding se calcula arriba y aterriza ya resuelto. Los chunks sin
-- cambios no se re-embeben.
--
-- Formato: concatenación legible (n8n no puede usar crypto). Debuggeable a simple vista.

-- =============================================================================
-- 6c. Vocabulario de claves por categoría (VISTAS derivadas — sin tabla, sin trigger)
-- =============================================================================
--
-- El contexto por clave NO se materializa ni se mergea: se DERIVA al leer, agregando
-- el keys_context que cada producto guardó en product_specs. Ventajas a esta escala:
--   - Sin lógica de merge/upsert ni governance de "agregar o actualizar".
--   - Se auto-sana: re-normalizar un producto sobreescribe SU fila -> el agregado
--     refleja la verdad actual; claves muertas (drift corregido) caen a n=0 y desaparecen.
--   - Discrepancias entre productos sobre shape/desc de una clave se resuelven por
--     MAYORÍA (mode()): el canónico = lo que dice la mayoría, auto-corrige outliers.
--   - n/example/value_type se derivan de specs_normalized (siempre presentes);
--     shape/desc de keys_context (los aporta el LLM). Si keys_context aún está vacío,
--     la vista igual entrega n/example/value_type.
--   - value_type es la clasificación AUTORITATIVA por jsonb_typeof del dato real
--     (number | number_array | enum | boolean | string | object). shape (del LLM) NO
--     es confiable para construir queries: colapsa arrays numéricos en 'scalar'
--     ([10,100,1000] reportado como scalar). Por eso las tools (filter_products_by_specs,
--     get_catalog_metadata.list_spec_keys) deciden el op por value_type, no por shape.
--
-- IMPORTANTE: ninguna capa de almacenamiento arregla el drift "misma cosa, una letra
-- distinta" (todas indexan por el string EXACTO). Eso se previene en el PROMPT (§2c/§5).
-- Estas vistas solo DETECTAN (category_key_drift) y evitan acumular variantes muertas.

-- Una fila por categoría con el vocabulario empaquetado como JSONB keyed por clave
-- (misma forma que lee n8n: { "<key>": { n, example, shape, desc } }).
CREATE VIEW category_keys_context AS
WITH per_product_key AS (
  SELECT p.category_id,
         ps.updated_at,
         kv.key                          AS key,
         ps.specs_normalized -> kv.key   AS value,
         ps.keys_context     -> kv.key   AS ctx        -- NULL si el LLM no lo emitió aún
  FROM product_specs ps
  JOIN products p ON p.id = ps.product_id
  CROSS JOIN LATERAL jsonb_object_keys(ps.specs_normalized) AS kv(key)
  WHERE ps.specs_normalized <> '{}'::jsonb
),
typed AS (
  -- value_type DERIVADO del dato (no del shape del LLM). Distingue array de
  -- números (filtrable por umbral) de enum (array de strings -> contains).
  SELECT ppk.*,
         CASE jsonb_typeof(value)
           WHEN 'number'  THEN 'number'
           WHEN 'boolean' THEN 'boolean'
           WHEN 'string'  THEN 'string'
           WHEN 'object'  THEN 'object'
           WHEN 'array'   THEN
             CASE WHEN jsonb_array_length(value) > 0
                       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(value) e
                                       WHERE jsonb_typeof(e) <> 'number')
                  THEN 'number_array'   -- [10,100,1000] -> filtrable por umbral
                  ELSE 'enum' END       -- ["rj45"], ["10gbase-r"] -> contains
           ELSE 'unknown'
         END AS vtype
  FROM per_product_key ppk
),
per_key AS (
  SELECT category_id,
         key,
         count(*)                                                  AS n,
         (array_agg(value ORDER BY updated_at DESC NULLS LAST))[1] AS example,
         mode() WITHIN GROUP (ORDER BY vtype)                      AS value_type,
         mode() WITHIN GROUP (ORDER BY ctx ->> 'shape')            AS shape,
         mode() WITHIN GROUP (ORDER BY ctx ->> 'desc')             AS descr
  FROM typed
  GROUP BY category_id, key
)
SELECT category_id,
       jsonb_object_agg(
         key,
         jsonb_strip_nulls(jsonb_build_object(
           'n',          n,
           'example',    example,
           'value_type', value_type,   -- autoritativo (derivado del dato)
           'shape',      shape,        -- pista del LLM (no autoritativa)
           'desc',       descr
         ))
         ORDER BY key
       ) AS keys_context
FROM per_key
GROUP BY category_id;

-- Radar de drift: pares de claves casi idénticas dentro de una categoría
-- (p.ej. operating_temperature_c_min vs operating_temperature_min_c). Solo FLAGEA;
-- el merge semántico lo hace el LLM viendo el vocabulario, no un umbral de similitud.
CREATE VIEW category_key_drift AS
WITH keys AS (
  SELECT cc.category_id, e.key, (e.value ->> 'n')::int AS n
  FROM category_keys_context cc
  CROSS JOIN LATERAL jsonb_each(cc.keys_context) AS e(key, value)
)
SELECT a.category_id,
       a.key                    AS key_a,
       b.key                    AS key_b,
       a.n                      AS n_a,
       b.n                      AS n_b,
       similarity(a.key, b.key) AS sim
FROM keys a
JOIN keys b
  ON a.category_id = b.category_id
 AND a.key < b.key
 AND similarity(a.key, b.key) > 0.6
ORDER BY a.category_id, sim DESC;

-- Radar de drift de VALORES: dentro de UNA misma clave enum, valores casi
-- identicos escritos de varias formas (p.ej. mounting: 'wall_mount' vs 'wall-mount';
-- 'din_rail_35_mm' vs 'din-rail 35 mm'). category_key_drift compara NOMBRES de clave
-- y nunca abre el array; este abre el array y compara sus elementos string. Importa
-- porque rompe el filtrado @>: specs_normalized @> '{"mounting":["din-rail"]}' pierde
-- las variantes. Solo FLAGEA — canonicalizar un valor es una DECISION (igual que
-- reference_aliases), no una derivacion por umbral.
-- Alcance: solo claves enum (arrays de strings); excluye narrativas (_*) y arrays
-- numericos. Mas ruidoso que el de claves (tokens cortos como c/c++, sfp/sfp+ y
-- pares legitimos como level 2/level 4 inflan similarity) -> subir el umbral o
-- filtrar por key al revisar; el merge semantico lo decide el humano/LLM, no el umbral.
CREATE VIEW category_enum_value_drift AS
WITH enum_values AS (
  SELECT p.category_id,
         kv.key                              AS key,
         jsonb_array_elements_text(kv.value) AS val
  FROM product_specs ps
  JOIN products p ON p.id = ps.product_id
  CROSS JOIN LATERAL jsonb_each(ps.specs_normalized) AS kv(key, value)
  WHERE jsonb_typeof(kv.value) = 'array'
    AND left(kv.key, 1) <> '_'                       -- excluye narrativas (_*_notes)
    AND NOT EXISTS (                                 -- solo arrays de strings (enum)
      SELECT 1
      FROM jsonb_array_elements(kv.value) AS el
      WHERE jsonb_typeof(el) <> 'string'
    )
),
per_value AS (
  SELECT category_id, key, val, count(*) AS n
  FROM enum_values
  GROUP BY category_id, key, val
)
SELECT a.category_id,
       a.key,
       a.val                    AS val_a,
       b.val                    AS val_b,
       a.n                      AS n_a,
       b.n                      AS n_b,
       similarity(a.val, b.val) AS sim
FROM per_value a
JOIN per_value b
  ON a.category_id = b.category_id
 AND a.key = b.key
 AND a.val < b.val
 AND similarity(a.val, b.val) > 0.6
ORDER BY a.category_id, a.key, sim DESC;

-- =============================================================================
-- 7. Productos recomendados (dirigidas: source -> target)
-- =============================================================================

CREATE TABLE product_recommendations (
  source_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  target_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (source_product_id, target_product_id),
  CHECK (source_product_id <> target_product_id)
);

-- =============================================================================
-- 8. RAG: chunks (prefiltro por JOIN a products — sin metadata denormalizada)
-- =============================================================================

create table public.rag_chunks (
  id bigint generated by default as identity primary key,

  -- Llave NATURAL/lógica del chunk: la calcula n8n ANTES de insertar
  -- ('product:123:features:0'). Es la llave de idempotencia del upsert
  -- (ON CONFLICT (source_key) en el trigger de §8b). NO es reemplazable por `id`:
  -- `id` lo genera la DB en el INSERT, n8n no lo conoce de antemano y cambia en
  -- cada re-ingesta; source_key es estable entre corridas. Quitarlo obligaría a
  -- recrear el mismo dato como (product_id, chunk_type, section_name, chunk_index)
  -- — más columnas, misma información. Por eso se conserva.
  source_key text unique,

  product_id bigint references public.products(id) on delete cascade,
  software_id bigint references public.software(id) on delete cascade,

  chunk_type text not null
    check (
      chunk_type in (
        'overview',
        'description',
        'features',
        'specs',
        'spec_section',
        'software',
        'compatibility',
        'variants'
      )
    ),

  section_name text,
  content text not null,

  metadata jsonb not null default '{}'::jsonb,

  -- NULLABLE a propósito. En el flujo actual el embedding NO entra por aquí
  -- directamente: n8n lo genera con Gemini (gemini-embedding-001, 3072 dims) y
  -- aterriza la fila en embedding_rag_chunk_upload; el trigger de §8b hace el
  -- upsert a rag_chunks YA con embedding. Se deja NULLABLE solo por defensa
  -- (tolerar una fila transitoria sin embedding); en la práctica SIEMPRE llega con
  -- embedding porque upload.embedding es NOT NULL y el trigger upserta con ese valor.
  -- OJO: la dimensión debe seguir siendo 3072 (default de gemini-embedding-001).
  -- Si se baja la dim de salida del modelo, este vector(3072) deja de cuadrar.
  embedding extensions.vector(3072),

  -- token_count int,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Owner XOR, además ligado al chunk_type: SOLO el chunk 'software' es
  -- propiedad de un software; todo otro tipo es propiedad de un producto.
  -- Esto rechaza en el INSERT el bug de "products.software_id estampado en
  -- cada chunk del producto" (overview/features/spec_section con software_id).
  -- La relación producto→software vive en products.software_id (se lee por JOIN),
  -- NO en rag_chunks.software_id.
  constraint chunk_owner check (
    (chunk_type =  'software' and software_id is not null and product_id is null)
    or
    (chunk_type <> 'software' and product_id  is not null and software_id is null)
  )
);

create table if not exists public.embedding_rag_chunk_upload (
  id bigint generated by default as identity primary key,
  content text not null,
  metadata jsonb not null default '{}'::jsonb,
  embedding extensions.vector(3072) not null,
  created_at timestamptz not null default now()
);

-- §8b. Sincronización upload -> rag_chunks (ÚNICO escritor del camino insert/update;
-- el DELETE de chunks removidos va por nodo aparte en n8n)
-- -----------------------------------------------------------------------------
-- Punto de entrada único: el nodo Vector Store de n8n (LangChain + Gemini) inserta
-- (content, metadata, embedding) en embedding_rag_chunk_upload. Este trigger
-- PARSEA la metadata, hace el UPSERT COMPLETO en rag_chunks y DRENA la fila de
-- staging en el acto. Así rag_chunks queda completo y consistente desde un solo
-- escritor, sin doble escritura y sin el pileup observado (upload=472 / rag_chunks=314).
--
-- En n8n: con esto ya NO hacen falta los nodos 'insert rag_chunks' / 'Update
-- rag_chunks' para el camino de embedding (DELETE sigue siendo nodo aparte: un
-- chunk borrado no pasa por embeddings).
--
-- REQUISITO en n8n: el Default Data Loader NO debe partir el content (text
-- splitter OFF -> 1 documento = 1 chunk). Si lo parte, los pedazos comparten
-- source_key y el ON CONFLICT deja SOLO el último pedazo ("el último partido")
-- -> content truncado y conteos que no cuadran. Eso NO se arregla en el trigger.
create or replace function public.sync_embedding_upload_to_rag_chunks()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_source_key   text;
  v_product_id   bigint;
  v_software_id  bigint;
  v_chunk_type   text;
  v_section_name text;
  v_rag_metadata jsonb;
begin
  v_source_key   := nullif(new.metadata->>'source_key', '');
  v_chunk_type   := nullif(new.metadata->>'chunk_type', '');
  v_section_name := nullif(new.metadata->>'section_name', '');

  -- Casts numéricos ROBUSTOS: el Default Data Loader manda '{{ $json.product_id }}'
  -- sin guard, así que en chunks de software llega 'undefined'/'null'/'' y un
  -- ::bigint directo ABORTA el INSERT. Solo casteamos cuando es realmente entero.
  v_product_id  := case when new.metadata->>'product_id'  ~ '^\d+$'
                        then (new.metadata->>'product_id')::bigint  end;
  v_software_id := case when new.metadata->>'software_id' ~ '^\d+$'
                        then (new.metadata->>'software_id')::bigint end;

  if v_source_key is null then
    raise exception 'metadata.source_key es obligatorio para hacer upsert en rag_chunks';
  end if;
  if v_chunk_type is null then
    raise exception 'metadata.chunk_type es obligatorio';
  end if;

  -- Owner XOR ligado al chunk_type (misma regla que el CHECK chunk_owner).
  if v_chunk_type = 'software' then
    if v_software_id is null or v_product_id is not null then
      raise exception 'chunk_type software requiere software_id y product_id null';
    end if;
  else
    if v_product_id is null or v_software_id is not null then
      raise exception 'chunk_type % requiere product_id y software_id null', v_chunk_type;
    end if;
  end if;

  -- rag_chunks NO lleva metadata denormalizada (el prefiltro es por JOIN a products).
  -- NO se copia la metadata de LangChain: trae ruido del loader/splitter
  -- (id, loc:{lines:{from,to}}, blobType, source...) que ensuciaba rag_chunks.metadata
  -- (el "va de from 8"). Solo se respeta una metadata REAL anidada bajo 'metadata'.
  v_rag_metadata := coalesce(new.metadata->'metadata', '{}'::jsonb);

  insert into public.rag_chunks (
    source_key, product_id, software_id, chunk_type, section_name,
    content, metadata, embedding, created_at, updated_at
  )
  values (
    v_source_key, v_product_id, v_software_id, v_chunk_type, v_section_name,
    new.content, v_rag_metadata, new.embedding, now(), now()
  )
  on conflict (source_key) do update set
    product_id   = excluded.product_id,
    software_id  = excluded.software_id,
    chunk_type   = excluded.chunk_type,
    section_name = excluded.section_name,
    content      = excluded.content,
    metadata     = excluded.metadata,
    embedding    = excluded.embedding,
    updated_at   = now();

  -- Drena el staging en el acto: el upload es TRANSITORIO (no debe acumular).
  -- upload.embedding es NOT NULL, así que el upsert ya dejó rag_chunks con
  -- embedding -> es seguro borrar esta fila ya. Esto reemplaza al trigger de
  -- limpieza separado y garantiza que el upload no vuelva a crecer (el 472).
  delete from public.embedding_rag_chunk_upload where id = new.id;

  return null;  -- AFTER trigger: el valor de retorno se ignora
end;
$$;

drop trigger if exists trg_sync_embedding_upload_to_rag_chunks
on public.embedding_rag_chunk_upload;

create trigger trg_sync_embedding_upload_to_rag_chunks
after insert on public.embedding_rag_chunk_upload
for each row
execute function public.sync_embedding_upload_to_rag_chunks();

-- El antiguo trigger de limpieza separado ya no se usa: la limpieza es inline en
-- el sync de arriba. Drop defensivo por si quedó instalado de una versión previa.
drop trigger   if exists trg_clean_embedding_upload_after_rag_chunk_write on public.rag_chunks;
drop function  if exists public.clean_embedding_upload_after_rag_chunk_write();

-- §8c. Limpieza inversa: al BORRAR un chunk de rag_chunks, drena cualquier fila
-- residual en el staging con el mismo source_key. El upload normalmente ya está
-- vacío (el sync de §8b lo drena en el acto), así que esto es una GUARDA defensiva
-- para que un DELETE de chunk no deje datos viejos colgando en el upload.
-- Match por metadata->>'source_key' (el upload no tiene columna source_key propia).
create or replace function public.clean_upload_on_rag_chunk_delete()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  delete from public.embedding_rag_chunk_upload
   where metadata->>'source_key' = old.source_key;
  return old;
end;
$$;

drop trigger if exists trg_clean_upload_on_rag_chunk_delete on public.rag_chunks;
create trigger trg_clean_upload_on_rag_chunk_delete
after delete on public.rag_chunks
for each row
execute function public.clean_upload_on_rag_chunk_delete();


create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger rag_chunks_set_updated_at
before update on public.rag_chunks
for each row
execute function public.set_updated_at();



-- =============================================================================
-- 9. Trazabilidad de ingesta
-- =============================================================================

CREATE TABLE ingestion_runs (
  id              BIGSERIAL PRIMARY KEY,
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at     TIMESTAMPTZ,
  source          TEXT NOT NULL,
  products_seen   INT DEFAULT 0,
  chunks_created  INT DEFAULT 0,
  chunks_updated  INT DEFAULT 0,
  chunks_skipped  INT DEFAULT 0,
  errors          JSONB DEFAULT '[]'
);

-- =============================================================================
-- INDICES
-- =============================================================================

-- Productos
CREATE INDEX idx_products_category    ON products (category_id);
CREATE INDEX idx_products_is_new      ON products (is_new) WHERE is_new = TRUE;
CREATE INDEX idx_products_brand       ON products (brand);
CREATE INDEX idx_products_search_text ON products USING gin (search_text gin_trgm_ops);
CREATE INDEX idx_products_aliases     ON products USING gin (search_aliases);

-- Atributos
-- idx_pav_product: PK ya cubre lookups por product_id (primer campo de PK), pero un
-- indice dedicado mejora EXISTS WHERE pav.product_id = p.id por su tamano menor.
-- idx_pav_option: indice inverso para "que productos tienen esta opcion" (A7, G6, F3).
-- La PK (product_id, attribute_option_id) NO sirve para esto porque attribute_option_id
-- es el segundo campo y un index scan por solo el segundo campo es ineficiente.
CREATE INDEX idx_pav_product   ON product_attribute_values (product_id);
CREATE INDEX idx_pav_option    ON product_attribute_values (attribute_option_id);
CREATE INDEX idx_attropt_attr  ON attribute_options (attribute_id);
CREATE INDEX idx_aoa_alias     ON attribute_option_aliases USING gin (alias gin_trgm_ops);

-- Specs JSONB normalizado.
-- jsonb_path_ops acelera CONTAINMENT (@>) y existencia de claves:
--   WHERE specs_normalized @> '{"has_wifi": true}'
--   WHERE specs_normalized @> '{"wifi_standard": ["802.11ac"]}'
-- NO acelera comparaciones numericas tipo:
--   WHERE (specs_normalized->>'throughput_lte_dl_mbps')::numeric >= 1000
-- Esas hacen seq scan + cast por fila. A <500 productos es aceptable.
-- Cuando una clave numerica se vuelva caliente (queries frecuentes y latencia
-- visible), agregar un indice de expresion sobre ESA clave, ejemplo:
--   CREATE INDEX idx_specs_throughput_lte_dl ON product_specs
--     (((specs_normalized->>'throughput_lte_dl_mbps')::numeric));
CREATE INDEX idx_specs_normalized ON product_specs USING gin (specs_normalized jsonb_path_ops);

-- Productos recomendados
CREATE INDEX idx_recommendations_target ON product_recommendations (target_product_id);
CREATE INDEX idx_recommendations_source ON product_recommendations (source_product_id);

-- RAG chunks. Sin índices sobre metadata denormalizada: el prefiltro de la ruta
-- semántica se hace por JOIN a products (idx_products_category / _is_new / _brand
-- cubren ese lado) y los chunks del producto se alcanzan por idx_chunks_product.
CREATE INDEX idx_chunks_product     ON rag_chunks (product_id, chunk_type)  WHERE product_id  IS NOT NULL;
CREATE INDEX idx_chunks_software    ON rag_chunks (software_id)             WHERE software_id IS NOT NULL;

-- Indice vectorial: NO crear. Decision deliberada para este catalogo.
-- Volumen real: 73 productos -> 310 chunks (medido); techo 500 productos -> ~3300 chunks.
-- Seq scan sobre vector(3072) con prefiltrado por JOIN a products (category_id /
-- is_new / brand) + EXISTS sobre pav deja el ORDER BY cosine sobre 50-300 chunks: < 10 ms.
-- A este horizonte cualquier indice aproximado agrega overhead sin beneficio.
--
-- Si en un futuro el catalogo creciera mas alla de 10k chunks Y la latencia
-- P95 sostenida superara ~150 ms, recien ahi tiene sentido activar indice.
-- Limitacion conocida de pgvector: HNSW/IVFFlat sobre `vector` solo indexan
-- hasta 2000 dims. gemini-embedding-001 entrega 3072 dims, asi que el dia
-- de la activacion el camino es:
--   ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE halfvec(3072)
--     USING embedding::halfvec(3072);
--   CREATE INDEX idx_chunks_embedding ON rag_chunks
--     USING hnsw (embedding halfvec_cosine_ops)
--     WITH (m = 16, ef_construction = 64);
-- Costo de esa migracion incluso a 3300 chunks: segundos. No-op planificar hoy.
