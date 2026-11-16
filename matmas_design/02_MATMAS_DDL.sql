-- =====================================================================
--  MATMAS schema - Material Master generalized integration (CDI)
--  Dialect: Oracle. For SQL Server: VARCHAR2->VARCHAR, TIMESTAMP->DATETIME2,
--  LISTAGG->STRING_AGG, INSTR/SUBSTR->CHARINDEX/SUBSTRING, SYSDATE->GETDATE().
-- =====================================================================

-- CREATE USER / SCHEMA MATMAS ... (platform specific)

-- ---------------------------------------------------------------------
-- 1. CONTROL: source / target system registry
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_SOURCE_SYSTEM (
    SYSTEM_CODE          VARCHAR2(20)   NOT NULL,     -- JDE, VISION, SAP, COUPA
    SYSTEM_NAME          VARCHAR2(100)  NOT NULL,
    SYSTEM_TYPE          VARCHAR2(20)   NOT NULL,     -- ERP / P2P / MDM / OTHER
    DEFAULT_DATE_FORMAT  VARCHAR2(30)   DEFAULT 'YYYY-MM-DD',
    TIME_ZONE            VARCHAR2(40),
    OWNER_EMAIL          VARCHAR2(200),
    ACTIVE_FLAG          CHAR(1)        DEFAULT 'Y' NOT NULL,
    CREATED_TS           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CREATED_BY           VARCHAR2(50),
    UPDATED_TS           TIMESTAMP,
    UPDATED_BY           VARCHAR2(50),
    CONSTRAINT PK_CTL_SOURCE_SYSTEM PRIMARY KEY (SYSTEM_CODE),
    CONSTRAINT CK_CTL_SS_ACTIVE CHECK (ACTIVE_FLAG IN ('Y','N'))
);

-- ---------------------------------------------------------------------
-- 2. CONTROL: inbound routes  (source system  ->  canonical)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_INBOUND_INTEGRATION (
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,     -- IN_JDE_MATMAS_FILE
    INTEGRATION_NAME     VARCHAR2(200)  NOT NULL,
    SOURCE_SYSTEM        VARCHAR2(20)   NOT NULL,     -- FK CTL_SOURCE_SYSTEM
    SOURCE_TYPE          VARCHAR2(10)   NOT NULL,     -- FILE / DB
    SOURCE_CONNECTION    VARCHAR2(100)  NOT NULL,     -- CDI connection name
    SOURCE_OBJECT        VARCHAR2(200)  NOT NULL,     -- file name/pattern or table
    SOURCE_SUBFOLDER     VARCHAR2(200),               -- relative to connection dir
    LANDING_TABLE        VARCHAR2(100)  NOT NULL,     -- MATMAS.MATERIAL_MASTER_JDE
    LOAD_TYPE            VARCHAR2(10)   DEFAULT 'FULL' NOT NULL,   -- FULL / DELTA
    NATURAL_KEY_COLUMNS  VARCHAR2(500)  NOT NULL,     -- canonical cols, comma separated
    RUN_GROUP            VARCHAR2(30)   DEFAULT 'DAILY' NOT NULL,
    RUN_SEQUENCE         NUMBER(5)      DEFAULT 10 NOT NULL,
    HARMONIZE_SQL_OVERRIDE VARCHAR2(4000),                      -- optional: hand-written SELECT
    PRE_SQL              VARCHAR2(2000),
    POST_SQL             VARCHAR2(2000),
    ACTIVE_FLAG          CHAR(1)        DEFAULT 'Y' NOT NULL,
    LAST_RUN_BATCH_ID    VARCHAR2(40),
    LAST_RUN_STATUS      VARCHAR2(20),
    LAST_RUN_TS          TIMESTAMP,
    CREATED_TS           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CREATED_BY           VARCHAR2(50),
    UPDATED_TS           TIMESTAMP,
    UPDATED_BY           VARCHAR2(50),
    CONSTRAINT PK_CTL_INBOUND PRIMARY KEY (INTEGRATION_ID),
    CONSTRAINT FK_CTL_INBOUND_SS FOREIGN KEY (SOURCE_SYSTEM)
        REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_CTL_INBOUND_TYPE CHECK (SOURCE_TYPE IN ('FILE','DB')),
    CONSTRAINT CK_CTL_INBOUND_LOAD CHECK (LOAD_TYPE IN ('FULL','DELTA'))
);

