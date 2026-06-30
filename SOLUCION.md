# Solución de catálogo + RAG — Bismark

Documento de referencia con todas las decisiones tomadas. El pipeline operativo es:

- **[flujo.json](flujo.json)** — workflow n8n (152 nodos) que implementa el pipeline
  completo: scrapea WooCommerce, parsea HTML de specs/features, deduplica software
  canónico, resuelve productos recomendados por fuzzy alias matching, normaliza specs
  con LLM, calcula fingerprints para idempotencia, carga en las tablas de
  [schema.sql](schema.sql) con upsert incremental (INSERT/UPDATE/DELETE por entidad),
  genera los embeddings de los chunks con Gemini y registra cada corrida en
  `ingestion_runs`. La carga ya no es un "loader" externo pendiente: vive dentro del
  mismo workflow.
- **[schema.sql](schema.sql)** — DDL destino: 14 tablas + 4 vistas (catálogo + EAV de
  atributos + capa RAG), más la tabla de staging `embedding_rag_chunk_upload` y su
  trigger de sincronización a `rag_chunks`.

Este texto es la guía operativa del pipeline completo. Donde aparece "el loader" más
abajo se refiere a la **etapa de carga del propio workflow n8n**, no a un componente
separado.

---

## 1. Enfoque general

El sistema separa **lo filtrable** (categorías, atributos taxonómicos, marca, `is_new`,
specs numéricas/enum) de **lo semántico** (descripción, specs narrativas, features,
software de gestión).

Sobre eso se monta un patrón **filter-then-rank** con dos rutas paralelas:

- **Ruta estructurada** — SQL puro sobre tablas normalizadas. Resuelve relaciones,
  filtros disponibles, filtros numéricos, taxonomía.
- **Ruta semántica** — similarity search sobre `rag_chunks`, prefiltrando por
  JOIN a `products` (categoría/novedad/marca) + EXISTS sobre `pav` antes del cosine.

En **runtime v1** esto lo ejecuta **un solo agente n8n con tool-calling** (ver §7): el
agente clasifica la pregunta de forma implícita al elegir y parametrizar las tools,
dispara ambas rutas y compone la respuesta sobre el merge. El "extractor NLU" **no es
una etapa runtime separada** — quedó como contrato lógico/evaluable (ver §7
"Arquitectura runtime" y [PREGUNTAS.md §1](PREGUNTAS.md)).

**Volumen (snapshot contra la base en Supabase — las cifras cambian en cada reload del ETL):** 74 productos →
**317 chunks** (74 overview + 11 description + 70 features + 115 spec_section
+ 34 specs + 4 variants + 3 compatibility + 6 software). El conteo de `description`
es bajo a propósito: la regla de chunking de §6 omite ese chunk cuando solapa
fuertemente con `overview`. 8 `category_id`, 11 marcas,
36 atributos filtrables válidos, 92 opciones válidas, 80 productos recomendados
(edges dirigidos), 6 grupos canónicos de software y 70/74 productos con specs
normalizadas (4 accesorios sin normalizar). En este snapshot `is_new` viene en 0.
**Techo planeado:** <500 productos → ~3300 chunks. PostgreSQL + pgvector en una
sola DB. **Sin índice vectorial nunca a este horizonte** (seq scan + prefiltrado
< 10 ms — ver §12 para la justificación cuantitativa y la migración a
`halfvec(3072)` que solo aplicaría si se cruza ~10k chunks).

---

## 2. Decisiones de diseño (cerradas)

| Decisión | Elegido | Justificación corta |
|---|---|---|
| Stack | PostgreSQL 15 + pgvector + pg_trgm | Una DB, todo cabe. |
| Modelo embeddings | `gemini-embedding-001` (3072 dims), vía n8n (Gemini + LangChain) | Costo trivial al volumen. La dimensión por defecto del modelo (3072) define la columna `vector(3072)`. |
| Índice vectorial | Ninguno (ver §12) | A 74 productos / 317 chunks reales, seq scan corre en <2 ms. En el techo planeado de 500 productos / ~3300 chunks, < 10 ms. Activación nunca se justifica a este horizonte. |
| Atributos taxonómicos (Woo `pa_*`) | EAV controlado | Multivalor + heterogéneo por categoría. |
| Specs técnicas | JSONB crudo + `specs_normalized` JSONB (LLM) | Catálogo manual de spec_keys es overkill a este volumen. |
| Software de gestión | Tabla canónica con embedding único | Evita 12 chunks idénticos (Robustel et al.). |
| Relaciones | Dirigidas siempre (bidireccionales se duplican) | Queries triviales, costo irrelevante. |
| Metadata en `rag_chunks` | **No denormalizada** — prefiltro por JOIN a `products` + EXISTS sobre `pav` | A ~3300 chunks sin índice vectorial el JOIN da la misma selectividad que columnas denormalizadas, con cero drift y cero copia que mantener. Se denormalizaría solo al activar índice vectorial (~10k chunks). |
| Re-ingesta | Fingerprint por registro calculado en n8n → skip si no cambió | Embeddings cuestan; idempotencia obligatoria. n8n no puede usar `require('crypto')` — se usa concatenación legible (`key:value\|key:value`) en lugar de MD5. |
| Precio / stock | No modelado | Confirmado fuera de scope. |

---

## 3. Esquema de base de datos

14 tablas + 4 vistas derivadas. DDL completo y comentado en [schema.sql](schema.sql).

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
  `specs_text`/`features_text` (markdown a embeddear) + `table_specs`/`variants`/`compatibility` (JSONB auxiliares).
- `product_specs.keys_context` (columna JSONB) — semántica por clave (`shape`/`desc`)
  que el LLM emite junto a `specs_normalized`. El vocabulario por categoría **no se
  materializa en tabla**: se deriva al leer con la vista `category_keys_context`
  (agrega el `keys_context` de todos los productos de la categoría). El loop de
  normalización lee esa vista para mantener consistencia de claves entre productos
  de la misma categoría. Las vistas `category_key_drift` y `category_enum_value_drift`
  detectan claves/valores casi idénticos para revisión manual.
- `reference_aliases` + `reference_alias_candidates` — datos de referencia GLOBALES
  para la normalización de specs (certificaciones, traducciones de valor,
  equivalencias de clave, descartes de identidad). `code.js` los lee vía la vista
  `reference_bundle` y mergea sobre sus mapas de fallback; los tokens desconocidos
  se acumulan en `reference_alias_candidates` para promoción humana. GLOBAL, no
  por categoría.
- `software` — software de gestión deduplicado (canónico),
  con FK circular `products.software_id` ↔ `software.canonical_product_id`.
- `product_recommendations` — dirigidas (source → target). Tabla específica para "productos recomendados"; no se mezclan otros tipos de relación (compatibilidad, accesorios) — si llegan a existir, se modelan en tablas propias.

**Capa RAG**

- `rag_chunks` — texto + embedding (**sin metadata denormalizada**: el prefiltro
  se hace por JOIN a `products` + EXISTS sobre `pav`).
  Un chunk pertenece a un producto **o** a un software (XOR check constraint).
  Tipos válidos: `overview`, `description`, `features`, `specs`, `spec_section`,
  `software`, `compatibility`, `variants`. La columna `section_name` identifica
  la sección técnica cuando aplica (`spec_section`).
- `ingestion_runs` — auditoría de cada corrida del ETL.

**Reglas de integridad clave**

- `chunk_owner_xor` en `rag_chunks` — un chunk no puede pertenecer a producto Y software a la vez.
- FK circular `products` ↔ `software` cerrada con `ALTER TABLE` después de crear `products`.

### Incongruencias actuales en `schema.sql` frente al output del flujo (`flujo.json`)

No se cambia el DDL automáticamente; estas son las diferencias que el ETL debe
resolver o que conviene corregir manualmente si se quiere trazabilidad completa:

| Punto | En el output del flujo (`flujo.json`) | En `schema.sql` | Impacto / decisión |
|---|---|---|---|
| Categorías | Solo existe `category_id` | `categories.name` y `categories.slug` son `NOT NULL` | El loader necesita lookup externo de Woo o valores sintéticos (`categoria-516`) antes de insertar productos. |
| Atributo inválido | 1 producto trae atributo `id = 0`, `taxonomy = null` | `attributes.taxonomy` es `NOT NULL` | Debe saltarse y registrarse como warning. |
| Fuente de recomendados | `productos_recomendados[]` viene del JSON actual | `product_recommendations` no tiene columna `source` | La fuente queda en `ingestion_runs.source`, no en cada edge. |
| Output del nodo "relaciones" | El nodo emite `{product_recommendations: [...], stats: {total_recommendations, skipped_*_recommendation, ...}}` | Tabla DB `product_recommendations` con las mismas columnas | El loader inserta 1:1 el campo en la tabla del mismo nombre. El nombre del node en n8n es `"relaciones"` aunque emite `product_recommendations` — desalineación visual sin impacto funcional. |
| `compatibility` mezcla dos semánticas | Caso A (Netio): items `{brand, models}` apuntando a marcas de terceros (Honeywell, DSC, Paradox) **fuera del catálogo**. Caso B (Robustel R1520): strings sueltos (`"Chile-SUBTEL"`, `"Uruguay-URSEC"`) que son **certificaciones regulatorias**, no compatibilidad de dispositivo | Una sola columna `product_specs.compatibility JSONB` | Decisión: **mantener como JSONB** (ver §12). Justificación: (a) ningún item resuelve a productos del catálogo, no aplica tabla relacional; (b) sparse (3/74 productos). Riesgo: el loader debe tolerar **ambas formas** del JSONB (lista de objetos `{brand, models}` y lista de strings) y emitir warning si llega una tercera forma. |
| Brand de productos sin attribute `fabricante` | Nodo `merge del catalogo` aplica heurística filtrada: brand desde attribute `fabricante` cuando existe; fallback solo si (a) `name` tiene espacio, (b) primera palabra no está en `GENERIC_FIRST_WORDS` (`antena, cable, kit, módulo, modem, router, gateway, switch, transceptor, adaptador, fuente, accesorio, conector, sensor, panel, soporte, rack`), (c) primera palabra ≥ 2 caracteres. Si alguna regla falla, `brand = null` y `model = null`. | `products.brand` y `products.model` admiten NULL; el nodo emite además `brand_source` con valores `'attribute' \| 'heuristic' \| null` | Cobertura sobre la base cargada (74 productos): 68 con marca resuelta (attribute `fabricante` o heurística) y 6 sin marca (`brand=null`, `model=null`). El loader debe loggear warning estructurado por cada producto con `brand_source='heuristic'` (deuda de datos: el attribute `fabricante` debería estar cargado en Woo para esos productos). |

---

## 4. Flujo ETL — orden de carga

El "ETL" tiene dos etapas claramente separadas:

**Etapa 1: extracción y transformación (n8n, [flujo.json](flujo.json))** — ya
implementada. Produce, en memoria del workflow, un objeto por producto que ya
contiene:

| Campo del output | Origen en el flujo |
|---|---|
| `id, slug, name, brand, model, brand_source, category_id, es_nuevo, attributes, search_aliases, description, source_url, productos_recomendados` | Nodo `merge del catalogo y los productos` (catálogo Woo + identificación + heurística filtrada de brand) |
| `specs[]` (array de `{name, value, section?, items?}`), `specs_text` (markdown) | Nodo `Especificaciones técnicas` (parsea HTML de tabla de specs) |
| `compatibility[]`, `variants[]`, `table_specs[]`, `features_text` | Nodo `Características normalizadas` (parsea HTML de caracteristicas) |
| `software_nombre, software_texto, software_attributes, software_fragmentos, software_caracteres, is_software_canonical, software_canonico_de, software_applies_to_product_ids, software_dedupe_group_id` | Nodo `Limpieza software de gestión` (dedupe por hash brand+texto) |
| `product_recommendations[]` con `{source_product_id, target_product_id}` + `stats {total_recommendations, skipped_*}` | Nodo `relaciones` (fuzzy alias matching). El node se llama "relaciones" en n8n pero emite `product_recommendations`. |

Lo que el flujo **ya filtra/limpia**: CTAs ("solicitar bajo demanda", "contáctenos",
"visite www..."), ruido editorial ("borrar", "añadir!!"), notas de reemplazo
(preservadas dentro de description), self-relations, recomendados que no
resuelven, duplicados.

**Etapa 2: carga (implementada en el mismo workflow n8n)** — toma cada item del
output, respeta las dependencias de FK y normaliza nombres (`es_nuevo` → `is_new`,
`software_canonico_de` → vínculo al producto canónico, `product_recommendations[]`
del flujo → inserción 1:1 en tabla `product_recommendations`, etc.):

