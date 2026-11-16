/* =====================================================================
   matmas - 04: test the SQL side without Informatica.
   Simulates what m_P2O_102_MATMAS_Load writes into stg.matmas_stage_file
   (6 file fields + start_date / end_date added by the mapping) and then
   calls what its Post SQL calls. Expected results are in the comments.
   ===================================================================== */
SET NOCOUNT ON;

/* ---- run 1: JDE sample (two identical rows + one without item number) */
INSERT INTO stg.matmas_stage_file (run_id, route_id, source_file_name, erp_item_number, material_description, plant_code,
            supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date)
VALUES ('20261116090000', 'JDE_MATMAS', N'JDE_MATMAS_20261116.txt', N'109589', N'SEN,PROXIMITY,29MM,12-24VDC', N'AUR', N'4462658 (Primary)', N'456526', N'4462658 (Fallback)', '2026-11-16', '9999-12-31'),
       ('20261116090000', 'JDE_MATMAS', N'JDE_MATMAS_20261116.txt', N'109589', N'SEN,PROXIMITY,29MM,12-24VDC', N'AUR', N'4462658 (Primary)', N'456526', N'4462658 (Fallback)', '2026-11-16', '9999-12-31'),
       ('20261116090000', 'JDE_MATMAS', N'JDE_MATMAS_20261116.txt', N'',       N'ROW WITHOUT ITEM NUMBER',     N'AUR', N'111 (Primary)',     N'456526', NULL,                  '2026-11-16', '9999-12-31');
EXEC matmas.sp_apply_stage;
-- expected LOADED: inserted=1 rejected=1 (MISSING erp_item_number) duplicates_collapsed=1
SELECT 'run1' AS step, * FROM matmas.v_run_status WHERE run_id = '20261116090000';
SELECT 'jde table' AS step, * FROM matmas.jde_material_master;

/* ---- run 2: the same file collected again --------------------------- */
INSERT INTO stg.matmas_stage_file (run_id, route_id, source_file_name, erp_item_number, material_description, plant_code,
            supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date)
SELECT '20261116100000', route_id, source_file_name, erp_item_number, material_description, plant_code,
       supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date
FROM   matmas.material_master_stage
WHERE  run_id = '20261116090000'
ORDER  BY stage_id;
EXEC matmas.sp_apply_stage;
-- expected: DUPLICATE_FILE then LOADED with inserted=0 updated=0 (whole file skipped)
SELECT 'run2' AS step, * FROM matmas.run_log WHERE run_id = '20261116100000' ORDER BY log_id;

/* ---- run 3: next day, description changed + one new supplier part ---- */
INSERT INTO stg.matmas_stage_file (run_id, route_id, source_file_name, erp_item_number, material_description, plant_code,
            supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date)
VALUES ('20261117090000', 'JDE_MATMAS', N'JDE_MATMAS_20261117.txt', N'109589', N'SEN,PROXIMITY,29MM,12-24VDC,IP67', N'AUR', N'4462658 (Primary)',  N'456526', N'4462658 (Fallback)', '2026-11-17', '9999-12-31'),
       ('20261117090000', 'JDE_MATMAS', N'JDE_MATMAS_20261117.txt', N'109589', N'SEN,PROXIMITY,29MM,12-24VDC,IP67', N'AUR', N'4462700 (Fallback)', N'456526', N'4462700 (Fallback)', '2026-11-17', '9999-12-31');
EXEC matmas.sp_apply_stage;
-- expected UPSERT: inserted=1 updated=1; the existing row keeps start_date 2026-11-16
SELECT 'run3' AS step, * FROM matmas.v_run_status WHERE run_id = '20261117090000';
SELECT 'jde table' AS step, * FROM matmas.jde_material_master ORDER BY supplier_part_number;

/* ---- run 4: a route whose target table is missing -> APPLY_FAILED ---- */
UPDATE cfg.matmas_route_config SET target_table = N'no_such_table' WHERE route_id = 'VISION_MATMAS';
INSERT INTO stg.matmas_stage_file (run_id, route_id, source_file_name, erp_item_number, material_description, plant_code,
            supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date)
VALUES ('20261117090000', 'VISION_MATMAS', N'VISION_MATMAS_20261117.txt', N'V-20001', N'SENSOR PROXIMITY 18MM 24VDC', N'MEL', N'PX-18-24 (Primary)', N'78001', N'PX-18-24 (Primary)', '2026-11-17', '9999-12-31');
BEGIN TRY
    EXEC matmas.sp_apply_stage;
END TRY
BEGIN CATCH
    PRINT CONCAT('expected error: ', ERROR_MESSAGE());
END CATCH
-- fix the config and retry only that run + route
UPDATE cfg.matmas_route_config SET target_table = N'vision_material_master' WHERE route_id = 'VISION_MATMAS';
EXEC matmas.sp_reapply_run '20261117090000', 'VISION_MATMAS';
-- expected: APPLY_FAILED then LOADED inserted=1
SELECT 'run4' AS step, * FROM matmas.run_log WHERE route_id = 'VISION_MATMAS' ORDER BY log_id;
SELECT 'vision table' AS step, * FROM matmas.vision_material_master;
SELECT 'rejects' AS step, * FROM matmas.material_master_reject;

/* ---- which OneLake folder each run + route goes to -------------------- */
-- expected: 20261116090000 JDE ARCHIVE | 20261116100000 JDE DUPLICATE | 20261117090000 JDE ARCHIVE
--           20261117090000 VISION ERROR (it failed first; the retry was done by hand)
SELECT 'outcome' AS step, * FROM matmas.v_run_outcome ORDER BY run_id, route_id;

/* ---- reset test data ---------------------------------------------------
TRUNCATE TABLE matmas.material_master_stage;   TRUNCATE TABLE matmas.material_master_reject;
TRUNCATE TABLE matmas.run_log;                 TRUNCATE TABLE matmas.file_history;
TRUNCATE TABLE matmas.jde_material_master;     TRUNCATE TABLE matmas.vision_material_master;
------------------------------------------------------------------------- */
