/* =====================================================================
   MATMAS - Material Master generalized integration
   01: schema, control tables, landing, canonical, target, run tables
   Platform: SQL database in Microsoft Fabric (Azure SQL engine, T-SQL)
   CDI connection: jdbcv2.MSSQL.sqldb-p2o-intg.stg (JDBC V2)
   Run order: (00 only for a clean re-install) -> 01 -> 02 -> 03 -> 04 test
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'MATMAS')
    EXEC ('CREATE SCHEMA MATMAS');
GO

/* ---------------------------------------------------------------------
   1. CTL_SOURCE_SYSTEM - registry of ERPs / endpoints
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_SOURCE_SYSTEM') IS NULL
CREATE TABLE MATMAS.CTL_SOURCE_SYSTEM (
    SYSTEM_CODE          VARCHAR(20)    NOT NULL,
    SYSTEM_NAME          NVARCHAR(100)  NOT NULL,
    SYSTEM_TYPE          VARCHAR(20)    NOT NULL,            -- ERP / P2P / MDM / OTHER
    DEFAULT_DATE_STYLE   INT            NOT NULL DEFAULT 23, -- T-SQL CONVERT style (23=yyyy-mm-dd, 103=dd/mm/yyyy)
    OWNER_EMAIL          NVARCHAR(200)  NULL,
    ACTIVE_FLAG          CHAR(1)        NOT NULL DEFAULT 'Y',
    CREATED_TS           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CREATED_BY           NVARCHAR(50)   NULL,
    UPDATED_TS           DATETIME2(3)   NULL,
    UPDATED_BY           NVARCHAR(50)   NULL,
    CONSTRAINT PK_CTL_SOURCE_SYSTEM PRIMARY KEY (SYSTEM_CODE),
    CONSTRAINT CK_CTL_SS_ACTIVE CHECK (ACTIVE_FLAG IN ('Y','N'))
);
GO

/* ---------------------------------------------------------------------
   2. CTL_CANONICAL_COLUMN - fixed canonical attribute list.
      sp_Harmonize generates its SELECT against this list, so the output
      shape is identical whatever the source is.
      Keep in sync with MATMAS.MATERIAL_MASTER and #stg in sp_Harmonize.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_CANONICAL_COLUMN') IS NULL
CREATE TABLE MATMAS.CTL_CANONICAL_COLUMN (
    COLUMN_NAME          VARCHAR(100)   NOT NULL,
    SQL_TYPE             VARCHAR(50)    NOT NULL,
    ORDINAL              INT            NOT NULL,
    DESCRIPTION          NVARCHAR(300)  NULL,
    CONSTRAINT PK_CTL_CANONICAL_COLUMN PRIMARY KEY (COLUMN_NAME)
);
GO

/* ---------------------------------------------------------------------
   3. CTL_INBOUND_INTEGRATION - one row per  source -> canonical  route.
      A landed file is routed to a route by its SUB-FOLDER name
      (FOLDER_KEY, e.g. JDE / VISION) and its file name (FILE_NAME_PATTERN,
      a T-SQL LIKE pattern). No CDI object is route specific.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_INBOUND_INTEGRATION') IS NULL
CREATE TABLE MATMAS.CTL_INBOUND_INTEGRATION (
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,            -- IN_JDE_MATMAS_FILE
    INTEGRATION_NAME     NVARCHAR(200)  NOT NULL,
    SOURCE_SYSTEM        VARCHAR(20)    NOT NULL,            -- FK CTL_SOURCE_SYSTEM
    SOURCE_TYPE          VARCHAR(10)    NOT NULL DEFAULT 'FILE', -- FILE / IDOC (phase 2) / DB
    FOLDER_KEY           NVARCHAR(100)  NOT NULL,            -- sub-folder under MATMAS\inbound, e.g. JDE
    FILE_NAME_PATTERN    NVARCHAR(200)  NOT NULL DEFAULT N'%', -- LIKE pattern on the file name, e.g. JDE_MATMAS%.txt
    SOURCE_CONNECTION    VARCHAR(100)   NULL,                -- informational (FILE) / CDI connection for IDOC routes
    SOURCE_FOLDER        NVARCHAR(500)  NULL,                -- physical folder, informational
    ARCHIVE_FOLDER       NVARCHAR(500)  NULL,                -- informational
    FILE_DELIMITER       CHAR(1)        NOT NULL DEFAULT '|',
    EXPECTED_HEADER      NVARCHAR(2000) NULL,                -- pipe-joined header; every file is checked against it
    LOAD_TYPE            VARCHAR(10)    NOT NULL DEFAULT 'FULL',   -- FULL (missing keys are closed) / DELTA
    NATURAL_KEY_COLUMNS  VARCHAR(500)   NOT NULL,            -- canonical columns, comma separated
    RUN_SEQUENCE         INT            NOT NULL DEFAULT 10,
    ACTIVE_FLAG          CHAR(1)        NOT NULL DEFAULT 'Y',
    LAST_RUN_BATCH_ID    VARCHAR(40)    NULL,
    LAST_RUN_STATUS      VARCHAR(20)    NULL,
    LAST_RUN_TS          DATETIME2(3)   NULL,
    CREATED_TS           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CREATED_BY           NVARCHAR(50)   NULL,
    UPDATED_TS           DATETIME2(3)   NULL,
    UPDATED_BY           NVARCHAR(50)   NULL,
    CONSTRAINT PK_CTL_INBOUND PRIMARY KEY (INTEGRATION_ID),
    CONSTRAINT FK_CTL_INBOUND_SS FOREIGN KEY (SOURCE_SYSTEM) REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_CTL_INBOUND_TYPE CHECK (SOURCE_TYPE IN ('FILE','IDOC','DB')),
    CONSTRAINT CK_CTL_INBOUND_LOAD CHECK (LOAD_TYPE IN ('FULL','DELTA'))
);
GO

/* ---------------------------------------------------------------------
   4. CTL_OUTBOUND_INTEGRATION - one row per  canonical -> target  route
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_OUTBOUND_INTEGRATION') IS NULL
CREATE TABLE MATMAS.CTL_OUTBOUND_INTEGRATION (
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,            -- OUT_ALL_TO_TARGET
    INTEGRATION_NAME     NVARCHAR(200)  NOT NULL,
    TARGET_SYSTEM        VARCHAR(20)    NOT NULL,            -- FK CTL_SOURCE_SYSTEM
    TARGET_TYPE          VARCHAR(10)    NOT NULL,            -- TABLE (done in SQL) / FILE / IDOC / API (CDI mapping, phase 2)
    TARGET_CONNECTION    VARCHAR(100)   NOT NULL,
    TARGET_OBJECT        VARCHAR(200)   NOT NULL,            -- schema.table | file name | IDoc type
    SOURCE_FILTER        NVARCHAR(2000) NOT NULL DEFAULT N'1 = 1', -- predicate on MATMAS.MATERIAL_MASTER mm
    PUBLISH_MODE         VARCHAR(10)    NOT NULL DEFAULT 'DELTA',  -- DELTA (unpublished versions) / FULL (truncate + snapshot)
    RUN_SEQUENCE         INT            NOT NULL DEFAULT 10,
    ACTIVE_FLAG          CHAR(1)        NOT NULL DEFAULT 'Y',
    LAST_PUBLISHED_TS    DATETIME2(3)   NULL,
    LAST_RUN_BATCH_ID    VARCHAR(40)    NULL,
    LAST_RUN_STATUS      VARCHAR(20)    NULL,
    CREATED_TS           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    CREATED_BY           NVARCHAR(50)   NULL,
    UPDATED_TS           DATETIME2(3)   NULL,
    UPDATED_BY           NVARCHAR(50)   NULL,
    CONSTRAINT PK_CTL_OUTBOUND PRIMARY KEY (INTEGRATION_ID),
    CONSTRAINT FK_CTL_OUTBOUND_SS FOREIGN KEY (TARGET_SYSTEM) REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_CTL_OUTBOUND_TYPE CHECK (TARGET_TYPE IN ('TABLE','FILE','IDOC','API')),
    CONSTRAINT CK_CTL_OUTBOUND_MODE CHECK (PUBLISH_MODE IN ('DELTA','FULL'))
);
GO

/* ---------------------------------------------------------------------
   5. CTL_FIELD_MAPPING - column rules
      IN : SOURCE_COLUMN = LANDING_RAW column (COL01..COL30), TARGET_COLUMN = canonical column
      OUT: SOURCE_COLUMN = canonical column, TARGET_COLUMN = target column
      TRANSFORM_EXPR : T-SQL expression (IN: over COLnn; OUT: over alias mm.)
      VALIDATION_EXPR: T-SQL boolean; when TRUE the row is rejected as 'INVALID <column>'
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_FIELD_MAPPING') IS NULL
CREATE TABLE MATMAS.CTL_FIELD_MAPPING (
    MAPPING_ID           INT IDENTITY(1000,1) NOT NULL,
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,
    DIRECTION            CHAR(3)        NOT NULL,            -- IN / OUT
    ORDINAL              INT            NOT NULL,
    SOURCE_COLUMN        VARCHAR(100)   NULL,
    TARGET_COLUMN        VARCHAR(100)   NOT NULL,
    TRANSFORM_EXPR       NVARCHAR(2000) NULL,
    VALIDATION_EXPR      NVARCHAR(2000) NULL,
    DATA_TYPE            VARCHAR(30)    NOT NULL DEFAULT 'STRING',
    DEFAULT_VALUE        NVARCHAR(200)  NULL,
    MANDATORY_FLAG       CHAR(1)        NOT NULL DEFAULT 'N',
    KEY_FLAG             CHAR(1)        NOT NULL DEFAULT 'N',
    DESCRIPTION          NVARCHAR(500)  NULL,
    ACTIVE_FLAG          CHAR(1)        NOT NULL DEFAULT 'Y',
    CREATED_TS           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    UPDATED_TS           DATETIME2(3)   NULL,
    CONSTRAINT PK_CTL_FIELD_MAPPING PRIMARY KEY (MAPPING_ID),
    CONSTRAINT UQ_CTL_FIELD_MAPPING UNIQUE (INTEGRATION_ID, DIRECTION, TARGET_COLUMN),
    CONSTRAINT CK_CTL_FM_DIR CHECK (DIRECTION IN ('IN','OUT'))
);
GO

/* ---------------------------------------------------------------------
   6. CTL_PARAMETER - key/value per route ('*' = global default)
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_PARAMETER') IS NULL
CREATE TABLE MATMAS.CTL_PARAMETER (
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,
    PARAM_NAME           VARCHAR(60)    NOT NULL,
    PARAM_VALUE          NVARCHAR(1000) NULL,
    DESCRIPTION          NVARCHAR(300)  NULL,
    CONSTRAINT PK_CTL_PARAMETER PRIMARY KEY (INTEGRATION_ID, PARAM_NAME)
);
GO

/* ---------------------------------------------------------------------
   7. CTL_BATCH_RUN - run log per batch / route / stage
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_BATCH_RUN') IS NULL
CREATE TABLE MATMAS.CTL_BATCH_RUN (
    BATCH_ID             VARCHAR(40)    NOT NULL,
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,
    STAGE                VARCHAR(10)    NOT NULL,            -- ASSIGN / HARMONIZE / PUBLISH
    STATUS               VARCHAR(10)    NOT NULL,            -- RUNNING / SUCCESS / FAILED / SKIPPED
    START_TS             DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    END_TS               DATETIME2(3)   NULL,
    ROWS_READ            INT            NULL,
    ROWS_INSERTED        INT            NULL,
    ROWS_UPDATED         INT            NULL,
    ROWS_REJECTED        INT            NULL,
    SRC_FILE_NAME        NVARCHAR(500)  NULL,
    MESSAGE              NVARCHAR(4000) NULL,
    CONSTRAINT PK_CTL_BATCH_RUN PRIMARY KEY (BATCH_ID, INTEGRATION_ID, STAGE)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CTL_BATCH_RUN_INT')
CREATE INDEX IX_CTL_BATCH_RUN_INT ON MATMAS.CTL_BATCH_RUN (INTEGRATION_ID, START_TS);
GO

/* ---------------------------------------------------------------------
   8. CTL_RUN_REQUEST - one row per run of the CDI process mapping.
      m_MATMAS_PROCESS inserts one row (REQUEST_SOURCE, REQUEST_NOTE)
      and its target Post SQL runs EXEC MATMAS.sp_MATMAS_Process, which
      picks up the newest REQUESTED row and writes the outcome back here.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.CTL_RUN_REQUEST') IS NULL
CREATE TABLE MATMAS.CTL_RUN_REQUEST (
    RUN_ID               INT IDENTITY(1,1) NOT NULL,
    REQUEST_SOURCE       NVARCHAR(50)   NULL,                -- written by CDI ('CDI')
    REQUEST_NOTE         NVARCHAR(200)  NULL,                -- written by CDI (pending rows at request time)
    REQUESTED_TS         DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    STATUS               VARCHAR(20)    NOT NULL DEFAULT 'REQUESTED', -- REQUESTED / RUNNING / SUCCESS / PARTIAL / FAILED / NO_DATA
    BATCH_ID             VARCHAR(40)    NULL,
    START_TS             DATETIME2(3)   NULL,
    END_TS               DATETIME2(3)   NULL,
    SUMMARY              NVARCHAR(4000) NULL,
    CONSTRAINT PK_CTL_RUN_REQUEST PRIMARY KEY (RUN_ID)
);
GO

/* ---------------------------------------------------------------------
   9. LANDING_RAW - ONE generic landing table for every file of every ERP.
      m_MATMAS_LAND writes only SRC_FILE_NAME (CurrentlyProcessedFileName,
      full path) and COL01..COL30. Everything else is filled by
      sp_MATMAS_Assign: batch id, route (from the sub-folder name), row
      number per file (row 1 = header, validated by sp_Harmonize).
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.LANDING_RAW') IS NULL
CREATE TABLE MATMAS.LANDING_RAW (
    LANDING_ID           BIGINT IDENTITY(1,1) NOT NULL,
    BATCH_ID             VARCHAR(40)    NULL,
    INTEGRATION_ID       VARCHAR(60)    NULL,
    SRC_FILE_NAME        NVARCHAR(500)  NULL,
    SRC_ROW_NUM          INT            NULL,                -- 1 = header row
    COL01 NVARCHAR(1000) NULL, COL02 NVARCHAR(1000) NULL, COL03 NVARCHAR(1000) NULL, COL04 NVARCHAR(1000) NULL, COL05 NVARCHAR(1000) NULL,
    COL06 NVARCHAR(1000) NULL, COL07 NVARCHAR(1000) NULL, COL08 NVARCHAR(1000) NULL, COL09 NVARCHAR(1000) NULL, COL10 NVARCHAR(1000) NULL,
    COL11 NVARCHAR(1000) NULL, COL12 NVARCHAR(1000) NULL, COL13 NVARCHAR(1000) NULL, COL14 NVARCHAR(1000) NULL, COL15 NVARCHAR(1000) NULL,
    COL16 NVARCHAR(1000) NULL, COL17 NVARCHAR(1000) NULL, COL18 NVARCHAR(1000) NULL, COL19 NVARCHAR(1000) NULL, COL20 NVARCHAR(1000) NULL,
    COL21 NVARCHAR(1000) NULL, COL22 NVARCHAR(1000) NULL, COL23 NVARCHAR(1000) NULL, COL24 NVARCHAR(1000) NULL, COL25 NVARCHAR(1000) NULL,
    COL26 NVARCHAR(1000) NULL, COL27 NVARCHAR(1000) NULL, COL28 NVARCHAR(1000) NULL, COL29 NVARCHAR(1000) NULL, COL30 NVARCHAR(1000) NULL,
    LOAD_TS              DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    LOAD_STATUS          VARCHAR(10)    NOT NULL DEFAULT 'NEW',   -- NEW / ASSIGNED / PROCESSED / FAILED / UNROUTED
    CONSTRAINT PK_LANDING_RAW PRIMARY KEY (LANDING_ID)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LANDING_RAW_BATCH')
CREATE INDEX IX_LANDING_RAW_BATCH ON MATMAS.LANDING_RAW (BATCH_ID, INTEGRATION_ID, SRC_ROW_NUM);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LANDING_RAW_STATUS')
CREATE INDEX IX_LANDING_RAW_STATUS ON MATMAS.LANDING_RAW (LOAD_STATUS) INCLUDE (SRC_FILE_NAME);
GO

/* ---------------------------------------------------------------------
   10. Per-ERP landing views (readable names over LANDING_RAW)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW MATMAS.MATERIAL_MASTER_JDE AS
SELECT BATCH_ID, SRC_FILE_NAME, SRC_ROW_NUM, LOAD_TS, LOAD_STATUS,
       COL01 AS ERP_ITEM_NUMBER, COL02 AS MATERIAL_DESCRIPTION, COL03 AS PLANT_CODE,
       COL04 AS SUPPLIER_PART_NO, COL05 AS SUPPLIER_NUMBER, COL06 AS MANUFACTURING_PART_NO,
       COL07 AS START_DATE, COL08 AS END_DATE
FROM   MATMAS.LANDING_RAW
WHERE  INTEGRATION_ID = 'IN_JDE_MATMAS_FILE' AND SRC_ROW_NUM > 1;
GO
CREATE OR ALTER VIEW MATMAS.MATERIAL_MASTER_VISION AS
SELECT BATCH_ID, SRC_FILE_NAME, SRC_ROW_NUM, LOAD_TS, LOAD_STATUS,
       COL01 AS ITEM_CODE, COL02 AS ITEM_DESC, COL03 AS SITE_CODE, COL04 AS VENDOR_ID,
       COL05 AS VENDOR_PART, COL06 AS PART_PRIORITY, COL07 AS MFR_PART,
       COL08 AS EFF_FROM, COL09 AS EFF_TO, COL10 AS UOM
FROM   MATMAS.LANDING_RAW
WHERE  INTEGRATION_ID = 'IN_VISION_MATMAS_FILE' AND SRC_ROW_NUM > 1;
GO

/* ---------------------------------------------------------------------
   11. MATERIAL_MASTER - canonical, SCD type 2
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER (
    HASH_KEY                 VARCHAR(32)    NOT NULL,        -- MD5(natural key)
    VALID_FROM_TS            DATETIME2(3)   NOT NULL,
    VALID_TO_TS              DATETIME2(3)   NOT NULL DEFAULT '9999-12-31',
    CURRENT_FLAG             CHAR(1)        NOT NULL DEFAULT 'Y',
    SOURCE_SYSTEM            VARCHAR(20)    NOT NULL,
    ERP_ITEM_NUMBER          VARCHAR(50)    NOT NULL,
    PLANT_CODE               VARCHAR(10)    NOT NULL,
    SUPPLIER_NUMBER          VARCHAR(30)    NOT NULL,
    SUPPLIER_PART_NUMBER     VARCHAR(60)    NOT NULL,
    MATERIAL_DESCRIPTION     NVARCHAR(240)  NULL,
    SUPPLIER_PART_ROLE       VARCHAR(10)    NULL,            -- PRIMARY / FALLBACK
    MANUFACTURER_PART_NUMBER VARCHAR(60)    NULL,
    MANUFACTURER_PART_ROLE   VARCHAR(10)    NULL,
    START_DATE               DATE           NOT NULL,        -- business effectivity (requested column)
    END_DATE                 DATE           NOT NULL DEFAULT '9999-12-31',
    ITEM_STATUS              VARCHAR(20)    NULL,            -- ACTIVE / INACTIVE
    BASE_UOM                 VARCHAR(10)    NULL,
    ITEM_CATEGORY            VARCHAR(50)    NULL,
    COMMODITY_CODE           VARCHAR(30)    NULL,
    EXT_ATTR_01              NVARCHAR(100)  NULL,
    EXT_ATTR_02              NVARCHAR(100)  NULL,
    EXT_ATTR_03              NVARCHAR(100)  NULL,
    EXT_ATTR_04              NVARCHAR(100)  NULL,
    EXT_ATTR_05              NVARCHAR(100)  NULL,
    HASH_DIFF                VARCHAR(32)    NOT NULL,
    BATCH_ID                 VARCHAR(40)    NOT NULL,
    INTEGRATION_ID           VARCHAR(60)    NOT NULL,
    SRC_FILE_NAME            NVARCHAR(500)  NULL,
    CREATED_TS               DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    UPDATED_TS               DATETIME2(3)   NULL,
    CONSTRAINT PK_MATERIAL_MASTER PRIMARY KEY (HASH_KEY, VALID_FROM_TS),
    CONSTRAINT FK_MM_SOURCE_SYSTEM FOREIGN KEY (SOURCE_SYSTEM) REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_MM_CURRENT CHECK (CURRENT_FLAG IN ('Y','N'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MM_CURRENT')
CREATE INDEX IX_MM_CURRENT ON MATMAS.MATERIAL_MASTER (CURRENT_FLAG, SOURCE_SYSTEM, PLANT_CODE) INCLUDE (HASH_DIFF);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MM_ITEM')
CREATE INDEX IX_MM_ITEM ON MATMAS.MATERIAL_MASTER (SOURCE_SYSTEM, ERP_ITEM_NUMBER);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MM_BATCH')
CREATE INDEX IX_MM_BATCH ON MATMAS.MATERIAL_MASTER (BATCH_ID);
GO
CREATE OR ALTER VIEW MATMAS.V_MATERIAL_MASTER_CURRENT AS
SELECT * FROM MATMAS.MATERIAL_MASTER WHERE CURRENT_FLAG = 'Y';
GO

/* ---------------------------------------------------------------------
   12. MATERIAL_MASTER_XREF - same material across systems
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_XREF') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_XREF (
    SOURCE_SYSTEM        VARCHAR(20)    NOT NULL,
    SOURCE_ITEM_NUMBER   VARCHAR(50)    NOT NULL,
    PLANT_CODE           VARCHAR(10)    NOT NULL,
    TARGET_SYSTEM        VARCHAR(20)    NOT NULL,
    TARGET_ITEM_NUMBER   VARCHAR(50)    NOT NULL,
    TARGET_PLANT_CODE    VARCHAR(10)    NULL,
    START_DATE           DATE           NOT NULL,
    END_DATE             DATE           NOT NULL DEFAULT '9999-12-31',
    ACTIVE_FLAG          CHAR(1)        NOT NULL DEFAULT 'Y',
    CREATED_TS           DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    UPDATED_TS           DATETIME2(3)   NULL,
    CONSTRAINT PK_MM_XREF PRIMARY KEY (SOURCE_SYSTEM, SOURCE_ITEM_NUMBER, PLANT_CODE, TARGET_SYSTEM)
);
GO

/* ---------------------------------------------------------------------
   13. MATERIAL_MASTER_REJECT
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_REJECT') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_REJECT (
    REJECT_ID            BIGINT IDENTITY(1,1) NOT NULL,
    BATCH_ID             VARCHAR(40)    NOT NULL,
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,
    SRC_FILE_NAME        NVARCHAR(500)  NULL,
    SRC_ROW_NUM          INT            NULL,
    REJECT_REASON        NVARCHAR(500)  NOT NULL,
    RAW_RECORD           NVARCHAR(MAX)  NULL,
    REJECT_TS            DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    REPROCESSED_FLAG     CHAR(1)        NOT NULL DEFAULT 'N',
    CONSTRAINT PK_MM_REJECT PRIMARY KEY (REJECT_ID)
);
GO

/* ---------------------------------------------------------------------
   14. MATERIAL_MASTER_OUTBOUND - publish log (idempotent publish)
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_OUTBOUND') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_OUTBOUND (
    INTEGRATION_ID       VARCHAR(60)    NOT NULL,
    HASH_KEY             VARCHAR(32)    NOT NULL,
    VALID_FROM_TS        DATETIME2(3)   NOT NULL,
    BATCH_ID             VARCHAR(40)    NOT NULL,
    PUBLISH_STATUS       VARCHAR(10)    NOT NULL,            -- SUCCESS / FAILED
    PUBLISHED_TS         DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    TARGET_REFERENCE     NVARCHAR(100)  NULL,
    MESSAGE              NVARCHAR(2000) NULL,
    CONSTRAINT PK_MM_OUTBOUND PRIMARY KEY (INTEGRATION_ID, HASH_KEY, VALID_FROM_TS)
);
GO

/* ---------------------------------------------------------------------
   15. MATERIAL_MASTER_TARGET - the end table in the SAME format as the
       JDE details shared by Prabakaran, plus Start Date / End Date.
       [Source System] is extra so JDE and Vision rows can be told apart;
       drop it (and its OUT mapping row) for a strict 8-column target.
   --------------------------------------------------------------------- */