| # | Tabla | Fuente | Notas |
|---|---|---|---|
| 1 | `categories` | `DISTINCT category_id` | Insertar 8 filas. Si no hay lookup de Woo, usar placeholders controlados para `name`/`slug` porque el DDL actual no permite NULL. |
| 2 | `attributes` + `attribute_options` | `attributes[].options[]` | Insertar solo atributos con `taxonomy` no NULL e `id != 0`. Snapshot: 36 atributos y 92 opciones válidas. |
| 3 | `category_attributes` | derivado del mismo JSON | Recorrer cada producto y registrar pares (`category_id`, `attribute_id`) únicos. |
| 4 | `software` (solo canónicos) | productos con `is_software_canonical = true` | Insertar 6 grupos canónicos usando `software_dedupe_group_id`, `software_nombre`, `software_texto`, `software_attributes`, `software_fragmentos`, `software_caracteres`. Aún sin `canonical_product_id`. |
| 5 | `products` | cada elemento del JSON | Mapear `id`, `slug`, `name`, `brand`, `model`, `category_id`, `source_url`, `description`, `es_nuevo`, `search_aliases`. Resolver `software_id` desde `software_dedupe_group_id`. |
| 6 | `software.canonical_product_id` | UPDATE | Cierre del bucle FK. |
| 7 | `product_attribute_values` | `attributes[].options[]` | Insertar una fila por producto-atributo-opción. Skipping explícito del atributo inválido detectado (`id = 0`, `taxonomy = null`) en `antena-magnetica-3-9-dbi-1-5-mts`. |
| 8 | `product_specs` (sin normalizado) | campos técnicos del producto | `specs`, `table_specs`, `variants`, `compatibility`, `specs_text`, `features_text`. |
| 9 | `product_specs.specs_normalized` | **LLM** sobre cada producto | Ver prompt en §5. |
| 10 | `product_recommendations` | `product_recommendations[]` (output del nodo `relaciones`) | El flujo ya resolvió los slugs y emitió pares `{source_product_id, target_product_id}`. El loader solo inserta. La fuente de la corrida queda en `ingestion_runs.source`. El `stats` del nodo (`total_recommendations`, `skipped_missing_source_id`, `skipped_unresolved_target`, `skipped_missing_target_id`, `skipped_self_recommendation`, `skipped_duplicate_recommendation`) debe persistirse en `ingestion_runs.errors` para auditoría. Snapshot: 80 edges. |
| 11 | `rag_chunks` + embeddings | derivado | Ver §6. |

### Validaciones obligatorias del loader

Las primeras tres validaciones ya están parcialmente cubiertas por el flujo
(el nodo `relaciones` saltea `productos_recomendados[]` no resueltos y los
cuenta en `stats.skipped_unresolved_target`). El loader debe revisar el
`stats` emitido por el flujo y abortar / alertar si los conteos de skipped
crecen vs corridas previas.

- Verificar que cada `product_recommendations[]` que el flujo emite tenga
  `source_product_id` y `target_product_id` existentes en `products` antes de
  insertar. El flujo ya filtra los no-resueltos pero el loader debe revalidar
  por integridad (defensa en profundidad).
- Loggear warning estructurado por cada producto con `brand_source='heuristic'`
  (deuda de datos: falta attribute `fabricante` en WooCommerce). Loggear también
  por cada producto con `brand_source=null` y `brand=null` (probable accesorio
  genérico sin marca propia, o name mal formado sin espacios — revisar manualmente
  en Woo).
- Verificar que `software_canonico_de` apunte a un producto existente y que su
  `software_dedupe_group_id` coincida con el grupo.
- Verificar que solo los productos canónicos generen chunk `software`; los demás
  se enlazan por `products.software_id`.
- Registrar como warning cualquier atributo con `taxonomy` vacío, `id = 0` u
  opción sin `slug`.
- Revisar manualmente nombres de software casi duplicados. En el snapshot existe
  `Robustel Coud Manager Service`, probablemente variante tipográfica de
  `Robustel Cloud Manager Service`; no fusionarlo automáticamente sin aprobación.
- **Validar forma del JSONB `compatibility`**: el flujo emite dos formas válidas
  (lista de `{brand, models}` o lista de strings). Si el loader detecta una
  tercera forma (objetos con otras claves, números, valores nulos), registrar
  warning y no insertar el campo. Adicionalmente, si el contenido de los strings
  matchea regex regulatoria (`/\b(SUBTEL|ENACOM|FCC|CE|ANATEL|URSEC)\b/i`),
  loggearlo — probablemente debería vivir en un futuro campo `certifications`
  pero hoy se acepta en `compatibility` (caso `robustel-r1520-4l`).
- **Multi-term Si/No: preservar, no deduplicar.** Si un producto trae
  `['no','si']` para el mismo atributo (snapshot actual: `robustel-r2011`,
  `robustel-r1510-4l`, `robustel-r2110` en `pa_wifi`; `suntech-kit-de-voz` en
  `pa_audio-en-cabina`), insertar **ambas** filas en
  `product_attribute_values`. El sitio de origen muestra el mismo
  comportamiento (el producto aparece en el filtro "Con WiFi" y en
  "Sin WiFi" por tener variantes). La PK compuesta soporta el caso. Lo mismo
  aplica a multi-term legítimo (`pa_uso: ['empresarial','industrial']`,
  `pa_red-celular: ['3g-4g','5g']`).
- **UX del multi-term en la respuesta del LLM final.** Cuando el producto
  recuperado tenga valores contradictorios (`['no','si']`) o múltiples
  (`['3g-4g','5g']`) para un mismo atributo y la pregunta del usuario sea
  binaria ("¿tiene WiFi el R2011?"), el prompt del LLM final debe instruirlo
  para **declarar la ambigüedad** en lugar de elegir uno. Texto esperado:
  "El R2011 tiene variantes con y sin WiFi" o "soporta 3G/4G y 5G según
  variante". Esto se implementa en el prompt de composición, no en el
  schema, pero depende de que el retrieval entregue las filas multi-term
  intactas; por eso la política de preservación es prerequisito.

### Test de paridad ETL ↔ sitio

Después de cada corrida completa del ETL, ejecutar una query que reconstruya
los conteos del front por (categoría, atributo, opción) y compararlos contra
el sitio. Es donde el bug de multi-term aparece primero si alguien deduplica.

```sql
SELECT a.taxonomy, ao.slug, COUNT(DISTINCT pav.product_id) AS productos
FROM product_attribute_values pav
JOIN attribute_options ao ON ao.id = pav.attribute_option_id
JOIN attributes a         ON a.id = ao.attribute_id
JOIN products p           ON p.id = pav.product_id
WHERE p.category_id = $1
GROUP BY a.taxonomy, ao.slug
ORDER BY a.taxonomy, ao.slug;
```

Criterio de aprobación: cada par `(taxonomy, slug)` cuadra contra el conteo
visible en el front para esa categoría. Diferencia > 0 = revisar inmediatamente.

### Repoblado desde cero (bootstrap)

Runbook para reconstruir la BD tras un wipe. Hay **tres clases** de tablas, con
dependencias distintas; respetarlas evita fallos de FK:

- **Seeds curados SQL** — datos reales viven en el archivo `.sql`.
- **Ingesta n8n** — las puebla el pipeline (`pipeline_ingesta.json`), pasos 1–11
  de la tabla de arriba.
- **Estructura + n8n** — el `.sql` solo crea tabla/función; los datos los genera
  un flujo n8n aparte.

**Nota sobre `schema.sql`:** hace `DROP ... CASCADE` (líneas 12–27) y recrea las
tablas del pipeline. **No toca `solution_pages_table`** (no está en esa lista; la
gobierna `solution_pages.sql`, que es idempotente por su propio `drop ... if exists`).

Orden de ejecución:

| # | Acción | Tabla(s) | Depende de | Por qué |
|---|---|---|---|---|
| 0 | Recrear esquema (solo si dropeaste tablas; **no** si solo borraste filas) | todas las del pipeline | — | `DROP/CREATE`; incluye el fix `products_software_id_fkey ON DELETE SET NULL` |
| 1 | `reference_aliases_seed.sql` | `reference_aliases` | nada | Texto puro (`kind, alias, canonical`), sin FK a datos → corre apenas exista el esquema |
| 2 | Ingesta n8n completa (`pipeline_ingesta.json`) | `categories` … `rag_chunks` | esquema | Pasos 1–11 de §4 |
| 3 | `attribute_option_aliases_seed.sql` | `attribute_option_aliases` | **paso 2** | ⚠️ Inserta IDs literales (`498`, `1586`…) con FK a `attribute_options(id)`. Si `attribute_options` está vacía, **las 226 filas fallan** con `violates foreign key constraint`. Solo corre tras la ingesta |
| 4 | `solution_pages.sql` (estructura) + flujo n8n de solution pages (datos) | `solution_pages_table` | independiente | El `.sql` solo crea tabla + `match_solution_pages`; los embeddings los puebla el flujo n8n de páginas de solución |

Regla mental: **`reference_aliases` antes de la ingesta; `attribute_option_aliases`
después** — porque el segundo referencia por FK lo que la ingesta crea en el paso 2.
`solution_pages` es un subsistema aparte (ver §7.2) y no bloquea al pipeline principal.

---

## 5. Prompt de normalización de specs (paso 9)

El **prompt vivo y autoritativo es [prompt.md](prompt.md)**; esta sección describe
cómo el loader lo invoca, qué le pasa y cómo valida la salida. El detalle de reglas
(unidades canónicas, dedup contra el vocabulario, certificaciones, rangos, narrativa
vs enum, etc.) vive en [prompt.md](prompt.md) — no se duplica aquí.

Una llamada LLM por producto. Modelo recomendado: `claude-sonnet-4-6` o
`gpt-4o-mini` (no necesita Opus). Costo total estimado para 74 productos: <$1.

**Input por producto** (ver `<context>` en [prompt.md](prompt.md)):
`{ category_name, specs: [{name, value, section?}], keys_context }`. El aplanado de
items anidados y la limpieza previa los hace `code.js` antes del LLM, de modo que
`specs` llega siempre con ≥1 ítem plano. `keys_context` es el vocabulario canónico
de la categoría, derivado de la vista `category_keys_context` (ver más abajo).

**Salida**: un único objeto JSON con tres claves de nivel superior —
`output` (= `specs_normalized`, se inserta en `product_specs.specs_normalized`),
`keys_context` (semántica por clave, se persiste en `product_specs.keys_context`) y
`audit_trace` (traza de decisiones para auditoría). El gate de post-validación manda
los productos con shape inválido a una cola `needs_review` en vez de insertarlos.

### Preprocesado antes del LLM (en `code.js`, no en el prompt)

`code.js` deja `specs` listo antes de la llamada al LLM:

- **Aplana items anidados.** Los sub-items (`items[]`) se concatenan a ítems planos
  (`"<padre> - <hijo>"`) para que el LLM vea una lista plana sin ambigüedad.
- **Garantiza `specs` no vacío.** La limpieza/relleno se hace aguas arriba, de modo
  que el LLM siempre recibe `specs` con ≥1 ítem.
- **Variantes multi-SKU.** El prompt ([prompt.md](prompt.md) §5/§13) emite una clave
  calificada por etiqueta/variante (`input_voltage_poe_pd_min_v`,
  `input_current_eth_gprs_max_a`, una pareja min/max por banda), en vez de aplanar al
  primer valor. El loader puede registrar `{product_id, variant_count}` en
  `ingestion_runs.errors` para auditar productos multi-variante.

### Construcción del `keys_context` de entrada

El loader lee el vocabulario canónico de la categoría desde la vista
`category_keys_context` (una fila por categoría con
`{ "<key>": { n, example, shape, desc } }`) y lo pasa como `keys_context`:

```sql
SELECT keys_context
FROM category_keys_context
WHERE category_id = $1;
```

La primera ejecución por categoría no devuelve fila (vocabulario vacío); el LLM crea
el vocabulario. A partir del 2º producto ya hay base de reuso. Las claves convergen
rápido (10–15 productos por categoría son suficientes para estabilizar).

### Reglas del system prompt

El system prompt **completo y autoritativo vive en [prompt.md](prompt.md)**: define
las reglas de comportamiento del LLM (forma del JSON, unidades canónicas, dedup
contra `keys_context`, rangos/escalares, narrativa vs enum, padre/hijas, identidad,
certificaciones, higiene de salida) y termina con ejemplos I/O. El system prompt no
cambia por producto, así que el prompt caching (TTL 5 min) lo mantiene barato; los
datos del producto van en el **text input** de cada llamada (abajo).

