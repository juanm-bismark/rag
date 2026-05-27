# Prompt 2 - Generar chunks RAG desde `salida_completa.json`

Usa este prompt para convertir la informacion de `salida_completa.json`
en chunks listos para embeddings, metadata filtering y relaciones de productos.

El JSON es un arreglo de productos enriquecidos con campos como `id`, `name`,
`description`, `features_text`, `specs`, `specs_text`, `software_texto` y
`productos_recomendados`.

---

## Prompt

### Rol

Eres un ingeniero experto en RAG, catalogos de productos B2B, busqueda
semantica, metadata filtering y normalizacion de datos para PostgreSQL +
pgvector.

### Objetivo

A partir de `salida_completa.json`, genera una estructura de chunks de retrieval
para un catalogo de productos. Cada chunk debe ser una unidad independiente,
limpia y filtrable, pensada para:

- busqueda semantica por embeddings;
- filtros por producto, marca, categoria, atributos y estado nuevo/usado;
- routing por tipo de informacion;
- deduplicacion de software de gestion compartido;
- trazabilidad hacia el campo original del JSON;
- relaciones dirigidas entre productos recomendados.

Prioriza precision de retrieval sobre pureza teorica. No inventes informacion
que no exista en el JSON.

---

## Contrato real de entrada

La entrada es un arreglo JSON. Cada elemento representa un producto y trae estos
campos de primer nivel:

```json
{
  "slug": "robustel-eg5100",
  "source_url": "https://...",
  "description": "Texto descriptivo corto del producto",
  "productos_recomendados": ["robustel-eg5120"],
  "id": 22615,
  "name": "Robustel EG5100",
  "brand": "Robustel",
  "model": "EG5100",
  "category_id": 516,
  "es_nuevo": true,
  "attributes": [],
  "search_aliases": [],
  "specs": [],
  "specs_text": "# Especificaciones tecnicas...",
  "compatibility": [],
  "table_specs": [],
  "variants": [],
  "features_text": "# Caracteristicas...",
  "software_nombre": "Robustel Cloud Manager Service",
  "software_texto": "Texto del software solo en el producto canonico",
  "software_fragmentos": 1,
  "software_caracteres": 1200,
  "software_attributes": [],
  "is_software_canonical": true,
  "software_canonico_de": null,
  "software_applies_to_product_ids": [22615, 22602],
  "software_dedupe_group_id": "sw_6z1yb5"
}
```

### Forma de `attributes`

Cada producto puede traer filtros WooCommerce en este formato:

```json
{
  "id": 63,
  "name": "Tipo de Accesorio",
  "taxonomy": "pa_tipo-de-accesorio",
  "options": [
    { "id": 1570, "name": "Antena", "slug": "antena" }
  ]
}
```

Reglas:

- Usa `attributes[].options[]`; no asumas que existe `terms`.
- Construye `attribute_slugs` como `taxonomy:option_slug`.
- Conserva tambien una version agrupada por taxonomia para filtros.

Ejemplo:

```json
{
  "attribute_slugs": [
    "pa_red-celular:5g",
    "pa_wifi:si"
  ],
  "attributes_by_taxonomy": {
    "pa_red-celular": ["5g"],
    "pa_wifi": ["si"]
  }
}
```

### Forma de `specs`

`specs` es un arreglo de objetos. La mayoria trae:

```json
{
  "name": "CPU",
  "value": "ARM Cortex-A7, 792 MHz",
  "section": "Sistema de hardware"
}
```

Algunos objetos pueden traer `items`:

```json
{
  "name": "Numero de antenas",
  "value": "Version 4G: 2 | Version 5G: 4",
  "section": "Interfaz celular",
  "items": ["Version 4G: 2", "Version 5G: 4"]
}
```

Reglas:

- No fuerces las specs a solo tres grupos fijos.
- Preserva la `section` original cuando exista.
- Si `section` no existe, usa `sin_seccion`.
- Normaliza una copia de la seccion a slug para metadata, pero conserva el texto
  original en el contenido o metadata.
- Si `items` existe, usalo para mejorar la legibilidad del contenido.

---

## Salida esperada

