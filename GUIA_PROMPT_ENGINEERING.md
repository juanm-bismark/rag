La idea central es esta: un prompt “correcto” no es el que suena mejor, sino el que produce resultados consistentes contra casos de prueba representativos. Google lo plantea como un proceso iterativo de diseño y refinamiento, y OpenAI recomienda definir qué significa “excelente”, medirlo y mejorar sobre esa base.
1. Documentación oficial recomendada
Fuente	Para qué sirve	Uso recomendado
OpenAI – Prompt guidance	Buenas prácticas para estructurar prompts, definir objetivos, criterios de éxito, reglas de decisión, instrucciones de tools y condiciones de parada. OpenAI recomienda prompts orientados al resultado y evitar reglas absolutas salvo que sean invariantes reales.	Base principal para prompts de producción con modelos OpenAI.
OpenAI – Function calling / tool calling	Explica cómo conectar modelos con funciones, APIs, datos externos y acciones de aplicación. Define el flujo: modelo recibe tools, decide llamar, la app ejecuta, devuelve output, y el modelo responde o sigue llamando tools.	Imprescindible para diseñar buenas tools.
OpenAI – Using tools	Resume los tipos de tools disponibles: web search, file search, function calling, MCP, tool search, etc.	Útil para decidir si necesitas tool propia, tool integrada o MCP.
OpenAI – Structured Outputs	Diferencia entre function calling para conectar con acciones/datos y structured outputs para controlar el formato de respuesta. También advierte que JSON mode no garantiza esquema; para eso conviene Structured Outputs o validación/reintentos.	Úsalo cuando necesites respuestas en JSON, formularios, extracción o integración backend.
OpenAI – Tool search	Recomienda cargar tools dinámicamente cuando hay muchas, agruparlas por namespaces o MCP servers y mantener cada namespace con menos de 10 funciones cuando sea posible.	Útil si tu agente tiene decenas o cientos de tools.
OpenAI – Agent evals	Recomienda evaluar agentes con traces, graders, datasets y eval runs. Los traces permiten revisar llamadas a modelos, tool calls, guardrails y handoffs; luego se pasa a datasets para repetibilidad.	Base para evaluar prompts y agentes con tools.
Google Gemini – Prompt design strategies	Introducción clara a diseño de prompts: instrucciones claras, contexto, ejemplos, formato y refinamiento iterativo.	Buena referencia neutral para fundamentos.
Google Gemini – Function calling	Explica function calling como puente entre lenguaje natural y acciones/datos reales: tomar acciones, aumentar conocimiento y extender capacidades con herramientas.	Buena comparación con OpenAI para diseño de tools.
Anthropic – Prompt engineering / best practices	Cubre claridad, ejemplos, estructuración XML, role prompting, pensamiento y prompt chaining. Anthropic también ofrece tutoriales interactivos.	Muy útil para patrones de prompts largos y agentes.
Anthropic – Tool use	Explica que Claude decide cuándo llamar una tool según la solicitud del usuario y la descripción de la tool, y devuelve una llamada estructurada que ejecuta la aplicación o Anthropic.	Buena referencia para escribir descripciones de tools.
Microsoft Azure OpenAI – Prompt engineering	Guía conceptual de prompts en Azure OpenAI; útil para fundamentos y ejemplos empresariales. Microsoft advierte que algunas técnicas clásicas no son recomendadas para modelos de razonamiento como GPT-5 y serie o.	Útil si trabajas en stack Azure/Microsoft Foundry.
OWASP – LLM Prompt Injection Prevention Cheat Sheet	Define prompt injection, tipos de ataque y defensas: separación de datos/instrucciones, least privilege, monitoreo, guardrails y testing.	Obligatorio si tus tools ejecutan acciones o acceden a datos sensibles.
NCSC – Prompt injection is not SQL injection	Recomienda tratar los LLMs como “inherently confusable deputy”: no asumir que la prompt injection se elimina totalmente, sino reducir impacto con diseño, límites y controles determinísticos.	Referencia fuerte para seguridad de agentes con tools.
2. Referencias académicas buenas
Paper / recurso	Qué aporta
The Prompt Report: A Systematic Survey of Prompting Techniques	Taxonomía amplia de técnicas de prompting: 33 términos, 58 técnicas para LLMs y 40 para otras modalidades. Útil como mapa general del campo.
Chain-of-Thought Prompting Elicits Reasoning in Large Language Models	Paper clásico sobre uso de pasos intermedios para mejorar tareas de razonamiento complejo, especialmente aritmética, sentido común y razonamiento simbólico.
ReAct: Synergizing Reasoning and Acting in Language Models	Introduce el patrón de razonar y actuar de forma intercalada; muy relevante para agentes que usan herramientas, búsqueda, APIs o entornos externos.
Toolformer: Language Models Can Teach Themselves to Use Tools	Referencia clave sobre modelos que aprenden cuándo llamar APIs, qué argumentos pasar y cómo incorporar resultados de herramientas.
PromptBench: A Unified Library for Evaluation of Large Language Models	Biblioteca y marco para evaluar LLMs; útil para robustez, benchmarks y comparación sistemática. La versión JMLR es una buena referencia académica.
HELM – Holistic Evaluation of Language Models	Marco de Stanford para evaluación holística: escenarios, métricas, transparencia, cobertura, limitaciones y riesgos.
LM Evaluation Harness – EleutherAI	Framework usado ampliamente para evaluar modelos con tareas reproducibles y métricas comparables.
G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment	Framework de evaluación con LLM como juez; útil para evaluar resúmenes, diálogo y tareas generativas, aunque el propio paper advierte sesgos hacia textos generados por LLMs.
A Survey on LLM-as-a-Judge	Revisión sobre cómo construir evaluadores LLM más fiables, incluyendo consistencia, sesgos y adaptación a distintos escenarios.
Formalizing and Benchmarking Prompt Injection Attacks and Defenses	Benchmark formal para ataques y defensas de prompt injection; relevante si tus prompts usan RAG, navegador, documentos externos o tools con privilegios.
3. Recomendaciones prácticas para prompts
Un buen prompt de producción debería tener, como mínimo, objetivo, contexto, límites, criterios de éxito, formato de salida y reglas de decisión. OpenAI recomienda describir el destino y los criterios, no sobreprescribir cada paso salvo que el orden importe; también recomienda usar reglas absolutas solo para invariantes reales, como seguridad, campos obligatorios o acciones prohibidas.
Estructura recomendada:
# Objetivo
Qué debe lograr el modelo y para quién.