### Input en runtime (text input por llamada)

El text input es el `user message` de cada llamada: los datos reales del producto.
Forma (ver `<context>` en [prompt.md](prompt.md)):

```json
{
  "category_name": "Modems y Routers",
  "specs": [
    {"name": "Throughput LTE", "value": "150 Mbps DL / 50 Mbps UL", "section": "Conectividad"},
    {"name": "Puertos LAN",    "value": "4 x RJ45 10/100",           "section": "Interfaces"},
    {"name": "Puertos WAN",    "value": "1 x RJ45 Gigabit",          "section": "Interfaces"},
    {"name": "Temperatura",    "value": "-40 a 75 °C",               "section": "Ambiental"},
    {"name": "Voltaje",        "value": "9-36 V DC",                 "section": "Alimentación"},
    {"name": "Certificaciones","value": "Homologado Chile-SUBTEL, Uruguay-URSEC"},
    {"name": "Instalación",    "value": "Montaje DIN rail. Requiere gabinete IP54."}
  ],
  "keys_context": {
    "throughput_lte_dl_mbps":      {"n": 8,  "example": 100, "shape": "scalar", "desc": "LTE downlink throughput"},
    "operating_temperature_min_c": {"n": 12, "example": -40, "shape": "range",  "desc": "minimum operating temperature"},
    "operating_temperature_max_c": {"n": 12, "example": 75,  "shape": "range",  "desc": "maximum operating temperature"}
  }
}
```

`keys_context` se construye desde la vista `category_keys_context` (ver arriba). En
la primera ejecución de una categoría llega vacío (`{}`); el LLM genera el
vocabulario inicial y las llamadas siguientes ya tienen claves de referencia.

### Ejemplo de salida esperada

`output` del LLM para el input anterior (las otras dos claves de nivel superior,
`keys_context` y `audit_trace`, se omiten aquí por brevedad):

```json
{
  "throughput_lte_dl_mbps": 150,
  "throughput_lte_ul_mbps": 50,
  "ports_lan_count": 4,
  "ports_lan_speed_mbps": 100,
  "ports_wan_count": 1,
  "ports_wan_speed_mbps": 1000,
  "voltage_min_v": 9,
  "voltage_max_v": 36,
  "operating_temperature_min_c": -40,
  "operating_temperature_max_c": 75,
  "certifications": ["CL-SUBTEL", "UY-URSEC"],
  "_install_notes": ["Montaje DIN rail", "Requiere gabinete IP54"]
}
```

### Validación en ETL (antes de insertar `specs_normalized`)

El LLM tiende a producir variantes tipográficas o semánticas de claves ya
existentes. La validación actúa en dos niveles complementarios:

**Nivel 1 — Levenshtein (tipográfico, ya existente):**

1. Por cada clave nueva emitida por el LLM para un producto, calcular distancia
   Levenshtein contra cada clave de `keys_context` (las claves canónicas de la categoría).
2. Si `distance ≤ 2` y la clave existente NO está ya presente en el output
   → **bloquear el INSERT** y forzar reuso o revisión manual. Registrar en
   `ingestion_runs.errors` con `{product_id, llm_key, suggested_key, distance}`.
3. Si `distance ≤ 2` pero la clave existente SÍ está en el output (el LLM las
   trata como distintas a propósito, p. ej. `*_dl_mbps` y `*_ul_mbps`) → permitir.
4. Si `distance > 2` o no hay claves comparables → permitir (clave genuinamente nueva).

Implementación: extensión `fuzzystrmatch` (`levenshtein(text, text)`), ya
disponible en Postgres. Costo por producto: <5 ms.

**Nivel 2 — Similitud semántica (variantes léxicas, nuevo):**

Levenshtein no detecta variantes como `temp_funcionamiento_c` ≈
`operating_temp_c` (distancia > 10). Para cubrir este caso:

```python
# Para cada llm_key que Levenshtein permitió:
emb_new = embed(llm_key)                    # embedding de la clave snake_case
for kk in keys_context:                     # claves canónicas de la categoría
    if kk not in embed_cache:
        embed_cache[kk] = embed(kk)
    if cosine_similarity(emb_new, embed_cache[kk]) >= 0.85:
        block_insert(product_id, llm_key, suggested_key=kk, reason="semantic_dup")
        break
```

Umbral 0.85 es conservador: deja pasar `ports_lan_count` vs `ports_wan_count`
(distintos) pero bloquea `operating_temp_c` vs `temp_funcionamiento_c`
(mismo concepto). Ajustar si hay falsos positivos en las primeras corridas.

Excluir claves con prefijo `_` de ambas validaciones (narrativas, por
definición poco frecuentes por producto).

### Forzar re-normalización tras cambio de prompt

`prompt_version` se eliminó por decisión deliberada: cambios de prompt son raros
(1-2 veces/año esperado) y mantener una columna + lógica condicional en n8n no
se justifica. Cuando se ajuste el prompt, forzar re-normalización completa:

```sql
-- Invalida el fingerprint de todos los productos
UPDATE product_specs SET specs_fingerprint = NULL;
```

En el próximo run de n8n, todos los productos tienen `stored_fp = NULL ≠ new_fp`,
por lo que entran al pipeline completo (re-normalize + re-gen-text + re-chunks).

Trade-off aceptado: no hay trazabilidad por producto de qué prompt produjo qué
normalized. Si se vuelve necesario auditar, reintroducir `prompt_version` como
columna opcional sin lógica de skip — solo para registro.

### Validación post-normalización

Query mensual para detectar claves huérfanas (segunda red de seguridad).
Excluir el prefijo `_` (narrativas, legítimamente poco frecuentes):

```sql
SELECT key, COUNT(*) AS products_with_key
FROM product_specs ps
CROSS JOIN LATERAL jsonb_object_keys(ps.specs_normalized) AS key
WHERE key NOT LIKE '\_%'
GROUP BY key
HAVING COUNT(*) < 3
ORDER BY products_with_key, key;
```

Si una clave aparece en 1–2 productos pese a los filtros, probablemente es
genuinamente nueva pero rara, o pasó ambos filtros. Refactorizar (renombrar
+ re-normalizar el producto huérfano).

---

## 6. Generación de `rag_chunks` (paso 11)

Los textos markdown listos para embedding (`specs_text`, `features_text`) ya
vienen construidos del flujo (nodos `Especificaciones técnicas` y
`Características normalizadas`). El loader los chunkea según las reglas
de abajo y embeddea.

### Reglas de chunking

| Fuente | Estrategia | Tamaño objetivo | `chunk_type` |
|---|---|---|---|
| `name + brand + model + description corta + atributos clave en prosa` | 1 chunk por producto. Tarjeta de identificación. | <200 tokens | `overview` |
| `products.description` | 1 chunk. **Omitir si solapa fuertemente con `overview` o es <30 t.** | <300 t | `description` |
| `product_specs.features_text` | 1 chunk si <500 t; split por headers `##` si más | 200–500 t | `features` |
| Cada `section` de `product_specs.specs` (agrupado) | 1 chunk por sección técnica. Merge con vecina si <100 t. Split por subgrupos si >500 t. Llenar `section_name`. | 200–500 t | `spec_section` |
| `product_specs.specs_text` completo | **Fallback** cuando no hay `sections` claras o `specs_text` es la única fuente. | <500 t | `specs` |
| `software.description_text` | 1 chunk por software canónico | <500 t | `software` |
| `product_specs.compatibility` formateado | Solo si hay compatibilidades listadas. 1 chunk. | <300 t | `compatibility` |
| `product_specs.variants` formateado | Solo si hay variantes con diferencias relevantes. 1 chunk. | <300 t | `variants` |

**Reglas duras:**

- Ningún chunk excede 500 tokens.
- Ningún chunk por debajo de 30 tokens (mergear con vecino o descartar).
- Prefijar el contenido con `"[<Producto>]\n"` ayuda a la similarity y al LLM final
  a identificar a qué producto pertenece sin tener que mirar metadata.
- Para `spec_section`, prefijar también con `"## <section_name>\n"` mantiene
  contexto cuando el chunk se ve aislado.

### Por cada chunk insertado

