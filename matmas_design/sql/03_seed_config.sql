/* =====================================================================
   MATMAS - 03: route configuration (one row per source location)
   Replace the <...> placeholders and the example agent / connection names
   with the real ones from your IDMC org before the first run.
   Re-runnable (MERGE on ROUTE_ID).
   ===================================================================== */
SET NOCOUNT ON;

/* ---- org-wide settings (from the IDMC / Fabric screenshots) ---------- */
MERGE MATMAS.CTL_MATMAS_SETTING AS t
USING (VALUES
 ('ONELAKE_CONNECTION', N'FABRIC.AMCOR.ONELAKE.P2O',
  N'IDMC connection, type Microsoft Fabric OneLake, workspace ws_p2o_intg_dev'),
 ('ONELAKE_ROOT',       N'lh_p2o_intg_dev/Files/erp_to_matmas',
  N'Root of the MATMAS folders in lakehouse lh_p2o_intg_dev. Same format as fi_P2O_000_BPDWFS_GR_to_OneLake (no leading slash)'),
 ('CENTRAL_RUNTIME_ENV', N'US.US02.01', N'Agent group that runs the 4 mapping tasks and the OneLake move task')
) AS s (SETTING_NAME, SETTING_VALUE, DESCRIPTION)
ON t.SETTING_NAME = s.SETTING_NAME
WHEN MATCHED THEN UPDATE SET SETTING_VALUE = s.SETTING_VALUE, DESCRIPTION = s.DESCRIPTION
WHEN NOT MATCHED THEN INSERT (SETTING_NAME, SETTING_VALUE, DESCRIPTION) VALUES (s.SETTING_NAME, s.SETTING_VALUE, s.DESCRIPTION);

/* ---- routes: one row per source location ---------------------------------
   OneLake folders come from ONELAKE_ROOT + /landing|archive|duplicate|error/ + ONELAKE_FOLDER
   (existing lakehouse folders: erp_to_matmas/landing/JDE and erp_to_matmas/landing/Vision) */
MERGE MATMAS.CTL_MATMAS_ROUTE AS t
USING (VALUES
 -- ROUTE_ID,       ERP,      name,                       group,  order, runtime env,        source connection,   source directory (on that agent),        pattern,               agent archive dir,                       OneLake folder, target table,             operation, keys
 ('JDE_MATMAS',    'JDE',    N'JDE material master',     'DAILY', 10, N'US.US02.01',        N'LF_MATMAS_JDE',    N'D:\Interfaces\JDE\MATMAS\outbound',    N'JDE_MATMAS*.txt',    NULL,                                       N'JDE',    N'JDE_MATERIAL_MASTER',    'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER'),
 ('VISION_MATMAS', 'VISION', N'Vision material master',  'DAILY', 20, N'US.AMCOR.01',       N'LF_MATMAS_VISION', N'D:\Interfaces\VISION\MATMAS\outbound', N'VISION_MATMAS*.txt', NULL,                                       N'Vision', N'VISION_MATERIAL_MASTER', 'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER'),
 ('SAP_MATMAS',    'SAP',    N'SAP material master',     'DAILY', 30, N'<SAP_AGENT_GROUP>', N'LF_MATMAS_SAP',    N'<SAP agent folder>',                       N'SAP_MATMAS*.txt',    NULL,                                       N'SAP',    N'SAP_MATERIAL_MASTER',    'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER')
) AS s (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUN_GROUP, RUN_ORDER, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION, SOURCE_DIRECTORY,
        FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_FOLDER, TARGET_TABLE, LOAD_OPERATION, KEY_COLUMNS)
ON t.ROUTE_ID = s.ROUTE_ID
WHEN MATCHED THEN UPDATE SET
     ERP_SYSTEM = s.ERP_SYSTEM, ROUTE_NAME = s.ROUTE_NAME, RUN_GROUP = s.RUN_GROUP, RUN_ORDER = s.RUN_ORDER,
     RUNTIME_ENVIRONMENT = s.RUNTIME_ENVIRONMENT, SOURCE_CONNECTION = s.SOURCE_CONNECTION, SOURCE_DIRECTORY = s.SOURCE_DIRECTORY,
     FILE_PATTERN = s.FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY = s.SOURCE_ARCHIVE_DIRECTORY, ONELAKE_FOLDER = s.ONELAKE_FOLDER,
     TARGET_TABLE = s.TARGET_TABLE, LOAD_OPERATION = s.LOAD_OPERATION, KEY_COLUMNS = s.KEY_COLUMNS,
     UPDATED_TS = SYSUTCDATETIME(), UPDATED_BY = 'MATMAS_SETUP'
WHEN NOT MATCHED THEN INSERT (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUN_GROUP, RUN_ORDER, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION,
     SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_FOLDER, TARGET_TABLE, LOAD_OPERATION, KEY_COLUMNS, CREATED_BY)
VALUES (s.ROUTE_ID, s.ERP_SYSTEM, s.ROUTE_NAME, s.RUN_GROUP, s.RUN_ORDER, s.RUNTIME_ENVIRONMENT, s.SOURCE_CONNECTION,
     s.SOURCE_DIRECTORY, s.FILE_PATTERN, s.SOURCE_ARCHIVE_DIRECTORY, s.ONELAKE_FOLDER, s.TARGET_TABLE, s.LOAD_OPERATION,
     s.KEY_COLUMNS, 'MATMAS_SETUP');

-- SAP stays inactive until its agent group and folder are filled in (also create erp_to_matmas/*/SAP in the lakehouse)
UPDATE MATMAS.CTL_MATMAS_ROUTE SET ACTIVE_FLAG = 'N' WHERE ROUTE_ID = 'SAP_MATMAS' AND RUNTIME_ENVIRONMENT LIKE N'<%';

SELECT * FROM MATMAS.V_MATMAS_ROUTE_READER ORDER BY RUN_GROUP, ROW_NUM;
GO

/* ---------------------------------------------------------------------
   ONBOARDING A NEW ERP = these two statements, nothing in CDI:

   EXEC MATMAS.sp_MATMAS_CreateErpTable N'QAD_MATERIAL_MASTER';

   INSERT INTO MATMAS.CTL_MATMAS_ROUTE (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION,
          SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_FOLDER, TARGET_TABLE, LOAD_OPERATION, RUN_ORDER)
   VALUES ('QAD_MATMAS', 'QAD', N'QAD material master', N'<agent group>', N'<local folder connection>',
          N'<folder on that agent>', N'QAD_MATMAS*.txt', N'<archive folder>', N'QAD',
          N'QAD_MATERIAL_MASTER', 'UPSERT', 40);
   -- and create Files/erp_to_matmas/landing/QAD, archive/QAD, duplicate/QAD, error/QAD in lh_p2o_intg_dev
   --------------------------------------------------------------------- */