IF OBJECT_ID('MATMAS.MATERIAL_MASTER_TARGET') IS NULL
CREATE TABLE MATMAS.MATERIAL_MASTER_TARGET (
    [Source System]        VARCHAR(20)    NOT NULL,
    [ERP Item Number]      VARCHAR(50)    NOT NULL,
    [Material Description] NVARCHAR(240)  NULL,
    [Plant Code]           VARCHAR(10)    NOT NULL,
    [Supplier Part#]       VARCHAR(80)    NULL,              -- "4462658 (Primary)"
    [Supplier Number]      VARCHAR(30)    NOT NULL,
    [Manufacturing Part#]  VARCHAR(80)    NULL,              -- "4462658 (Fallback)"
    [Start Date]           DATE           NOT NULL,
    [End Date]             DATE           NOT NULL,
    [Loaded At]            DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------------
   16. V_MATMAS_RUN_REQUEST - source of m_MATMAS_PROCESS. Always exactly
       one row (aggregate without GROUP BY), all string columns.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW MATMAS.V_MATMAS_RUN_REQUEST AS
SELECT CAST(N'CDI' AS NVARCHAR(50))                                        AS REQUEST_SOURCE,
       CAST(CONCAT(N'pending landing rows: ', COUNT(*)) AS NVARCHAR(200)) AS REQUEST_NOTE
FROM   MATMAS.LANDING_RAW
WHERE  LOAD_STATUS = 'NEW';
GO

/* ---------------------------------------------------------------------
   18. CDI INTERFACE VIEWS in schema stg.
       The JDBC V2 connection jdbcv2.MSSQL.sqldb-p2o-intg.stg has default
       schema "stg", and the reference mapping addresses tables there with
       an empty schema. These updatable single-table views let both CDI
       mappings work the same way while the data stays in schema MATMAS.
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    EXEC ('CREATE SCHEMA stg');
GO
-- target of m_MATMAS_LAND (insert-through view). Column names match what CDI generates for a
-- headerless delimited file (Field1..Field30) plus the 'Add Currently Processed File Name'
-- field, so the target field mapping is fully automatic.
CREATE OR ALTER VIEW stg.MATMAS_LANDING_RAW AS
SELECT SRC_FILE_NAME AS CurrentlyProcessedFileName,
       COL01 AS Field1,
       COL02 AS Field2,
       COL03 AS Field3,
       COL04 AS Field4,
       COL05 AS Field5,
       COL06 AS Field6,
       COL07 AS Field7,
       COL08 AS Field8,
       COL09 AS Field9,
       COL10 AS Field10,
       COL11 AS Field11,
       COL12 AS Field12,
       COL13 AS Field13,
       COL14 AS Field14,
       COL15 AS Field15,
       COL16 AS Field16,
       COL17 AS Field17,
       COL18 AS Field18,
       COL19 AS Field19,
       COL20 AS Field20,
       COL21 AS Field21,
       COL22 AS Field22,
       COL23 AS Field23,
       COL24 AS Field24,
       COL25 AS Field25,
       COL26 AS Field26,
       COL27 AS Field27,
       COL28 AS Field28,
       COL29 AS Field29,
       COL30 AS Field30
FROM   MATMAS.LANDING_RAW;
GO
-- source of m_MATMAS_PROCESS (always one row)
CREATE OR ALTER VIEW stg.MATMAS_RUN_REQUEST_SRC AS
SELECT REQUEST_SOURCE, REQUEST_NOTE FROM MATMAS.V_MATMAS_RUN_REQUEST;
GO
-- target of m_MATMAS_PROCESS (insert-through view; Post SQL then runs the pipeline)
CREATE OR ALTER VIEW stg.MATMAS_RUN_REQUEST AS
SELECT REQUEST_SOURCE, REQUEST_NOTE FROM MATMAS.CTL_RUN_REQUEST;
GO

/* ---------------------------------------------------------------------
   17. V_MATMAS_RUN_STATUS - what happened in the last runs (monitoring)
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW MATMAS.V_MATMAS_RUN_STATUS AS
SELECT r.RUN_ID, r.STATUS AS RUN_STATUS, r.REQUESTED_TS, r.START_TS, r.END_TS, r.SUMMARY,
       b.INTEGRATION_ID, b.STAGE, b.STATUS AS STAGE_STATUS, b.ROWS_READ, b.ROWS_INSERTED,
       b.ROWS_UPDATED, b.ROWS_REJECTED, b.MESSAGE
FROM   MATMAS.CTL_RUN_REQUEST r
LEFT   JOIN MATMAS.CTL_BATCH_RUN b ON b.BATCH_ID = r.BATCH_ID;
GO