Devuelve un objeto JSON con esta forma:

```json
{
  "product_chunks": [],
  "software_chunks": [],
  "product_relations": [],
  "stats": {
    "products_read": 0,
    "product_chunks_created": 0,
    "software_chunks_created": 0,
    "relations_created": 0,
    "relations_unresolved": 0
  },
  "warnings": []
}
```

### Estructura comun de chunk

Cada chunk debe usar este contrato:

```json
{
  "product_id": 22615,
  "software_dedupe_group_id": null,
  "software_canonical_product_id": null,
  "product_slug": "robustel-eg5100",
  "product_name": "Robustel EG5100",
  "brand": "Robustel",
  "model": "EG5100",
  "category_id": 516,
  "is_new": true,
  "chunk_type": "description",
  "section_name": "description",
  "title": "Robustel EG5100 - descripcion",
  "content": "Texto limpio del chunk...",
  "metadata": {
    "lang": "es",
    "source_file": "salida_completa.json",
    "source_fields": ["description"],
    "source_url": "https://...",
    "search_aliases": [],
    "attribute_slugs": [],
    "attributes_by_taxonomy": {},
    "retrieval_priority": 0.95,
    "quality_score": 0.95
  }
}
```

`chunk_type` debe ser uno de:

- `overview`
- `description`
- `features`
- `specs`
- `spec_section`
- `software`
- `compatibility`
- `variants`

Usa `section_name` para guardar la seccion interna del chunk. En el DDL esto
mapea a `rag_chunks.section_name`.

---

## Reglas de limpieza de texto

Aplica estas reglas antes de crear chunks:

1. Convierte saltos repetidos y espacios multiples en espacios o saltos limpios.
2. Conserva listas tecnicas cuando mejoren la lectura.
3. Elimina encabezados duplicados si quedan pegados al contenido.
4. No traduzcas nombres de productos, marcas, modelos, protocolos ni software.
5. No inventes categoria por nombre. El JSON actual solo trae `category_id`.
6. No elimines unidades tecnicas como Mbps, GHz, MHz, V, W, dBi, Ohm, RS232,
   RS485, LTE, 5G, 4G, WiFi, GPS, GNSS, SFP, SIM, Docker, VPN.
7. Si un campo esta vacio, `null`, `[]` o no aporta contenido semantico, no
   generes chunk desde ese campo.

---

## Chunks por producto

### 1. Chunk `overview`

Crear un chunk por producto con una tarjeta breve de identificacion.

Fuente:

- `name`
- `brand`
- `model`
- `description`
- `attributes`

Contrato:

```json
{
  "chunk_type": "overview",
  "section_name": "overview",
  "source_fields": ["name", "brand", "model", "description", "attributes"],
  "retrieval_priority": 0.97,
  "quality_score": 0.94
}
```

Contenido recomendado:

```txt
Producto: Robustel EG5100
Marca: Robustel
Modelo: EG5100
Categoria ID: 516
Resumen: Gateway industrial...
Atributos clave: pa_red-celular:5g; pa_wifi:si
```

Sirve para preguntas abiertas de identificacion y para recall inicial por
producto.

### 2. Chunk `description`

Crear un chunk cuando `description` tenga texto util.

Fuente:

- `description`

Contrato:

```json
{
  "chunk_type": "description",
  "section_name": "description",
  "source_fields": ["description"],
  "retrieval_priority": 0.95,
  "quality_score": 0.95
}
```

Contenido recomendado:

```txt
Producto: Robustel EG5100
Marca: Robustel
Modelo: EG5100
Descripcion: La EG5100 de Robustel es una gateway industrial...
```

Sirve para preguntas como:

- que es este producto;
- para que sirve;
- dame un resumen;
- que producto es el Robustel EG5100.

### 3. Chunks `features`

Crear chunks desde `features_text`.

Fuente:

- `features_text`

Reglas:

- `features_text` viene en Markdown.
- Divide por encabezados `##` cuando existan.
- Si no hay encabezados, crea un chunk unico.
- Si una seccion supera aproximadamente 500 tokens, dividela por listas o
  parrafos sin cortar frases.
