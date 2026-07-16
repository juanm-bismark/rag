# Comparación normalización local vs backup (GPT producción)

## granite4:micro-h (tag: exp2)

- Productos: 10 (ok=8, review=2)
- Cobertura de claves del backup: 97/361 = **26.9%**
- Valores idénticos en claves comunes: 56/97 = **57.7%**
- **Eje aritmético** (claves numéricas comunes): 44/65 = **67.7%**
- Claves emitidas vs backup: 138 vs 361

| producto | slug | cobertura | exactitud | solo backup | solo sim |
|---|---|---|---|---|---|
| 9987 | robustel-r2110 | 8/77 claves del backup presentes | 6/8 valores idénticos | solo_backup=['absolute_max_current_a', 'application_framework', 'bluetooth_antenna_connector', 'bluetooth_antennas_count', 'certifications', 'digital_input_absolute_max_voltage_v', 'digital_input_connector', 'digital_inputs_count'] | solo_sim=['antenna_count', 'antenna_count_wifi', 'bluetooth_antenna_count', 'connector_type', 'connector_type_bluetooth', 'connector_type_wifi', 'digital_io_connector_type', 'environmental_certifications'] |
| 18264 | galileosky-10-4g | 8/72 claves del backup presentes | 4/8 valores idénticos | solo_backup=['_signal_type_notes', 'analog_discrete_and_pulse_inputs_count', 'analog_input_resolution_v', 'analog_input_voltage_max_v', 'analog_input_voltage_min_v', 'battery_internal_lifetime_max_years', 'body_material', 'can_count'] | solo_sim=['gnss_update_rate_hz', 'position_accuracy_sbas_m', 'receiver_sensitivity_tracking_dbm', 'sim_card_type', 'warm_start_time_max_s'] |
| 15206 | robustel-r1520-4l | 10/71 claves del backup presentes | 6/10 valores idénticos | solo_backup=['_rtc_notes', 'absolute_max_current_a', 'analog_input_connector', 'analog_input_current_max_a', 'analog_input_current_min_a', 'analog_input_signal_definition', 'analog_input_voltage_max_v', 'analog_input_voltage_min_v'] | solo_sim=['dimensions_mm', 'flash_gb', 'power', 'power_supply_frequency_max_hz', 'power_supply_frequency_min_hz', 'ram_gb', 'vpn_features'] |
| 18816 | suntech-st8310-4g | 14/51 claves del backup presentes | 9/14 valores idénticos | solo_backup=['accelerometer_features', 'active_current_max_a', 'active_current_min_a', 'antenna_types', 'battery_chemistry', 'battery_voltage_v', 'cellular_2g_bands', 'cold_start_time_max_s'] | solo_sim=['active_current_a', 'input_voltage_v', 'power_consumption_average_w', 'sleep_current_a'] |
| 17915 | teldat-m10-smart | REVIEW | invalid_json |  |  |
| 18853 | lynkworld-lw4g-5e | 11/38 claves del backup presentes | 8/11 valores idénticos | solo_backup=['accelerometer_features', 'battery_chemistry', 'battery_voltage_v', 'cellular_2g_bands', 'cold_start_time_max_s', 'digital_inputs_count', 'digital_outputs_count', 'glonass_l1_frequency_mhz'] | solo_sim=['_signal_type_notes'] |
| 22602 | robustel-eg5120 | REVIEW | invalid_json |  |  |
| 16884 | eon-transceptor-sfp-gsx-1g-10km | 10/10 claves del backup presentes | 6/10 valores idénticos | solo_backup=[] | solo_sim=[] |
| 14874 | antena-magnetica-3dbi-1-5-y-3mts | 16/16 claves del backup presentes | 9/16 valores idénticos | solo_backup=[] | solo_sim=['cellular_band_3_max_mhz', 'cellular_band_3_min_mhz', 'cellular_band_4_max_mhz', 'cellular_band_4_min_mhz', 'cellular_band_5_max_mhz', 'cellular_band_5_min_mhz'] |
| 14885 | antena-magnetica-7-dbi-3-mts | 20/26 claves del backup presentes | 8/20 valores idénticos | solo_backup=['cellular_band_4_max_mhz', 'cellular_band_4_min_mhz', 'cellular_band_6_max_mhz', 'cellular_band_6_min_mhz', 'cellular_band_7_max_mhz', 'cellular_band_7_min_mhz'] | solo_sim=[] |