-- ---------------------------------------------------------------------
-- 3. CONTROL: outbound routes  (canonical  ->  target system)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_OUTBOUND_INTEGRATION (
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,     -- OUT_JDE_AUR_TO_SAP
    INTEGRATION_NAME     VARCHAR2(200)  NOT NULL,
    TARGET_SYSTEM        VARCHAR2(20)   NOT NULL,     -- FK CTL_SOURCE_SYSTEM
    TARGET_TYPE          VARCHAR2(10)   NOT NULL,     -- TABLE / FILE / IDOC / API
    TARGET_CONNECTION    VARCHAR2(100)  NOT NULL,
    TARGET_OBJECT        VARCHAR2(200)  NOT NULL,     -- table, file name pattern, IDoc type
    SOURCE_FILTER        VARCHAR2(2000) NOT NULL,     -- SQL predicate on MATERIAL_MASTER
    PUBLISH_MODE         VARCHAR2(10)   DEFAULT 'DELTA' NOT NULL,  -- DELTA / FULL
    RUN_GROUP            VARCHAR2(30)   DEFAULT 'DAILY' NOT NULL,
    RUN_SEQUENCE         NUMBER(5)      DEFAULT 10 NOT NULL,
    PUBLISH_SQL_OVERRIDE VARCHAR2(4000),
    POST_COMMAND         VARCHAR2(500),               -- e.g. SFTP script name
    ACTIVE_FLAG          CHAR(1)        DEFAULT 'Y' NOT NULL,
    LAST_PUBLISHED_TS    TIMESTAMP,                   -- watermark for DELTA
    LAST_RUN_BATCH_ID    VARCHAR2(40),
    LAST_RUN_STATUS      VARCHAR2(20),
    CREATED_TS           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CREATED_BY           VARCHAR2(50),
    UPDATED_TS           TIMESTAMP,
    UPDATED_BY           VARCHAR2(50),
    CONSTRAINT PK_CTL_OUTBOUND PRIMARY KEY (INTEGRATION_ID),
    CONSTRAINT FK_CTL_OUTBOUND_SS FOREIGN KEY (TARGET_SYSTEM)
        REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_CTL_OUTBOUND_TYPE CHECK (TARGET_TYPE IN ('TABLE','FILE','IDOC','API'))
);

-- ---------------------------------------------------------------------
-- 4. CONTROL: column-level mapping rules (both directions)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_FIELD_MAPPING (
    MAPPING_ID           NUMBER(10)     NOT NULL,
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,     -- inbound or outbound id
    DIRECTION            CHAR(3)        NOT NULL,     -- IN  (landing -> canonical)
                                                      -- OUT (canonical -> target)
    ORDINAL              NUMBER(4)      NOT NULL,
    SOURCE_COLUMN        VARCHAR2(100),               -- NULL when TRANSFORM_EXPR is a literal
    TARGET_COLUMN        VARCHAR2(100)  NOT NULL,     -- IN: canonical column, OUT: target column
    TRANSFORM_EXPR       VARCHAR2(2000),              -- SQL expr; NULL = straight copy
    DATA_TYPE            VARCHAR2(30)   DEFAULT 'STRING',  -- STRING/DATE/NUMBER (doc + reject check)
    DATE_FORMAT          VARCHAR2(30),                -- for DATE when source is text
    DEFAULT_VALUE        VARCHAR2(200),
    MANDATORY_FLAG       CHAR(1)        DEFAULT 'N' NOT NULL,
    KEY_FLAG             CHAR(1)        DEFAULT 'N' NOT NULL,
    DESCRIPTION          VARCHAR2(500),
    ACTIVE_FLAG          CHAR(1)        DEFAULT 'Y' NOT NULL,
    CREATED_TS           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_TS           TIMESTAMP,
    CONSTRAINT PK_CTL_FIELD_MAPPING PRIMARY KEY (MAPPING_ID),
    CONSTRAINT UQ_CTL_FIELD_MAPPING UNIQUE (INTEGRATION_ID, DIRECTION, TARGET_COLUMN),
    CONSTRAINT CK_CTL_FM_DIR CHECK (DIRECTION IN ('IN','OUT'))
);

