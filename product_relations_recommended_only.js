// ============================================================
// Product Relations - Nodo Code n8n
// Entrada esperada: items con productos en item.json
// Salida: { product_relations, stats }
//
// Este nodo genera UNICAMENTE relaciones:
//   relation_type = "recommended_product"
//
// Direccion de la relacion:
//   source_product_id -> target_product_id
//   producto actual   -> producto recomendado por ese producto
//
// Ejemplo:
//   Si el producto A tiene:
//     productos_recomendados: ["Producto B"]
//
//   Entonces se crea:
//     source_product_id = A.id
//     target_product_id = B.id
//     relation_type     = "recommended_product"
//
// Importante:
//   La relacion es dirigida. Este codigo NO crea automaticamente B -> A.
//   Si tambien debe existir B -> A, B debe traer A en su propio arreglo
//   productos_recomendados.
//
// Los matches se resuelven usando slug / aliases,
// pero la relacion final se guarda usando IDs de producto.
// ============================================================

function normalizeId(text) {
  return String(text || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

function cleanRelatedLabel(text) {
  return String(text || '')
    .replace(/\([^)]*\)/g, ' ')
    .replace(/["“”']/g, ' ')
    .replace(/[–—]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
}

function stripRelationNoise(text) {
  let v = cleanRelatedLabel(text)
  let prev = null

  const leadArticleRx = /^(?:al|a|el|la|los|las|un|una|unos|unas)\s+/i
  const leadDeviceRx = /^(?:equipo|modelo|dispositivo|router|gateway|pasarela|switch|tracker|rastreador|comunicador|modem|módem|antena|accesorio)\s+/i

  while (v && v !== prev) {
    prev = v
    v = v
      .replace(leadArticleRx, '')
      .replace(leadDeviceRx, '')
      .trim()
  }

  return v
}

function candidateForms(text) {
  const cleaned = stripRelationNoise(text)

  const forms = new Set([
    text,
    cleaned,
    cleaned.replace(/\bserie\b/gi, '').replace(/\bmodelo\b/gi, '').replace(/\s+/g, ' ').trim(),
    cleaned.replace(/[,:;]+$/g, '').trim(),
    cleaned.replace(/[–—]/g, '-').trim(),
    cleaned.replace(/\s+/g, '-').trim(),
  ])

  return Array.from(forms).filter(Boolean)
}

function normalizeLoose(text) {
  return String(text || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[–—]/g, '-')
    .replace(/<=|>=|<|>|√/g, ' ')
    .replace(/(\d)\s*dbi\b/g, '$1 dbi')
    .replace(/(\d)\s*mts?\b/g, '$1 mts')
    .replace(/\bmetros?\b/g, 'mts')
    .replace(/\by\b/g, ' ')
    .replace(/\bo\b/g, ' ')
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function buildAliasForms(p) {
  const aliases = new Set();

  [
    p.slug,
    p.name,
    p.brand,
    p.model,
    [p.brand, p.model].filter(Boolean).join(' '),
    ...(Array.isArray(p.search_aliases) ? p.search_aliases : []),
  ].forEach(v => {
    if (v) aliases.add(String(v).trim())
  })

  const out = new Set()

  for (const alias of aliases) {
    const clean = cleanRelatedLabel(alias)
    if (!clean) continue

    out.add(clean)
    out.add(stripRelationNoise(clean))
    out.add(normalizeLoose(clean))
    out.add(normalizeId(clean))
  }

  return Array.from(out).filter(Boolean)
}

function hasValidId(p) {
  return p && p.id !== undefined && p.id !== null
}

const products = $input
  .all()
  .map(i => i.json)
  .filter(Boolean)

const slugSet = new Set(products.map(p => p.slug).filter(Boolean))

const productBySlug = {}
const aliasToSlug = {}

for (const p of products) {
  if (p.slug) {
    productBySlug[p.slug] = p
  }

  for (const alias of buildAliasForms(p)) {
    const normId = normalizeId(alias)
    const normLoose = normalizeLoose(alias)

    if (normId) aliasToSlug[normId] = p.slug
    if (normLoose) aliasToSlug[normLoose] = p.slug
  }
}

function resolveSlug(text) {
  for (const form of candidateForms(text)) {
    const normId = normalizeId(form)
    const normLoose = normalizeLoose(form)

    if (slugSet.has(normId)) return normId
    if (aliasToSlug[normId]) return aliasToSlug[normId]
    if (aliasToSlug[normLoose]) return aliasToSlug[normLoose]
  }

  return null
}

const relations = []
const seenRelations = new Set()

let skippedMissingSourceId = 0
let skippedUnresolvedTarget = 0
let skippedMissingTargetId = 0
let skippedSelfRelation = 0
let skippedDuplicateRelation = 0

for (const p of products) {
  // El producto que se esta procesando es siempre el origen de la flecha.
  // Si no tiene ID, no se puede crear source_product_id.
  if (!hasValidId(p)) {
    skippedMissingSourceId++
    continue
  }

  const recommendedProducts = Array.isArray(p.productos_recomendados)
    ? p.productos_recomendados
    : []

  for (const rec of recommendedProducts) {
    // rec es el texto/slug/alias del producto recomendado.
    // Ese producto sera el destino de la flecha.
    const targetSlug = resolveSlug(rec)

    if (!targetSlug) {
      skippedUnresolvedTarget++
      continue
    }

    if (targetSlug === p.slug) {
      skippedSelfRelation++
      continue
    }

    const targetProduct = productBySlug[targetSlug]

    if (!hasValidId(targetProduct)) {
      skippedMissingTargetId++
      continue
    }

    const key = `${p.id}|recommended_product|${targetProduct.id}`

    if (seenRelations.has(key)) {
      skippedDuplicateRelation++
      continue
    }

    seenRelations.add(key)

    relations.push({
      source_product_id: p.id,
      target_product_id: targetProduct.id,
      relation_type: 'recommended_product',
      weight: 0.7,
    })
  }
}

return [
  {
    json: {
      product_relations: relations,
      stats: {
        total_products: products.length,
        total_relations: relations.length,
        skipped_missing_source_id: skippedMissingSourceId,
        skipped_unresolved_target: skippedUnresolvedTarget,
        skipped_missing_target_id: skippedMissingTargetId,
        skipped_self_relation: skippedSelfRelation,
        skipped_duplicate_relation: skippedDuplicateRelation,
      },
    },
  },
]
