/* =====================================================================
   matmas - 03: settings and route configuration (one row per source location)
   Replace the example folders, patterns and the SAP placeholders with the
   real values before the first run. Re-runnable (MERGE on the keys).
   ===================================================================== */
SET NOCOUNT ON;

/* ---- org-wide settings ------------------------------------------------ */
MERGE cfg.matmas_setting AS t
USING (VALUES
    ('onelake_connection',  N'FABRIC.AMCOR.ONELAKE.P2O',
                            N'IDMC connection, type Microsoft Fabric OneLake, workspace ws_p2o_intg_dev'),
    ('onelake_root',        N'lh_p2o_intg_dev/Files/erp_to_matmas',
                            N'Root of the MATMAS folders in lakehouse lh_p2o_intg_dev (same format as fi_P2O_000_BPDWFS_GR_to_OneLake, no leading slash)'),
    ('central_runtime_env', N'US.US02.01',
                            N'Agent group that runs the 4 mapping tasks and the OneLake move task')
) AS s (setting_name, setting_value, description)
ON t.setting_name = s.setting_name
WHEN MATCHED THEN
    UPDATE SET setting_value = s.setting_value,
               description   = s.description
WHEN NOT MATCHED THEN
    INSERT (setting_name, setting_value, description)
    VALUES (s.setting_name, s.setting_value, s.description);

/* ---- routes: one row per source location --------------------------------
   OneLake folders = onelake_root + /landing|archive|duplicate|error/ + onelake_folder
   (lakehouse folders: erp_to_matmas/landing/JDE, erp_to_matmas/landing/Vision, ...) */
MERGE cfg.matmas_route_config AS t
USING (VALUES
--   route_id,        erp_system, route_name,                 run_group, run_order, active_flag, runtime_environment,  source_connection,   source_directory,                         file_pattern,          onelake_folder, target_table,              load_operation, key_columns
    ('JDE_MATMAS',    'JDE',      N'JDE material master',     'DAILY',   10,        1,           N'US.US02.01',        N'LF_MATMAS_JDE',    N'D:\Interfaces\JDE\MATMAS\outbound',    N'JDE_MATMAS*.txt',    N'JDE',         N'jde_material_master',    'UPSERT',       N'erp_item_number,plant_code,supplier_number,supplier_part_number'),
    ('VISION_MATMAS', 'VISION',   N'Vision material master',  'DAILY',   20,        1,           N'US.AMCOR.01',       N'LF_MATMAS_VISION', N'D:\Interfaces\VISION\MATMAS\outbound', N'VISION_MATMAS*.txt', N'Vision',      N'vision_material_master', 'UPSERT',       N'erp_item_number,plant_code,supplier_number,supplier_part_number'),
    ('SAP_MATMAS',    'SAP',      N'SAP material master',     'DAILY',   30,        0,           N'<SAP_AGENT_GROUP>', N'LF_MATMAS_SAP',    N'<SAP agent folder>',                    N'SAP_MATMAS*.txt',    N'SAP',         N'sap_material_master',    'UPSERT',       N'erp_item_number,plant_code,supplier_number,supplier_part_number')
) AS s (route_id, erp_system, route_name, run_group, run_order, active_flag, runtime_environment, source_connection,
        source_directory, file_pattern, onelake_folder, target_table, load_operation, key_columns)
ON t.route_id = s.route_id
WHEN MATCHED THEN
    UPDATE SET erp_system          = s.erp_system,
               route_name          = s.route_name,
               run_group           = s.run_group,
               run_order           = s.run_order,
               active_flag         = s.active_flag,
               runtime_environment = s.runtime_environment,
               source_connection   = s.source_connection,
               source_directory    = s.source_directory,
               file_pattern        = s.file_pattern,
               onelake_folder      = s.onelake_folder,
               target_table        = s.target_table,
               load_operation      = s.load_operation,
               key_columns         = s.key_columns,
               updated_ts          = SYSUTCDATETIME(),
               updated_by          = N'matmas_setup'
WHEN NOT MATCHED THEN
    INSERT (route_id, erp_system, route_name, run_group, run_order, active_flag, runtime_environment, source_connection,
            source_directory, file_pattern, onelake_folder, target_table, load_operation, key_columns, created_by)
    VALUES (s.route_id, s.erp_system, s.route_name, s.run_group, s.run_order, s.active_flag, s.runtime_environment, s.source_connection,
            s.source_directory, s.file_pattern, s.onelake_folder, s.target_table, s.load_operation, s.key_columns, N'matmas_setup');

-- SAP stays inactive (active_flag = 0) until its agent group and folder are filled in;
-- then set active_flag = 1 and create erp_to_matmas/{landing,archive,duplicate,error}/SAP in the lakehouse.

SELECT * FROM matmas.v_route_reader ORDER BY run_group, row_num;
GO

/* ---------------------------------------------------------------------
   ONBOARDING A NEW ERP = these two statements, nothing in CDI:

   EXEC matmas.sp_create_erp_table N'qad_material_master';

   INSERT INTO cfg.matmas_route_config (route_id, erp_system, route_name, run_order, runtime_environment,
          source_connection, source_directory, file_pattern, onelake_folder, target_table, load_operation)
   VALUES ('QAD_MATMAS', 'QAD', N'QAD material master', 40, N'<agent group>',
          N'<local folder connection>', N'<folder on that agent>', N'QAD_MATMAS*.txt', N'QAD',
          N'qad_material_master', 'UPSERT');
   -- and create Files/erp_to_matmas/landing/QAD, archive/QAD, duplicate/QAD, error/QAD in lh_p2o_intg_dev
   --------------------------------------------------------------------- */
