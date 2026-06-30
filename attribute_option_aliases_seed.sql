-- =============================================================================
-- Seed de attribute_option_aliases  (diccionario de sinónimos NLU)
-- =============================================================================
-- Mapea términos en lenguaje natural -> attribute_option correcta. Lo consume
-- get_catalog_metadata(type=resolve_alias) y la resolución de attribute_filters.
-- Proceso/gobernanza: ver ARQUITECTURA_RAG.md §7.1. Alias SIEMPRE en minúscula
-- (resolve_alias baja el término con lower(); pg_trgm es case-sensitive).
--
-- Estado: 226 alias sobre 76 opciones (revisado 2026-06-23). Idempotente.
--
-- Decisiones de desambiguación:
--  - "movil"/"móvil"/"celular"/"4g"/"lte" -> pa_red-celular (red móvil), NO pa_uso:movil.
--    pa_uso:movil (uso vehicular) usa 'vehicular'/'flota'/'camion'/'vehiculo'/'bus'.
--  - "wireless" -> pa_wifi:si (NO la marca sierra-wireless).
--  - Opciones "No" de booleanos: SIN alias (negación la maneja el LLM). Antes se
--    probaron 'sin lan/wan/serial/wifi' pero contaminaban el término positivo
--    ("serial" devolvía también :no) -> se removieron.
--  - pa_red:n-a (N/A) se deja sin alias a propósito.
--  - NO se incluyen vpn / dual sim / poe: NO son opciones de atributo, son specs
--    (vpn_features, sim_slots_count, ethernet_poe_ports_count). El agente los
--    resuelve por filter_products_by_specs, no por attribute_filters.
-- =============================================================================

