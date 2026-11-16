/* =====================================================================
   MATMAS - 03: route configuration (one row per source location)
   Replace the <...> placeholders and the example agent / connection names
   with the real ones from your IDMC org before the first run.
   Re-runnable (MERGE on ROUTE_ID).
   ===================================================================== */
SET NOCOUNT ON;

MERGE MATMAS.CTL_MATMAS_ROUTE AS t
USING (VALUES
 -- ROUTE_ID,          ERP,      name,                               group,  order, runtime env,        source connection,   source directory,                         pattern,          agent archive dir,                              OneLake conn,  OneLake base dir,                  target table,             operation, keys
 ('JDE_MATMAS',       'JDE',    N'JDE material master',             'DAILY', 10, N'US.US02.01',        N'LF_MATMAS_JDE',    N'D:\Interfaces\JDE\MATMAS\outbound',     N'JDE_MATMAS*.txt',    N'D:\Interfaces\JDE\MATMAS\archive',      N'OL_MATMAS', N'Files/matmas/inbound/JDE',     N'JDE_MATERIAL_MASTER',    'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER'),
 ('VISION_MATMAS',    'VISION', N'Vision material master',          'DAILY', 20, N'US.AMCOR.01',       N'LF_MATMAS_VISION', N'D:\Interfaces\VISION\MATMAS\outbound',  N'VISION_MATMAS*.txt', N'D:\Interfaces\VISION\MATMAS\archive',   N'OL_MATMAS', N'Files/matmas/inbound/VISION',  N'VISION_MATERIAL_MASTER', 'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER'),
 ('SAP_MATMAS',       'SAP',    N'SAP material master',             'DAILY', 30, N'<SAP_AGENT_GROUP>', N'LF_MATMAS_SAP',    N'<SAP agent folder>',                    N'SAP_MATMAS*.txt',    NULL,                                     N'OL_MATMAS', N'Files/matmas/inbound/SAP',     N'SAP_MATERIAL_MASTER',    'UPSERT', N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER')
) AS s (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUN_GROUP, RUN_ORDER, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION, SOURCE_DIRECTORY,
        FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_CONNECTION, ONELAKE_DIRECTORY, TARGET_TABLE, LOAD_OPERATION, KEY_COLUMNS)
ON t.ROUTE_ID = s.ROUTE_ID
WHEN MATCHED THEN UPDATE SET
     ERP_SYSTEM = s.ERP_SYSTEM, ROUTE_NAME = s.ROUTE_NAME, RUN_GROUP = s.RUN_GROUP, RUN_ORDER = s.RUN_ORDER,
     RUNTIME_ENVIRONMENT = s.RUNTIME_ENVIRONMENT, SOURCE_CONNECTION = s.SOURCE_CONNECTION, SOURCE_DIRECTORY = s.SOURCE_DIRECTORY,
     FILE_PATTERN = s.FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY = s.SOURCE_ARCHIVE_DIRECTORY, ONELAKE_CONNECTION = s.ONELAKE_CONNECTION,
     ONELAKE_DIRECTORY = s.ONELAKE_DIRECTORY, TARGET_TABLE = s.TARGET_TABLE, LOAD_OPERATION = s.LOAD_OPERATION,
     KEY_COLUMNS = s.KEY_COLUMNS, UPDATED_TS = SYSUTCDATETIME(), UPDATED_BY = 'MATMAS_SETUP'
WHEN NOT MATCHED THEN INSERT (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUN_GROUP, RUN_ORDER, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION,
     SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_CONNECTION, ONELAKE_DIRECTORY, TARGET_TABLE,
     LOAD_OPERATION, KEY_COLUMNS, CREATED_BY)
VALUES (s.ROUTE_ID, s.ERP_SYSTEM, s.ROUTE_NAME, s.RUN_GROUP, s.RUN_ORDER, s.RUNTIME_ENVIRONMENT, s.SOURCE_CONNECTION,
     s.SOURCE_DIRECTORY, s.FILE_PATTERN, s.SOURCE_ARCHIVE_DIRECTORY, s.ONELAKE_CONNECTION, s.ONELAKE_DIRECTORY, s.TARGET_TABLE,
     s.LOAD_OPERATION, s.KEY_COLUMNS, 'MATMAS_SETUP');

-- SAP stays inactive until its agent group and folder are filled in
UPDATE MATMAS.CTL_MATMAS_ROUTE SET ACTIVE_FLAG = 'N' WHERE ROUTE_ID = 'SAP_MATMAS' AND RUNTIME_ENVIRONMENT LIKE N'<%';

SELECT * FROM MATMAS.V_MATMAS_ROUTE_READER ORDER BY RUN_GROUP, ROW_NUM;
GO

/* ---------------------------------------------------------------------
   ONBOARDING A NEW ERP = these two statements, nothing in CDI:

   EXEC MATMAS.sp_MATMAS_CreateErpTable N'QAD_MATERIAL_MASTER';

   INSERT INTO MATMAS.CTL_MATMAS_ROUTE (ROUTE_ID, ERP_SYSTEM, ROUTE_NAME, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION,
          SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_CONNECTION, ONELAKE_DIRECTORY,
          TARGET_TABLE, LOAD_OPERATION, RUN_ORDER)
   VALUES ('QAD_MATMAS', 'QAD', N'QAD material master', N'<agent group>', N'<local folder connection>',
          N'<folder on that agent>', N'QAD_MATMAS*.txt', N'<archive folder>', N'OL_MATMAS', N'Files/matmas/inbound/QAD',
          N'QAD_MATERIAL_MASTER', 'UPSERT', 40);
   --------------------------------------------------------------------- */
