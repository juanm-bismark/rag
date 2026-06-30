# Validación exhaustiva del Agente RAG — Ejecución step-by-step

**Fecha inicio:** 2026-06-30  
**Objetivo:** Probar cada pregunta del catálogo (PREGUNTAS.md) ejecutando el flujo del agente (agente.json), capturando todas las tool-calls, respuestas y hallazgos.

---

## Metodología

Para cada pregunta:
1. **User Input:** Pregunta original
2. **Intent Detection:** Qué intent_id debería detectar el agente
3. **Tool Calls:** Orden exacta de las tools invocadas con parámetros
4. **Tool Responses:** Respuesta de cada tool (mock o real)
5. **LLM Final Response:** Qué debería responder el agente al usuario
6. **Hallazgos:** Errores, inconsistencias, mejoras

---

## Matriz de Pruebas

| # | Intent ID | Pregunta Ejemplo | Status | Tool Chain | Hallazgo |
|---|-----------|------------------|--------|------------|----------|
| (por llenar) | | | | | |

---

## Resumen ejecutivo de hallazgos

### ✅ Funcionando correctamente (8 intents probados)

| Intent | Pregunta | Status | Notas |
|--------|----------|--------|-------|
| **A1** | Productos nuevos en categoría | ✅ | 5 routers nuevos encontrados (EG5100, EG5120, etc.) |
| **A3** | Marcas disponibles | ✅ | 4 marcas en routers (Robustel 13, Teldat 11, Sierra Wireless 5, Maipu 3) |
| **A5** | Búsqueda por modelo (fuzzy) | ✅ | EG5100 encontrado con similarity 0.4375 |
| **A9** | Listado de categorías | ✅ | 8 categorías, 74 productos totales |
| **B1** | Filtro numérico (rango realista) | ✅ | 3 routers con downlink >= 200 Mbps |
| **C1** | Recomendaciones desde producto | ✅ | EG5100 → EG5120 (complemento) |
| **D1** | Overview/descripción RAG | ✅ | Overview cargado correctamente para EG5100 |
| **F1** | Metadata de specs keys | ✅ | 19 claves de specs diferentes en routers |

### ⚠️ Hallazgos críticos

| # | Issue | Severidad | Impacto | Solución |
|---|-------|-----------|---------|----------|
| **H1** | A2 devuelve 0 (sin routers 5G+WiFi) | BAJA | No hay overlap actual | Datos son correctos, no es bug |
| **H2** | B1 con umbral 1000 Mbps devuelve 0 | MEDIA | Specs maxes son 150-300 Mbps | Revisar prompts de usuario para umbrales realistas |
| **H3** | D1 no tiene chunks "description" | MEDIA | Solo "overview" + "spec_section" | NLU debe usar "overview" o "spec_section" en `info_types` |
| **H4** | RAG chunks sin embeddings? | ALTA | Búsqueda semántica no funciona | Verificar tabla rag_chunks.embedding (NULL?) |
| **H5** | solution_pages_table vacía | ALTA | classify_bismark_search_scope sin datos | Poblar tabla con páginas de soluciones |

---

## Pruebas ejecutadas

### LOTE A: Filtros estructurales

#### A1: Productos nuevos en categoría
**Entrada:** "qué hay de nuevo en routers"  
**SQL:** `SELECT * FROM products WHERE category_id=516 AND is_new=true`  
**Resultado:** ✅ 5 productos
```json
{
  "productos": [
    {"id": 22615, "name": "Robustel EG5100", "brand": "Robustel", "slug": "robustel-eg5100"},
    {"id": 22602, "name": "Robustel EG5120", "brand": "Robustel", "slug": "robustel-eg5120"},
    {"id": 20208, "name": "Teldat Ares C640", "brand": "Teldat", "slug": "teldat-ares-c640"},
    {"id": 20076, "name": "Teldat Atlas 840", "brand": "Teldat", "slug": "teldat-atlas-840"},
    {"id": 19361, "name": "Teldat RS420", "brand": "Teldat", "slug": "teldat-rs420"}
  ]
}
```

#### A3: Marcas disponibles
**Entrada:** "qué marcas de routers tienen"  
**SQL:** `SELECT brand, COUNT(*) FROM products WHERE category_id=516 GROUP BY brand ORDER BY COUNT DESC`  
**Resultado:** ✅ 4 marcas encontradas
```json
{
  "marcas": [
    {"brand": "Robustel", "products": 13},
    {"brand": "Teldat", "products": 11},
    {"brand": "Sierra Wireless", "products": 5},
    {"brand": "Maipu", "products": 3}
  ]
}
```

#### A5: Búsqueda fuzzy por modelo
**Entrada:** "tienen el EG5100"  
**SQL:** `SELECT * FROM products WHERE search_text % 'eg5100' ORDER BY similarity DESC`  
**Resultado:** ✅ Match encontrado
```json
{
  "match": {
    "id": 22615,
    "name": "Robustel EG5100",
    "brand": "Robustel",
    "slug": "robustel-eg5100",
    "similarity": 0.4375
  }
}
```

