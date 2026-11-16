/* =====================================================================
   MATMAS - Material Master, config-driven ingestion (Informatica CDI)
   01: schemas, config table, run log, staging, reject, file history,
       ERP target tables, and the CDI interface views in schema stg.
   Platform : SQL database in Microsoft Fabric (T-SQL, compat level 160)
   CDI conn : jdbcv2.MSSQL.sqldb-p2o-intg.stg (JDBC V2, default schema stg)
   Run order: 01 -> 02 -> 03 -> 04 (test)
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'MATMAS') EXEC ('CREATE SCHEMA MATMAS');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')    EXEC ('CREATE SCHEMA stg');
GO

/* ---------------------------------------------------------------------
   0. CTL_MATMAS_SETTING - org-wide values used by every route
      (OneLake connection, lakehouse root, script path). One place to fix.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_MATMAS_SETTING') IS NULL
CREATE TABLE MATMAS.CTL_MATMAS_SETTING (
    SETTING_NAME   VARCHAR(60)    NOT NULL,
    SETTING_VALUE  NVARCHAR(1000) NOT NULL,
    DESCRIPTION    NVARCHAR(300)  NULL,
    CONSTRAINT PK_CTL_MATMAS_SETTING PRIMARY KEY (SETTING_NAME)
);
GO

/* ---------------------------------------------------------------------
   1. CTL_MATMAS_ROUTE - ONE ROW PER SOURCE LOCATION.
      Everything the taskflow needs for that location comes from here:
      where to collect (agent, connection, folder, pattern), where to put
      it in OneLake, and how to load it (target table, operation, keys).
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_MATMAS_ROUTE') IS NULL
CREATE TABLE MATMAS.CTL_MATMAS_ROUTE (
    ROUTE_ID                 VARCHAR(60)    NOT NULL,   -- JDE_AUR_MATMAS
    ERP_SYSTEM               VARCHAR(30)    NOT NULL,   -- JDE / VISION / SAP / ...
    ROUTE_NAME               NVARCHAR(200)  NOT NULL,
    RUN_GROUP                VARCHAR(30)    NOT NULL DEFAULT 'DAILY',
    RUN_ORDER                INT            NOT NULL DEFAULT 10,
    ACTIVE_FLAG              CHAR(1)        NOT NULL DEFAULT 'Y',
    -- collect: file ingestion task overrides (Ingestion Task step input fields)
    RUNTIME_ENVIRONMENT      NVARCHAR(100)  NOT NULL,   -- Secure Agent group where the file lands
    SOURCE_CONNECTION        NVARCHAR(100)  NOT NULL,   -- local folder / SFTP connection name in IDMC
    SOURCE_DIRECTORY         NVARCHAR(500)  NOT NULL,   -- folder on that agent
    FILE_PATTERN             NVARCHAR(200)  NOT NULL DEFAULT N'*.txt',
    SOURCE_ARCHIVE_DIRECTORY NVARCHAR(500)  NULL,       -- where the agent-side file goes after a good load (NULL = no archive step)
    ONELAKE_FOLDER           NVARCHAR(100)  NOT NULL,   -- ERP sub-folder under erp_to_matmas/{landing,archive,duplicate,error}, e.g. JDE / Vision
    -- load: generic mapping + apply procedure
    TARGET_SCHEMA            SYSNAME        NOT NULL DEFAULT N'MATMAS',
    TARGET_TABLE             SYSNAME        NOT NULL,   -- JDE_MATERIAL_MASTER
    LOAD_OPERATION           VARCHAR(20)    NOT NULL DEFAULT 'UPSERT',
    KEY_COLUMNS              NVARCHAR(500)  NOT NULL DEFAULT N'ERP_ITEM_NUMBER,PLANT_CODE,SUPPLIER_NUMBER,SUPPLIER_PART_NUMBER',
    START_DATE_VALUE         VARCHAR(10)    NULL,       -- yyyy-mm-dd; NULL = load date
    END_DATE_VALUE           VARCHAR(10)    NOT NULL DEFAULT '9999-12-31',
    SKIP_DUPLICATE_FILE      CHAR(1)        NOT NULL DEFAULT 'Y',  -- same file content already loaded for this route -> skip
    NOTIFY_EMAIL             NVARCHAR(400)  NULL,
    CREATED_TS               DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CREATED_BY               NVARCHAR(50)   NULL,
    UPDATED_TS               DATETIME2(3)   NULL,
    UPDATED_BY               NVARCHAR(50)   NULL,
    CONSTRAINT PK_CTL_MATMAS_ROUTE PRIMARY KEY (ROUTE_ID),
    CONSTRAINT CK_ROUTE_ACTIVE CHECK (ACTIVE_FLAG IN ('Y','N')),
    CONSTRAINT CK_ROUTE_OPERATION CHECK (LOAD_OPERATION IN ('INSERT','UPSERT','UPDATE','DELETE','TRUNCATE_INSERT')),
    CONSTRAINT CK_ROUTE_SKIPDUP CHECK (SKIP_DUPLICATE_FILE IN ('Y','N')),
    CONSTRAINT CK_ROUTE_START CHECK (START_DATE_VALUE IS NULL OR TRY_CONVERT(DATE, START_DATE_VALUE, 23) IS NOT NULL),
    CONSTRAINT CK_ROUTE_END   CHECK (TRY_CONVERT(DATE, END_DATE_VALUE, 23) IS NOT NULL)
);
GO

/* ---------------------------------------------------------------------
   2. CTL_MATMAS_RUN_LOG - append-only event log, one row per event.
      Written by CDI (STARTED, NO_FILE, COLLECT_FAILED, LOAD_FAILED,
      ARCHIVE_FAILED) and by the apply procedure (LOADED, DUPLICATE_FILE,
      APPLY_FAILED).
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_MATMAS_RUN_LOG') IS NULL
CREATE TABLE MATMAS.CTL_MATMAS_RUN_LOG (
    LOG_ID          BIGINT IDENTITY(1,1) NOT NULL,
    RUN_ID          VARCHAR(30)    NULL,
    ROUTE_ID        VARCHAR(60)    NULL,
    EVENT           VARCHAR(30)    NULL,
    FILE_COUNT      INT            NULL,
    ROWS_STAGED     INT            NULL,
    ROWS_INSERTED   INT            NULL,
    ROWS_UPDATED    INT            NULL,
    ROWS_DELETED    INT            NULL,
    ROWS_REJECTED   INT            NULL,
    MESSAGE         NVARCHAR(4000) NULL,
    LOG_TS          DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_CTL_MATMAS_RUN_LOG PRIMARY KEY (LOG_ID)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_RUN_LOG_RUN')
CREATE INDEX IX_RUN_LOG_RUN ON MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, LOG_ID);
GO

/* ---------------------------------------------------------------------
   3. MATERIAL_MASTER_STAGE - what the generic CDI mapping writes:
      the 6 file fields + START_DATE / END_DATE added in the mapping.
      sp_MATMAS_ApplyStage moves it into the route's ERP table.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_STAGE') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_STAGE (
    STAGE_ID                  BIGINT IDENTITY(1,1) NOT NULL,
    RUN_ID                    VARCHAR(30)    NULL,
    ROUTE_ID                  VARCHAR(60)    NULL,
    SOURCE_FILE_NAME          NVARCHAR(500)  NULL,
    ERP_ITEM_NUMBER           NVARCHAR(1000) NULL,
    MATERIAL_DESCRIPTION      NVARCHAR(1000) NULL,
    PLANT_CODE                NVARCHAR(1000) NULL,
    SUPPLIER_PART_NUMBER      NVARCHAR(1000) NULL,
    SUPPLIER_NUMBER           NVARCHAR(1000) NULL,
    MANUFACTURING_PART_NUMBER NVARCHAR(1000) NULL,
    START_DATE                DATE           NULL,
    END_DATE                  DATE           NULL,
    STAGE_STATUS              VARCHAR(12)    NOT NULL DEFAULT 'NEW',   -- NEW / APPLIED / REJECTED / DUPLICATE / FAILED
    LOAD_TS                   DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_MATERIAL_MASTER_STAGE PRIMARY KEY (STAGE_ID)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_STAGE_STATUS')
CREATE INDEX IX_STAGE_STATUS ON MATMAS.MATERIAL_MASTER_STAGE (STAGE_STATUS, RUN_ID, ROUTE_ID);
GO

/* ---------------------------------------------------------------------
   4. MATERIAL_MASTER_REJECT - rows that failed validation (missing key)
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_REJECT') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_REJECT (
    REJECT_ID                 BIGINT IDENTITY(1,1) NOT NULL,
    RUN_ID                    VARCHAR(30)    NULL,
    ROUTE_ID                  VARCHAR(60)    NULL,
    SOURCE_FILE_NAME          NVARCHAR(500)  NULL,
    REJECT_REASON             NVARCHAR(500)  NOT NULL,
    ERP_ITEM_NUMBER           NVARCHAR(1000) NULL,
    MATERIAL_DESCRIPTION      NVARCHAR(1000) NULL,
    PLANT_CODE                NVARCHAR(1000) NULL,
    SUPPLIER_PART_NUMBER      NVARCHAR(1000) NULL,
    SUPPLIER_NUMBER           NVARCHAR(1000) NULL,
    MANUFACTURING_PART_NUMBER NVARCHAR(1000) NULL,
    REJECT_TS                 DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_MATERIAL_MASTER_REJECT PRIMARY KEY (REJECT_ID)
);
GO

/* ---------------------------------------------------------------------
   5. CTL_MATMAS_FILE_HISTORY - fingerprint of every applied file, so a
      file re-collected after a failed archive is not loaded twice.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_MATMAS_FILE_HISTORY') IS NULL
CREATE TABLE MATMAS.CTL_MATMAS_FILE_HISTORY (
    ROUTE_ID          VARCHAR(60)    NOT NULL,
    FILE_FINGERPRINT  VARCHAR(64)    NOT NULL,   -- SHA2_256 of the file's rows
    SOURCE_FILE_NAME  NVARCHAR(500)  NULL,
    ROW_COUNT         INT            NULL,
    RUN_ID            VARCHAR(30)    NULL,
    APPLIED_TS        DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_CTL_MATMAS_FILE_HISTORY PRIMARY KEY (ROUTE_ID, FILE_FINGERPRINT)
);
GO

/* ---------------------------------------------------------------------
   6. ERP target tables - one per ERP, identical columns:
      the 6 business fields from the file + START_DATE / END_DATE + audit.
      sp_MATMAS_CreateErpTable creates a new one from the same template.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_CreateErpTable
    @TableName SYSNAME,
    @SchemaName SYSNAME = N'MATMAS'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @full NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName), @sql NVARCHAR(MAX);
    IF OBJECT_ID(@full, 'U') IS NOT NULL
    BEGIN
        PRINT CONCAT('exists: ', @full);
        RETURN;
    END
    SET @sql = N'CREATE TABLE ' + @full + N' (
        ERP_ITEM_NUMBER           NVARCHAR(50)   NOT NULL,
        MATERIAL_DESCRIPTION      NVARCHAR(240)  NULL,
        PLANT_CODE                NVARCHAR(20)   NOT NULL,
        SUPPLIER_PART_NUMBER      NVARCHAR(80)   NULL,
        SUPPLIER_NUMBER           NVARCHAR(30)   NULL,
        MANUFACTURING_PART_NUMBER NVARCHAR(80)   NULL,
        START_DATE                DATE           NOT NULL,
        END_DATE                  DATE           NOT NULL,
        SOURCE_FILE_NAME          NVARCHAR(500)  NULL,
        RUN_ID                    VARCHAR(30)    NULL,
        CREATED_TS                DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
        UPDATED_TS                DATETIME2(3)   NULL);
      CREATE INDEX ' + QUOTENAME(N'IX_' + @TableName + N'_KEY') + N' ON ' + @full
      + N' (ERP_ITEM_NUMBER, PLANT_CODE, SUPPLIER_NUMBER, SUPPLIER_PART_NUMBER);';
    EXEC sp_executesql @sql;
    PRINT CONCAT('created: ', @full);
END
GO
EXEC MATMAS.sp_MATMAS_CreateErpTable N'JDE_MATERIAL_MASTER';
EXEC MATMAS.sp_MATMAS_CreateErpTable N'VISION_MATERIAL_MASTER';
EXEC MATMAS.sp_MATMAS_CreateErpTable N'SAP_MATERIAL_MASTER';
GO

/* ---------------------------------------------------------------------
   7. Monitoring views
   --------------------------------------------------------------------- */