# Contexto
Información confiable que debe usar.

# Datos del usuario o datos externos
Información que puede contener errores, instrucciones maliciosas o contenido no confiable.

# Criterios de éxito
Qué debe cumplir una buena respuesta.

# Reglas de decisión
Cuándo responder, cuándo pedir aclaración, cuándo abstenerse y cuándo usar tools.

# Reglas de tools
Qué tool usar, cuándo usarla, cuándo no usarla, qué hacer si faltan datos y qué confirmar antes de acciones sensibles.

# Formato de salida
Estructura exacta: JSON, tabla, bullets, campos requeridos, idioma, tono, extensión.

# Verificación
Comprobar consistencia, fuentes, formato, campos obligatorios y posibles riesgos antes de finalizar.
Para prompts largos, OpenAI recomienda cuidar la organización: en contextos largos, colocar instrucciones al inicio y también al final puede funcionar mejor que ponerlas solo arriba o solo abajo.
No conviene evaluar un prompt con uno o dos ejemplos favorables. Conviene crear un set de casos representativos: casos normales, casos límite, entradas ambiguas, entradas maliciosas, información incompleta, errores de tool, respuestas largas y formatos estrictos. OpenAI recomienda crear evals para saber si un cambio de prompt mejora o empeora el caso de uso concreto, y volver a correr evals después de cada cambio pequeño.
4. Recomendaciones prácticas para tools
Una buena tool debe tener nombre específico, descripción operacional, esquema estricto de parámetros, límites claros, validación externa y control de permisos. OpenAI recomienda describir la funcionalidad en la definición de la tool y explicar en el prompt cuándo y cómo debe usarse.
Ejemplo de especificación limpia:
{
  "type": "function",
  "name": "get_customer_orders",
  "description": "Read-only. Retrieve recent orders for a verified customer. Use only after the customer identity has been verified.",
  "parameters": {
    "type": "object",
    "properties": {
      "customer_id": {
        "type": "string",
        "description": "Verified internal customer identifier."
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of orders to return. Use 10 unless the user asks for fewer.",
        "minimum": 1,
        "maximum": 20
      }
    },
    "required": ["customer_id"],
    "additionalProperties": false
  }
}
Reglas para tools:
Una tool debe hacer una cosa clara. Evita tools genéricas como do_action, query_system o manage_user; son difíciles de controlar y evaluar.
Separa lectura y escritura. get_invoice no debería también poder modificar facturas.
Usa permisos mínimos. La tool solo debe acceder a lo estrictamente necesario. OWASP y NCSC insisten en reducir el impacto si el modelo es manipulado por prompt injection.
Confirma acciones sensibles. Cancelar pedidos, enviar emails, mover dinero, borrar datos o cambiar permisos debe requerir confirmación explícita y verificable.
Valida todo fuera del modelo. El modelo puede proponer una llamada, pero tu backend debe validar identidad, permisos, tipos, rangos, estados y reglas de negocio.
Trata outputs externos como datos, no instrucciones. Resultados de web, RAG, emails, PDFs o páginas pueden contener prompt injection indirecta. OWASP describe ataques donde contenido externo manipula el comportamiento del sistema.
Usa schemas estrictos y structured outputs cuando el formato importe. JSON válido no basta si necesitas un esquema concreto; OpenAI recomienda Structured Outputs o validación con reintentos.
Agrupa muchas tools por namespaces o MCP. Si tienes muchas funciones, OpenAI recomienda tool search y namespaces con descripciones claras para reducir tokens y cargar solo tools relevantes.
5. Cómo evaluar prompts y tools
Evalúa en tres niveles:
Nivel	Qué medir
Respuesta final	Exactitud, completitud, groundedness, formato, idioma, tono, ausencia de invenciones.
Uso de tools	Si eligió la tool correcta, si no llamó tools innecesarias, si los argumentos fueron válidos, si respetó permisos, si manejó errores.
Flujo completo del agente	Éxito end-to-end, número de tool calls, latencia, coste, seguridad, recuperaciones ante fallos, comportamiento ante prompt injection.
Para agentes, OpenAI recomienda empezar con traces cuando todavía estás depurando comportamiento, porque un trace captura llamadas al modelo, tool calls, guardrails y handoffs. Cuando ya sabes qué significa “bueno”, pasas a datasets y eval runs repetibles para comparar prompts, cambios de tools o modelos.
Métricas concretas que deberías registrar:
task_success_rate
tool_selection_accuracy
tool_argument_validity
schema_validity_rate
unnecessary_tool_call_rate
missing_tool_call_rate
groundedness_score
hallucination_rate
clarification_needed_but_not_asked_rate
unsafe_action_attempt_rate
prompt_injection_resistance
latency
cost_per_successful_task
Puedes usar LLM-as-a-judge para evaluaciones cualitativas con rúbricas, pero no como única fuente de verdad. G-Eval muestra utilidad para alinear evaluación automática con juicio humano en tareas generativas, pero también señala sesgos hacia textos generados por LLMs; el survey de LLM-as-a-Judge recomienda diseñar estos jueces con cuidado para controlar consistencia y sesgos.
6. Orden de lectura recomendado
OpenAI Prompt guidance + Google Prompt design strategies para fundamentos de prompts.
OpenAI Function calling + Anthropic Tool use + Google Function calling para diseño de tools.
OpenAI Agent evals + OpenAI evals framework para evaluación práctica.
OWASP Prompt Injection Cheat Sheet + NCSC Prompt injection is not SQL injection para seguridad.
The Prompt Report, ReAct, Toolformer, PromptBench, HELM para base académica.
