/* =====================================================================
   matmas - material master, config-driven ingestion (Informatica CDI)
   01: schemas, config tables, run log, staging, reject, file history,
       ERP target tables, views, and the CDI interface views in schema stg.

   platform  : SQL database in Microsoft Fabric (T-SQL, compatibility level 160)
   cdi conn  : jdbcv2.MSSQL.sqldb-p2o-intg.stg (JDBC V2, default schema stg)
   run order : 01 -> 02 -> 03 -> 04 (test)

   naming standard (same as cfg.erp_file_config, cfg.erp_field_map):
     schema, table, view, column, constraint, index and procedure names are
     lower case with underscores. Flags are bit (1 = yes, 0 = no).

     cfg.matmas_setting            org-wide values (OneLake connection, root)
     cfg.matmas_route_config       one row per source location
     matmas.*                      run log, stage, reject, file history,
                                   ERP tables, views, procedures
     stg.matmas_*                  views the CDI mappings read and write
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'cfg')    EXEC ('CREATE SCHEMA cfg');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'matmas') EXEC ('CREATE SCHEMA matmas');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')    EXEC ('CREATE SCHEMA stg');
GO

/* ---------------------------------------------------------------------
   1. cfg.matmas_setting - org-wide values used by every route
   --------------------------------------------------------------------- */
IF OBJECT_ID('cfg.matmas_setting') IS NULL
CREATE TABLE cfg.matmas_setting (
    setting_name                VARCHAR(60)     NOT NULL,
    setting_value               NVARCHAR(1000)  NOT NULL,
    description                 NVARCHAR(300)   NULL,
    CONSTRAINT pk_matmas_setting PRIMARY KEY (setting_name)
);
GO

/* ---------------------------------------------------------------------
   2. cfg.matmas_route_config - ONE ROW PER SOURCE LOCATION.
      Everything the taskflow needs for a location comes from here:
      where to collect (agent, connection, folder, pattern), which OneLake
      folder to use, and how to load (target table, operation, keys).
   --------------------------------------------------------------------- */
IF OBJECT_ID('cfg.matmas_route_config') IS NULL
CREATE TABLE cfg.matmas_route_config (
    route_id                    VARCHAR(60)     NOT NULL,                       -- JDE_MATMAS
    erp_system                  VARCHAR(30)     NOT NULL,                       -- JDE / VISION / SAP / ...
    route_name                  NVARCHAR(200)   NOT NULL,
    run_group                   VARCHAR(30)     NOT NULL  DEFAULT 'DAILY',
    run_order                   INT             NOT NULL  DEFAULT 10,
    active_flag                 BIT             NOT NULL  DEFAULT 1,
    -- collect: file ingestion task overrides
    runtime_environment         NVARCHAR(100)   NOT NULL,                       -- Secure Agent group where the file lands
    source_connection           NVARCHAR(100)   NOT NULL,                       -- local folder / SFTP connection in IDMC
    source_directory            NVARCHAR(500)   NOT NULL,                       -- folder on that agent
    file_pattern                NVARCHAR(200)   NOT NULL  DEFAULT N'*.txt',
    onelake_folder              NVARCHAR(100)   NOT NULL,                       -- sub-folder under erp_to_matmas/{landing,archive,duplicate,error}
    -- load: generic mapping + apply procedure
    target_schema               SYSNAME         NOT NULL  DEFAULT N'matmas',
    target_table                SYSNAME         NOT NULL,                       -- jde_material_master
    load_operation              VARCHAR(20)     NOT NULL  DEFAULT 'UPSERT',     -- INSERT / UPSERT / UPDATE / DELETE / TRUNCATE_INSERT
    key_columns                 NVARCHAR(500)   NOT NULL  DEFAULT N'erp_item_number,plant_code,supplier_number,supplier_part_number',
    start_date_value            VARCHAR(10)     NULL,                           -- yyyy-mm-dd, NULL = load date
    end_date_value              VARCHAR(10)     NOT NULL  DEFAULT '9999-12-31',
    skip_duplicate_file         BIT             NOT NULL  DEFAULT 1,            -- same file content already loaded -> skip
    notify_email                NVARCHAR(400)   NULL,
    created_ts                  DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
    created_by                  NVARCHAR(50)    NULL,
    updated_ts                  DATETIME2(3)    NULL,
    updated_by                  NVARCHAR(50)    NULL,
    CONSTRAINT pk_matmas_route_config        PRIMARY KEY (route_id),
    CONSTRAINT ck_matmas_route_config_op     CHECK (load_operation IN ('INSERT','UPSERT','UPDATE','DELETE','TRUNCATE_INSERT')),
    CONSTRAINT ck_matmas_route_config_start  CHECK (start_date_value IS NULL OR TRY_CONVERT(DATE, start_date_value, 23) IS NOT NULL),
    CONSTRAINT ck_matmas_route_config_end    CHECK (TRY_CONVERT(DATE, end_date_value, 23) IS NOT NULL)
);
GO

