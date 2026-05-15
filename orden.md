Orden de carga del ETL (importa por las FKs)
categories ← categorias.json
attributes + attribute_options ← combinacion_filtros_con_opcionesposibles.json
category_attributes ← derivar de productos_con_filtros.json (qué atributos aparecen en cada categoría)
software (canónicos primero, sin canonical_product_id aún) ← salida_specs_software_description.json filtrando por software_canonico_de == null
products ← productos_con_filtros.json (toma name, slug, brand, category_id, is_new) + complemento desde salida_specs (source_url, description, software_id)
UPDATE software SET canonical_product_id = ... (cerrar el bucle)
product_attribute_values ← productos_con_filtros.json recorriendo attributes[].terms[]
product_specs ← salida_specs_software_description.json (aún sin specs_normalized)
Paso de normalización LLM → llena specs_normalized (prompt abajo)
product_relations ← relations.json
rag_chunks ← generar texto + embeddings + denormalizar metadata