-- active routes with a row number per run group (read row N by the taskflow loop)
CREATE OR ALTER VIEW MATMAS.V_MATMAS_ROUTE_READER AS
WITH cfg AS (
    SELECT MAX(CASE WHEN SETTING_NAME = 'ONELAKE_CONNECTION' THEN SETTING_VALUE END) AS ONELAKE_CONNECTION,
           MAX(CASE WHEN SETTING_NAME = 'ONELAKE_ROOT'       THEN SETTING_VALUE END) AS ONELAKE_ROOT
    FROM   MATMAS.CTL_MATMAS_SETTING)
SELECT CAST(ROW_NUMBER() OVER (PARTITION BY r.RUN_GROUP ORDER BY r.RUN_ORDER, r.ROUTE_ID) AS INT) AS ROW_NUM,
       CAST(COUNT(*) OVER (PARTITION BY r.RUN_GROUP) AS INT)                                  AS TOTAL_ROUTES,
       CAST(r.RUN_GROUP AS NVARCHAR(30))                            AS RUN_GROUP,
       CAST(r.ROUTE_ID AS NVARCHAR(60))                             AS ROUTE_ID,
       CAST(r.ERP_SYSTEM AS NVARCHAR(30))                           AS ERP_SYSTEM,
       r.RUNTIME_ENVIRONMENT, r.SOURCE_CONNECTION, r.SOURCE_DIRECTORY, r.FILE_PATTERN,
       CAST(ISNULL(r.SOURCE_ARCHIVE_DIRECTORY, N'') AS NVARCHAR(500)) AS SOURCE_ARCHIVE_DIRECTORY,
       CAST(c.ONELAKE_CONNECTION AS NVARCHAR(100))                                     AS ONELAKE_CONNECTION,
       CAST(CONCAT(c.ONELAKE_ROOT, N'/landing/',   r.ONELAKE_FOLDER) AS NVARCHAR(500)) AS ONELAKE_LANDING_DIR,
       CAST(CONCAT(c.ONELAKE_ROOT, N'/archive/',   r.ONELAKE_FOLDER) AS NVARCHAR(500)) AS ONELAKE_ARCHIVE_DIR,
       CAST(CONCAT(c.ONELAKE_ROOT, N'/duplicate/', r.ONELAKE_FOLDER) AS NVARCHAR(500)) AS ONELAKE_DUPLICATE_DIR,
       CAST(CONCAT(c.ONELAKE_ROOT, N'/error/',     r.ONELAKE_FOLDER) AS NVARCHAR(500)) AS ONELAKE_ERROR_DIR,
       CAST(CONCAT(r.TARGET_SCHEMA, N'.', r.TARGET_TABLE) AS NVARCHAR(300)) AS TARGET_TABLE,
       CAST(r.LOAD_OPERATION AS NVARCHAR(20))                       AS LOAD_OPERATION,
       CAST(ISNULL(r.START_DATE_VALUE, '') AS NVARCHAR(10))         AS START_DATE_VALUE,
       CAST(r.END_DATE_VALUE AS NVARCHAR(10))                       AS END_DATE_VALUE,
       CAST(ISNULL(r.NOTIFY_EMAIL, N'') AS NVARCHAR(400))           AS NOTIFY_EMAIL