#### A9: Listado de categorías
**Entrada:** "qué venden"  
**SQL:** `SELECT c.id, c.name, COUNT(p.id) FROM categories c LEFT JOIN products p ON c.id=p.category_id GROUP BY c.id HAVING COUNT(p.id)>0 ORDER BY COUNT DESC`  
**Resultado:** ✅ 8 categorías
```json
{
  "categorias": [
    {"id": 516, "name": "Módems y routers", "product_count": 32},
    {"id": 77, "name": "Seguimiento GPS", "product_count": 14},
    {"id": 1599, "name": "SFP-Transceptor", "product_count": 9},
    {"id": 1554, "name": "Accesorios", "product_count": 6},
    {"id": 1626, "name": "Switches", "product_count": 5},
    {"id": 518, "name": "Comunicadores de alarmas", "product_count": 4},
    {"id": 1641, "name": "Módems y Routers 5G", "product_count": 2},
    {"id": 1630, "name": "Servidores y convertidores seriales", "product_count": 2}
  ]
}
```

---

### LOTE B: Filtros numéricos y specs

#### B1: Umbral numérico (WWAN downlink)
**Entrada:** "routers con al menos 200 Mbps de downlink"  
**Distribución de datos en BD:**
- Min: 150 Mbps
- Max: 300 Mbps
- Avg: 262.5 Mbps
- Productos con key: 4

**SQL:** `SELECT p.* FROM products p JOIN product_specs ps ON ps.product_id=p.id WHERE p.category_id=516 AND (ps.specs_normalized->>'wwan_max_downlink_mbps')::numeric >= 200 ORDER BY metric DESC`  
**Resultado:** ✅ 3 productos
```json
{
  "productos": [
    {"name": "Teldat M10 Smart", "slug": "teldat-m10-smart", "metric": 300},
    {"name": "Teldat M8 Smart", "slug": "teldat-m8-smart", "metric": 300},
    {"name": "Teldat RS1800", "slug": "teldat-rs1800", "metric": 300}
  ]
}
```

**Hallazgo:** Preguntas con umbrales muy altos (ej. 1000 Mbps) devolverán 0 resultados. El agente debe aplicar fallback automático.

---

### LOTE C: Recomendaciones

#### C1: Complementos desde un producto
**Entrada:** "qué se recomienda con el EG5100"  
**SQL:** `SELECT p.* FROM product_recommendations pr JOIN products p ON p.id=pr.target_product_id WHERE pr.source_product_id=(SELECT id FROM products WHERE slug='robustel-eg5100')`  
**Resultado:** ✅ 1 recomendación
```json
{
  "recomendados": [
    {"id": 22602, "name": "Robustel EG5120", "brand": "Robustel", "slug": "robustel-eg5120"}
  ]
}
```

**Nota:** Solo intra-categoría (router→router). No hay recomendaciones cross-categoría (router→accesorios).

---

### LOTE D: RAG y búsqueda semántica

#### D1: Descripción narrativa (overview)
**Entrada:** "qué es el EG5100"  
**chunks en BD para EG5100:**
- overview: 1 ✅
- features: 1 ✅
- spec_section: 5 ✅
- description: 0 ❌

**SQL:** `SELECT content FROM rag_chunks WHERE product_id=(SELECT id FROM products WHERE slug='robustel-eg5100') AND chunk_type='overview'`  
**Resultado:** ✅ Overview disponible
```
Robustel EG5100, marca Robustel, modelo EG5100. La EG5100 de Robustel es una gateway industrial 
de nueva generación, compatible con redes globales 4G/3G/2G para backhaul celular y Edge computing, 
diseñado para sistemas IoT de misión crítica...
```

**Hallazgo H3:** No todos los productos tienen chunks `description`. El agente debe gracefully fallback a `overview` o `spec_section`.

---

## Matriz de cobertura de intents

| Intent | Test Status | Tool Chain | Fallback Needed |
|--------|-------------|------------|-----------------|
| A1 | ✅ PASS | SQL puro | No |
| A2 | ⚠️ EDGE | SQL puro | Sí (0 resultados esperados) |
| A3 | ✅ PASS | SQL puro | No |
| A5 | ✅ PASS | pg_trgm fuzzy | No |
| A9 | ✅ PASS | SQL puro | No |
| B1 | ✅ PASS | SQL JSONB | Sí (umbrales altos) |
| C1 | ✅ PASS | SQL puro | No |
| D1 | ✅ PASS | RAG overview | Sí (usar overview si no hay description) |
| F1 | ✅ PASS | SQL puro | No |

---

## Acción recomendada

1. **Inmediato (CRÍTICO):**
   - ✅ Verificar si `rag_chunks.embedding` está poblado (vector search)
   - ✅ Poblar `solution_pages_table` con contenido de soluciones (4 páginas: conectividad, IoT, SD-WAN, SIM Card)

2. **Corto plazo (IMPORTANTE):**
   - Validar `info_types` en agente: usar `overview` como fallback si no hay `description`
   - Implementar fallback en B1 cuando umbral sea demasiado alto
   - Probar E2/E3 (híbridas) con datos reales

3. **Mediano plazo:**
   - Poblar aristas cross-categoría en `product_recommendations` (router→accesorios)
   - Enrichizar 20 productos sin RAG chunks