-- ---------------------------------------------------------------------
-- 5. CONTROL: free key/value parameters per route
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_PARAMETER (
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,     -- or '*' for global default
    PARAM_NAME           VARCHAR2(60)   NOT NULL,     -- FILE_DELIMITER, HEADER_ROW, SFTP_DIR, NOTIFY_EMAIL...
    PARAM_VALUE          VARCHAR2(1000),
    DESCRIPTION          VARCHAR2(300),
    CONSTRAINT PK_CTL_PARAMETER PRIMARY KEY (INTEGRATION_ID, PARAM_NAME)
);

-- ---------------------------------------------------------------------
-- 6. CONTROL: run / audit log
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.CTL_BATCH_RUN (
    BATCH_ID             VARCHAR2(40)   NOT NULL,     -- yyyymmddhh24miss
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,
    STAGE                VARCHAR2(10)   NOT NULL,     -- LAND / HARMONIZE / PUBLISH
    STATUS               VARCHAR2(10)   NOT NULL,     -- RUNNING / SUCCESS / FAILED / SKIPPED
    START_TS             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    END_TS               TIMESTAMP,
    ROWS_READ            NUMBER(12),
    ROWS_INSERTED        NUMBER(12),
    ROWS_UPDATED         NUMBER(12),
    ROWS_REJECTED        NUMBER(12),
    SRC_FILE_NAME        VARCHAR2(300),
    TASKFLOW_RUN_ID      VARCHAR2(100),
    ERROR_MESSAGE        VARCHAR2(4000),
    CONSTRAINT PK_CTL_BATCH_RUN PRIMARY KEY (BATCH_ID, INTEGRATION_ID, STAGE)
);
CREATE INDEX IX_CTL_BATCH_RUN_INT ON MATMAS.CTL_BATCH_RUN (INTEGRATION_ID, START_TS);

-- ---------------------------------------------------------------------
-- 7. LANDING: JDE (columns = file header + START/END DATE + audit, all text)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER_JDE (
    ERP_ITEM_NUMBER        VARCHAR2(100),
    MATERIAL_DESCRIPTION   VARCHAR2(500),
    PLANT_CODE             VARCHAR2(50),
    SUPPLIER_PART_NO       VARCHAR2(200),     -- "4462658 (Primary)" as delivered
    SUPPLIER_NUMBER        VARCHAR2(100),
    MANUFACTURING_PART_NO  VARCHAR2(200),     -- "4462658 (Fallback)" as delivered
    START_DATE             VARCHAR2(30),      -- new column requested
    END_DATE               VARCHAR2(30),      -- new column requested
    -- audit (same 6 columns on every landing table)
    BATCH_ID               VARCHAR2(40)   NOT NULL,
    INTEGRATION_ID         VARCHAR2(60)   NOT NULL,
    SRC_FILE_NAME          VARCHAR2(300),
    SRC_ROW_NUM            NUMBER(12),
    LOAD_TS                TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    LOAD_STATUS            VARCHAR2(10)   DEFAULT 'NEW'       -- NEW / PROCESSED / REJECTED
);
CREATE INDEX IX_MM_JDE_BATCH ON MATMAS.MATERIAL_MASTER_JDE (BATCH_ID);