FROM   MATMAS.CTL_MATMAS_ROUTE r
CROSS  JOIN cfg c
WHERE  r.ACTIVE_FLAG = 'Y';
GO
-- last event per run and route
CREATE OR ALTER VIEW MATMAS.V_MATMAS_RUN_STATUS AS
SELECT RUN_ID, ROUTE_ID, EVENT AS LAST_EVENT, FILE_COUNT, ROWS_STAGED, ROWS_INSERTED, ROWS_UPDATED,
       ROWS_DELETED, ROWS_REJECTED, MESSAGE, LOG_TS
FROM  (SELECT *, ROW_NUMBER() OVER (PARTITION BY RUN_ID, ROUTE_ID ORDER BY LOG_ID DESC) AS rn
       FROM MATMAS.CTL_MATMAS_RUN_LOG) x
WHERE  rn = 1;
GO

-- outcome of one run + route: decides which OneLake folder the run's files are copied to
CREATE OR ALTER VIEW MATMAS.V_MATMAS_RUN_OUTCOME AS
SELECT RUN_ID, ROUTE_ID,
       CAST(CASE WHEN SUM(CASE WHEN EVENT IN ('APPLY_FAILED','LOAD_FAILED') THEN 1 ELSE 0 END) > 0 THEN 'ERROR'
                 WHEN SUM(CASE WHEN EVENT = 'DUPLICATE_FILE' THEN 1 ELSE 0 END) > 0
                  AND SUM(CASE WHEN EVENT = 'LOADED' THEN ISNULL(ROWS_INSERTED,0) + ISNULL(ROWS_UPDATED,0) + ISNULL(ROWS_DELETED,0) ELSE 0 END) = 0
                  AND SUM(CASE WHEN EVENT = 'LOADED' THEN ISNULL(ROWS_REJECTED,0) ELSE 0 END) = 0 THEN 'DUPLICATE'
                 WHEN SUM(CASE WHEN EVENT = 'LOADED' THEN 1 ELSE 0 END) > 0 THEN 'ARCHIVE'
                 ELSE 'ERROR' END AS NVARCHAR(20)) AS OUTCOME
