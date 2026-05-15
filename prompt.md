# Prompt - Arquitectura RAG para catalogo de productos

Usa este prompt para pedir una propuesta tecnica de arquitectura RAG basada en
`salida_completa.json`.

## Rol

Eres un arquitecto experto en Retrieval-Augmented Generation (RAG), busqueda
vectorial, PostgreSQL, pgvector, metadata filtering, normalizacion de catalogos
de productos B2B y diseno de pipelines ETL.

## Contexto

Estoy construyendo un sistema RAG para un catalogo de productos B2B de
telecomunicaciones, networking, IoT industrial, alarmas, rastreo, switches,
antenas, transceptores y software de gestion.

La fuente principal de datos es `salida_completa.json`. Es un arreglo de
productos enriquecidos. Cada producto contiene informacion comercial,
atributos filtrables, especificaciones tecnicas, caracteristicas, software de
gestion y productos recomendados.

El volumen inicial es pequeno: decenas de productos, con crecimiento esperado a
menos de 500 productos. La prioridad es calidad de retrieval, trazabilidad y
facilidad de mantenimiento.

## Estructura de entrada

Cada producto trae campos como:

```json
{
  "id": 22615,
  "slug": "robustel-eg5100",
  "source_url": "https://...",
  "name": "Robustel EG5100",
  "brand": "Robustel",
  "model": "EG5100",
  "category_id": 516,
  "es_nuevo": true,
  "description": "Descripcion corta del producto",
  "attributes": [],
  "search_aliases": [],
  "specs": [],
  "specs_text": "# Especificaciones tecnicas...",
  "features_text": "# Caracteristicas...",
  "compatibility": [],
  "table_specs": [],
  "variants": [],
  "productos_recomendados": [],
  "software_nombre": "Robustel Cloud Manager Service",
  "software_texto": "Texto descriptivo del software",
  "software_attributes": [],
  "is_software_canonical": true,
  "software_canonico_de": null,
  "software_applies_to_product_ids": [22615, 22602],
  "software_dedupe_group_id": "sw_6z1yb5"
}
```

### Atributos filtrables

`attributes` contiene filtros de catalogo con taxonomia y opciones:

```json
{
  "id": 31,
  "name": "WiFi",
  "taxonomy": "pa_wifi",
  "options": [
    { "id": 10, "name": "Si", "slug": "si" }
  ]
}
```

Estos atributos deben servir para filtros estructurados y metadata filtering.

### Especificaciones tecnicas

`specs` contiene pares tecnico-valor, a veces agrupados por seccion:

```json
{
  "name": "CPU",
  "value": "ARM Cortex-A7, 792 MHz",
  "section": "Sistema de hardware"
}
```

Algunas specs pueden traer `items` para valores compuestos:

```json
{
  "name": "Numero de antenas",
  "value": "Version 4G: 2 | Version 5G: 4",
  "section": "Interfaz celular",
  "items": ["Version 4G: 2", "Version 5G: 4"]
}
```

Tambien existe `specs_text`, que contiene una version narrativa o Markdown de
las especificaciones.

### Software de gestion

El software ya viene deduplicado semanticamente:

- `software_dedupe_group_id` identifica el grupo.
- `is_software_canonical` indica el producto canonico que contiene el texto.
- `software_canonico_de` apunta al producto canonico cuando el producto no
  contiene el texto completo.
- `software_applies_to_product_ids` indica a que productos aplica el software.

Necesito modelar este software como una entidad reutilizable y evitar duplicar
embeddings identicos por producto.

### Productos recomendados

`productos_recomendados` contiene referencias a otros productos. Estas
referencias deben convertirse en relaciones dirigidas:

```txt
producto actual -> producto recomendado
```

La relacion esperada es `recommended_product`.

## Objetivo de diseno

Necesito una arquitectura practica para:

- almacenar el catalogo en PostgreSQL;
- separar informacion estructurada de informacion semantica;
- crear chunks para embeddings;
- permitir filtros por producto, marca, categoria, atributos, estado nuevo y
  tipo de informacion;
- consultar specs tecnicas con SQL cuando sea posible;
- usar embeddings cuando la pregunta sea semantica;
- resolver productos recomendados con relaciones estructuradas;
- reutilizar software canonico sin duplicar embeddings;
- mantener el ETL idempotente y facil de reejecutar.

## Preguntas a responder

Analiza y responde:

1. Que arquitectura recomiendas: tablas normalizadas, tabla unificada de
   retrieval, o enfoque hibrido?
2. Que tablas deberia tener la base de datos?
3. Como modelarias productos, categorias, atributos y valores de atributos?
4. Como modelarias specs crudas, specs normalizadas y texto tecnico para RAG?
5. Como modelarias el software de gestion canonico y su relacion con productos?
6. Como modelarias `productos_recomendados` como relaciones dirigidas?
7. Como deberia ser la tabla de chunks para embeddings?
8. Que `chunk_type` deberian existir y cuando usarlos?
9. Que metadata debe acompanar cada chunk?
10. Como deberia funcionar el routing de retrieval segun la pregunta del usuario?
11. Cuando conviene usar SQL puro y cuando conviene usar similarity search?
12. Como deberia funcionar el extractor NLU de filtros e intenciones?
13. Como manejar alias, sinonimos y busqueda fuzzy de productos?
14. Como evitar duplicar embeddings cuando el contenido no cambia?
15. Que validaciones o metricas recomiendas para saber si el retrieval funciona?

## Escenarios de retrieval

Considera estos casos:

- "Que es el Robustel EG5100?"
- "Dame las caracteristicas del Robustel EG5120."
- "Que specs tiene este router?"
- "Tiene WiFi?"
- "Que productos tienen 5G y WiFi?"
- "Que routers industriales nuevos hay?"
- "Que software usa este producto?"
- "Que productos usan Robustel Cloud Manager Service?"
- "Con que paneles es compatible este comunicador?"
- "Que producto recomienda este modelo?"
- "Compara dos productos por specs y caracteristicas."
- "Busco un equipo con RS485, 4G y gestion remota."

## Requisitos de salida

Entrega una propuesta concreta con:

1. Arquitectura recomendada.
2. Esquema SQL sugerido.
3. Diseno de tabla `rag_chunks`.
4. Tipos de chunks y reglas de chunking.
5. Metadata recomendada por chunk.
6. Flujo ETL paso a paso.
7. Prompt o estrategia para normalizar specs.
8. Estrategia para software canonico.
9. Estrategia para relaciones entre productos.
10. Logica de routing de retrieval.
11. Pseudocodigo de consultas principales.
12. Tradeoffs y decisiones practicas.
13. Recomendacion final para este volumen de catalogo.

Prioriza una solucion pragmatica, mantenible y precisa para un catalogo pequeno
o mediano. Evita sobrediseno innecesario.