La idempotencia de chunks gira sobre `source_key` (columna `unique` en `rag_chunks`,
estable entre corridas). **El embedding se calcula arriba, no se hace backfill de
`NULL`** — el camino "INSERT con `embedding = NULL` → recoger después `WHERE embedding
IS NULL`" ya no existe.

1. n8n compara el `content` por `source_key` **antes** del nodo Vector Store. Si el
   chunk no cambió → **skip** (no se re-embeddea, incrementar `chunks_skipped`).
2. Si el chunk es nuevo o su `content` cambió → se embeddea con Gemini
   (`gemini-embedding-001`, 3072 dims) y la fila aterriza en la tabla de staging
   `embedding_rag_chunk_upload` (`content`, `metadata`, `embedding` NOT NULL).
3. El trigger `sync_embedding_upload_to_rag_chunks` (schema.sql §8b) parsea la
   `metadata`, hace el **UPSERT por `source_key`** (`ON CONFLICT`) en `rag_chunks`
   ya con embedding, y **drena** la fila de staging en el acto. Así `rag_chunks`
   queda siempre con embedding, desde un único escritor (sin doble escritura ni el
   pileup observado upload=472 / rag_chunks=314).
4. Los chunks **eliminados** (producto/sección que desaparece) van por un nodo
   `Delete` aparte en n8n — un chunk borrado no pasa por embeddings.

No existe columna `content_hash` en `rag_chunks`: la comparación de cambio se hace
directamente sobre `content`, indexada por `source_key`.

> **Requisito en n8n:** el Default Data Loader **no** debe partir el `content` (text
> splitter en OFF → 1 documento = 1 chunk). Si lo parte, los pedazos comparten
> `source_key` y el `ON CONFLICT` deja solo el último → content truncado y conteos
> que no cuadran. Esto no se arregla en el trigger.

**El chunk no guarda metadata de catálogo** (`category_id`/`is_new`/`brand` y los
filtros de atributo se resuelven por JOIN a `products`/`pav` en query time). La
fase 1 solo escribe `content` + owner (`product_id` **o** `software_id`) +
`chunk_type`/`section_name`; no necesita leer `products`.

### Chunks de software

- `product_id IS NULL`, `software_id IS NOT NULL`.
- Sin metadata de categoría/marca (un mismo software puede pertenecer a varios productos
  de marcas distintas, aunque hoy típicamente coincide).
- Resolución de "qué productos usan este software" se hace por JOIN
  (`products.software_id = software.id`), no por similarity.

---

## 7. Patrón de retrieval

### Arquitectura runtime: agente único (v1) — decisión oficial

**Runtime v1 = un solo agente n8n con tool-calling** ([agente.json](agente.json)),
NO un pipeline "NLU separado → LLM final → tools". El AI Agent (modelo con
function-calling, configurado en [agente.json](agente.json) — hoy gpt-5.x-mini, temp
baja) entiende la intención, elige las tools, rellena los `filter` con `$fromAI()` y
compone la respuesta,
todo en un loop. Es el patrón nativo de n8n (AI Agent + herramientas conectadas) y el
modelo estándar de function-calling: el "NLU" queda **implícito dentro del tool-call**
— cuando el agente llama `search_products({category_id, attribute_filters})`, eso *es*
la extracción de intención + filtros.

**Por qué a este volumen**: 74 productos / 8 categorías / 317 chunks, tools agrupadas
por mecanismo, sin rerank ni índice vectorial. No hay volumen ni ambigüedad que pague
un NLU separado + caller con cascada de fallback.

**El contrato NLU de [PREGUNTAS.md §1](PREGUNTAS.md) NO desaparece**: queda como
**contrato lógico / de evaluación**, no como etapa runtime obligatoria. El agente lo
produce de forma implícita en cada tool-call.

> **Terminología**: en el resto de SOLUCION/TOOLS/PREGUNTAS, "extractor NLU" / "el NLU"
> se refiere a **esa extracción implícita del agente** (el contrato lógico), no a una
> etapa ni componente separado. Las secciones marcadas `[DIFERIDO]` describen lo que se
> construiría **si** se separa el NLU (ver condiciones arriba).

**Deuda diferida (marcada, no borrada)** — SOLUCION/TOOLS/PREGUNTAS se diseñaron
alrededor de un NLU previo + LLM final + tools. Lo que se difiere en v1:

- `confidence` explícito de extracción y **eco al usuario** por baja confianza
  (ver "Política de confianza del NLU").
- **Fallback determinista en el caller** (cascada relajar `spec_filters` →
  `attribute_filters` → `category_id`; ver "Política de fallback", [PREGUNTAS.md §4](PREGUNTAS.md),
  [TOOLS.md §5](TOOLS.md)). En v1 el reintento lo decide el propio agente.
- **Logging estructurado del contrato** (intent, filtros, ruta, fallback) para el
  golden-set/eval (§9 gate, §10).
- **Budget de merge cruzado** (≤3 chunks/producto, ≤10 total, ≤4000 tokens). En v1 el
  dedup por producto vive dentro de `semantic_search`/`match_rag_chunks`; el budget
  cruzado no se impone.

**Deuda de datos del catálogo (detectada con el set [pr](pr), 2026-06-25)** — no son bugs
de SQL (las tools devuelven lo que el dato permite), sino huecos de ingesta a poblar:

- **Recomendaciones cross-categoría ausentes.** `product_recommendations` (80 aristas) es
  producto-a-producto dentro de la MISMA categoría (router↔router). No hay aristas hacia
  accesorios/antenas, así que "¿qué accesorios necesito para el EG5100?" no se resuelve con
  `get_recommendations` (devuelve otro gateway). Mitigación v1: el agente usa
  `compatibility_query` y, si vacío, lista Accesorios (cat 1554) con disclaimer. Fix de
  raíz: poblar aristas de accesorio/compatibilidad en la ingesta.
- **Compatibilidad casi vacía (3/74).** `product_specs.compatibility` solo está poblada en
  3 productos; el EG5100 no es uno. "Antenas compatibles con X" queda sin dato. Fix:
  extraer compatibilidad en la ingesta para todo el catálogo.
- **Ganancia de antena canónica.** La antena 3.9 dBi usaba `gain_max_dbi`; se normalizó en
  la BD a `gain_dbi` (clave canónica). La ingesta debe emitir `gain_dbi` para no
  reintroducir el split de claves en la próxima corrida.
- **Split de categoría "routers" {516, 1641}.** Resuelto a nivel de tool con `category_ids`
  (arreglo) — ver [TOOLS.md §6.2](TOOLS.md). Si a futuro se decide consolidar la taxonomía,
  hacerlo en el source (Woo/`category_worker`), no en la BD del RAG.

**Siguiente mejora obligatoria (antes de medir calidad en serio)**: loggear cada
tool-call como "contrato observado" — intención inferida, tool usada, filtros enviados,
resultado, fallback aplicado y warnings. Conserva trazabilidad para el eval **sin meter
otro LLM**.

**Condiciones para activar el NLU separado (solo si el eval lo exige)**:
- el golden set muestra baja precisión de `attribute_filters`/`intent`;
- el agente elige las tools correctas pero con **argumentos inestables**;
- se necesita `confidence` real para UX o auditoría;
- crece el catálogo y sube la ambigüedad;
- se requiere **Structured Outputs (`strict: true`)** para forzar el contrato JSON antes
  del retrieval como requisito de producción.

### Contrato lógico de extracción (NLU) — query time

> Esto es el **contrato lógico/evaluable** (no una etapa runtime en v1; ver
> "Arquitectura runtime"). En v1 el agente lo produce implícitamente al llamar las tools.

```json
{
  "products_referenced": ["slug-o-id"],
  "category_id":         516,
  "is_new":              true,
  "brand":               null,
  "attribute_filters": [
    {"taxonomy": "pa_red-celular", "option_slugs": ["5g"]}
  ],
  "spec_filters": [
    {"spec_slug": "throughput_lte_dl_mbps", "operator": ">=", "value": 1000}
  ],
  "info_types":         ["overview", "description", "specs"],
  "structured_lookups": ["relations"],
  "intent":              "describe | list_specs | list_features | compare | software_lookup | relation_lookup | attribute_check | filter_search | compatibility_lookup",
  "confidence":          0.85
}
```

**Semántica de `attribute_filters` (importante):**

- El array está estructurado **por grupo de atributo**. Cada elemento es
  un grupo: una `taxonomy` + una lista `option_slugs` de opciones aceptables
  para ese grupo.
- **OR dentro del grupo, AND entre grupos.** El backend materializa esto en
  N cláusulas separadas (ver query 7 en §8): un `EXISTS` sobre
  `product_attribute_values` por grupo (con `ao.slug = ANY(...)` para el OR
  interno). Colapsar todos los grupos en un solo EXISTS/IN da OR global y es
  un anti-patrón.
- El NLU **debe** preservar la separación por grupo en el output; no
  emitir todos los slugs en una lista única.

### Mapeo `info_types` / `structured_lookups`

| Tipo | Fuente | Mecanismo |
|---|---|---|
| `overview` | `rag_chunks` (chunk_type='overview') | Embeddings + filtros |
| `description` | `rag_chunks` (chunk_type='description') | Embeddings + filtros |
| `features` | `rag_chunks` (chunk_type='features') | Embeddings + filtros |
| `specs` / `spec_section` | `rag_chunks` (chunk_type IN ('specs','spec_section')) | Embeddings + filtros |
| `compatibility` | `rag_chunks` (chunk_type='compatibility') | Embeddings + filtros |
| `variants` | `rag_chunks` (chunk_type='variants') | Embeddings + filtros |
| `software` | `rag_chunks` (chunk_type='software', software_id) | Embeddings + JOIN |
| `recommendations` | `product_recommendations` | SQL puro |
| `available_filters` | `category_attributes` + `attribute_options` | SQL puro |
| `category_info` | `categories` | SQL puro |
| `specs_structured` (filtros numéricos) | `product_specs.specs_normalized` | SQL puro JSONB |
| `compatibility_lookup` | `product_specs.compatibility` (JSONB) | SQL puro JSONB |

### Política de confianza del NLU  · [DIFERIDO en v1 — ver "Arquitectura runtime"]

| `confidence` | Comportamiento |
|---|---|
| `< 0.6` | Ignorar `attribute_filters` y `spec_filters`. Conservar solo `category_id`/producto detectado e `info_types`. Tratar como búsqueda abierta. |
| `0.6 – 0.8` | Aplicar filtros, pero **registrar el output completo del NLU en la respuesta al usuario** ("Entendí: 5G + WiFi=Sí; corrígeme si no es correcto"). Permite recuperar de extracciones plausibles pero erróneas sin que el usuario tenga que adivinar qué entendió el sistema. |
| `≥ 0.8` | Aplicar filtros silenciosamente. |

### Política de fallback  · [DIFERIDO en v1 — el reintento lo decide el propio agente]

1. Si la query estructurada devuelve 0 resultados → relajar en este orden:
   `spec_filters` → último grupo de `attribute_filters` agregado → resto de
   `attribute_filters` → `is_new` → `category_id`.
2. Si la similarity devuelve <3 chunks → expandir `info_types` a
   `["description","specs","features"]`.

### Re-ranking (NO necesario al volumen actual)

El re-ranking clásico (cross-encoders, Cohere Rerank, LLM-as-reranker)
está diseñado para escenarios de **alto recall**: BM25/cosine devuelve
100-200 candidatos con orden ruidoso y necesita refinarlos. **No es este caso.**

A 74 productos / 317 chunks con prefiltrado SQL fuerte (JOIN a `products` por
`category_id`/`is_new`/`brand` + EXISTS de atributos sobre `pav`), el pool sobre el que opera cosine es
típicamente 20-100 chunks. Cosine sobre `gemini-embedding-001` ya
ordena bien sobre ese pool. El verdadero motor de calidad es el
**prefiltrado** + el **dedup por `product_id`**, no el rerank.

**Decisión: NO implementar rerank en v1.** Mantenerlo identificado como
optimización condicional.

#### Cuándo reconsiderar

Activar rerank (detrás de feature flag, A/B contra cosine puro) **solo si**
el golden set de §9 muestra al menos uno de estos:

- P@5 < 0.80 en `intent=compare` (cosine no balancea chunks entre productos
  comparados, ni siquiera con dedup).
- P@5 < 0.85 en queries con criterio implícito numérico ("el más rápido",
  "el más barato") **y** el NLU no logra extraer `spec_filters` con
  `ORDER BY` explícito (la solución correcta para ese caso es el NLU,
  no el rerank).
- >10% de queries de producción reciben feedback negativo del usuario
  sobre el orden de resultados.

#### Cómo se implementaría si llega el momento

```
Input:  pregunta original + top-20 chunks (id, chunk_type, product_name, content recortado a ~150 tokens)
Output: lista ordenada de hasta 8 chunk_ids, con score de relevancia (0–10)
Modelo: claude-haiku-4-5 o gpt-4o-mini
Costo:  ~$0.0003 por query, +200-400 ms latencia
```

Reglas si se activa: usa solo `id`s del input, no inventa; penaliza chunks
que no responden la pregunta aunque tengan alta similitud; en `compare`
garantiza ≥2 chunks por producto.

Aceptación: P@5 sube ≥10 puntos vs cosine puro. Si no, se desactiva.

### Dedupe y limit por producto

El retrieval crudo puede traer 4+ chunks del mismo producto (un `overview`,
un `description`, dos `spec_section`). Sin control, el LLM final "pondera"
por repetición y el contexto se desbalancea.

Reglas para el merge final que entra al prompt de composición:

- **Máximo 3 chunks por `product_id`** (o `software_id`). Si hay más,
  conservar los de mayor score de cosine (o post-rerank si está activado).
- Si dos chunks del mismo producto tienen `chunk_type` redundantes
  (`overview` + `description` cuando solapan en >70% de tokens), conservar
  solo el de mayor score.
- Para `intent = compare`: forzar paridad — mismo número de chunks por
  producto comparado.
- Contexto final al LLM: ≤10 chunks totales, ≤4000 tokens combinados.

Implementación: el merge se hace en backend (no en SQL) sobre el top-20
de cosine, antes de construir el prompt final.

### Intent taxonomy

El extractor clasifica cada pregunta en un `intent` que decide rutas y `info_types`:

| Patrón en pregunta | `intent` | `info_types` | `structured_lookups` |
|---|---|---|---|
| "qué es", "para qué sirve", "describe X" | `describe` | `overview`, `description` | — |
| "specs", "throughput", "puertos", "qué voltaje" | `list_specs` | `specs`, `spec_section` (+ `specs_structured` si filtro numérico) | — |
| "características", "features de X" | `list_features` | `features` | — |
| "compara X con Y", "diferencia entre" | `compare` | `overview`, `specs`, `spec_section`, `features` | `relations` |
| "qué software gestiona", "qué app usa" | `software_lookup` | `software` | — (o JOIN `products.software_id`) |
| "qué recomienda con X", "qué sugiere para Y" | `relation_lookup` | — | `relations` |
| "tiene WiFi", "soporta 5G" (booleano/enum) | `attribute_check` | — | `attribute_filters` (SQL) |
| "tiene throughput >= 1Gbps", "temp min -20" | `attribute_check` (numérico) | `specs_structured` | — |
| "busco/quiero/necesito ... con ..." | `filter_search` | `overview`, `features` + prefiltro SQL | `available_filters` |
| "compatible con", "funciona con", "se acopla a" | `compatibility_lookup` | `compatibility` | `compatibility_lookup` (JSONB) |
| "qué filtros hay para routers" | `filter_search` | — | `available_filters` |

### Resolución fuzzy de productos en la pregunta

Cuando el usuario menciona un producto sin marca explícita ("EG5100", "X3000"), el
NLU debe resolverlo contra `products.search_text` (generado por trigger desde
`name + brand + model + search_aliases`) usando `pg_trgm`:

```sql
SELECT id, slug, name, brand,
       GREATEST(
         similarity(search_text, $1),
         CASE WHEN $1 = ANY(search_aliases) THEN 1.0 ELSE 0.0 END
       ) AS score
