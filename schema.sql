-- =============================================================================
-- RAG-ready Catalog Schema
-- PostgreSQL 15+ con pgvector y pg_trgm
-- Diseño: filter-then-rank con metadata denormalizada en rag_chunks.
-- Embeddings: text-embedding-3-large (3072 dims).
-- Volumen objetivo: <500 productos, ~2500 chunks. Sin índice vectorial al inicio.
-- =============================================================================

DROP TABLE IF EXISTS
  product_relations,
  rag_chunks,
  ingestion_runs,
  product_specs,
  product_attribute_values,
  category_attributes,
  attribute_option_aliases,
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
  slug          TEXT NOT NULL UNIQUE,
  product_count INT DEFAULT 0
);

-- =============================================================================
-- 2. Atributos taxonómicos (filtros tipo Woo: pa_red-celular, pa_wifi, ...)
-- =============================================================================

CREATE TABLE attributes (
  id        INT PRIMARY KEY,
  name      TEXT NOT NULL,
  taxonomy  TEXT NOT NULL UNIQUE
);

-- Nota: el JSON fuente usa `parent: 0` para indicar "sin padre" en algunos casos.
-- El ETL debe mapear `0` -> NULL antes de insertar si se usa la FK.
CREATE TABLE attribute_options (
  id            INT PRIMARY KEY,
  attribute_id  INT NOT NULL REFERENCES attributes(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  slug          TEXT NOT NULL,
  product_count INT DEFAULT 0,
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
-- 3. Software de gestión (deduplicado, embeddable independientemente)
-- =============================================================================

CREATE TABLE software (
  id                   BIGSERIAL PRIMARY KEY,
  dedupe_group_id      TEXT NOT NULL UNIQUE,
  canonical_product_id BIGINT,                       -- FK a products: se agrega abajo
  name                 TEXT,
  description_text     TEXT,
  attributes           TEXT[] DEFAULT '{}',          -- ['vpn','sdwan','mqtt','modbus']
  fragments_count      INT,
  characters_count     INT,
  content_hash         TEXT,                         -- skip incremental en ETL
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 4. Productos
-- =============================================================================

CREATE TABLE products (
  id              BIGSERIAL PRIMARY KEY,
  slug            TEXT NOT NULL UNIQUE,
  name            TEXT NOT NULL,
  brand           TEXT,
  model           TEXT,
  category_id     INT NOT NULL REFERENCES categories(id),
  source_url      TEXT,
  description     TEXT,
  is_new          BOOLEAN NOT NULL DEFAULT FALSE,
  search_aliases  TEXT[] DEFAULT '{}',
  software_id     BIGINT REFERENCES software(id),
  attributes_hash TEXT,
  specs_hash      TEXT,
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


-- =============================================================================
-- 5. Asignación producto <-> atributos (multivalor)
-- =============================================================================

CREATE TABLE product_attribute_values (
  product_id          BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  attribute_id        INT NOT NULL REFERENCES attributes(id) ON DELETE CASCADE,
  attribute_option_id INT NOT NULL REFERENCES attribute_options(id) ON DELETE CASCADE,
  PRIMARY KEY (product_id, attribute_id, attribute_option_id)
);

-- =============================================================================
-- 6. Specs tecnicas (crudas + normalizadas por LLM)
-- =============================================================================

CREATE TABLE product_specs (
  product_id        BIGINT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  specs             JSONB NOT NULL DEFAULT '[]',    -- crudo: [{name, value, section?, items?}]
  specs_normalized  JSONB NOT NULL DEFAULT '{}',    -- snake_case + numerico (LLM)
  table_specs       JSONB NOT NULL DEFAULT '[]',
  variants          JSONB NOT NULL DEFAULT '[]',
  compatibility     JSONB NOT NULL DEFAULT '[]',
  specs_text        TEXT,                            -- markdown -> embedding
  features_text     TEXT,                            -- markdown -> embedding
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 7. Relaciones entre productos (dirigidas, multi-tipo)
-- =============================================================================

CREATE TABLE product_relations (
  source_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  target_product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  weight            NUMERIC(3,2) NOT NULL DEFAULT 0.7,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (source_product_id, target_product_id, relation_type),
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
                    ('description','specs','features','software','category_summary')),
  section_name    TEXT,
  content         TEXT NOT NULL,
  content_hash    TEXT NOT NULL,
  embedding       VECTOR(3072),
  -- Metadata denormalizada para prefiltrado (cambios -> re-sync por ETL)
  category_slug   TEXT,
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
CREATE INDEX idx_pav_product   ON product_attribute_values (product_id);
CREATE INDEX idx_pav_attr_opt  ON product_attribute_values (attribute_id, attribute_option_id);
CREATE INDEX idx_attropt_attr  ON attribute_options (attribute_id);
CREATE INDEX idx_aoa_alias     ON attribute_option_aliases USING gin (alias gin_trgm_ops);

-- Specs JSONB normalizado (existencia de claves y matching de valores)
CREATE INDEX idx_specs_normalized ON product_specs USING gin (specs_normalized jsonb_path_ops);

-- Relaciones
CREATE INDEX idx_relations_target ON product_relations (target_product_id, relation_type);
CREATE INDEX idx_relations_source ON product_relations (source_product_id, relation_type);

-- RAG chunks
CREATE INDEX idx_chunks_filter      ON rag_chunks (category_id, is_new, chunk_type);
CREATE INDEX idx_chunks_attr_slugs  ON rag_chunks USING gin (attribute_slugs);
CREATE INDEX idx_chunks_product     ON rag_chunks (product_id, chunk_type)  WHERE product_id  IS NOT NULL;
CREATE INDEX idx_chunks_software    ON rag_chunks (software_id)             WHERE software_id IS NOT NULL;

-- Indice vectorial: NO crear al inicio. Activarlo cuando rag_chunks supere ~10k filas:
-- CREATE INDEX idx_chunks_embedding ON rag_chunks
--   USING ivfflat (embedding vector_cosine_ops) WITH (lists = 10);
