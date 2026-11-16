/* =====================================================================
   MATMAS - 02: stored procedures
   sp_MATMAS_Process  : ENTRY POINT. Called by the Post SQL of the CDI
                        mapping m_MATMAS_PROCESS (or by hand). Runs
                        Assign -> Harmonize (each route) -> Publish (each route).
   sp_MATMAS_Assign   : stamps batch id on new landing rows, numbers rows
                        per file, routes each file by sub-folder + file name.
   sp_Harmonize       : one route: header check, SELECT generated from
                        CTL_FIELD_MAPPING, rejects, duplicates, SCD2 merge.
   sp_Publish         : one outbound route: INSERT generated from OUT mappings.
   sp_MATMAS_Reprocess: re-run harmonize (+ publish) for an earlier batch.
   Platform: SQL database in Fabric (T-SQL, compatibility level 160)
   ===================================================================== */

/* ---------------------------------------------------------------------
   sp_MATMAS_Assign
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_Assign
    @BatchId     VARCHAR(40),
    @FilesFound  INT OUTPUT,
    @FilesRouted INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @FilesFound = 0, @FilesRouted = 0;

    -- 1. claim every row the land mapping wrote since the last run
    UPDATE MATMAS.LANDING_RAW SET BATCH_ID = @BatchId
    WHERE  LOAD_STATUS = 'NEW' AND BATCH_ID IS NULL;

    -- 2. drop completely empty lines (e.g. trailing newline)
    DELETE FROM MATMAS.LANDING_RAW
    WHERE  BATCH_ID = @BatchId
      AND  LEN(CONCAT(COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08,COL09,COL10,
                      COL11,COL12,COL13,COL14,COL15,COL16,COL17,COL18,COL19,COL20,
                      COL21,COL22,COL23,COL24,COL25,COL26,COL27,COL28,COL29,COL30)) = 0;

    -- 3. row number per file in arrival order (row 1 = header)
    ;WITH n AS (
        SELECT SRC_ROW_NUM, ROW_NUMBER() OVER (PARTITION BY SRC_FILE_NAME ORDER BY LANDING_ID) AS rn
        FROM   MATMAS.LANDING_RAW WHERE BATCH_ID = @BatchId)
    UPDATE n SET SRC_ROW_NUM = rn;

    -- strip a UTF-8 byte order mark from the first header cell
    UPDATE MATMAS.LANDING_RAW SET COL01 = REPLACE(COL01, NCHAR(65279), N'')
    WHERE  BATCH_ID = @BatchId AND SRC_ROW_NUM = 1;

    -- 4. route each file: parent folder name = FOLDER_KEY, file name LIKE FILE_NAME_PATTERN
    CREATE TABLE #files (SRC_FILE_NAME NVARCHAR(500), FILE_NAME NVARCHAR(500), FOLDER NVARCHAR(500), INTEGRATION_ID VARCHAR(60), ROWS_CNT INT);

    ;WITH f AS (
        SELECT SRC_FILE_NAME, REPLACE(ISNULL(SRC_FILE_NAME, N''), N'\', N'/') AS p, COUNT(*) AS cnt
        FROM   MATMAS.LANDING_RAW WHERE BATCH_ID = @BatchId
        GROUP  BY SRC_FILE_NAME),
    f2 AS (SELECT SRC_FILE_NAME, p, cnt, RIGHT(p, CHARINDEX(N'/', REVERSE(p) + N'/') - 1) AS fname FROM f),
    f3 AS (SELECT SRC_FILE_NAME, cnt, fname,
                  CASE WHEN LEN(p) > LEN(fname) THEN LEFT(p, LEN(p) - LEN(fname) - 1) ELSE N'' END AS dir FROM f2)
    INSERT INTO #files (SRC_FILE_NAME, FILE_NAME, FOLDER, ROWS_CNT)
    SELECT SRC_FILE_NAME, fname, RIGHT(dir, CHARINDEX(N'/', REVERSE(dir) + N'/') - 1), cnt FROM f3;

    ;WITH m AS (
        SELECT f.SRC_FILE_NAME, r.INTEGRATION_ID,
               ROW_NUMBER() OVER (PARTITION BY f.SRC_FILE_NAME ORDER BY r.RUN_SEQUENCE, r.INTEGRATION_ID) AS rn
        FROM   #files f
        JOIN   MATMAS.CTL_INBOUND_INTEGRATION r
               ON  UPPER(r.FOLDER_KEY) = UPPER(f.FOLDER)
               AND f.FILE_NAME LIKE r.FILE_NAME_PATTERN
               AND r.ACTIVE_FLAG = 'Y' AND r.SOURCE_TYPE = 'FILE')
    UPDATE f SET INTEGRATION_ID = m.INTEGRATION_ID
    FROM   #files f JOIN m ON m.SRC_FILE_NAME = f.SRC_FILE_NAME AND m.rn = 1;

    UPDATE l SET INTEGRATION_ID = ISNULL(f.INTEGRATION_ID, 'UNROUTED'),
                 LOAD_STATUS    = CASE WHEN f.INTEGRATION_ID IS NULL THEN 'UNROUTED' ELSE 'ASSIGNED' END
    FROM   MATMAS.LANDING_RAW l JOIN #files f ON f.SRC_FILE_NAME = l.SRC_FILE_NAME
    WHERE  l.BATCH_ID = @BatchId;

    SELECT @FilesFound = COUNT(*), @FilesRouted = COUNT(INTEGRATION_ID) FROM #files;

    -- 5. log one ASSIGN row per route (+ one for unrouted files)
    INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS, END_TS, ROWS_READ, SRC_FILE_NAME, MESSAGE)
    SELECT @BatchId, ISNULL(INTEGRATION_ID, 'UNROUTED'), 'ASSIGN',
           CASE WHEN INTEGRATION_ID IS NULL THEN 'FAILED' ELSE 'SUCCESS' END,
           SYSUTCDATETIME(), SUM(ROWS_CNT),
           LEFT(STRING_AGG(CAST(FILE_NAME AS NVARCHAR(MAX)), N', '), 500),
           CASE WHEN INTEGRATION_ID IS NULL
                THEN LEFT(CONCAT(N'No active FILE route matches folder/file: ',
                                 STRING_AGG(CAST(CONCAT(FOLDER, N'/', FILE_NAME) AS NVARCHAR(MAX)), N', ')), 4000)
                ELSE CONCAT(COUNT(*), N' file(s) routed') END
    FROM   #files
    GROUP  BY INTEGRATION_ID;
END
GO

/* ---------------------------------------------------------------------
   sp_Harmonize  (one inbound route, one batch)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_Harmonize
    @IntegrationId  VARCHAR(60),
    @BatchId        VARCHAR(40),
    @RowsRead       INT            OUTPUT,
    @RowsInserted   INT            OUTPUT,
    @RowsUpdated    INT            OUTPUT,
    @RowsRejected   INT            OUTPUT,
    @Message        NVARCHAR(2000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Now        DATETIME2(3) = SYSUTCDATETIME(),
            @Src        VARCHAR(20), @LoadType VARCHAR(10),
            @ExpHdr     NVARCHAR(2000), @Hdr NVARCHAR(2000), @BadFile NVARCHAR(500), @N INT,
            @KeyCols    VARCHAR(500),
            @Sql        NVARCHAR(MAX), @ColList NVARCHAR(MAX), @SelectList NVARCHAR(MAX),
            @RejectList NVARCHAR(MAX), @KeyExpr NVARCHAR(MAX), @DiffExpr NVARCHAR(MAX),
            @Dups INT = 0, @Closed INT = 0, @Err NVARCHAR(2048);

    SELECT @RowsRead = 0, @RowsInserted = 0, @RowsUpdated = 0, @RowsRejected = 0;

    SELECT @Src = SOURCE_SYSTEM, @LoadType = LOAD_TYPE, @ExpHdr = EXPECTED_HEADER, @KeyCols = NATURAL_KEY_COLUMNS
    FROM   MATMAS.CTL_INBOUND_INTEGRATION
    WHERE  INTEGRATION_ID = @IntegrationId;

    IF @Src IS NULL
    BEGIN
        SET @Err = CONCAT('Unknown inbound INTEGRATION_ID ', @IntegrationId);
        THROW 50001, @Err, 1;
    END

    IF NOT EXISTS (SELECT 1 FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'HARMONIZE')
        INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS) VALUES (@BatchId, @IntegrationId, 'HARMONIZE', 'RUNNING');
    ELSE
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'RUNNING', START_TS = @Now, END_TS = NULL, MESSAGE = NULL
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'HARMONIZE';

    -- re-run safety: remove rejects of an earlier attempt of the same batch/route
    DELETE FROM MATMAS.MATERIAL_MASTER_REJECT WHERE BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId;

    /* typed canonical staging (keep in sync with CTL_CANONICAL_COLUMN) */
    CREATE TABLE #stg (
        LANDING_ID               BIGINT,
        SRC_ROW_NUM              INT,
        SRC_FILE_NAME            NVARCHAR(500),
        SOURCE_SYSTEM            VARCHAR(20),
        ERP_ITEM_NUMBER          VARCHAR(50),
        MATERIAL_DESCRIPTION     NVARCHAR(240),
        PLANT_CODE               VARCHAR(10),
        SUPPLIER_NUMBER          VARCHAR(30),
        SUPPLIER_PART_NUMBER     VARCHAR(60),
        SUPPLIER_PART_ROLE       VARCHAR(10),
        MANUFACTURER_PART_NUMBER VARCHAR(60),
        MANUFACTURER_PART_ROLE   VARCHAR(10),
        START_DATE               DATE,
        END_DATE                 DATE,
        ITEM_STATUS              VARCHAR(20),
        BASE_UOM                 VARCHAR(10),
        ITEM_CATEGORY            VARCHAR(50),
        COMMODITY_CODE           VARCHAR(30),
        EXT_ATTR_01              NVARCHAR(100),
        EXT_ATTR_02              NVARCHAR(100),
        EXT_ATTR_03              NVARCHAR(100),
        EXT_ATTR_04              NVARCHAR(100),
        EXT_ATTR_05              NVARCHAR(100),
        REJECT_REASON            NVARCHAR(500),
        HASH_KEY                 VARCHAR(32),
        HASH_DIFF                VARCHAR(32),
        RN                       INT
    );

    BEGIN TRY
        /* ---- 1. count + header validation (every file of the route) ---- */
        SELECT @RowsRead = COUNT(*)
        FROM   MATMAS.LANDING_RAW
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND SRC_ROW_NUM > 1;

        IF @ExpHdr IS NOT NULL
        BEGIN
            SET @N = LEN(@ExpHdr) - LEN(REPLACE(@ExpHdr, '|', '')) + 1;
            ;WITH h AS (
                SELECT SRC_FILE_NAME, CONCAT_WS('|',
                         COL01, IIF(@N>=2,COL02,NULL), IIF(@N>=3,COL03,NULL), IIF(@N>=4,COL04,NULL), IIF(@N>=5,COL05,NULL),
                         IIF(@N>=6,COL06,NULL), IIF(@N>=7,COL07,NULL), IIF(@N>=8,COL08,NULL), IIF(@N>=9,COL09,NULL), IIF(@N>=10,COL10,NULL),
                         IIF(@N>=11,COL11,NULL), IIF(@N>=12,COL12,NULL), IIF(@N>=13,COL13,NULL), IIF(@N>=14,COL14,NULL), IIF(@N>=15,COL15,NULL),
                         IIF(@N>=16,COL16,NULL), IIF(@N>=17,COL17,NULL), IIF(@N>=18,COL18,NULL), IIF(@N>=19,COL19,NULL), IIF(@N>=20,COL20,NULL),
                         IIF(@N>=21,COL21,NULL), IIF(@N>=22,COL22,NULL), IIF(@N>=23,COL23,NULL), IIF(@N>=24,COL24,NULL), IIF(@N>=25,COL25,NULL),
                         IIF(@N>=26,COL26,NULL), IIF(@N>=27,COL27,NULL), IIF(@N>=28,COL28,NULL), IIF(@N>=29,COL29,NULL), IIF(@N>=30,COL30,NULL)) AS HDR
                FROM   MATMAS.LANDING_RAW
                WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND SRC_ROW_NUM = 1)
            SELECT TOP 1 @BadFile = SRC_FILE_NAME, @Hdr = HDR
            FROM   h
            WHERE  UPPER(LTRIM(RTRIM(HDR))) <> UPPER(LTRIM(RTRIM(@ExpHdr)));

            IF @BadFile IS NOT NULL
            BEGIN
                SET @Err = LEFT(CONCAT('Header mismatch in ', @BadFile, '. Expected [', @ExpHdr, '] got [', @Hdr, ']'), 2048);
                THROW 50002, @Err, 1;
            END
        END

        /* ---- 2. dynamic SELECT generated from CTL_FIELD_MAPPING --------- */
        SELECT
            @ColList    = STRING_AGG(CAST(c.COLUMN_NAME AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.ORDINAL),
            @SelectList = STRING_AGG(CAST(
                            COALESCE(m.TRANSFORM_EXPR, m.SOURCE_COLUMN,
                                     CASE WHEN m.DEFAULT_VALUE IS NOT NULL
                                          THEN '''' + REPLACE(m.DEFAULT_VALUE, '''', '''''') + '''' END,
                                     'NULL')
                            + ' AS ' + c.COLUMN_NAME AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.ORDINAL),
            @RejectList = STRING_AGG(CAST(
                            NULLIF(CONCAT_WS(', ',
                              CASE WHEN m.MANDATORY_FLAG = 'Y'
                                   THEN 'CASE WHEN (' + COALESCE(m.TRANSFORM_EXPR, m.SOURCE_COLUMN) + ') IS NULL THEN ''MISSING ' + c.COLUMN_NAME + ''' END' END,
                              CASE WHEN m.VALIDATION_EXPR IS NOT NULL
                                   THEN 'CASE WHEN (' + m.VALIDATION_EXPR + ') THEN ''INVALID ' + c.COLUMN_NAME + ''' END' END), '')
                            AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.ORDINAL)
        FROM  MATMAS.CTL_CANONICAL_COLUMN c
        LEFT JOIN MATMAS.CTL_FIELD_MAPPING m
               ON m.INTEGRATION_ID = @IntegrationId AND m.DIRECTION = 'IN'
              AND m.TARGET_COLUMN  = c.COLUMN_NAME   AND m.ACTIVE_FLAG = 'Y'
        WHERE c.COLUMN_NAME <> 'SOURCE_SYSTEM';

        IF @RejectList IS NULL OR @RejectList = '' SET @RejectList = 'NULL';   -- STRING_AGG skips NULL entries

        SET @Sql = N'INSERT INTO #stg (LANDING_ID, SRC_ROW_NUM, SRC_FILE_NAME, SOURCE_SYSTEM, ' + @ColList + N', REJECT_REASON) '
                 + N'SELECT LANDING_ID, SRC_ROW_NUM, SRC_FILE_NAME, @s, ' + @SelectList
                 + N', NULLIF(CONCAT_WS(''; '', ' + @RejectList + N', NULL), '''') '
                 + N'FROM MATMAS.LANDING_RAW '
                 + N'WHERE BATCH_ID = @b AND INTEGRATION_ID = @i AND SRC_ROW_NUM > 1';
        EXEC sp_executesql @Sql, N'@s VARCHAR(20), @b VARCHAR(40), @i VARCHAR(60)',
                           @s = @Src, @b = @BatchId, @i = @IntegrationId;

        /* ---- 3. hash key / hash diff ----------------------------------- */
        SELECT @KeyExpr = STRING_AGG(CAST('ISNULL(CONVERT(NVARCHAR(MAX), ' + LTRIM(RTRIM(value)) + ', 126), '''')' AS NVARCHAR(MAX)), ', ''|'', ')
                          WITHIN GROUP (ORDER BY ordinal)
        FROM   STRING_SPLIT(@KeyCols, ',', 1);

        SELECT @DiffExpr = STRING_AGG(CAST('ISNULL(CONVERT(NVARCHAR(MAX), ' + c.COLUMN_NAME + ', 126), '''')' AS NVARCHAR(MAX)), ', ''|'', ')
                           WITHIN GROUP (ORDER BY c.ORDINAL)
        FROM   MATMAS.CTL_CANONICAL_COLUMN c
        WHERE  c.COLUMN_NAME NOT IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@KeyCols, ','));

        SET @Sql = N'UPDATE #stg SET '
                 + N'HASH_KEY  = CONVERT(VARCHAR(32), HASHBYTES(''MD5'', CONCAT(' + @KeyExpr  + N', '''')), 2), '
                 + N'HASH_DIFF = CONVERT(VARCHAR(32), HASHBYTES(''MD5'', CONCAT(' + @DiffExpr + N', '''')), 2) '
                 + N'WHERE REJECT_REASON IS NULL';
        EXEC sp_executesql @Sql;

        /* ---- 4. duplicates inside the batch ---------------------------- */
        ;WITH d AS (
            SELECT RN, REJECT_REASON, HASH_DIFF,
                   ROW_NUMBER() OVER (PARTITION BY HASH_KEY ORDER BY SRC_FILE_NAME, SRC_ROW_NUM) AS r,
                   FIRST_VALUE(HASH_DIFF) OVER (PARTITION BY HASH_KEY ORDER BY SRC_FILE_NAME, SRC_ROW_NUM
                                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS first_diff
            FROM   #stg WHERE REJECT_REASON IS NULL)
        UPDATE d SET RN = r,
                     REJECT_REASON = CASE WHEN r > 1 AND HASH_DIFF <> first_diff
                                          THEN 'DUPLICATE KEY WITH DIFFERENT ATTRIBUTES' END;

        DELETE FROM #stg WHERE RN > 1 AND REJECT_REASON IS NULL;   -- exact duplicates: collapsed
        SET @Dups = @@ROWCOUNT;

        /* ---- 5. rejects ------------------------------------------------- */
        INSERT INTO MATMAS.MATERIAL_MASTER_REJECT (BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM, REJECT_REASON, RAW_RECORD)
        SELECT @BatchId, @IntegrationId, s.SRC_FILE_NAME, s.SRC_ROW_NUM, s.REJECT_REASON,
               CONCAT_WS('|', l.COL01,l.COL02,l.COL03,l.COL04,l.COL05,l.COL06,l.COL07,l.COL08,l.COL09,l.COL10,
                              l.COL11,l.COL12,l.COL13,l.COL14,l.COL15,l.COL16,l.COL17,l.COL18,l.COL19,l.COL20,
                              l.COL21,l.COL22,l.COL23,l.COL24,l.COL25,l.COL26,l.COL27,l.COL28,l.COL29,l.COL30)
        FROM   #stg s
        JOIN   MATMAS.LANDING_RAW l ON l.LANDING_ID = s.LANDING_ID
        WHERE  s.REJECT_REASON IS NOT NULL;
        SET @RowsRejected = @@ROWCOUNT;

        /* ---- 6. SCD2 merge --------------------------------------------- */
        BEGIN TRAN;

        -- 6a. changed keys: close current version
        UPDATE mm
        SET    VALID_TO_TS = @Now, CURRENT_FLAG = 'N', UPDATED_TS = @Now
        FROM   MATMAS.MATERIAL_MASTER mm
        JOIN   #stg s ON s.HASH_KEY = mm.HASH_KEY
        WHERE  mm.CURRENT_FLAG = 'Y' AND s.REJECT_REASON IS NULL AND s.HASH_DIFF <> mm.HASH_DIFF;
        SET @RowsUpdated = @@ROWCOUNT;

        -- 6b. new + changed keys: insert new version
        INSERT INTO MATMAS.MATERIAL_MASTER
              (HASH_KEY, VALID_FROM_TS, VALID_TO_TS, CURRENT_FLAG, SOURCE_SYSTEM, ERP_ITEM_NUMBER, PLANT_CODE,
               SUPPLIER_NUMBER, SUPPLIER_PART_NUMBER, MATERIAL_DESCRIPTION, SUPPLIER_PART_ROLE,
               MANUFACTURER_PART_NUMBER, MANUFACTURER_PART_ROLE, START_DATE, END_DATE, ITEM_STATUS, BASE_UOM,
               ITEM_CATEGORY, COMMODITY_CODE, EXT_ATTR_01, EXT_ATTR_02, EXT_ATTR_03, EXT_ATTR_04, EXT_ATTR_05,
               HASH_DIFF, BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, CREATED_TS)
        SELECT s.HASH_KEY, @Now, '9999-12-31', 'Y', s.SOURCE_SYSTEM, s.ERP_ITEM_NUMBER, s.PLANT_CODE,
               s.SUPPLIER_NUMBER, s.SUPPLIER_PART_NUMBER, s.MATERIAL_DESCRIPTION, s.SUPPLIER_PART_ROLE,
               s.MANUFACTURER_PART_NUMBER, s.MANUFACTURER_PART_ROLE, s.START_DATE, s.END_DATE,
               ISNULL(s.ITEM_STATUS, 'ACTIVE'), s.BASE_UOM,
               s.ITEM_CATEGORY, s.COMMODITY_CODE, s.EXT_ATTR_01, s.EXT_ATTR_02, s.EXT_ATTR_03, s.EXT_ATTR_04, s.EXT_ATTR_05,
               s.HASH_DIFF, @BatchId, @IntegrationId, s.SRC_FILE_NAME, @Now
        FROM   #stg s
        WHERE  s.REJECT_REASON IS NULL
          AND  NOT EXISTS (SELECT 1 FROM MATMAS.MATERIAL_MASTER mm
                           WHERE mm.HASH_KEY = s.HASH_KEY AND mm.CURRENT_FLAG = 'Y');
        SET @RowsInserted = @@ROWCOUNT;

        -- 6c. FULL load: keys missing from the extract -> new INACTIVE version, END_DATE = today
        IF @LoadType = 'FULL'
        BEGIN
            SELECT mm.HASH_KEY, mm.VALID_FROM_TS
            INTO   #gone
            FROM   MATMAS.MATERIAL_MASTER mm
            WHERE  mm.CURRENT_FLAG = 'Y' AND mm.SOURCE_SYSTEM = @Src AND mm.INTEGRATION_ID = @IntegrationId
              AND  mm.BATCH_ID <> @BatchId AND ISNULL(mm.ITEM_STATUS, 'ACTIVE') <> 'INACTIVE'
              AND  NOT EXISTS (SELECT 1 FROM #stg s WHERE s.HASH_KEY = mm.HASH_KEY AND s.REJECT_REASON IS NULL);

            INSERT INTO MATMAS.MATERIAL_MASTER
                  (HASH_KEY, VALID_FROM_TS, VALID_TO_TS, CURRENT_FLAG, SOURCE_SYSTEM, ERP_ITEM_NUMBER, PLANT_CODE,
                   SUPPLIER_NUMBER, SUPPLIER_PART_NUMBER, MATERIAL_DESCRIPTION, SUPPLIER_PART_ROLE,
                   MANUFACTURER_PART_NUMBER, MANUFACTURER_PART_ROLE, START_DATE, END_DATE, ITEM_STATUS, BASE_UOM,
                   ITEM_CATEGORY, COMMODITY_CODE, EXT_ATTR_01, EXT_ATTR_02, EXT_ATTR_03, EXT_ATTR_04, EXT_ATTR_05,
                   HASH_DIFF, BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, CREATED_TS)
            SELECT mm.HASH_KEY, @Now, '9999-12-31', 'Y', mm.SOURCE_SYSTEM, mm.ERP_ITEM_NUMBER, mm.PLANT_CODE,
                   mm.SUPPLIER_NUMBER, mm.SUPPLIER_PART_NUMBER, mm.MATERIAL_DESCRIPTION, mm.SUPPLIER_PART_ROLE,
                   mm.MANUFACTURER_PART_NUMBER, mm.MANUFACTURER_PART_ROLE, mm.START_DATE, CAST(@Now AS DATE), 'INACTIVE', mm.BASE_UOM,
                   mm.ITEM_CATEGORY, mm.COMMODITY_CODE, mm.EXT_ATTR_01, mm.EXT_ATTR_02, mm.EXT_ATTR_03, mm.EXT_ATTR_04, mm.EXT_ATTR_05,
                   CONVERT(VARCHAR(32), HASHBYTES('MD5', CONCAT(mm.HASH_DIFF, '|INACTIVE')), 2),
                   @BatchId, @IntegrationId, NULL, @Now
            FROM   MATMAS.MATERIAL_MASTER mm
            JOIN   #gone g ON g.HASH_KEY = mm.HASH_KEY AND g.VALID_FROM_TS = mm.VALID_FROM_TS;
            SET @Closed = @@ROWCOUNT;

            UPDATE mm SET VALID_TO_TS = @Now, CURRENT_FLAG = 'N', UPDATED_TS = @Now
            FROM   MATMAS.MATERIAL_MASTER mm
            JOIN   #gone g ON g.HASH_KEY = mm.HASH_KEY AND g.VALID_FROM_TS = mm.VALID_FROM_TS;
        END

        UPDATE MATMAS.LANDING_RAW SET LOAD_STATUS = 'PROCESSED'
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId;

        COMMIT;

        SET @Message = CONCAT('read=', @RowsRead, ' inserted=', @RowsInserted, ' closed_changed=', @RowsUpdated,
                              ' rejected=', @RowsRejected, ' exact_duplicates=', @Dups, ' closed_missing=', @Closed);

        UPDATE MATMAS.CTL_BATCH_RUN
        SET    STATUS = 'SUCCESS', END_TS = SYSUTCDATETIME(), ROWS_READ = @RowsRead, ROWS_INSERTED = @RowsInserted,
               ROWS_UPDATED = @RowsUpdated, ROWS_REJECTED = @RowsRejected, MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'HARMONIZE';

        UPDATE MATMAS.CTL_INBOUND_INTEGRATION
        SET    LAST_RUN_BATCH_ID = @BatchId, LAST_RUN_STATUS = 'SUCCESS', LAST_RUN_TS = SYSUTCDATETIME()
        WHERE  INTEGRATION_ID = @IntegrationId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Message = LEFT(CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 2000);
        UPDATE MATMAS.LANDING_RAW SET LOAD_STATUS = 'FAILED'
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId;
        UPDATE MATMAS.CTL_BATCH_RUN
        SET    STATUS = 'FAILED', END_TS = SYSUTCDATETIME(), ROWS_READ = @RowsRead, MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'HARMONIZE';
        UPDATE MATMAS.CTL_INBOUND_INTEGRATION
        SET    LAST_RUN_BATCH_ID = @BatchId, LAST_RUN_STATUS = 'FAILED', LAST_RUN_TS = SYSUTCDATETIME()
        WHERE  INTEGRATION_ID = @IntegrationId;
        THROW;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   sp_Publish  (TARGET_TYPE = TABLE; FILE / IDOC / API routes are handled
   by a CDI publish mapping in phase 2 and are reported SKIPPED here)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_Publish
    @IntegrationId  VARCHAR(60),
    @BatchId        VARCHAR(40),
    @RowsInserted   INT            OUTPUT,
    @Status         VARCHAR(10)    OUTPUT,
    @Message        NVARCHAR(2000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME(), @TgtType VARCHAR(10), @TgtObj VARCHAR(200),
            @Filter NVARCHAR(2000), @Mode VARCHAR(10), @Sql NVARCHAR(MAX),
            @ColList NVARCHAR(MAX), @SelList NVARCHAR(MAX), @Err NVARCHAR(2048);
    SET @RowsInserted = 0;

    SELECT @TgtType = TARGET_TYPE, @TgtObj = TARGET_OBJECT, @Filter = SOURCE_FILTER, @Mode = PUBLISH_MODE
    FROM   MATMAS.CTL_OUTBOUND_INTEGRATION WHERE INTEGRATION_ID = @IntegrationId;

    IF @TgtType IS NULL
    BEGIN
        SET @Err = CONCAT('Unknown outbound INTEGRATION_ID ', @IntegrationId); THROW 50011, @Err, 1;
    END

    IF NOT EXISTS (SELECT 1 FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'PUBLISH')
        INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS) VALUES (@BatchId, @IntegrationId, 'PUBLISH', 'RUNNING');
    ELSE
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'RUNNING', START_TS = @Now, END_TS = NULL, MESSAGE = NULL
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'PUBLISH';

    IF @TgtType <> 'TABLE'
    BEGIN
        SET @Status = 'SKIPPED';
        SET @Message = CONCAT('Target type ', @TgtType, ' is published by a CDI publish mapping, not by SQL');
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'SKIPPED', END_TS = SYSUTCDATETIME(), MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'PUBLISH';
        RETURN;
    END

    CREATE TABLE #pub (HASH_KEY VARCHAR(32), VALID_FROM_TS DATETIME2(3));

    BEGIN TRY
        IF OBJECT_ID(@TgtObj, 'U') IS NULL
        BEGIN
            SET @Err = CONCAT('Target table ', @TgtObj, ' does not exist in this database'); THROW 50012, @Err, 1;
        END

        SELECT @ColList = STRING_AGG(CAST(QUOTENAME(m.TARGET_COLUMN) AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY m.ORDINAL),
               @SelList = STRING_AGG(CAST(COALESCE(m.TRANSFORM_EXPR, 'mm.' + m.SOURCE_COLUMN) AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY m.ORDINAL)
        FROM   MATMAS.CTL_FIELD_MAPPING m
        WHERE  m.INTEGRATION_ID = @IntegrationId AND m.DIRECTION = 'OUT' AND m.ACTIVE_FLAG = 'Y';

        IF @ColList IS NULL
        BEGIN
            SET @Err = CONCAT('No OUT field mappings for ', @IntegrationId); THROW 50013, @Err, 1;
        END

        SET @Sql = N'INSERT INTO #pub (HASH_KEY, VALID_FROM_TS) SELECT mm.HASH_KEY, mm.VALID_FROM_TS '
                 + N'FROM MATMAS.MATERIAL_MASTER mm WHERE mm.CURRENT_FLAG = ''Y'' AND (' + @Filter + N')'
                 + CASE WHEN @Mode = 'DELTA' THEN
                   N' AND NOT EXISTS (SELECT 1 FROM MATMAS.MATERIAL_MASTER_OUTBOUND ob WHERE ob.INTEGRATION_ID = @i '
                 + N' AND ob.HASH_KEY = mm.HASH_KEY AND ob.VALID_FROM_TS = mm.VALID_FROM_TS AND ob.PUBLISH_STATUS = ''SUCCESS'')'
                   ELSE N'' END;
        EXEC sp_executesql @Sql, N'@i VARCHAR(60)', @i = @IntegrationId;

        BEGIN TRAN;

        IF @Mode = 'FULL'
        BEGIN
            SET @Sql = N'TRUNCATE TABLE ' + @TgtObj;   -- @TgtObj validated with OBJECT_ID above
            EXEC sp_executesql @Sql;
            DELETE FROM MATMAS.MATERIAL_MASTER_OUTBOUND WHERE INTEGRATION_ID = @IntegrationId;
        END

        SET @Sql = N'INSERT INTO ' + @TgtObj + N' (' + @ColList + N') SELECT ' + @SelList
                 + N' FROM MATMAS.MATERIAL_MASTER mm JOIN #pub p ON p.HASH_KEY = mm.HASH_KEY AND p.VALID_FROM_TS = mm.VALID_FROM_TS';
        EXEC sp_executesql @Sql;
        SET @RowsInserted = @@ROWCOUNT;

        DELETE ob FROM MATMAS.MATERIAL_MASTER_OUTBOUND ob
        JOIN   #pub p ON p.HASH_KEY = ob.HASH_KEY AND p.VALID_FROM_TS = ob.VALID_FROM_TS
        WHERE  ob.INTEGRATION_ID = @IntegrationId;
        INSERT INTO MATMAS.MATERIAL_MASTER_OUTBOUND (INTEGRATION_ID, HASH_KEY, VALID_FROM_TS, BATCH_ID, PUBLISH_STATUS, TARGET_REFERENCE)
        SELECT @IntegrationId, p.HASH_KEY, p.VALID_FROM_TS, @BatchId, 'SUCCESS', @TgtObj FROM #pub p;

        UPDATE MATMAS.CTL_OUTBOUND_INTEGRATION
        SET    LAST_PUBLISHED_TS = @Now, LAST_RUN_BATCH_ID = @BatchId, LAST_RUN_STATUS = 'SUCCESS'
        WHERE  INTEGRATION_ID = @IntegrationId;

        COMMIT;

        SET @Status = 'OK';
        SET @Message = CONCAT('published=', @RowsInserted, ' mode=', @Mode, ' target=', @TgtObj);
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'SUCCESS', END_TS = SYSUTCDATETIME(), ROWS_INSERTED = @RowsInserted, MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'PUBLISH';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Status = 'FAILED';
        SET @Message = LEFT(CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 2000);
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'FAILED', END_TS = SYSUTCDATETIME(), MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'PUBLISH';
        UPDATE MATMAS.CTL_OUTBOUND_INTEGRATION SET LAST_RUN_BATCH_ID = @BatchId, LAST_RUN_STATUS = 'FAILED'
        WHERE  INTEGRATION_ID = @IntegrationId;
        THROW;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_Process - ENTRY POINT (Post SQL of m_MATMAS_PROCESS)
   Never raises for a single failed route: every route is attempted,
   failures are logged in CTL_BATCH_RUN and summarised in CTL_RUN_REQUEST.
   Safe under JDBC autocommit=false: the driver's open transaction is
   committed first and the transaction count is restored on exit.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_Process
    @RunId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    SET IMPLICIT_TRANSACTIONS OFF;
    WHILE @@TRANCOUNT > 0 COMMIT;      -- close the JDBC driver's implicit transaction (writes already done)

    DECLARE @b VARCHAR(40) = FORMAT(SYSUTCDATETIME(), 'yyyyMMddHHmmssfff'),
            @found INT = 0, @routed INT = 0, @steps INT = 0, @fails INT = 0,
            @id VARCHAR(60), @rr INT, @ri INT, @ru INT, @rj INT, @st VARCHAR(10),
            @msg NVARCHAR(2000), @summary NVARCHAR(4000), @status VARCHAR(20);

    BEGIN TRY
        IF @RunId IS NULL
            SELECT TOP 1 @RunId = RUN_ID FROM MATMAS.CTL_RUN_REQUEST WHERE STATUS = 'REQUESTED' ORDER BY RUN_ID DESC;
        IF @RunId IS NULL
        BEGIN
            INSERT INTO MATMAS.CTL_RUN_REQUEST (REQUEST_SOURCE, REQUEST_NOTE) VALUES (N'MANUAL', N'direct EXEC');
            SET @RunId = SCOPE_IDENTITY();
        END
        UPDATE MATMAS.CTL_RUN_REQUEST SET STATUS = 'SUPERSEDED' WHERE STATUS = 'REQUESTED' AND RUN_ID < @RunId;
        UPDATE MATMAS.CTL_RUN_REQUEST SET STATUS = 'RUNNING', BATCH_ID = @b, START_TS = SYSUTCDATETIME() WHERE RUN_ID = @RunId;

        /* 1. assign */
        BEGIN TRY
            EXEC MATMAS.sp_MATMAS_Assign @b, @found OUTPUT, @routed OUTPUT;
            IF @found > @routed SET @fails += 1;
        END TRY
        BEGIN CATCH
            SET @fails += 1;
            INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS, END_TS, MESSAGE)
            VALUES (@b, '*', 'ASSIGN', 'FAILED', SYSUTCDATETIME(), LEFT(ERROR_MESSAGE(), 4000));
        END CATCH

        /* 2. harmonize every route that received rows */
        DECLARE cin CURSOR LOCAL FAST_FORWARD FOR
            SELECT r.INTEGRATION_ID
            FROM   MATMAS.CTL_INBOUND_INTEGRATION r
            WHERE  EXISTS (SELECT 1 FROM MATMAS.LANDING_RAW l
                           WHERE l.BATCH_ID = @b AND l.INTEGRATION_ID = r.INTEGRATION_ID AND l.LOAD_STATUS = 'ASSIGNED')
            ORDER  BY r.RUN_SEQUENCE, r.INTEGRATION_ID;
        OPEN cin; FETCH NEXT FROM cin INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @steps += 1;
            BEGIN TRY
                EXEC MATMAS.sp_Harmonize @id, @b, @rr OUTPUT, @ri OUTPUT, @ru OUTPUT, @rj OUTPUT, @msg OUTPUT;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK;
                SET @fails += 1;          -- details already logged by sp_Harmonize
            END CATCH
            FETCH NEXT FROM cin INTO @id;
        END
        CLOSE cin; DEALLOCATE cin;

        /* 3. publish every active outbound route */
        DECLARE cout CURSOR LOCAL FAST_FORWARD FOR
            SELECT INTEGRATION_ID FROM MATMAS.CTL_OUTBOUND_INTEGRATION
            WHERE  ACTIVE_FLAG = 'Y' ORDER BY RUN_SEQUENCE, INTEGRATION_ID;
        OPEN cout; FETCH NEXT FROM cout INTO @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @steps += 1;
            BEGIN TRY
                EXEC MATMAS.sp_Publish @id, @b, @ri OUTPUT, @st OUTPUT, @msg OUTPUT;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK;
                SET @fails += 1;
            END CATCH
            FETCH NEXT FROM cout INTO @id;
        END
        CLOSE cout; DEALLOCATE cout;

        /* 4. outcome */
        SELECT @summary = LEFT(STRING_AGG(CAST(CONCAT(INTEGRATION_ID, ' ', STAGE, ' ', STATUS, ': ', MESSAGE) AS NVARCHAR(MAX)), ' | ')
                               WITHIN GROUP (ORDER BY START_TS), 4000)
        FROM   MATMAS.CTL_BATCH_RUN WHERE BATCH_ID = @b;

        SET @status = CASE WHEN @fails = 0 AND @found = 0 THEN 'NO_DATA'
                           WHEN @fails = 0                THEN 'SUCCESS'
                           WHEN @fails < @steps + 1       THEN 'PARTIAL'
                           ELSE 'FAILED' END;

        UPDATE MATMAS.CTL_RUN_REQUEST
        SET    STATUS = @status, END_TS = SYSUTCDATETIME(),
               SUMMARY = CONCAT('files=', @found, ' routed=', @routed, ' failed_steps=', @fails, ' | ', @summary)
        WHERE  RUN_ID = @RunId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE MATMAS.CTL_RUN_REQUEST
        SET    STATUS = 'FAILED', END_TS = SYSUTCDATETIME(), BATCH_ID = ISNULL(BATCH_ID, @b),
               SUMMARY = LEFT(CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000)
        WHERE  RUN_ID = @RunId;
    END CATCH

    WHILE @@TRANCOUNT < @tc BEGIN TRAN;   -- give the caller back the transaction count it had
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_Reprocess - re-run harmonize for an earlier batch (after a
   config fix), then publish. @IntegrationId NULL = every route of the batch.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_Reprocess
    @BatchId       VARCHAR(40),
    @IntegrationId VARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @id VARCHAR(60), @rr INT, @ri INT, @ru INT, @rj INT, @st VARCHAR(10), @msg NVARCHAR(2000);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT l.INTEGRATION_ID FROM MATMAS.LANDING_RAW l
        WHERE  l.BATCH_ID = @BatchId AND l.INTEGRATION_ID <> 'UNROUTED'
          AND  (@IntegrationId IS NULL OR l.INTEGRATION_ID = @IntegrationId);
    OPEN c; FETCH NEXT FROM c INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC MATMAS.sp_Harmonize @id, @BatchId, @rr OUTPUT, @ri OUTPUT, @ru OUTPUT, @rj OUTPUT, @msg OUTPUT;
            PRINT CONCAT(@id, ' OK ', @msg);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            PRINT CONCAT(@id, ' FAILED ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM c INTO @id;
    END
    CLOSE c; DEALLOCATE c;

    DECLARE o CURSOR LOCAL FAST_FORWARD FOR
        SELECT INTEGRATION_ID FROM MATMAS.CTL_OUTBOUND_INTEGRATION WHERE ACTIVE_FLAG = 'Y' ORDER BY RUN_SEQUENCE;
    OPEN o; FETCH NEXT FROM o INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC MATMAS.sp_Publish @id, @BatchId, @ri OUTPUT, @st OUTPUT, @msg OUTPUT;
            PRINT CONCAT(@id, ' ', @st, ' ', @msg);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            PRINT CONCAT(@id, ' FAILED ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM o INTO @id;
    END
    CLOSE o; DEALLOCATE o;
END
GO

/* old taskflow-dispatcher design (v0.2) - removed */
DROP PROCEDURE IF EXISTS MATMAS.sp_MATMAS_Run;
DROP TABLE IF EXISTS MATMAS.CTL_STEP_RESULT;
GO