FROM products
WHERE search_text % $1 OR $1 = ANY(search_aliases)
ORDER BY score DESC
LIMIT 5;
```

Reglas:

- Si el `score` top ≥ 0.6 → tratar como producto identificado y poblar
  `products_referenced`.
- Si el `score` top está entre 0.4 y 0.6 → ambiguo; pedir confirmación o devolver
  los 2–3 candidatos al LLM final para que desambigüe.
- Si el `score` top < 0.4 → tratar como búsqueda abierta, no como identificación;
  caer en `filter_search` o `describe` según `intent`.

### Tool surface del agente

En runtime v1 el **extractor NLU y el "LLM final" son el mismo agente** (ver
"Arquitectura runtime" arriba): no recibe un contrato NLU precomputado, sino que llama
directamente a un set acotado de **tools** que envuelven SQL/embeddings y devuelven
payloads tipados. Diseño completo (firmas, composición de híbridas, errores y
warnings) en [TOOLS.md](TOOLS.md).

Decisión: **6 tools agrupadas por mecanismo de retrieval**, no una mega-tool ni una
tool por intent.

| Tool | Cubre intents de [PREGUNTAS.md](PREGUNTAS.md) | Mecanismo |
|---|---|---|
| `search_products` | A1, A2, A4, A5, A10 | SQL puro sobre `products` + `product_attribute_values` |
| `filter_products_by_specs` | B1–B6 | SQL JSONB sobre `product_specs.specs_normalized` |
| `get_recommendations` | C1–C4 | SQL sobre `product_recommendations` |
| `get_product_narrative` | D1–D4, A4b | RAG con filtro duro por `product_id`/`software_id` |
| `semantic_search` | D5, D6 | RAG con embedding + prefiltrado + dedup |
| `get_catalog_metadata` | A3, A6, A7, A8, A9, F1–F3 | SQL sobre catálogo |

Híbridas (E1–E4) **no tienen tool propia**: el LLM las compone llamando 2-3 tools y
encadenando resultados (ej. E2 = `filter_products_by_specs` → `semantic_search` con
`product_ids_shortlist`). Operación (G*) va aislada en `ops_health`, solo en contexto
de operador.

Anti-patrones rechazados:

- **Una sola tool `answer(query)`**: opaca, sin trazabilidad, imposibilita componer
  híbridas, fallbacks quedan como if-else gigante.
- **Una tool por intent (30+)**: el LLM se confunde entre intents casi idénticos,
  surface enorme, system prompt costoso.

Los fallbacks de §7 ("Política de fallback") viven **dentro** del adapter de cada
tool, no en el LLM. El LLM solo ve el resultado final + warnings tipados
(`fallback_applied`, `spec_key_unknown`, etc. — ver [TOOLS.md §5](TOOLS.md)).

---

## 7.1 Diccionario de sinónimos de atributos (`attribute_option_aliases`)

**Qué es.** Tabla `(attribute_option_id, alias)` que mapea términos en lenguaje natural
del usuario a la `attribute_option` correcta. La consumen:

- `get_catalog_metadata({type:"resolve_alias", term})` (intent A8 de [PREGUNTAS.md](PREGUNTAS.md)).
- La resolución de `attribute_filters` dentro de `search_products` / `semantic_search`
  cuando el usuario escribe un término coloquial ("móvil") en vez del slug (`pa_red-celular:4g`).

**Estado: SEMBRADA** — 226 alias sobre 76 opciones (seed curado y aplicado 2026-06-23).
`resolve_alias` verificado: "movil"/"celular"→`pa_red-celular:3g-4g`,
"industrial"→`pa_uso:industrial`, "wireless"→`pa_wifi:si`, "sfp"/"omnidireccional"/"yagi"/etc.
Con esto el filter-then-rank ya NO se degrada a "rank por similitud" por falta de
sinónimos → el gate de cierre de fase 9 (§9, punto 1) queda **satisfecho**.

> Los filtros que llegan con el **slug exacto** (el agente emite `pa_uso:industrial`)
> funcionan sin diccionario — el EAV `product_attribute_values` es la fuente de verdad;
> el diccionario solo cubre el salto "término coloquial → slug".
>
> Las 16 opciones sin alias son los valores **"No"** de los booleanos + `pa_red:n/a`
> (intencional — la negación la maneja el LLM). `vpn` / `dual sim` / `poe` tampoco van
> aquí: NO son opciones de atributo sino **specs** (`vpn_features`, `sim_slots_count`,
> `ethernet_poe_ports_count`) → se resuelven por `filter_products_by_specs`.

**Cómo se sembró / cómo regenerar.** Ejecutado en
[attribute_option_aliases_seed.sql](attribute_option_aliases_seed.sql) (226 alias,
idempotente con `ON CONFLICT DO NOTHING`). El mapa término→opción es una **decisión
curada**, no una derivación de los datos. Para regenerar o ampliar:

1. Listar las opciones reales del catálogo (hoy 92 filas):

   ```sql
   SELECT ao.id AS attribute_option_id, a.taxonomy, a.name AS attribute, ao.slug, ao.name
   FROM attribute_options ao
   JOIN attributes a ON a.id = ao.attribute_id
   ORDER BY a.taxonomy, ao.slug;
   ```

2. Pasar esa lista a un LLM con la instrucción: "por cada (atributo, opción) genera los
   términos en español que un usuario escribiría para referirse a ella — coloquiales,
   abreviaturas, con/sin tilde, sinónimos técnicos. Devuelve filas
   `{attribute_option_id, alias}` con `alias` en minúscula." Ejemplos esperados:
   `pa_red-celular:4g` → `4g, lte, movil, móvil, celular, datos móviles`;
   `pa_uso:industrial` → `industrial, rugerizado, uso rudo, outdoor`;
   `pa_wifi:si` → `wifi, wi-fi, inalámbrico, wlan`.

3. Insertar (alias **siempre en minúscula** — `resolve_alias` baja el término con
   `lower()` y `pg_trgm` es case-sensitive):

   ```sql
   INSERT INTO attribute_option_aliases (attribute_option_id, alias) VALUES
     (<id>, 'movil'), (<id>, 'celular'), (<id>, 'lte')
   ON CONFLICT (attribute_option_id, alias) DO NOTHING;
   ```

   Costo: 92 opciones → una sola llamada LLM, < $1. Es la **fase 8** del plan (§9).

**Cuándo se actualiza / modifica.**

- **Nuevas opciones**: cuando entra un atributo/opción nuevo desde Woo (cambia
  `attribute_options`), correr el LLM solo sobre las opciones que aún no tienen alias.
- **Mensual** (§10): revisar el log del NLU/agente — términos del usuario que **no
  resolvieron** — y promover los recurrentes como nuevos alias. Curaduría humana, misma
  filosofía que `reference_alias_candidates` (se detecta, un humano aprueba; no se
  auto-inserta al canon).
- No hay trigger ni cálculo automático: es estado curado y editable a mano.
- ⚠️ **El reload del ETL borra los aliases.** `attribute_option_aliases` tiene
  `ON DELETE CASCADE` a `attribute_options`; si el flujo n8n hace **delete+insert** de
  las opciones (en vez de upsert), la cascada **vacía la tabla de aliases** en cada
  corrida (observado: 226 → 0). Los `attribute_option_id` vienen de WooCommerce y son
  **estables**, así que el seed sigue válido — solo hay que **re-correrlo**. Dos arreglos
  de raíz para no hacerlo a mano:
  - **(A, recomendado)** que el ETL haga `INSERT … ON CONFLICT DO UPDATE` (upsert) sobre
    `attribute_options` → no se dispara la cascada y los aliases sobreviven.
  - **(B)** agregar `attribute_option_aliases_seed.sql` como **paso final idempotente**
    del flujo n8n (después de cargar opciones).

Query para auditar opciones sin ningún alias (huecos del diccionario):

```sql
SELECT a.taxonomy, ao.slug, ao.name
FROM attribute_options ao
JOIN attributes a ON a.id = ao.attribute_id
LEFT JOIN attribute_option_aliases aoa ON aoa.attribute_option_id = ao.id
WHERE aoa.alias IS NULL
ORDER BY a.taxonomy, ao.slug;
```

---

## 7.2 Subsistema de páginas de solución (`solution_pages`)

Además del catálogo de productos, el agente tiene una **segunda superficie de retrieval**:
las **páginas de solución** de bismark.net.co (contenido consultivo de alto nivel:
conectividad, IoT, SD-WAN, SIM Card). Es un RAG **independiente** del catálogo — otra
tabla, otra función, otro propósito: responde "¿qué ofrece Bismark? / ¿en qué consiste
SD-WAN?", no "¿qué router 5G tiene throughput > X?". DDL en
[solution_pages.sql](solution_pages.sql).

**Tabla `solution_pages_table`** (genérica, estilo LangChain):

- `id`, `content` (texto de la página/sección), `metadata jsonb`, `embedding vector(3072)`
  (`gemini-embedding-001`, vía n8n), `created_at`. RLS habilitado (SELECT a `authenticated`;
  INSERT/UPDATE/DELETE a `service_role`).
- Índices: GIN sobre `metadata jsonb_path_ops` **+ HNSW** sobre `embedding::halfvec(3072)`
  (`halfvec_cosine_ops`). Nota: aquí SÍ hay índice vectorial, al contrario del catálogo
  (`rag_chunks` corre seq scan, ver §12).
- Estado actual: **43 filas, 0 embeddings nulos**; `page_key` ∈ {sdwan 19, conectividad 9,
  iot 8, sim-card 7}.
- ⚠️ La `metadata` se guarda **plana, con el ruido del loader LangChain** (`loc`, `blobType`,
  `source`, `lines`, junto a `page_key`, `doc_type`, `canonical_url`…) — al contrario del
  catálogo, donde el trigger de §8b de [schema.sql](schema.sql) limpia ese ruido. Es una
  inconsistencia de diseño entre los dos RAG; funciona (la función lee
  `metadata->>'page_key'`), pero conviene saberlo.

**Función `match_solution_pages(query_embedding, match_threshold, match_count, filter)`**
→ `(id, content, metadata, similarity)`:

- Enrutamiento por `filter`: `search_mode` ∈ {`specific`, `general`} + `page_keys` (array de
  {`conectividad`, `iot`, `sdwan`, `sim-card`}). `specific` exige 1–4 page_keys válidos;
  `general` fuerza `page_keys=null` (panorama amplio). Valida ambos y lanza excepción ante
  combinaciones inválidas (p.ej. `general` con page_keys específicos, o un page_key fuera de
  la lista).
- `match_count`: default 5 (specific) / 7 (general). Orden por distancia coseno + `limit`.
- **Threshold desactivado a propósito** (las 3 líneas — declaración, asignación y `WHERE` —
  comentadas; riesgo de resultados vacíos). El parámetro `match_threshold` permanece en la
  firma por compatibilidad con el nodo Vector Store, pero **no se aplica** (ni en el SQL ni
  desde el agente — ver TOOLS.md / agente.json: se quitó esa guía).
- **`match_documents`**: shim que reenvía a `match_solution_pages` (el nodo LangChain por
  defecto invoca `match_documents`). **`match_solution_pages_debug`**: variante de
  depuración, no para producción.

**En el agente** ([agente.json](agente.json)): la tool **`classify_bismark_search_scope`**
(nodo Vector Store en modo retrieve-as-tool, `queryName=match_solution_pages`, con su nodo
de embeddings Gemini) ES esta superficie. El agente la usa para consultas de solución de
alto nivel y usa las 6 tools del catálogo ([TOOLS.md](TOOLS.md)) para producto concreto. El
modelo decide internamente `search_mode`/`page_keys`; no se exponen al usuario.

**Ingesta**: las páginas se cargan vía n8n (Gemini + LangChain) a `solution_pages_table`.
Volumen pequeño y estable; no usa el pipeline de fingerprints del catálogo (§10).

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
	    JOIN attributes a         ON a.id = ao.attribute_id
	    WHERE pav.product_id = p.id
	      AND a.taxonomy = 'pa_red-celular' AND ao.slug = '5g')
	  AND EXISTS (
	    SELECT 1 FROM product_attribute_values pav
	    JOIN attribute_options ao ON ao.id = pav.attribute_option_id
	    JOIN attributes a         ON a.id = ao.attribute_id
	    WHERE pav.product_id = p.id
	      AND a.taxonomy = 'pa_wifi' AND ao.slug = 'si');

-- 3) Filtro numérico sobre specs normalizadas
-- Nota: el índice GIN sobre specs_normalized NO acelera esta query (es cast
-- numérico, no containment). Hace seq scan + cast por fila. A <500 productos
-- corre en <20 ms y es aceptable. Si una clave numérica se vuelve caliente,
-- agregar índice de expresión sobre esa clave concreta (ver §10).
SELECT p.id, p.name,
       (ps.specs_normalized->>'throughput_lte_dl_mbps')::numeric AS throughput
FROM products p
JOIN product_specs ps ON ps.product_id = p.id
WHERE p.category_id = $1
  AND (ps.specs_normalized->>'throughput_lte_dl_mbps')::numeric >= 1000
ORDER BY throughput DESC;

-- 4) Recomendados desde un producto
SELECT p.* FROM product_recommendations pr
JOIN products p ON p.id = pr.target_product_id
WHERE pr.source_product_id = (SELECT id FROM products WHERE slug = $1)
ORDER BY pr.created_at DESC;

-- 5) Más recomendados dentro de una categoría
SELECT p.id, p.name, COUNT(*) AS times_recommended
FROM product_recommendations pr
JOIN products p ON p.id = pr.target_product_id
WHERE p.category_id = $1
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
--    $5: chunk_types[]
--
-- Prefiltro por JOIN a products (rag_chunks NO denormaliza metadata).
-- Atributos: el backend agrega dinámicamente un EXISTS-por-grupo sobre
-- product_attribute_values por cada grupo de `attribute_filters` del NLU. El IN
-- dentro de cada EXISTS da el OR del grupo; AND entre EXISTS da la semántica
-- esperada del usuario ("5G Y WiFi", no "5G O WiFi").
--
-- Ejemplo: attribute_filters = [
--   {"taxonomy":"pa_red-celular","option_slugs":["5g","4g"]},
--   {"taxonomy":"pa_wifi","option_slugs":["si"]}
-- ]
-- => se inyectan dos EXISTS (uno por taxonomy):
--   AND EXISTS (... a.taxonomy='pa_red-celular' AND ao.slug = ANY('{5g,4g}'))
--   AND EXISTS (... a.taxonomy='pa_wifi'        AND ao.slug = ANY('{si}'))
--
-- ANTI-PATRÓN: un único EXISTS/IN mezclando taxonomies colapsa a OR global.
SELECT c.id, c.product_id, c.software_id, c.chunk_type, c.content,
       1 - (c.embedding <=> $1::vector) AS similarity
FROM rag_chunks c
JOIN products p ON p.id = c.product_id
WHERE c.embedding IS NOT NULL
  AND ($2::int    IS NULL OR p.category_id   = $2)
  AND ($3::bool   IS NULL OR p.is_new        = $3)
  AND ($4::text   IS NULL OR p.brand         = $4)
  AND ($5::text[] IS NULL OR c.chunk_type    = ANY($5))
  -- + N cláusulas EXISTS sobre pav (una por grupo del NLU):
  --   AND EXISTS (SELECT 1 FROM product_attribute_values pav
  --     JOIN attribute_options ao ON ao.id = pav.attribute_option_id
  --     JOIN attributes a         ON a.id = ao.attribute_id
  --     WHERE pav.product_id = c.product_id
  --       AND a.taxonomy = $tax AND ao.slug = ANY($opts))
ORDER BY c.embedding <=> $1::vector
LIMIT 20;

-- 7b) Opción A — fallback para predicados complejos (negación, exclusiones cruzadas).
--     Cuando el NLU emita filtros que `&&` no expresa (ej. "5G pero NO 3G",
--     "WiFi solo si NO es industrial"), pre-resolver IDs vía SQL sobre el EAV
--     y pasarlos al retrieval. Más caro (JOINs explícitos) pero general.
--
-- WITH matching_products AS (
--   SELECT p.id
--   FROM products p
--   WHERE p.category_id = $2
--     AND p.is_new = COALESCE($3, p.is_new)
--     AND EXISTS (              -- grupo positivo: 5G OR 4G
--       SELECT 1 FROM product_attribute_values pav
--       JOIN attribute_options ao ON ao.id = pav.attribute_option_id
--       JOIN attributes a         ON a.id  = ao.attribute_id
--       WHERE pav.product_id = p.id
--         AND a.taxonomy = 'pa_red-celular'
--         AND ao.slug = ANY(ARRAY['5g','4g'])
--     )
--     AND NOT EXISTS (          -- exclusión: NO 3G
--       SELECT 1 FROM product_attribute_values pav
--       JOIN attribute_options ao ON ao.id = pav.attribute_option_id
--       JOIN attributes a         ON a.id  = ao.attribute_id
--       WHERE pav.product_id = p.id
--         AND a.taxonomy = 'pa_red-celular'
--         AND ao.slug = '3g'
--     )
-- )
-- SELECT c.id, c.product_id, c.chunk_type, c.content,
--        1 - (c.embedding <=> $1::vector) AS similarity
-- FROM rag_chunks c
-- WHERE c.product_id IN (SELECT id FROM matching_products)
--   AND c.embedding IS NOT NULL
--   AND ($5::text[] IS NULL OR c.chunk_type = ANY($5))
-- ORDER BY c.embedding <=> $1::vector
-- LIMIT 20;

-- 8) Claves disponibles de specs en una categoría (alimenta al extractor NLU)
SELECT DISTINCT jsonb_object_keys(ps.specs_normalized) AS spec_key
FROM product_specs ps
JOIN products p ON p.id = ps.product_id
WHERE p.category_id = $1
  AND ps.specs_normalized <> '{}'::jsonb
ORDER BY 1;

-- 9) Productos similares por specs (similarity entre embeddings de chunks técnicos)
-- "misma categoría" se resuelve por JOIN a products (p1=referencia, p2=candidato),
-- ya que rag_chunks no denormaliza category_id.
SELECT p2.id, p2.name,
       AVG(1 - (c2.embedding <=> c1.embedding)) AS avg_sim
FROM products p1
JOIN rag_chunks c1
  ON c1.product_id = p1.id
 AND c1.chunk_type IN ('specs','spec_section')
 AND c1.embedding IS NOT NULL
JOIN products p2
  ON p2.category_id = p1.category_id
 AND p2.id <> p1.id
JOIN rag_chunks c2
  ON c2.product_id = p2.id
 AND c2.chunk_type IN ('specs','spec_section')
 AND c2.embedding IS NOT NULL
WHERE p1.slug = $1
GROUP BY p2.id, p2.name
ORDER BY avg_sim DESC LIMIT 5;

-- 10) Match fuzzy de producto por mención del usuario (resuelve "EG5100" sin marca)
SELECT id, slug, name, brand,
       GREATEST(
         similarity(search_text, $1),
         CASE WHEN $1 = ANY(search_aliases) THEN 1.0 ELSE 0.0 END
       ) AS score
FROM products
WHERE search_text % $1 OR $1 = ANY(search_aliases)
ORDER BY score DESC
LIMIT 5;

-- 11) Software que usa un producto
SELECT s.name, s.description_text
FROM products p
JOIN software s ON s.id = p.software_id
WHERE p.slug = $1;

-- 12) Productos que usan un software
SELECT p.id, p.name, p.brand
FROM products p
WHERE p.software_id = (SELECT id FROM software WHERE name = $1);
```