- Conserva los bullets cuando sean claros.
- Si hay secciones como compatibilidad u homologaciones dentro de
  `features_text`, mantenlas como `chunk_type = "features"` y usa
  `section_name = "compatibility"` o `section_name = "homologaciones"` segun corresponda.

Contrato:

```json
{
  "chunk_type": "features",
  "section_name": "caracteristicas_principales",
  "source_fields": ["features_text"],
  "retrieval_priority": 0.9,
  "quality_score": 0.9
}
```

Sirve para preguntas como:

- que caracteristicas tiene;
- que ventajas ofrece;
- sirve para IoT industrial;
- permite gestion remota;
- soporta Docker, VPN, alarmas, telemetria o monitoreo.

### 4. Chunks tecnicos

Crear chunks tecnicos desde `specs`, `specs_text` y `table_specs`.
`compatibility` y `variants` tienen `chunk_type` propio.

#### 4.1 Specs estructuradas desde `specs`

Agrupa `specs[]` por `section`.

Para cada grupo, crea un chunk:

```json
{
  "chunk_type": "spec_section",
  "section_name": "interfaz_celular",
  "source_fields": ["specs"],
  "retrieval_priority": 1.0,
  "quality_score": 0.98
}
```

Contenido recomendado:

```txt
Producto: Robustel EG5100
Seccion tecnica: Interfaz celular
- Conector: SMA-K
- Numero de antenas: 2
- SIM: 2 x Mini SIM (2FF)
```

Si `items` existe, puedes representarlo asi:

```txt
- Numero de antenas: Version 4G: 2; Version 5G: 4
```

#### 4.2 Fallback desde `specs_text`

Usa `specs_text` como respaldo cuando:

- `specs` este vacio; o
- necesites conservar una version narrativa completa para embeddings.

Reglas:

- Divide por encabezados Markdown si existen.
- Mantiene `chunk_type = "specs"`.
- Usa `section_name = "specs_text"` si no hay una seccion mas especifica.
- Usa `source_fields = ["specs_text"]` o `["specs", "specs_text"]` si combinaste
  ambas fuentes.
- Evita duplicar palabra por palabra el mismo contenido generado desde `specs`
  si ya quedo cubierto.

#### 4.3 `table_specs`

Si `table_specs` trae datos, crea un chunk de specs con:

```json
{
  "chunk_type": "specs",
  "section_name": "table_specs",
  "source_fields": ["table_specs"],
  "retrieval_priority": 0.92,
  "quality_score": 0.9
}
```

Formato:

```txt
Tabla tecnica adicional:
- Elementos: 1 Arnes de conexion; 1 Parlante; 1 Microfono
```

#### 4.4 `compatibility`

Si `compatibility` trae datos, crea un chunk propio con:

```json
{
  "chunk_type": "compatibility",
  "section_name": "compatibility",
  "source_fields": ["compatibility"],
  "retrieval_priority": 0.94,
  "quality_score": 0.92
}
```

Formato:

```txt
Compatibilidad:
- Honeywell: Vista 12, Vista 15, Vista 21, Vista 48
- DSC: Classic PC585 y Power Series PC1616, PC1832, PC1864
```

#### 4.5 `variants`

Si `variants` trae datos, crea un chunk propio con:

```json
{
  "chunk_type": "variants",
  "section_name": "variants",
  "source_fields": ["variants"],
  "retrieval_priority": 0.88,
  "quality_score": 0.85
}
```

Formato:

```txt
Variantes o notas de configuracion:
- Texto de variante...
```

---

## Chunks de software

El JSON ya trae software deduplicado con estos campos:

- `software_nombre`
- `software_texto`
- `software_attributes`
- `is_software_canonical`
- `software_canonico_de`
- `software_applies_to_product_ids`
- `software_dedupe_group_id`

Regla principal:

Crear chunks de software SOLO desde productos canonicos:

```txt
is_software_canonical === true
software_texto tiene contenido util
software_dedupe_group_id no es null
```

No crees chunks de software para productos no canonicos. En esos casos
`software_texto` normalmente viene `null` y `software_canonico_de` apunta al
producto canonico.