INSERT INTO attribute_option_aliases (attribute_option_id, alias) VALUES
  -- pa_1-wire
  (498, '1-wire'), (498, '1 wire'), (498, 'onewire'),
  -- pa_2g-3g
  (1586, '2g/3g'), (1586, '2g-3g'), (1586, '2g 3g'),
  -- pa_4g-lte
  (1587, '4g lte'), (1587, '4g/lte'), (1587, 'lte'),
  -- pa_audio-en-cabina
  (506, 'audio en cabina'), (506, 'audio'), (506, 'microfono'), (506, 'manos libres'),
  -- pa_can-bus
  (504, 'can'), (504, 'can bus'), (504, 'canbus'), (504, 'can-bus'), (504, 'j1939'),
  -- pa_capacidad
  (1566, '1g'), (1566, '1 gbps'), (1566, '1gbe'), (1566, 'gigabit'),
  (1567, '10g'), (1567, '10 gbps'), (1567, '10gbe'),
  -- pa_conductas-de-manejo
  (497, 'conductas de manejo'), (497, 'estilo de manejo'), (497, 'comportamiento de conduccion'),
  -- pa_dbi
  (1584, '3 dbi'), (1584, '3dbi'),
  (1645, '3.9 dbi'), (1645, '3.9dbi'),
  (1581, '5 dbi'), (1581, '5dbi'),
  (1580, '7 dbi'), (1580, '7dbi'),
  (1582, '7 o 9 dbi'), (1582, '9 dbi'),
  (1585, '15 dbi'), (1585, '15dbi'),
  -- pa_distancia-antena
  (1647, '1.5 m'), (1647, '1.5m'), (1647, 'cable 1.5 m'),
  (1600, '1.5 m o 3 m'),
  (1601, '3 m'), (1601, '3m'), (1601, 'cable 3 m'),
  -- pa_distancia-sfp
  (1572, '10 km'), (1572, '10km'),
  (1575, '20 km'), (1575, '20km'),
  (1574, '300 m'), (1574, '300m'),
  (1573, '40 km'), (1573, '40km'),
  (1571, '500 m'), (1571, '500m'),
  -- pa_fabricante
  (1612, 'maipu'),
  (484, 'robustel'),
  (485, 'sierra'), (485, 'sierra wireless'), (485, 'airlink'),
  (486, 'teldat'),
  -- pa_fabricante-gps
  (1628, 'galileosky'), (1628, 'galileo sky'), (1628, 'galileo'),
  (1639, 'lynkworld'), (1639, 'lynk world'),
  (1627, 'suntech'), (1627, 'sun tech'),
  -- pa_fabricantetrans
  (755, '3i'), (755, '3i corporation'),
  (756, 'netio'),
  -- pa_factor-de-forma
  (1593, 'sfp'), (1593, 'fibra optica'), (1593, 'fibra'), (1593, 'gbic'),
  (1594, 'sfp+'), (1594, 'sfp plus'),
  -- pa_i-o
  (543, 'i/o'), (543, 'io'), (543, 'entradas y salidas'), (543, 'entradas/salidas'), (543, 'gpio'),
  -- pa_lan
  (545, 'lan'), (545, 'ethernet'), (545, 'puerto lan'), (545, 'rj45'),
  -- pa_modo
  (1592, 'direccional'), (1592, 'antena direccional'), (1592, 'yagi'),
  (1589, 'multimodo'), (1589, 'multimode'), (1589, 'mmf'), (1589, 'fibra multimodo'),
  (1591, 'omni'), (1591, 'omnidireccional'), (1591, 'antena omnidireccional'),
  (1590, 'monomodo'), (1590, 'single mode'), (1590, 'smf'), (1590, 'fibra monomodo'),
  -- pa_obd-ii
  (502, 'obd'), (502, 'obd2'), (502, 'obd ii'), (502, 'obdii'), (502, 'obd-ii'),
  -- pa_portatil
  (494, 'portatil'), (494, 'portable'), (494, 'portátil'),
  -- pa_proteccion-ip-65
  (492, 'ip65'), (492, 'ip 65'), (492, 'ip67'), (492, 'ip68'), (492, 'intemperie'),
  (492, 'resistente al agua'), (492, 'a prueba de agua'), (492, 'impermeable'),
  (492, 'sumergible'), (492, 'outdoor'), (492, 'proteccion ip'),
  -- pa_puertos-seriales
  (548, 'serial'), (548, 'puerto serial'), (548, 'puertos seriales'), (548, 'rs485'),
  -- pa_red
  (568, '2g'),
  (569, '3g'),
  (1650, '4g cat1'), (1650, 'lte cat1'), (1650, 'cat1'), (1650, 'cat 1'),
  (571, 'lte-m'), (571, 'nb-iot'), (571, 'cat-m'), (571, 'catm'), (571, 'nbiot'),
  -- pa_red-celular
  (549, '2g/3g/4g'),
  (1631, '2g/4g'),
  (551, '3g/4g'), (551, '3g 4g'), (551, '4g'), (551, 'lte'), (551, 'celular'), (551, 'movil'), (551, 'móvil'), (551, 'datos moviles'),
  (1640, '5g'), (1640, '5 g'),
  (550, 'lora'), (550, 'lorawan'), (550, 'lpwan'),
  -- pa_red-transmisor
  (1607, '2g/4g transmisor'),
  (1606, '4g transmisor'),
  -- pa_sdwan
  (554, 'sdwan'), (554, 'sd-wan'), (554, 'sd wan'),
  -- pa_serial-rs232
  (500, 'rs232'), (500, 'rs-232'), (500, 'serial rs232'), (500, 'db9'),
  -- pa_software-de-gestion
  (556, 'alms'), (556, 'airlink management'), (556, 'airlink management service'),
  (557, 'cnm'), (557, 'cloud netmanager'), (557, 'cloud net manager'),
  (555, 'rcms'), (555, 'robustel cloud manager'), (555, 'robustel cloud manager service'),
  -- pa_software-transmisor
  (759, 'click manager'), (759, 'clickmanager'),
  (758, 'zeus'), (758, 'zeus nx'),
  -- pa_tipo-de-accesorio
  (1570, 'antena'),
  (1569, 'transceptor'), (1569, 'transceiver'),
  -- pa_tipo-de-antena
  (1648, 'logaritmica periodica'), (1648, 'log periodica'), (1648, 'antena logaritmica'),
  (1595, 'magnetica'), (1595, 'magnética'), (1595, 'antena magnetica'), (1595, 'iman'), (1595, 'base magnetica'),
  -- pa_tipo-de-conector
  (1649, 'n hembra'), (1649, 'n-hembra'), (1649, 'conector n'), (1649, 'n-female'), (1649, 'tipo n'), (1649, 'conector tipo n'),
  (1597, 'sma'), (1597, 'sma male'), (1597, 'sma macho'), (1597, 'conector sma'),
  -- pa_tipo-de-dispositivo
  (490, 'accesorio'),
  (491, 'equipo'), (491, 'dispositivo'),
  -- pa_transmision-de-fotos
  (509, 'transmision de fotos'), (509, 'fotos'), (509, 'camara'), (509, 'imagenes'),
  -- pa_uso
  (1643, 'corporativo'), (1643, 'corporativa'),
  (540, 'empresarial'), (540, 'empresa'), (540, 'negocio'), (540, 'pyme'),
  (537, 'industrial'), (537, 'rugerizado'), (537, 'uso rudo'), (537, 'robusto'), (537, 'planta'),
  (539, 'vehicular'), (539, 'flota'), (539, 'uso movil'), (539, 'camion'), (539, 'vehiculo'), (539, 'bus'),
  -- pa_wan
  (562, 'wan'), (562, 'puerto wan'),
  -- pa_wifi
  (564, 'wifi'), (564, 'wi-fi'), (564, 'inalambrico'), (564, 'inalámbrico'), (564, 'wlan'), (564, 'wireless')
ON CONFLICT (attribute_option_id, alias) DO NOTHING;