-- ---------------------------------------------------------------------
-- 8. LANDING: VISION (layout ASSUMED - replace with real file header)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER_VISION (
    ITEM_CODE              VARCHAR2(100),
    ITEM_DESC              VARCHAR2(500),
    SITE_CODE              VARCHAR2(50),
    VENDOR_ID              VARCHAR2(100),
    VENDOR_PART            VARCHAR2(200),
    VENDOR_PART_PRIORITY   VARCHAR2(20),      -- e.g. P / F
    MFR_PART               VARCHAR2(200),
    EFF_FROM               VARCHAR2(30),
    EFF_TO                 VARCHAR2(30),
    UOM                    VARCHAR2(20),
    BATCH_ID               VARCHAR2(40)   NOT NULL,
    INTEGRATION_ID         VARCHAR2(60)   NOT NULL,
    SRC_FILE_NAME          VARCHAR2(300),
    SRC_ROW_NUM            NUMBER(12),
    LOAD_TS                TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    LOAD_STATUS            VARCHAR2(10)   DEFAULT 'NEW'
);
CREATE INDEX IX_MM_VISION_BATCH ON MATMAS.MATERIAL_MASTER_VISION (BATCH_ID);

-- Template for the next ERP: copy block 7, rename table, replace business columns.

-- ---------------------------------------------------------------------
-- 9. CANONICAL: harmonized material master (SCD type 2)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER (
    HASH_KEY                 VARCHAR2(32)   NOT NULL,   -- MD5(natural key)
    VALID_FROM_TS            TIMESTAMP      NOT NULL,
    VALID_TO_TS              TIMESTAMP      DEFAULT TIMESTAMP '9999-12-31 00:00:00' NOT NULL,
    CURRENT_FLAG             CHAR(1)        DEFAULT 'Y' NOT NULL,
    -- natural key
    SOURCE_SYSTEM            VARCHAR2(20)   NOT NULL,
    ERP_ITEM_NUMBER          VARCHAR2(50)   NOT NULL,
    PLANT_CODE               VARCHAR2(10)   NOT NULL,
    SUPPLIER_NUMBER          VARCHAR2(30)   NOT NULL,
    SUPPLIER_PART_NUMBER     VARCHAR2(60)   NOT NULL,
    -- attributes
    MATERIAL_DESCRIPTION     VARCHAR2(240),
    SUPPLIER_PART_ROLE       VARCHAR2(10),               -- PRIMARY / FALLBACK
    MANUFACTURER_PART_NUMBER VARCHAR2(60),
    MANUFACTURER_PART_ROLE   VARCHAR2(10),               -- PRIMARY / FALLBACK
    START_DATE               DATE           NOT NULL,    -- business effectivity
    END_DATE                 DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    ITEM_STATUS              VARCHAR2(20),
    BASE_UOM                 VARCHAR2(10),
    ITEM_CATEGORY            VARCHAR2(50),
    COMMODITY_CODE           VARCHAR2(30),
    EXT_ATTR_01              VARCHAR2(100),
    EXT_ATTR_02              VARCHAR2(100),
    EXT_ATTR_03              VARCHAR2(100),
    EXT_ATTR_04              VARCHAR2(100),
    EXT_ATTR_05              VARCHAR2(100),
    -- change detection + audit
    HASH_DIFF                VARCHAR2(32)   NOT NULL,
    BATCH_ID                 VARCHAR2(40)   NOT NULL,
    INTEGRATION_ID           VARCHAR2(60)   NOT NULL,
    SRC_FILE_NAME            VARCHAR2(300),
    CREATED_TS               TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_TS               TIMESTAMP,
    CONSTRAINT PK_MATERIAL_MASTER PRIMARY KEY (HASH_KEY, VALID_FROM_TS),
    CONSTRAINT FK_MM_SOURCE_SYSTEM FOREIGN KEY (SOURCE_SYSTEM)
        REFERENCES MATMAS.CTL_SOURCE_SYSTEM (SYSTEM_CODE),
    CONSTRAINT CK_MM_CURRENT CHECK (CURRENT_FLAG IN ('Y','N')),
    CONSTRAINT CK_MM_SUP_ROLE CHECK (SUPPLIER_PART_ROLE IN ('PRIMARY','FALLBACK')),
    CONSTRAINT CK_MM_MFR_ROLE CHECK (MANUFACTURER_PART_ROLE IN ('PRIMARY','FALLBACK'))
);
CREATE INDEX IX_MM_CURRENT  ON MATMAS.MATERIAL_MASTER (CURRENT_FLAG, SOURCE_SYSTEM, PLANT_CODE);
CREATE INDEX IX_MM_ITEM     ON MATMAS.MATERIAL_MASTER (SOURCE_SYSTEM, ERP_ITEM_NUMBER);
CREATE INDEX IX_MM_BATCH    ON MATMAS.MATERIAL_MASTER (BATCH_ID);

