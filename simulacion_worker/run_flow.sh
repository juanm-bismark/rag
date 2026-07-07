#!/bin/bash
# run_flow.sh — ejecuta TODO el flujo de simulación del worker y guarda resultados.
#
#   ./run_flow.sh            → corre todo en background (nohup) y deja corrida.log
#   ./run_flow.sh --check    → solo verifica entorno (no lanza nada)
#   ./run_flow.sh --fg       → corre en primer plano (uso interno de nohup)
#
# Hace, en orden:
#   1. valida python3, Ollama y el prompt
#   2. genera input_productos.json + backup_normalizado.json si faltan (Supabase)
#   3. normaliza los 71 productos: qwen2.5:3b completo, luego granite4:micro-h
#      (8 categorías en paralelo, reanudable si se corta)
#   4. exporta normalizado_<modelo>.json (misma forma que el backup)
#   5. genera comparacion_normalizacion.md (vs backup y entre modelos)
#
# Config opcional por variables de entorno:
#   MODELOS=qwen2.5:3b,granite4:micro-h   PARALELO=4   OLLAMA_HOST_FLOW=http://IP:11434
set -u
cd "$(dirname "$0")"

MODELOS="${MODELOS:-qwen2.5:3b,granite4:micro-h}"
PARALELO="${PARALELO:-4}"

# --- host: env explícito > .env del repo (Mac) > localhost (servidor) ---
HOST="${OLLAMA_HOST_FLOW:-}"
if [ -z "$HOST" ] && [ -f ../.env ]; then
  HOST=$(grep -E "^OLLAMA_REMOTE_HOST=" ../.env | cut -d= -f2 | tr -d '"' | tr -d "'")
fi
HOST="${HOST:-localhost:11434}"
case "$HOST" in http*) ;; *) HOST="http://$HOST";; esac
echo "$HOST" | grep -qE ':[0-9]+$' || HOST="$HOST:11434"

# --- prompt: local > repo > home ---
PROMPT=""
for cand in ./PROMPT_NORMALIZACION.md ../PROMPT_NORMALIZACION.md "$HOME/PROMPT_NORMALIZACION.md"; do
  [ -f "$cand" ] && PROMPT="$cand" && break
done

verificar() {
  local fallo=0
  command -v python3 >/dev/null || { echo "✗ python3 no encontrado"; fallo=1; }
  [ -n "$PROMPT" ] && echo "✓ prompt: $PROMPT" || { echo "✗ PROMPT_NORMALIZACION.md no encontrado (ponlo junto al script)"; fallo=1; }
  if curl -s --max-time 5 "$HOST/api/version" >/dev/null; then
    echo "✓ Ollama responde en $HOST"
    for m in $(echo "$MODELOS" | tr ',' ' '); do
      if curl -s "$HOST/api/tags" | grep -q "\"$m\""; then echo "✓ modelo $m disponible"
      else echo "✗ modelo $m NO está en el servidor"; fallo=1; fi
    done
  else
    echo "✗ Ollama NO responde en $HOST"; fallo=1
  fi
  [ -f input_productos.json ] && echo "✓ input_productos.json ($(python3 -c "import json;d=json.load(open('input_productos.json'));print(sum(len(c['productos']) for c in d['categorias']),'productos')" 2>/dev/null))" \
    || echo "· input_productos.json falta (se generará desde Supabase si hay ../.env)"
  [ -f backup_normalizado.json ] && echo "✓ backup_normalizado.json" || echo "· backup_normalizado.json falta"
  return $fallo
}

if [ "${1:-}" = "--check" ]; then
  verificar; exit $?
fi

if [ "${1:-}" != "--fg" ]; then
  verificar || { echo; echo "Corrige lo anterior y vuelve a correr."; exit 1; }
  nohup "$0" --fg >> corrida.log 2>&1 &
  echo
  echo "▶ Flujo corriendo en background (PID $!)"
  echo "  Ver avance:      tail -f $(pwd)/corrida.log"
  echo "  Ver comparación: cat $(pwd)/comparacion_normalizacion.md (al final o parcial)"
  exit 0
fi

echo "════════ RUN FLOW $(date '+%F %T') ════════"
echo "host=$HOST | modelos=$MODELOS | paralelo=$PARALELO | prompt=$PROMPT"

if [ ! -f input_productos.json ] || [ ! -f backup_normalizado.json ]; then
  echo "── generando archivos de entrada desde Supabase ──"
  python3 crear_input.py || { echo "ERROR creando entrada"; exit 1; }
fi

# si interrumpen la corrida, comparar igual con lo acumulado
trap 'echo "── interrumpido: comparando lo acumulado ──"; python3 simulador_worker.py comparar --modelos "$MODELOS"; exit 130' INT TERM

echo "── normalizando (reanudable; primero un modelo, luego el otro) ──"
python3 simulador_worker.py correr --modelos "$MODELOS" --host "$HOST" \
  --prompt "$PROMPT" --paralelo "$PARALELO"

echo "── comparando contra backup y entre modelos ──"
python3 simulador_worker.py comparar --modelos "$MODELOS"

echo "════════ FLUJO COMPLETO $(date '+%F %T') ════════"
echo "Resultados guardados:"
ls -1 normalizado_*.json comparacion_normalizacion.md resultados_*.jsonl contexto_*.json 2>/dev/null | sed 's/^/  /'