---

## 9. Plan de implementación por fases

| Fase | Trabajo | Salida | Esfuerzo |
|---|---|---|---|
| 0 | Cerrar incongruencias DDL ↔ JSON listadas en §3 (categorías sin `name`/`slug`, atributo `id=0`, fuente de productos recomendados) | `schema.sql` y ETL alineados con el output del flujo (`flujo.json`) | medio día |
| 1 | Crear DB y ejecutar `schema.sql` | DB lista | <1 h |
| 2 | ETL pasos 1–3 (taxonomía + atributos) | `categories`, `attributes`, `attribute_options`, `category_attributes` | medio día |
| 3 | ETL pasos 4–7 (software + productos + atributos por producto) | `software`, `products`, `product_attribute_values` | 1 día |
| 4 | ETL paso 8 (specs crudas) | `product_specs` con JSONB crudo | medio día |
| 5 | ETL paso 9 (normalización LLM de specs) | `specs_normalized` poblado | 1 día (incluye revisión claves huérfanas) |
| 6 | ETL paso 10 (productos recomendados) | `product_recommendations` | medio día |
| 7 | ETL paso 11 (chunks + embeddings) | `rag_chunks` poblado | 1 día |
| 8 | Diccionario inicial de `attribute_option_aliases` | sinónimos cargados ✅ **hecho** (226 alias / 76 opciones, ver §7.1) | medio día |
| 9 | Endpoint de retrieval (agente con tool-calling) + dedup por producto | API funcional | 2–3 días |
| 10 | Métricas de operación, diccionario de huérfanos, golden set de 50 queries para eval end-to-end | dashboard mínimo + eval automatizada | 2 días |

**Total estimado:** 9–11 días de trabajo enfocado para tener el RAG funcionando
end-to-end con prefiltrado real y eval. El re-ranking se evalúa **después**
sobre los resultados del golden set; si los umbrales de §7 no se cumplen,
no se implementa.

### Gate de cierre de fase 9 (capa de extracción del agente)

La fase 9 no se cierra sin estos cinco entregables. Sin ellos, el patrón
filter-then-rank se degrada silenciosamente a "rank por similitud" y nadie
lo nota.

1. **Diccionario `attribute_option_aliases` cargado.** ✅ **Cumplido** (226 alias / 76
   opciones, ver §7.1). El agente sin aliases no resuelve "móvil" → `pa_red-celular`.
2. **Logging estructurado del extractor por cada query.** Campos mínimos:
   pregunta original, output completo del tool-call, `confidence`, intent
   detectado, ruta tomada (filtros aplicados vs fallback), número de chunks
   recuperados, latencia de cada paso (NLU, retrieval, rerank, composición),
   `model_version` del NLU.
3. **Las 4 métricas de §10 emitidas y visibles.**
   - `% queries con filtros extraídos`
   - `% queries con fallback activado`
   - `latencia P50/P95 de extract_filters`
   - `chunks devueltos por chunk_type`
4. **Set de evaluación de 80 queries etiquetadas a mano**, distribuidas por
   `intent` (mínimo 8 por intent crítico: `attribute_check`, `filter_search`,
   `compare`, `list_specs`, `software_lookup`, `relation_lookup`,
   `compatibility_lookup`). Cada query etiquetada con: filtros esperados,
   `info_types` esperados, `intent` esperado.
5. **Umbrales mínimos por métrica** (no agregados):
   - `precision` de `attribute_filters` por intent crítico ≥ 0.90.
     Un grupo de filtros mal extraído invalida toda la respuesta; falsos
     positivos son peores que falsos negativos.
   - `recall` de `attribute_filters` ≥ 0.85.
   - `accuracy` de `intent` ≥ 0.90.
   - `accuracy` de `info_types` ≥ 0.90.
   - `accuracy` de resolución fuzzy de productos (cuando aplica) ≥ 0.95.
   - **0 casos de filtros aplanados a OR global** en logs (regresión de
     §14.7). Test automatizado en CI.

### Eval automatizada del pipeline completo (gate adicional para producción)

Además del eval del NLU aislado, antes de producción se necesita un golden
set de 50 pares `(pregunta, respuesta_esperada)` con campos verificables
(spec value, lista de productos, slug de software). Eval con LLM-as-judge
sobre factualidad:

- **Factualidad** ≥ 0.95 (la respuesta no inventa specs ni atributos).
- **Cobertura** ≥ 0.85 (la respuesta menciona los productos/specs que el
  ground truth lista).
- **Ausencia de alucinación de identificadores**: cero modelos/slugs
  inventados en 50 queries.

Re-correr este eval automático en cada cambio de prompt del NLU, prompt
de composición, o re-normalización de specs.

---

## 10. Operación y métricas

### Métricas mínimas a instrumentar desde día 1

- `% queries con filtros extraídos` por el NLU vs solo rank por similarity.
- `% queries con fallback activado` (señal de NLU fallando o vocabulario incompleto).
- `latencia P50/P95` desglosada por paso: extract_filters, query 7, composición final.
- `chunks devueltos por chunk_type` — confirma que el filtrado por `info_types` funciona.
- `chunks promedio por producto en el contexto final` — debe estar ≤3 (verifica dedup).
- `% claves nuevas creadas por producto en specs_normalized` — converge a 0 con el tiempo.
- `% INSERTs bloqueados por validación Levenshtein` — alto en producto nuevo de categoría madura es señal de prompt fallando.
- `P@5 del retrieval cosine puro` (sobre golden set, semanal). Es el número que decide si vale la pena activar rerank.
- `Factualidad del LLM final` (LLM-as-judge sobre golden set, semanal).

### Mantenimiento periódico

- **Mensual:** correr query de claves huérfanas de §5 y consolidar.
- **Mensual:** revisar log del NLU para sumar sinónimos a `attribute_option_aliases`.
- **Mensual:** identificar claves numéricas "calientes" en `specs_normalized`
  (consultadas con `>=`/`<=` y con latencia visible) y crear índice de
  expresión sobre cada una. El GIN actual cubre containment, no rangos
  numéricos. Ejemplo cuando `throughput_lte_dl_mbps` se vuelva caliente:

  ```sql
  CREATE INDEX idx_specs_throughput_lte_dl ON product_specs
    (((specs_normalized->>'throughput_lte_dl_mbps')::numeric));
  ```

  Detección: log de queries lentas (`pg_stat_statements`) filtrado por
  predicados `specs_normalized->>'...'::numeric`.