Contrato de chunk de software:

```json
{
  "product_id": null,
  "software_dedupe_group_id": "sw_6z1yb5",
  "software_canonical_product_id": 22615,
  "product_slug": null,
  "product_name": null,
  "brand": "Robustel",
  "model": null,
  "category_id": null,
  "is_new": null,
  "chunk_type": "software",
  "section_name": "software_management",
  "title": "Robustel Cloud Manager Service",
  "content": "Texto limpio del software...",
  "metadata": {
    "lang": "es",
    "source_file": "salida_completa.json",
    "source_fields": ["software_nombre", "software_texto"],
    "software_nombre": "Robustel Cloud Manager Service",
    "software_dedupe_group_id": "sw_6z1yb5",
    "software_canonical_product_id": 22615,
    "applies_to_product_ids": [22615, 22602],
    "is_shared_semantic": true,
    "software_attributes": [],
    "retrieval_priority": 0.72,
    "quality_score": 0.88
  }
}
```

Reglas:

- `applies_to_product_ids` debe salir de `software_applies_to_product_ids`.
- Si ese campo esta vacio pero el producto es canonico, usa `[id]`.
- `is_shared_semantic` es `true` cuando aplica a mas de un producto.
- Incluye `software_nombre` al inicio del contenido.
- No dupliques chunks identicos para cada producto que usa el mismo software.

Sirve para preguntas como:

- que software tiene este producto;
- se puede gestionar en la nube;
- soporta monitoreo remoto;
- que plataforma usa Robustel/Teldat/Sierra Wireless;
- que productos usan este software.

---

## Relaciones de productos recomendados

Ademas de chunks, genera `product_relations` desde
`productos_recomendados`.

La relacion es dirigida:

```txt
producto actual -> producto recomendado
```

Salida:

```json
{
  "source_product_id": 22615,
  "target_product_id": 22602,
  "relation_type": "recommended_product",
  "weight": 1.0,
  "source": "salida_completa.productos_recomendados",
  "metadata": {
    "source_slug": "robustel-eg5100",
    "target_slug": "robustel-eg5120",
    "raw_value": "robustel-eg5120"
  }
}
```

Reglas de resolucion:

1. Construye un indice por `slug`.
2. Construye un indice de aliases usando:
   - `slug`
   - `name`
   - `brand`
   - `model`
   - `brand + " " + model`
   - cada elemento de `search_aliases`
3. Normaliza aliases:
   - lowercase;
   - quitar tildes;
   - convertir guiones largos a guion normal;
   - reemplazar caracteres no alfanumericos por espacios o guiones;
   - colapsar espacios;
   - eliminar ruido como "equipo", "modelo", "router", "gateway",
     "switch", "tracker", "antena", "accesorio" cuando venga al inicio.
4. Si no se puede resolver el destino, no inventes el ID. Agrega un warning.
5. No crees autorrelaciones.
6. No dupliques la misma relacion `(source_product_id, relation_type,
   target_product_id)`.
7. No hagas la relacion inversa automaticamente.

---

## Metadata obligatoria por chunk

Cada chunk de producto debe incluir:

```json
{
  "lang": "es",
  "source_file": "salida_completa.json",
  "source_fields": [],
  "source_url": "...",
  "product_id": 22615,
  "product_slug": "robustel-eg5100",
  "product_name": "Robustel EG5100",
  "brand": "Robustel",
  "model": "EG5100",
  "category_id": 516,
  "is_new": true,
  "search_aliases": [],
  "attribute_slugs": [],
  "attributes_by_taxonomy": {},
  "retrieval_priority": 0.9,
  "quality_score": 0.9
}
```

Cada chunk de software debe incluir:

```json
{
  "lang": "es",
  "source_file": "salida_completa.json",
  "source_fields": ["software_nombre", "software_texto"],
  "software_nombre": "Robustel Cloud Manager Service",
  "software_dedupe_group_id": "sw_6z1yb5",
  "software_canonical_product_id": 22615,
  "applies_to_product_ids": [22615, 22602],
  "is_shared_semantic": true,
  "software_attributes": [],
  "retrieval_priority": 0.72,
  "quality_score": 0.88
}
```

