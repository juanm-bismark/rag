-- =============================================================================
-- RAG-ready Catalog Schema
-- PostgreSQL 15+ con pgvector y pg_trgm
-- Diseño: filter-then-rank con metadata denormalizada en rag_chunks.
-- Embeddings: text-embedding-3-large (3072 dims).
-- Volumen objetivo: <500 productos, ~2500 chunks. Sin índice vectorial al inicio.
-- =============================================================================

DROP TABLE IF EXISTS
  product_recommendations,
  rag_chunks,
  ingestion_runs,
  category_known_keys,
  product_specs,
  product_attribute_values,
  category_attributes,
  attribute_option_aliases,
  attribute_options,
  attributes,
  solution_pages_table,
  products,
  software,
  categories
CASCADE;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- Sinónimos para el extractor NLU: "móvil"/"celular"/"4G/LTE" -> option correcta
CREATE TABLE attribute_option_aliases (
  attribute_option_id INT NOT NULL REFERENCES attribute_options(id) ON DELETE CASCADE,
  alias               TEXT NOT NULL,
  PRIMARY KEY (attribute_option_id, alias)
);

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

CREATE TRIGGER trg_product_specs_updated_at
BEFORE UPDATE ON product_specs
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
  -- Version del prompt usado para normalizar. Permite re-normalizar selectivamente
  -- cuando se ajuste el prompt sin perder trazabilidad. Formato sugerido: 'vYYYY-MM-DD'.
  prompt_version      TEXT,
  prompt_normalized_at TIMESTAMPTZ,
  table_specs         JSONB,
  variants            JSONB,
  compatibility       JSONB,
  specs_text            TEXT,                          -- markdown -> embedding
  features_text         TEXT,                          -- markdown -> embedding
  specs_fingerprint     TEXT,                          -- calculado y escrito por n8n: 'specs:<json>|normalized:<json>'
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 6b. Triggers: specs_hash en products + embedding_hash en product_specs
-- =============================================================================

-- specs_fingerprint: concatenación legible de (specs | specs_normalized).
-- Formato: "specs:<json>|normalized:<json>"
-- n8n computa: 'specs:' + JSON.stringify(specs) + '|normalized:' + JSON.stringify(specs_normalized)
-- specs_fingerprint calculado por n8n antes del upsert:
--   'specs:' + JSON.stringify(specs) + '|normalized:' + JSON.stringify(specs_normalized)
-- n8n escribe el valor en el INSERT/UPDATE; el DB no lo recalcula.

-- embedding_fingerprint calculado por n8n antes del upsert:
--   'specs_text:' + (specs_text ?? '') + '|features_text:' + (features_text ?? '')
-- Señal de re-embedding: si cambia entre runs, los chunks specs/features están desactualizados.
-- Separado de specs_fingerprint porque specs_text/features_text pueden regenerarse con un
-- prompt distinto sin que el JSON crudo cambie.
-- n8n escribe el valor en el INSERT/UPDATE; el DB no lo recalcula.

-- =============================================================================
-- 6c. Known keys por categoría (mantenida por trigger tras cada normalización)
-- =============================================================================

-- Tabla de una fila por categoría con el array de claves snake_case ya conocidas
-- en specs_normalized. Se usa en el loop de normalización para que el LLM reutilice
-- nombres de claves consistentes entre productos de la misma categoría.
-- Poblada directamente por el ETL (n8n) vía upsert.
CREATE TABLE category_known_keys (
  category_id  INT PRIMARY KEY REFERENCES categories(id) ON DELETE CASCADE,
  known_keys   TEXT[] NOT NULL DEFAULT '{}',
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

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
-- 8. RAG: chunks con metadata denormalizada para prefiltrado
-- =============================================================================

CREATE TABLE rag_chunks (
  id              BIGSERIAL PRIMARY KEY,
  product_id      BIGINT REFERENCES products(id) ON DELETE CASCADE,
  software_id     BIGINT REFERENCES software(id) ON DELETE CASCADE,
  chunk_type      TEXT NOT NULL
                  CHECK (chunk_type IN
                    ('overview','description','features','specs','spec_section',
                     'software','compatibility','variants')),
  section_name    TEXT,
  content         TEXT NOT NULL,
  embedding       VECTOR(3072),
  -- Metadata denormalizada para prefiltrado (cambios -> re-sync por ETL)
  category_id     INT,
  is_new          BOOLEAN,
  brand           TEXT,
  attribute_slugs TEXT[] DEFAULT '{}',               -- ['pa_red-celular:5g','pa_wifi:si']
  token_count     INT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT chunk_owner_xor CHECK (
    (product_id IS NOT NULL AND software_id IS NULL) OR
    (product_id IS NULL AND software_id IS NOT NULL)
  )
);

-- =============================================================================
-- 8b. Trigger: updated_at en rag_chunks
-- =============================================================================

-- No se usa columna de fingerprint/hash para chunks.
-- n8n compara content directamente:
--   SELECT content FROM rag_chunks WHERE product_id = X AND chunk_type = Y AND section_name = Z
--   Si incoming_content != stored_content → UPDATE + nullear embedding (re-embed necesario).
-- Señal de re-embedding: embedding IS NULL después de un UPDATE de content.
CREATE OR REPLACE FUNCTION rag_chunks_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  NEW.embedding  := NULL;  -- invalida el vector; el ETL de embeddings lo detecta
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_chunks_updated_at
BEFORE UPDATE OF content
ON rag_chunks
FOR EACH ROW EXECUTE FUNCTION rag_chunks_set_updated_at();

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

-- RAG chunks
CREATE INDEX idx_chunks_filter      ON rag_chunks (category_id, is_new, chunk_type);
CREATE INDEX idx_chunks_attr_slugs  ON rag_chunks USING gin (attribute_slugs);
CREATE INDEX idx_chunks_product     ON rag_chunks (product_id, chunk_type)  WHERE product_id  IS NOT NULL;
CREATE INDEX idx_chunks_software    ON rag_chunks (software_id)             WHERE software_id IS NOT NULL;

-- Indice vectorial: NO crear. Decision deliberada para este catalogo.
-- Volumen real: 74 productos -> ~495 chunks; techo 500 productos -> ~3300 chunks.
-- Seq scan sobre vector(3072) con prefiltrado por category_id / is_new /
-- attribute_slugs deja el ORDER BY cosine sobre 50-300 chunks: < 10 ms.
-- A este horizonte cualquier indice aproximado agrega overhead sin beneficio.
--
-- Si en un futuro el catalogo creciera mas alla de 10k chunks Y la latencia
-- P95 sostenida superara ~150 ms, recien ahi tiene sentido activar indice.
-- Limitacion conocida de pgvector: HNSW/IVFFlat sobre `vector` solo indexan
-- hasta 2000 dims. text-embedding-3-large entrega 3072 dims, asi que el dia
-- de la activacion el camino es:
--   ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE halfvec(3072)
--     USING embedding::halfvec(3072);
--   CREATE INDEX idx_chunks_embedding ON rag_chunks
--     USING hnsw (embedding halfvec_cosine_ops)
--     WITH (m = 16, ef_construction = 64);
-- Costo de esa migracion incluso a 3300 chunks: segundos. No-op planificar hoy.