- **Solo si el catálogo cruza ~10k chunks reales (improbable a este horizonte):**
  recién ahí evaluar la migración `vector → halfvec(3072)` y crear el índice
  HNSW con `halfvec_cosine_ops`. Mientras P95 del retrieval se mantenga bajo
  150 ms, no tocar.
- **Cuando llegue producto nuevo o cambie el catálogo:** correr el ETL incremental (los fingerprints garantizan re-embeddear solo lo que cambió; hard delete elimina los productos retirados del source).

### Re-ingesta incremental

El sistema es idempotente por diseño. n8n calcula los fingerprints antes de escribir — el DB no los recalcula (no hay triggers de fingerprint).

**Flujo n8n por cada corrida:**

```
[Source: productos entrantes]
         ↓
[Code: calcular fingerprints]
         ↓
[Supabase Get Many: SELECT id, content_fingerprint, specs_fingerprint
                    FROM products / software / product_specs]
         ↓
[Code: clasificar cada registro]
    - id no existe en DB              → INSERT  (incluye fingerprint)
    - fingerprint cambió              → UPDATE  (incluye nuevo fingerprint)
    - fingerprint igual               → skip    (no se escribe nada)
    - id en DB pero no en source      → DELETE  (hard delete + CASCADE)
         ↓
[Supabase Create / Update / Delete según _action]
```

**Columnas de fingerprint por tabla:**

| Tabla | Columna | Campos que cubre | Formato n8n |
|---|---|---|---|
| `software` | `content_fingerprint` | `name`, `description_text`, `attributes` | `'name:<v>\|desc:<v>\|attrs:<v>'` |
| `products` | `content_fingerprint` | `name`, `brand`, `model`, `description`, `is_new`, `search_aliases`, `software_id` | `'name:<v>\|brand:<v>\|model:<v>\|desc:<v>\|is_new:<v>\|aliases:<v>\|sw_id:<v>'` |
| `product_specs` | `specs_fingerprint` | Todo EXCEPTO `specs_normalized` (derivado del LLM): `specs`, `table_specs`, `variants`, `compatibility`, `specs_text`, `features_text` | `'specs:<json>\|table_specs:<json>\|variants:<json>\|compatibility:<json>\|specs_text:<text>\|features_text:<text>'` |
| `rag_chunks` | — (idempotencia por `source_key`) | `content` (sin columna separada) | comparar `content` por `source_key` antes del Vector Store |

**Señal de re-embedding en chunks:** n8n compara el `content` por `source_key` **antes** del nodo Vector Store. Solo los chunks nuevos o con `content` cambiado se embeben (Gemini) y aterrizan en `embedding_rag_chunk_upload`; el trigger `sync_embedding_upload_to_rag_chunks` (schema.sql §8b) hace el UPSERT por `source_key` dejando `rag_chunks` siempre con embedding. Ya no existe el camino `embedding = NULL` + backfill.

**Forzar re-normalización tras cambio de prompt LLM:** `UPDATE product_specs SET specs_fingerprint = NULL`. En el próximo run, n8n ve fingerprint distinto y re-procesa todo el pipeline (normalize + gen-text + chunks).

**Stale records (hard delete):** productos presentes en DB pero ausentes en el source se eliminan. `ON DELETE CASCADE` limpia `rag_chunks`, `product_specs`, `product_attribute_values` automáticamente. Solo aplica cuando el source envía el **catálogo completo**; si el source es parcial, recolectar todos los IDs vistos antes de correr los DELETEs.

`ingestion_runs` registra cada corrida con conteos (`chunks_created`, `chunks_updated`, `chunks_skipped`, `errors`).

Una re-corrida sin cambios reales cuesta 0 USD en embeddings y <30s de wall time.

---

## 11. Riesgos identificados

| Riesgo | Mitigación |
|---|---|
| Inconsistencia de claves entre productos en `specs_normalized` | Validación Levenshtein en ETL (§5) + reuso de `keys_context` + query mensual de huérfanas. |
| Extractor NLU saca filtros incorrectos | `confidence` umbral + fallback escalonado + log obligatorio + eco de filtros al usuario cuando `confidence ∈ [0.6, 0.8]`. |
| Specs sin parsear (`raw_text` ambiguo) | Quedan en `specs` crudo; no se pierden. El LLM final puede leerlas vía retrieval por chunk `specs`. |
| Cambios en WooCommerce no se reflejan | ETL incremental con fingerprints corre periódicamente o por webhook. Productos eliminados en Woo se detectan por hard delete al comparar IDs del source vs DB. |
| Software huérfano (canónico borrado) | FK `ON DELETE SET NULL` en `software.canonical_product_id`; queries deben tolerar NULL. |
| Crecimiento que invalide el "sin índice vectorial" | Métrica de latencia P95; cuando supere umbral, una sola sentencia `CREATE INDEX` resuelve. |
| Drift del prompt de normalización de specs sin trazabilidad | Cambios de prompt son raros (1-2/año). Forzar re-normalize global con `UPDATE product_specs SET specs_fingerprint = NULL`. Aceptado el trade-off de no auditar qué prompt produjo qué normalized. |
| Inyección vía `description` / `features_text` (proveedor malicioso o scraper que arrastra instrucciones del HTML del fabricante) | Sanitización en ingesta: stripear etiquetas `<script>`, frases tipo "ignore previous instructions", URLs sospechosas. En el prompt de composición, encerrar los chunks recuperados en delimitadores claros (`<chunk id="..." product="...">...</chunk>`) e instruir al LLM final que **nunca** ejecute instrucciones dentro de delimitadores. |
| Fan-out del contexto al LLM final crece con catálogo | Dedup por `product_id` (≤3 chunks/producto) + límite duro de 10 chunks totales / 4000 tokens en el merge. Re-evaluar si `compare` con >2 productos se vuelve común. |
| Pool de cosine sin ordenar bien por sí solo en queries de `compare` o criterio implícito | Mitigación primaria: dedup por `product_id`. Si el eval muestra P@5 < 0.80 en `intent=compare`, activar rerank detrás de feature flag (§7). |

---

## 12. Tradeoffs y alternativas descartadas

Cada decisión expuesta contra la opción que se descartó y la razón. Las
condiciones que invalidarían cada elección quedan explícitas para revisión futura.

| Decisión | Elegido | Alternativa descartada | Razón | Condición para revisar |
|---|---|---|---|---|
| Vector store | pgvector en mismo Postgres | Pinecone / Qdrant / Weaviate | Una sola DB, joins SQL triviales con catálogo, menos ops. A <500 productos no justifica DB extra. | >100k chunks o necesidad de filtrado por metadata muy compleja. |
| Modelo de embedding | `gemini-embedding-001` (3072 dims), vía n8n (Gemini + LangChain) | Salida reducida a 1536 dims vía `output_dimensionality` | Costo absoluto despreciable al volumen. Si llega el momento de necesitar menos dims (índice HNSW, storage), el path **sin cambiar de modelo** es pedirle al mismo `gemini-embedding-001` una `output_dimensionality` menor — el modelo está entrenado con Matryoshka Representation Learning, así que el output reducido preserva la mayor parte de la calidad del 3072. | Si P95 de retrieval supera 150 ms o el storage cruza umbrales de costo. Migración: `ALTER COLUMN ... TYPE vector(1536)` + re-embeddear con `output_dimensionality=1536`. |
| Índice vectorial | **Ninguno**, ni hoy ni en el techo planeado | IVFFlat / HNSW desde día 1 | Volumen real medido: 74 productos → 317 chunks. Techo 500 productos → ~3300 chunks. Con prefiltrado por JOIN a `products` (`category_id`/`is_new`/`brand`) + EXISTS de atributos sobre `pav` el ORDER BY cosine corre sobre 50–300 chunks: <10 ms en seq scan. Cualquier índice aproximado agrega overhead sin beneficio bajo 10k filas. | Que el catálogo crezca más allá de 10k chunks **y** P95 sostenida > 150 ms. Improbable en este negocio. |
| Tipo de embedding en DDL | `vector(3072)` | `halfvec(3072)` desde día 1 | A 317 chunks la diferencia de storage (~4 MB vs ~2 MB) es irrelevante. `vector` es el tipo más probado, mejor soportado por drivers y el default en la mayoría de tutoriales/ejemplos de pgvector. Half-precision solo se justificaría si hubiera que indexar, y eso no va a pasar a este horizonte. | Si algún día se cruza el umbral del índice: `ALTER COLUMN ... TYPE halfvec(3072) USING ...::halfvec(3072)` toma segundos a 3300 filas. No se pierde nada por aplazar. |
| Atributos taxonómicos | EAV controlado (3 tablas) | Una columna JSONB por producto | EAV permite filtros eficientes con índices estándar y multivalor por categoría. JSONB sirve para leer pero rinde mal en filtros booleanos múltiples. | No aplica a este volumen ni dominio. |
| Specs técnicas | JSONB crudo + `specs_normalized` JSONB (LLM) | Tabla `spec_keys` + `product_spec_values` | Vocabulario emergente y heterogéneo por categoría. El catálogo manual no escala a 1600+ specs. El LLM con reuso de `keys_context` converge en 10–15 productos por categoría. | Si la query mensual de claves huérfanas no converge en 2 ciclos. |
| Software de gestión | Tabla canónica + chunk único | Texto duplicado por producto | Embedding único elimina ruido en top-K (12 productos comparten la misma descripción de Robustel Cloud Manager). | Si el software empieza a tener variantes reales por producto, splittear. |
| Recomendados | Tabla `product_recommendations` dirigida (source → target) sin `relation_type` ni `weight` | Tabla genérica `product_relations` con `relation_type` (`recommended`, `alternative`, `accessory`, ...) | Decisión deliberada de **una tabla por tipo de relación**, no una tabla polimórfica. Hoy solo existen "recomendados"; si llegan otros tipos (compatibilidad, accesorios) se crearán tablas específicas. Ventajas: nombres semánticos en SQL (`product_recommendations`, `product_compatibility`), sin columna `relation_type` que mantener, queries más claras. `weight` eliminado porque el flujo siempre emite 0.7 — no aporta información diferencial. | Si aparecen ≥4 tipos de relaciones con la misma estructura (source, target) y queries que las consultan unificadamente, consolidar en una tabla polimórfica con `relation_type`. |
| Brand | TEXT en `products` | Tabla `brands` separada | 11 marcas hoy, sin atributos asociados a la marca. Tabla suma joins sin valor. | Si aparecen atributos por marca (logos, contactos, garantía). |
| Metadata en `rag_chunks` | **Sin denormalizar** — prefiltro por JOIN a `products` + EXISTS sobre `pav` | (a) columnas denormalizadas en el chunk; (b) JSONB de metadata | A ~3300 chunks sin índice vectorial el JOIN da la misma selectividad que las columnas, sin la copia que mantener (drift, write-amplification al cambiar atributos). pgvector vive en el mismo Postgres → el JOIN al catálogo es trivial. | El día que se active índice vectorial (~10k chunks): denormalizar entonces y backfillear desde el JOIN (minutos). |
| Re-ingesta | Fingerprint por contenido calculado en n8n (`content_fingerprint` en products/software, `specs_fingerprint` en product_specs) + hard delete para stale. Chunks comparan `content` directo (sin fingerprint). | Truncate + reload / MD5 en DB | Reload rompe IDs y FKs. Fingerprints garantizan idempotencia y diff barato (re-corrida sin cambios = 0 USD en embeddings). MD5 descartado porque n8n no puede usar `require('crypto')` — fingerprint legible es equivalente y debuggeable. Hard delete elegido sobre soft delete porque el source siempre envía el catálogo completo. | Si el source pasa a envíos parciales, cambiar hard delete por soft delete con `is_active`. |
| Categorías | Tabla con `name`/`slug` `NOT NULL` (placeholders si Woo no responde) | NOT NULL estricto bloqueante | Permite ingesta sin bloquear por lookup externo. | Cuando se conecte Woo en vivo, reemplazar placeholders. |
| `category_summary` chunk | **No se genera** | 1 chunk por categoría con texto descriptivo | A este volumen el contexto de categoría se obtiene mejor desde SQL puro (`categories`) o desde los `overview` agregados. | Si retrieval muestra que el LLM final necesita contexto narrativo de categoría. |
| Hybrid search (BM25/keyword + RRF) | **No se implementa hoy** | Agregar `ts_vector` sobre `rag_chunks.content` + fusión RRF con el cosine | A 74 productos los casos donde keyword vence a embedding ya están cubiertos: identificadores ("R2011", "EG5100") por el matcher fuzzy de §7, marca/atributos por filtros SQL exactos. El delta de calidad estimado es <2% y el costo de mantener dos índices + tuning de RRF (`k`, peso por canal) supera el beneficio. | Catálogo >500 productos **o** >5% de queries con respuesta incorrecta atribuible a fallo de embedding en términos técnicos raros **o** entrada de descripciones largas con jerga única. Activación: `ALTER TABLE rag_chunks ADD COLUMN ts tsvector GENERATED ALWAYS AS (to_tsvector('spanish', content)) STORED;` + índice GIN + fusión RRF en query layer. |
| Cache de embeddings de queries | **No se implementa hoy** | Tabla `query_cache (hash, embedding, created_at)` con TTL | Con `gemini-embedding-001` el costo por query es una fracción de centavo; a 10k queries/mes sigue siendo trivial. La complejidad operativa (invalidación cuando cambia el modelo, TTL, normalización de query antes del hash) supera el ahorro. | >100k queries/mes **o** latencia de embedding domina P50 del pipeline. |
| Re-ranking post-cosine | **No en v1; opcional detrás de feature flag** | Implementar rerank desde día 1 / cross-encoder dedicado (Cohere, BGE) | El rerank está pensado para alto recall (100-200 candidatos con orden ruidoso). A 74 productos con prefiltrado fuerte, el pool sobre el que opera cosine es 20-100 chunks y `gemini-embedding-001` ya los ordena bien. El motor real de calidad es prefiltrado + dedup por producto, no rerank. Implementarlo de entrada agrega ~300 ms y costo sin beneficio medible. | Si el golden set muestra P@5 < 0.80 en `intent=compare` **o** queries con criterio numérico implícito fallan y el NLU no las puede expresar como `spec_filters` (ver §7). |
| Dedup de chunks por producto en merge | **Sí, máximo 3/producto, ≤10 totales** | Pasar el top-K crudo al LLM final | Sin dedup, el contexto del LLM se llena de `overview`+`description`+`features` del mismo producto y el modelo pondera por repetición. | No aplica. |
| `product_specs.compatibility` | **JSONB sin normalizar** | Tabla `product_compatibility` con FK a productos / split en `compatibility` + `certifications` | Inspección del JSON real: 3/74 productos tienen `compatibility` no vacía. Ninguno apunta a productos del catálogo (Honeywell/DSC/Paradox son marcas externas; `"Chile-SUBTEL"` es certificación regulatoria, no compatibilidad). Una tabla relacional con 6-9 filas no aporta nada. El chunk `compatibility` del retrieval ya cubre el caso para el LLM final. | Si llegan ≥10 productos con `compatibility` que apunte a slugs del catálogo, normalizar a tabla. Si las certificaciones regulatorias se multiplican, agregar `product_specs.certifications JSONB` separado y dejar `compatibility` solo para compatibilidad de dispositivo. |