FROM   MATMAS.CTL_MATMAS_RUN_LOG
GROUP  BY RUN_ID, ROUTE_ID;
GO

/* ---------------------------------------------------------------------
   8. CDI INTERFACE VIEWS in schema stg (the JDBC V2 connection's default
      schema, as in the org's existing mappings). Single-table views, so
      the two writer views accept INSERT.
   --------------------------------------------------------------------- */
-- source of m_P2O_101_MATMAS_Route_Reader
CREATE OR ALTER VIEW stg.MATMAS_ROUTE_READER AS
SELECT ROW_NUM, TOTAL_ROUTES, RUN_GROUP, ROUTE_ID, ERP_SYSTEM, RUNTIME_ENVIRONMENT, SOURCE_CONNECTION,
       SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY, ONELAKE_CONNECTION, ONELAKE_LANDING_DIR,
       ONELAKE_ARCHIVE_DIR, ONELAKE_DUPLICATE_DIR, ONELAKE_ERROR_DIR, TARGET_TABLE, LOAD_OPERATION,
       START_DATE_VALUE, END_DATE_VALUE, NOTIFY_EMAIL
FROM   MATMAS.V_MATMAS_ROUTE_READER;
GO
-- source of m_P2O_103_MATMAS_Outcome
CREATE OR ALTER VIEW stg.MATMAS_RUN_OUTCOME AS
SELECT CAST(RUN_ID AS NVARCHAR(30)) AS RUN_ID, CAST(ROUTE_ID AS NVARCHAR(60)) AS ROUTE_ID, OUTCOME
FROM   MATMAS.V_MATMAS_RUN_OUTCOME;
GO
-- target of the reader, outcome and log mappings
CREATE OR ALTER VIEW stg.MATMAS_RUN_LOG AS
SELECT RUN_ID, ROUTE_ID, EVENT, FILE_COUNT, MESSAGE FROM MATMAS.CTL_MATMAS_RUN_LOG;
GO
-- target of m_P2O_102_MATMAS_Load
CREATE OR ALTER VIEW stg.MATMAS_MATERIAL_MASTER_STAGE AS
SELECT RUN_ID, ROUTE_ID, SOURCE_FILE_NAME, ERP_ITEM_NUMBER, MATERIAL_DESCRIPTION, PLANT_CODE,
       SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER, START_DATE, END_DATE
FROM   MATMAS.MATERIAL_MASTER_STAGE;
GO
-- one-row source of m_P2O_104_MATMAS_Log
CREATE OR ALTER VIEW stg.MATMAS_ONE_ROW AS SELECT CAST(1 AS INT) AS ONE;
GO