-- Current view (what targets consume)
CREATE OR REPLACE VIEW MATMAS.V_MATERIAL_MASTER_CURRENT AS
SELECT * FROM MATMAS.MATERIAL_MASTER WHERE CURRENT_FLAG = 'Y';

-- ---------------------------------------------------------------------
-- 10. CANONICAL: cross-reference of the same material across systems
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER_XREF (
    SOURCE_SYSTEM        VARCHAR2(20)   NOT NULL,
    SOURCE_ITEM_NUMBER   VARCHAR2(50)   NOT NULL,
    PLANT_CODE           VARCHAR2(10)   NOT NULL,
    TARGET_SYSTEM        VARCHAR2(20)   NOT NULL,
    TARGET_ITEM_NUMBER   VARCHAR2(50)   NOT NULL,
    TARGET_PLANT_CODE    VARCHAR2(10),
    START_DATE           DATE           NOT NULL,
    END_DATE             DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    ACTIVE_FLAG          CHAR(1)        DEFAULT 'Y' NOT NULL,
    CREATED_TS           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_TS           TIMESTAMP,
    CONSTRAINT PK_MM_XREF PRIMARY KEY (SOURCE_SYSTEM, SOURCE_ITEM_NUMBER, PLANT_CODE, TARGET_SYSTEM)
);

-- ---------------------------------------------------------------------
-- 11. CANONICAL: rejects
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER_REJECT (
    BATCH_ID             VARCHAR2(40)   NOT NULL,
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,
    SRC_FILE_NAME        VARCHAR2(300),
    SRC_ROW_NUM          NUMBER(12),
    REJECT_REASON        VARCHAR2(500)  NOT NULL,
    RAW_RECORD           VARCHAR2(4000),
    REJECT_TS            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    REPROCESSED_FLAG     CHAR(1)        DEFAULT 'N' NOT NULL
);
CREATE INDEX IX_MM_REJECT_BATCH ON MATMAS.MATERIAL_MASTER_REJECT (BATCH_ID, INTEGRATION_ID);

-- ---------------------------------------------------------------------
-- 12. CANONICAL: outbound publish log (idempotent publish)
-- ---------------------------------------------------------------------
CREATE TABLE MATMAS.MATERIAL_MASTER_OUTBOUND (
    INTEGRATION_ID       VARCHAR2(60)   NOT NULL,     -- outbound route
    HASH_KEY             VARCHAR2(32)   NOT NULL,
    VALID_FROM_TS        TIMESTAMP      NOT NULL,     -- which version was sent
    BATCH_ID             VARCHAR2(40)   NOT NULL,
    PUBLISH_STATUS       VARCHAR2(10)   NOT NULL,     -- SENT / SUCCESS / FAILED
    PUBLISHED_TS         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    TARGET_REFERENCE     VARCHAR2(100),               -- IDoc no., file name, API id
    ERROR_MESSAGE        VARCHAR2(4000),
    CONSTRAINT PK_MM_OUTBOUND PRIMARY KEY (INTEGRATION_ID, HASH_KEY, VALID_FROM_TS)
);