/* ---------------------------------------------------------------------
   3. matmas.run_log - append-only event log, one row per event.
      Written by CDI (STARTED, NO_FILE, COLLECT_FAILED, LOAD_FAILED,
      OUTCOME) and by the apply procedure (LOADED, DUPLICATE_FILE,
      APPLY_FAILED).
   --------------------------------------------------------------------- */
IF OBJECT_ID('matmas.run_log') IS NULL
CREATE TABLE matmas.run_log (
    log_id                      BIGINT          IDENTITY(1,1) NOT NULL,
    run_id                      VARCHAR(30)     NULL,
    route_id                    VARCHAR(60)     NULL,
    event                       VARCHAR(30)     NULL,
    file_count                  INT             NULL,
    rows_staged                 INT             NULL,
    rows_inserted               INT             NULL,
    rows_updated                INT             NULL,
    rows_deleted                INT             NULL,
    rows_rejected               INT             NULL,
    message                     NVARCHAR(4000)  NULL,
    log_ts                      DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_run_log PRIMARY KEY (log_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_run_log_run' AND object_id = OBJECT_ID('matmas.run_log'))
CREATE INDEX ix_run_log_run ON matmas.run_log (run_id, route_id, log_id);
GO

/* ---------------------------------------------------------------------
   4. matmas.material_master_stage - what the generic CDI mapping writes:
      the 6 file fields + start_date / end_date added in the mapping.
      matmas.sp_apply_stage moves it into the route's ERP table.
   --------------------------------------------------------------------- */
IF OBJECT_ID('matmas.material_master_stage') IS NULL
CREATE TABLE matmas.material_master_stage (
    stage_id                    BIGINT          IDENTITY(1,1) NOT NULL,
    run_id                      VARCHAR(30)     NULL,
    route_id                    VARCHAR(60)     NULL,
    source_file_name            NVARCHAR(500)   NULL,
    erp_item_number             NVARCHAR(1000)  NULL,
    material_description        NVARCHAR(1000)  NULL,
    plant_code                  NVARCHAR(1000)  NULL,
    supplier_part_number        NVARCHAR(1000)  NULL,
    supplier_number             NVARCHAR(1000)  NULL,
    manufacturing_part_number   NVARCHAR(1000)  NULL,
    start_date                  DATE            NULL,
    end_date                    DATE            NULL,
    stage_status                VARCHAR(12)     NOT NULL  DEFAULT 'NEW',        -- NEW / APPLIED / REJECTED / DUPLICATE / FAILED
    load_ts                     DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_material_master_stage PRIMARY KEY (stage_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_material_master_stage_status' AND object_id = OBJECT_ID('matmas.material_master_stage'))
CREATE INDEX ix_material_master_stage_status ON matmas.material_master_stage (stage_status, run_id, route_id);
GO

/* ---------------------------------------------------------------------
   5. matmas.material_master_reject - rows that failed validation
   --------------------------------------------------------------------- */
IF OBJECT_ID('matmas.material_master_reject') IS NULL
CREATE TABLE matmas.material_master_reject (
    reject_id                   BIGINT          IDENTITY(1,1) NOT NULL,
    run_id                      VARCHAR(30)     NULL,
    route_id                    VARCHAR(60)     NULL,
    source_file_name            NVARCHAR(500)   NULL,
    reject_reason               NVARCHAR(500)   NOT NULL,
    erp_item_number             NVARCHAR(1000)  NULL,
    material_description        NVARCHAR(1000)  NULL,
    plant_code                  NVARCHAR(1000)  NULL,
    supplier_part_number        NVARCHAR(1000)  NULL,
    supplier_number             NVARCHAR(1000)  NULL,
    manufacturing_part_number   NVARCHAR(1000)  NULL,
    reject_ts                   DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_material_master_reject PRIMARY KEY (reject_id)
);
GO

/* ---------------------------------------------------------------------
   6. matmas.file_history - fingerprint of every applied file, so a file
      collected twice is not loaded twice.
   --------------------------------------------------------------------- */
IF OBJECT_ID('matmas.file_history') IS NULL
CREATE TABLE matmas.file_history (
    route_id                    VARCHAR(60)     NOT NULL,
    file_fingerprint            VARCHAR(64)     NOT NULL,                       -- SHA2_256 of the file's rows
    source_file_name            NVARCHAR(500)   NULL,
    row_count                   INT             NULL,
    run_id                      VARCHAR(30)     NULL,
    applied_ts                  DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_file_history PRIMARY KEY (route_id, file_fingerprint)
);
GO

/* ---------------------------------------------------------------------
   7. ERP target tables - one per ERP, identical columns:
      the 6 business fields + start_date / end_date + audit columns.
      matmas.sp_create_erp_table creates a new one from the same template.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE matmas.sp_create_erp_table
    @table_name   SYSNAME,
    @schema_name  SYSNAME = N'matmas'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @full NVARCHAR(300) = QUOTENAME(@schema_name) + N'.' + QUOTENAME(@table_name),
            @sql  NVARCHAR(MAX);

    IF OBJECT_ID(@full, 'U') IS NOT NULL
    BEGIN
        PRINT CONCAT('exists: ', @full);
        RETURN;
    END

    SET @sql = N'CREATE TABLE ' + @full + N' (
        erp_item_number             NVARCHAR(50)    NOT NULL,
        material_description        NVARCHAR(240)   NULL,
        plant_code                  NVARCHAR(20)    NOT NULL,
        supplier_part_number        NVARCHAR(80)    NULL,
        supplier_number             NVARCHAR(30)    NULL,
        manufacturing_part_number   NVARCHAR(80)    NULL,
        start_date                  DATE            NOT NULL,
        end_date                    DATE            NOT NULL,
        source_file_name            NVARCHAR(500)   NULL,
        run_id                      VARCHAR(30)     NULL,
        created_ts                  DATETIME2(3)    NOT NULL  DEFAULT SYSUTCDATETIME(),
        updated_ts                  DATETIME2(3)    NULL);
      CREATE INDEX ' + QUOTENAME(N'ix_' + @table_name + N'_key') + N' ON ' + @full
      + N' (erp_item_number, plant_code, supplier_number, supplier_part_number);';
    EXEC sp_executesql @sql;
    PRINT CONCAT('created: ', @full);
END
GO
EXEC matmas.sp_create_erp_table N'jde_material_master';
EXEC matmas.sp_create_erp_table N'vision_material_master';
EXEC matmas.sp_create_erp_table N'sap_material_master';
GO

/* ---------------------------------------------------------------------
   8. Views
   --------------------------------------------------------------------- */
-- active routes with a row number per run group (the taskflow loop reads row N)
CREATE OR ALTER VIEW matmas.v_route_reader AS
WITH setting AS (
    SELECT MAX(CASE WHEN setting_name = 'onelake_connection' THEN setting_value END) AS onelake_connection,
           MAX(CASE WHEN setting_name = 'onelake_root'       THEN setting_value END) AS onelake_root
    FROM   cfg.matmas_setting
)
SELECT CAST(ROW_NUMBER() OVER (PARTITION BY r.run_group ORDER BY r.run_order, r.route_id) AS INT)   AS row_num,
       CAST(COUNT(*) OVER (PARTITION BY r.run_group) AS INT)                                        AS total_routes,
       CAST(r.run_group                                                   AS NVARCHAR(30))          AS run_group,
       CAST(r.route_id                                                    AS NVARCHAR(60))          AS route_id,
       CAST(r.erp_system                                                  AS NVARCHAR(30))          AS erp_system,
       r.runtime_environment                                                                        AS runtime_environment,
       r.source_connection                                                                          AS source_connection,
       r.source_directory                                                                           AS source_directory,
       r.file_pattern                                                                               AS file_pattern,
       CAST(s.onelake_connection                                          AS NVARCHAR(100))         AS onelake_connection,
       CAST(CONCAT(s.onelake_root, N'/landing/',   r.onelake_folder)      AS NVARCHAR(500))         AS onelake_landing_dir,
       CAST(CONCAT(s.onelake_root, N'/archive/',   r.onelake_folder)      AS NVARCHAR(500))         AS onelake_archive_dir,
       CAST(CONCAT(s.onelake_root, N'/duplicate/', r.onelake_folder)      AS NVARCHAR(500))         AS onelake_duplicate_dir,
       CAST(CONCAT(s.onelake_root, N'/error/',     r.onelake_folder)      AS NVARCHAR(500))         AS onelake_error_dir,
       CAST(CONCAT(r.target_schema, N'.', r.target_table)                 AS NVARCHAR(300))         AS target_table,
       CAST(r.load_operation                                              AS NVARCHAR(20))          AS load_operation,
       CAST(ISNULL(r.start_date_value, '')                                AS NVARCHAR(10))          AS start_date_value,
       CAST(r.end_date_value                                              AS NVARCHAR(10))          AS end_date_value,
       CAST(ISNULL(r.notify_email, N'')                                   AS NVARCHAR(400))         AS notify_email
FROM   cfg.matmas_route_config r
CROSS  JOIN setting s
WHERE  r.active_flag = 1;
GO

-- last event per run and route
CREATE OR ALTER VIEW matmas.v_run_status AS
SELECT run_id,
       route_id,
       event            AS last_event,
       file_count,
       rows_staged,
       rows_inserted,
       rows_updated,
       rows_deleted,
       rows_rejected,
       message,
       log_ts
FROM  (SELECT *, ROW_NUMBER() OVER (PARTITION BY run_id, route_id ORDER BY log_id DESC) AS rn
       FROM   matmas.run_log) x
WHERE  rn = 1;
GO

-- outcome of one run + route: decides which OneLake folder the run's files move to
CREATE OR ALTER VIEW matmas.v_run_outcome AS
SELECT run_id,
       route_id,
       CAST(CASE WHEN SUM(CASE WHEN event IN ('APPLY_FAILED','LOAD_FAILED') THEN 1 ELSE 0 END) > 0
                 THEN 'ERROR'
                 WHEN SUM(CASE WHEN event = 'DUPLICATE_FILE' THEN 1 ELSE 0 END) > 0
                  AND SUM(CASE WHEN event = 'LOADED' THEN ISNULL(rows_inserted,0) + ISNULL(rows_updated,0) + ISNULL(rows_deleted,0) ELSE 0 END) = 0
                  AND SUM(CASE WHEN event = 'LOADED' THEN ISNULL(rows_rejected,0) ELSE 0 END) = 0
                 THEN 'DUPLICATE'
                 WHEN SUM(CASE WHEN event = 'LOADED' THEN 1 ELSE 0 END) > 0
                 THEN 'ARCHIVE'
                 ELSE 'ERROR'
            END AS NVARCHAR(20)) AS outcome
FROM   matmas.run_log
GROUP  BY run_id, route_id;
GO

/* ---------------------------------------------------------------------
   9. CDI interface views in schema stg (the JDBC V2 connection's default
      schema). Single-table views, so the two writer views accept INSERT.
   --------------------------------------------------------------------- */
-- source of m_P2O_101_MATMAS_Route_Reader
CREATE OR ALTER VIEW stg.matmas_route_reader AS
SELECT row_num,
       total_routes,
       run_group,
       route_id,
       erp_system,
       runtime_environment,
       source_connection,
       source_directory,
       file_pattern,
       onelake_connection,
       onelake_landing_dir,
       onelake_archive_dir,
       onelake_duplicate_dir,
       onelake_error_dir,
       target_table,
       load_operation,
       start_date_value,
       end_date_value,
       notify_email
FROM   matmas.v_route_reader;
GO

-- source of m_P2O_103_MATMAS_Outcome
CREATE OR ALTER VIEW stg.matmas_run_outcome AS
SELECT CAST(run_id   AS NVARCHAR(30)) AS run_id,
       CAST(route_id AS NVARCHAR(60)) AS route_id,
       outcome
FROM   matmas.v_run_outcome;
GO

-- target of the reader, outcome and log mappings
CREATE OR ALTER VIEW stg.matmas_run_log AS
SELECT run_id,
       route_id,
       event,
       file_count,
       message
FROM   matmas.run_log;
GO

-- target of m_P2O_102_MATMAS_Load (the mapping maps the file header fields to these columns)
CREATE OR ALTER VIEW stg.matmas_stage_file AS
SELECT run_id,
       route_id,
       source_file_name,
       erp_item_number,
       material_description,
       plant_code,
       supplier_part_number,
       supplier_number,
       manufacturing_part_number,
       start_date,
       end_date
FROM   matmas.material_master_stage;
GO

-- one-row source of m_P2O_104_MATMAS_Log
CREATE OR ALTER VIEW stg.matmas_one_row AS
SELECT CAST(1 AS INT) AS one;
GO
