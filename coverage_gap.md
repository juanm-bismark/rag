 Coverage gaps (columnas en el DDL sin query en el catálogo)
No son problemas — son funcionalidad latente que el DDL soporta pero ninguna pregunta documentada ejercita. Decides si vale la pena agregar preguntas:

Columna / capacidad	Pregunta que podría existir
software.attributes TEXT[] (vpn, sdwan, mqtt, modbus…)	"qué softwares soportan MQTT" — útil para filtrar D4
product_specs.prompt_version + prompt_normalized_at	G-level: "productos con prompt obsoleto para re-normalizar"
product_specs.variants JSONB	"qué variantes tiene el EG5100" — hoy se accede solo vía chunks variants
software.canonical_product_id	"cuál es el producto canónico de este software"
Las columnas tipo ETL (attributes_hash, specs_hash, content_hash, fragments_count, characters_count, token_count) son internas — correcto que no haya queries de usuario sobre ellas.