-- ---------------------------------------------------------------------
-- 13. RUNTIME VIEW: builds the harmonize SELECT per inbound route
--     Output column list is ALWAYS the full canonical list (unmapped = NULL)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MATMAS.V_CTL_INBOUND_RUNTIME AS
WITH canon AS (                                   -- fixed canonical column list
    SELECT 'ERP_ITEM_NUMBER'          AS COL, 10 AS ORD FROM DUAL UNION ALL
    SELECT 'MATERIAL_DESCRIPTION',       20 FROM DUAL UNION ALL
    SELECT 'PLANT_CODE',                 30 FROM DUAL UNION ALL
    SELECT 'SUPPLIER_NUMBER',            40 FROM DUAL UNION ALL
    SELECT 'SUPPLIER_PART_NUMBER',       50 FROM DUAL UNION ALL
    SELECT 'SUPPLIER_PART_ROLE',         60 FROM DUAL UNION ALL
    SELECT 'MANUFACTURER_PART_NUMBER',   70 FROM DUAL UNION ALL
    SELECT 'MANUFACTURER_PART_ROLE',     80 FROM DUAL UNION ALL
    SELECT 'START_DATE',                 90 FROM DUAL UNION ALL
    SELECT 'END_DATE',                  100 FROM DUAL UNION ALL
    SELECT 'ITEM_STATUS',               110 FROM DUAL UNION ALL
    SELECT 'BASE_UOM',                  120 FROM DUAL UNION ALL
    SELECT 'ITEM_CATEGORY',             130 FROM DUAL UNION ALL
    SELECT 'COMMODITY_CODE',            140 FROM DUAL UNION ALL
    SELECT 'EXT_ATTR_01',               150 FROM DUAL UNION ALL
    SELECT 'EXT_ATTR_02',               160 FROM DUAL UNION ALL
    SELECT 'EXT_ATTR_03',               170 FROM DUAL UNION ALL
    SELECT 'EXT_ATTR_04',               180 FROM DUAL UNION ALL
    SELECT 'EXT_ATTR_05',               190 FROM DUAL
),
sel AS (
    SELECT i.INTEGRATION_ID,
           LISTAGG(
             COALESCE(m.TRANSFORM_EXPR, m.SOURCE_COLUMN,
                      CASE WHEN m.DEFAULT_VALUE IS NOT NULL THEN '''' || m.DEFAULT_VALUE || '''' END,
                      'NULL')
             || ' AS ' || c.COL, ', ') WITHIN GROUP (ORDER BY c.ORD)    AS SELECT_LIST,
           LISTAGG(
             CASE WHEN m.MANDATORY_FLAG = 'Y'
                  THEN 'WHEN ' || COALESCE(m.TRANSFORM_EXPR, m.SOURCE_COLUMN) || ' IS NULL THEN ''MISSING ' || c.COL || ''''
             END, ' ') WITHIN GROUP (ORDER BY c.ORD)                    AS MANDATORY_CHECKS
    FROM   MATMAS.CTL_INBOUND_INTEGRATION i
    CROSS  JOIN canon c
    LEFT   JOIN MATMAS.CTL_FIELD_MAPPING m
           ON  m.INTEGRATION_ID = i.INTEGRATION_ID
           AND m.DIRECTION      = 'IN'
           AND m.TARGET_COLUMN  = c.COL
           AND m.ACTIVE_FLAG    = 'Y'
    GROUP  BY i.INTEGRATION_ID
)
SELECT i.INTEGRATION_ID, i.INTEGRATION_NAME, i.SOURCE_SYSTEM, i.SOURCE_TYPE,
       i.SOURCE_CONNECTION, i.SOURCE_OBJECT, i.SOURCE_SUBFOLDER, i.LANDING_TABLE,
       i.LOAD_TYPE, i.NATURAL_KEY_COLUMNS, i.RUN_GROUP, i.RUN_SEQUENCE,
       ROW_NUMBER() OVER (PARTITION BY i.RUN_GROUP ORDER BY i.RUN_SEQUENCE, i.INTEGRATION_ID) AS ROW_NUM,
       COUNT(*)     OVER (PARTITION BY i.RUN_GROUP)                                           AS TOTAL_ROWS,
       COALESCE(i.HARMONIZE_SQL_OVERRIDE,
         'SELECT ''' || i.SOURCE_SYSTEM || ''' AS SOURCE_SYSTEM, '
         || s.SELECT_LIST
         || CASE WHEN s.MANDATORY_CHECKS IS NULL THEN ', NULL AS REJECT_REASON'
                 ELSE ', CASE ' || s.MANDATORY_CHECKS || ' ELSE NULL END AS REJECT_REASON' END
         || ', BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM'
         || ' FROM ' || i.LANDING_TABLE
         || ' WHERE BATCH_ID = ''$$BATCH_ID''')                                               AS HARMONIZE_SQL
FROM   MATMAS.CTL_INBOUND_INTEGRATION i
JOIN   sel s ON s.INTEGRATION_ID = i.INTEGRATION_ID
WHERE  i.ACTIVE_FLAG = 'Y';

-- ---------------------------------------------------------------------
-- 14. RUNTIME VIEW: builds the publish SELECT per outbound route
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MATMAS.V_CTL_OUTBOUND_RUNTIME AS
WITH sel AS (
    SELECT m.INTEGRATION_ID,
           LISTAGG(COALESCE(m.TRANSFORM_EXPR, 'mm.' || m.SOURCE_COLUMN) || ' AS ' || m.TARGET_COLUMN, ', ')
             WITHIN GROUP (ORDER BY m.ORDINAL) AS SELECT_LIST
    FROM   MATMAS.CTL_FIELD_MAPPING m
    WHERE  m.DIRECTION = 'OUT' AND m.ACTIVE_FLAG = 'Y'
    GROUP  BY m.INTEGRATION_ID
)
SELECT o.INTEGRATION_ID, o.INTEGRATION_NAME, o.TARGET_SYSTEM, o.TARGET_TYPE,
       o.TARGET_CONNECTION, o.TARGET_OBJECT, o.PUBLISH_MODE, o.POST_COMMAND,
       o.RUN_GROUP, o.RUN_SEQUENCE,
       ROW_NUMBER() OVER (PARTITION BY o.RUN_GROUP ORDER BY o.RUN_SEQUENCE, o.INTEGRATION_ID) AS ROW_NUM,
       COUNT(*)     OVER (PARTITION BY o.RUN_GROUP)                                           AS TOTAL_ROWS,
       COALESCE(o.PUBLISH_SQL_OVERRIDE,
         'SELECT mm.HASH_KEY, mm.VALID_FROM_TS, ' || s.SELECT_LIST
         || ' FROM MATMAS.MATERIAL_MASTER mm'
         || ' WHERE mm.CURRENT_FLAG = ''Y'' AND (' || o.SOURCE_FILTER || ')'
         || CASE WHEN o.PUBLISH_MODE = 'DELTA' THEN
              ' AND NOT EXISTS (SELECT 1 FROM MATMAS.MATERIAL_MASTER_OUTBOUND ob'
              || ' WHERE ob.INTEGRATION_ID = ''' || o.INTEGRATION_ID || ''''
              || ' AND ob.HASH_KEY = mm.HASH_KEY AND ob.VALID_FROM_TS = mm.VALID_FROM_TS'
              || ' AND ob.PUBLISH_STATUS = ''SUCCESS'')'
            ELSE '' END)                                                                      AS PUBLISH_SQL
FROM   MATMAS.CTL_OUTBOUND_INTEGRATION o
JOIN   sel s ON s.INTEGRATION_ID = o.INTEGRATION_ID
WHERE  o.ACTIVE_FLAG = 'Y';

-- Sequence for CTL_FIELD_MAPPING.MAPPING_ID
CREATE SEQUENCE MATMAS.SEQ_CTL_FIELD_MAPPING START WITH 1000 INCREMENT BY 1;