---

## 13. Lo que NO está aquí (decisiones explícitamente fuera de scope)

- **Catálogo formal de `spec_keys`.** Reemplazado por `specs_normalized` JSONB autorregulado + validación Levenshtein en ETL.
- **HNSW.** Se evalúa solo cuando `rag_chunks` supere ~10k filas.
- **Particionado de `rag_chunks`.** Solo a 100k+ filas.
- **Hybrid search (BM25 + RRF).** Solo si catálogo >500 productos o el eval muestra >5% de queries fallan por términos técnicos raros (ver §12).
- **Cache de embeddings de queries.** Solo si >100k queries/mes (ver §12).
- **Multi-tenant / `tenant_id` en tablas.** No hay segundo cliente planeado; agregar después es una migración acotada (columna NOT NULL DEFAULT + reescritura de queries con filtro).
- **Re-ranking en v1.** Solo se activa si el golden set muestra que cosine + dedup no alcanza umbrales en `intent=compare` o queries de criterio implícito (ver §7).

---

## 14. Decisiones rechazadas y contexto histórico

Esta sección preserva el contexto de decisiones descartadas y trampas conocidas. Útil para onboarding y para evitar repetir ciclos de análisis cuando el catálogo crece.

### 14.1 Por qué `search_aliases TEXT[]` con `gin_trgm_ops` no funciona

En una iteración previa se intentó:

```sql
CREATE INDEX ON products USING gin (search_aliases gin_trgm_ops);
```

**Problema:** pgvector's `pg_trgm` no soporta `gin_trgm_ops` sobre arrays. Solo sobre columnas escalares TEXT. Esto produce un error de validación silencioso o indirecto en tiempo de query.

**Solución adoptada:** columna `search_text TEXT GENERATED AS (lower(concat_ws(...)))` + índice GIN trgm sobre la columna concatenada. La concatenación normaliza el array a string, el índice funciona.

**Lección:** siempre verificar que el tipo de dato soporta el operador de índice. `gin_trgm_ops` requiere TEXT escalar, no array.

### 14.2 Diseño rechazado: catálogo formal `spec_keys` + `product_spec_values`

Se consideró un modelo de specs totalmente tipado:

```sql
CREATE TABLE spec_keys (
  id              SERIAL PRIMARY KEY,
  category_id     INT NOT NULL REFERENCES categories(id),
  name            TEXT NOT NULL,
  slug            TEXT NOT NULL,
  data_type       TEXT NOT NULL,  -- 'number' | 'enum' | 'text' | 'boolean' | 'range'
  unit            TEXT,
  allowed_values  JSONB,
  description     TEXT,
  is_filterable   BOOLEAN DEFAULT TRUE,
  UNIQUE (category_id, slug)
);

CREATE TABLE product_spec_values (
  product_id     BIGINT NOT NULL REFERENCES products(id),
  spec_key_id    INT    NOT NULL REFERENCES spec_keys(id),
  value_number   NUMERIC,
  value_text     TEXT,
  value_enum     TEXT,
  value_boolean  BOOLEAN,
  raw_text       TEXT NOT NULL,
  PRIMARY KEY (product_id, spec_key_id)
);
```

**Por qué se rechazó (para 74 productos, techo <500):**
- Curaduría manual: ~80–120 spec_keys entre 8 categorías. Mantenimiento perpetuo.
- Parser de unidades robusto: "1.5 Gbps" → 1500 Mbps requiere reglas por unidad.
- Validación de `allowed_values`: bloquea ingestas si una opción no está pre-registrada.
- ROI negativo: el catálogo es más trabajo que el problema que resuelve.

**Decisión:** un JSONB normalizado por LLM en el ETL + lista mensual de "claves huérfanas" para consolidar manualmente. Emerge el catálogo del uso, no se cuida a mano.

**Cuándo reconsiderar:** si el catálogo crece a 2000+ productos y surgen 500+ claves únicas con inconsistencia problemática. Entonces vale invertir el esfuerzo de formalización.

### 14.3 Qué cubre exactamente `jsonb_path_ops` y qué no

El índice GIN en [schema.sql:249](schema.sql#L249):

```sql
CREATE INDEX idx_specs_normalized ON product_specs USING gin (specs_normalized jsonb_path_ops);
```

**Qué SÍ acelera:**
- Containment: `WHERE specs_normalized @> '{"has_wifi": true}'`
- Existencia de claves: `WHERE specs_normalized ? 'throughput_lte_mbps'`
- Valores como strings: `WHERE specs_normalized @> '{"wifi_standard": "802.11ac"}'`

**Qué NO acelera:**
- Comparaciones numéricas: `WHERE (specs_normalized->>'throughput_lte_mbps')::numeric >= 1000`
- El cast numérico sale del índice; es seq scan + cast por fila.

**Mitigación:** cuando una clave numérica se vuelva "caliente", crear un índice de expresión sobre esa clave concreta (ver §10 mantenimiento).

### 14.4 Diagrama del flujo de retrieval

```
Pregunta del usuario
       │
       ▼
[Agente n8n (tool-calling)]  ←  el "extractor NLU" implícito: entiende la intención
                    y elige/parametriza tools (categoría auto-detectada o ambigua)
       │
       ▼
{category_id, is_new, brand, attribute_filters,
 spec_filters, info_types, structured_lookups, intent, confidence}
       │
       ├─── SQL paralela (structured_lookups + spec_filters) ─────┐
       │     (relaciones, categoría info, opciones disponibles)   │
       │                                                           │
       └─── Similarity (sobre rag_chunks filtrados) → top-20 ─────┤
            (JOIN products: category_id/is_new/brand + EXISTS pav,│
             chunk_type IN info_types + prefiltrado)             │
                          │                                       │
                          ▼                                       │
                  [Dedup por product_id, ≤3 chunks/producto]      │
                  [Re-rank opcional detrás de feature flag — §7]  │
                          │                                       │
                          ▼                                       ▼
                                  Merge en contexto LLM final
                                  (SQL + chunks + scores)
                                          │
                                          ▼
                              Respuesta (+ explicación de ambigüedad si aplica,
                               + eco del intent si confidence ∈ [0.6, 0.8])
```

La clave: **filter-then-rank** con dos rutas paralelas. Estructurado
(SQL puro) y semántico (embeddings) confluyen en el contexto final con
dedupe por producto. El rerank queda como optimización condicional, no
parte del pipeline base (ver §7 "Re-ranking").

### 14.5 Por qué el catálogo `spec_keys` es overkill para este caso

Costo real de la alternativa descartada:

| Trabajo | Esfuerzo | Costo operacional |
|---|---|---|
| Descubrimiento inicial de claves (LLM) | 1 día | <$1 |
| Curaduría manual de spec_keys (80–120) | 2–3 días | N/A (trabajo humano) |
| Parser de unidades (Mbps, dBi, °C, V) | 1–2 días | N/A |
| Validación de allowed_values en ingesta | 0.5 días | Riesgo: bloquea ingestas mal formatadas |
| Mantenimiento por producto nuevo con spec nueva | 0.5 día/ciclo | Decisión per-producto: ¿nueva clave o variante? |
| Mitigación de inconsistencias (claves huérfanas) | 0.5 día/mes | Query mensual + fusión manual |

**Costo del JSONB + LLM (elegido):**
- Normalización por producto: ~2 minutos/producto × 74 = 2–3 horas.
- Prompt reutilizable.
- Revisión manual de huérfanas: 0.5 día/mes.
- **Total: 1 día vs 8 días. ROI claro.**

A 500 productos (techo): seria ~100 horas de ETL normalización vs curaduría manual perpetua del catálogo. El break-even estaría alrededor de 1500–2000 productos.

### 14.6 Multi-term Si/No: por qué no es bug

Cuatro productos en el snapshot tienen valores contradictorios para el mismo atributo:

```
robustel-r2011       -> pa_wifi -> ['no', 'si']
robustel-r1510-4l    -> pa_wifi -> ['no', 'si']
robustel-r2110       -> pa_wifi -> ['no', 'si']
suntech-kit-de-voz   -> pa_audio-en-cabina -> ['no', 'si']
```

**Razón:** el producto en el sitio de origen existe en variantes. Uno con WiFi, otro sin. El scraper ve ambas variantes y registra los atributos de ambas en el mismo objeto producto (porque WooCommerce modeliza variantes como hijos del padre).

**Por qué preservar:** replicar el comportamiento del sitio es correcto. El producto aparece en el filtro "Con WiFi" Y en "Sin WiFi" porque **sí** lo hace en el sitio. Deduplicar en el ETL rompe la paridad.

**Cómo el LLM final lo maneja:** el prompt debe instruir que si un producto tiene `['no','si']` para un atributo y la pregunta es binaria ("¿tiene WiFi?"), la respuesta es "El producto tiene variantes: con y sin WiFi". Ver §4 (UX de ambigüedad).

### 14.7 Filtros de atributo: un EXISTS por grupo (nunca un array plano)

Los `attribute_filters` del NLU vienen agrupados por `taxonomy`. La semántica
correcta es **OR dentro del grupo, AND entre grupos** ("5G **o** 4G" **y** "WiFi=sí").

El backend la materializa con **un `EXISTS` sobre `product_attribute_values` por
cada grupo** (ver query 7 en §8 y `semantic_search` en [TOOLS.md](TOOLS.md)): el
`ao.slug IN (...)` interno da el OR del grupo; el AND entre los EXISTS da el AND
entre grupos. El EAV (`product_attribute_values`) es la fuente de verdad del filtro.

Tentación a evitar: colapsar los slugs de todos los grupos en un solo predicado
(`IN` único o un array con `&&`). Eso evalúa **OR global** y deja pasar productos
que cumplen UNO solo de los filtros — un producto con WiFi pero sin 5G entraría a
"5G y WiFi". Un EXISTS por grupo preserva la semántica sin ambigüedad.

Predicados que un `IN`/EXISTS simple no expresa (negaciones, exclusiones cruzadas:
"5G pero NO 3G") se resuelven agregando un `NOT EXISTS` por cada grupo negado.