---

## Prioridades recomendadas

| Fuente | `chunk_type` | Prioridad | Calidad |
| --- | --- | ---: | ---: |
| `name + brand + model + description + atributos` | `overview` | 0.97 | 0.94 |
| `description` | `description` | 0.95 | 0.95 |
| `features_text` | `features` | 0.90 | 0.90 |
| `specs` agrupadas por seccion | `spec_section` | 1.00 | 0.98 |
| `specs_text` fallback | `specs` | 0.94 | 0.92 |
| `table_specs` | `specs` | 0.92 | 0.90 |
| `compatibility` | `compatibility` | 0.94 | 0.92 |
| `variants` | `variants` | 0.88 | 0.85 |
| `software_texto` canonico | `software` | 0.72 | 0.88 |

La prioridad no reemplaza el score vectorial. Usala como boost o tie-breaker en
ranking final.

---

## Routing de retrieval recomendado

Usa `chunk_type` y `section_name` para reducir ruido:

| Pregunta | Donde buscar |
| --- | --- |
| "Que es X?" | `overview`, `description` |
| "Para que sirve X?" | `overview`, `description`, `features` |
| "Caracteristicas de X" | `features` |
| "Specs de X" | `specs`, `spec_section` |
| "Tiene WiFi/4G/RS485/GPS?" | `specs`, con filtros por atributos si existen |
| "Con que paneles es compatible?" | `compatibility` |
| "Que software usa X?" | `software`, filtrando por `applies_to_product_ids` |
| "Productos con 5G y WiFi" | SQL/metadata primero; luego `overview`, `features`, `description` |
| "Que productos recomienda X?" | `product_relations`, no embeddings |

Para relaciones exactas, consulta `product_relations` como fuente estructurada.

---

## Validaciones

Antes de entregar la salida, valida:

1. Todos los chunks tienen `content` no vacio.
2. Todos los chunks tienen `chunk_type` permitido.
3. Los chunks de producto tienen `product_id`.
4. Los chunks de software NO duplican contenido por producto.
5. Los chunks de software canonico tienen `software_dedupe_group_id`.
6. `attribute_slugs` usa formato `taxonomy:slug`.
7. `is_new` sale de `es_nuevo`.
8. `category_id` sale de `category_id`; no inventes `category_slug`.
9. Las relaciones usan IDs numericos reales del mismo JSON.
10. Las relaciones no resueltas quedan en `warnings`.

---

## Criterios finales

- Usa los campos de entrada definidos en el contrato real de
  `salida_completa.json`.
- Usa solo estos `chunk_type`: `overview`, `description`, `features`,
  `specs`, `spec_section`, `software`, `compatibility`, `variants`.
- Crea chunks de software unicamente desde productos canonicos con
  `is_software_canonical = true`.
- Trata `productos_recomendados` como relaciones dirigidas entre productos.
- Mantiene `category_id` como identificador de categoria.
- Separa descripcion, caracteristicas, especificaciones y software en chunks
  independientes.
- Crea chunks solo cuando el campo fuente tenga contenido util.

---

## Resumen operativo

Para cada producto:

1. Lee campos basicos: `id`, `slug`, `name`, `brand`, `model`,
   `category_id`, `es_nuevo`, `source_url`, `search_aliases`.
2. Aplana `attributes[].options[]` en `attribute_slugs` y
   `attributes_by_taxonomy`.
3. Crea chunk `overview` desde identidad, descripcion corta y atributos.
4. Crea chunk `description` desde `description`.
5. Crea chunks `features` desde `features_text`.
6. Crea chunks `spec_section` agrupando `specs[]` por `section`.
7. Agrega chunks `specs` desde `table_specs` y `specs_text` como fallback
   o complemento sin duplicar contenido.
8. Agrega chunks `compatibility` y `variants` cuando existan.
9. Si el producto es software canonico, crea un unico chunk `software`.
10. Resuelve `productos_recomendados` como relaciones dirigidas.
11. Devuelve `product_chunks`, `software_chunks`, `product_relations`,
    `stats` y `warnings`.
