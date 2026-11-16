/* =====================================================================
   MATMAS - 02: stored procedures
   sp_Harmonize   : LANDING_RAW -> MATERIAL_MASTER (dynamic SELECT built
                    from CTL_FIELD_MAPPING, header check, rejects, SCD2)
   sp_Publish     : MATERIAL_MASTER -> target TABLE (dynamic INSERT built
                    from CTL_FIELD_MAPPING OUT rows)
   sp_MATMAS_Run  : single entry point called by the CDI mapping
                    m_MATMAS_EXEC_SQL; always returns exactly ONE row with
                    a fixed column list so the mapping never changes.
   Platform: SQL database in Fabric (T-SQL)
   ===================================================================== */

/* ---------------------------------------------------------------------
   sp_Harmonize
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
            @ExpHdr     NVARCHAR(2000), @Hdr NVARCHAR(2000), @N INT,
            @KeyCols    VARCHAR(500),
            @Sql        NVARCHAR(MAX), @ColList NVARCHAR(MAX), @SelectList NVARCHAR(MAX),
            @RejectList NVARCHAR(MAX), @KeyExpr NVARCHAR(MAX), @DiffExpr NVARCHAR(MAX),
            @Dups INT = 0, @Closed INT = 0, @Err NVARCHAR(2048);

    SELECT @RowsRead = 0, @RowsInserted = 0, @RowsUpdated = 0, @RowsRejected = 0;

    SELECT @Src = SOURCE_SYSTEM, @LoadType = LOAD_TYPE, @ExpHdr = EXPECTED_HEADER,
           @KeyCols = NATURAL_KEY_COLUMNS
    FROM   MATMAS.CTL_INBOUND_INTEGRATION
    WHERE  INTEGRATION_ID = @IntegrationId;

    IF @Src IS NULL
    BEGIN
        SET @Err = CONCAT('Unknown inbound INTEGRATION_ID ', @IntegrationId);
        THROW 50001, @Err, 1;
    END

    IF NOT EXISTS (SELECT 1 FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='HARMONIZE')
        INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS)
        VALUES (@BatchId, @IntegrationId, 'HARMONIZE', 'RUNNING');
    ELSE
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS='RUNNING', START_TS=@Now, END_TS=NULL, MESSAGE=NULL
        WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='HARMONIZE';

    /* staging table: typed canonical columns (keep in sync with CTL_CANONICAL_COLUMN) */
    CREATE TABLE #stg (
        SRC_ROW_NUM              INT,
        SRC_FILE_NAME            NVARCHAR(300),
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
        /* ---- 1. counts + header validation ---------------------------- */
        SELECT @RowsRead = COUNT(*)
        FROM   MATMAS.LANDING_RAW
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND SRC_ROW_NUM > 1;

        IF @ExpHdr IS NOT NULL
        BEGIN
            SET @N = LEN(@ExpHdr) - LEN(REPLACE(@ExpHdr, '|', '')) + 1;
            SELECT @Hdr = CONCAT_WS('|',
                     COL01, IIF(@N>=2,COL02,NULL), IIF(@N>=3,COL03,NULL), IIF(@N>=4,COL04,NULL), IIF(@N>=5,COL05,NULL),
                     IIF(@N>=6,COL06,NULL), IIF(@N>=7,COL07,NULL), IIF(@N>=8,COL08,NULL), IIF(@N>=9,COL09,NULL), IIF(@N>=10,COL10,NULL),
                     IIF(@N>=11,COL11,NULL), IIF(@N>=12,COL12,NULL), IIF(@N>=13,COL13,NULL), IIF(@N>=14,COL14,NULL), IIF(@N>=15,COL15,NULL),
                     IIF(@N>=16,COL16,NULL), IIF(@N>=17,COL17,NULL), IIF(@N>=18,COL18,NULL), IIF(@N>=19,COL19,NULL), IIF(@N>=20,COL20,NULL),
                     IIF(@N>=21,COL21,NULL), IIF(@N>=22,COL22,NULL), IIF(@N>=23,COL23,NULL), IIF(@N>=24,COL24,NULL), IIF(@N>=25,COL25,NULL),
                     IIF(@N>=26,COL26,NULL), IIF(@N>=27,COL27,NULL), IIF(@N>=28,COL28,NULL), IIF(@N>=29,COL29,NULL), IIF(@N>=30,COL30,NULL))
            FROM   MATMAS.LANDING_RAW
            WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND SRC_ROW_NUM = 1;

            IF @Hdr IS NULL OR UPPER(LTRIM(RTRIM(@Hdr))) <> UPPER(LTRIM(RTRIM(@ExpHdr)))
            BEGIN
                SET @Err = CONCAT('Header mismatch. Expected [', @ExpHdr, '] got [', ISNULL(@Hdr,'<no header row>'), ']');
                THROW 50002, @Err, 1;
            END
        END

        /* ---- 2. build the dynamic SELECT from CTL_FIELD_MAPPING -------- */
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

        SET @Sql = N'INSERT INTO #stg (SRC_ROW_NUM, SRC_FILE_NAME, SOURCE_SYSTEM, ' + @ColList + N', REJECT_REASON) '
                 + N'SELECT SRC_ROW_NUM, SRC_FILE_NAME, @s, ' + @SelectList
                 + N', NULLIF(CONCAT_WS(''; '', ' + @RejectList + N', NULL), '''') '
                 + N'FROM MATMAS.LANDING_RAW '
                 + N'WHERE BATCH_ID = @b AND INTEGRATION_ID = @i AND SRC_ROW_NUM > 1';
        EXEC sp_executesql @Sql, N'@s VARCHAR(20), @b VARCHAR(40), @i VARCHAR(60)',
                           @s = @Src, @b = @BatchId, @i = @IntegrationId;

        /* ---- 3. hash key / hash diff (key list comes from the route) --- */
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

        /* ---- 4. duplicates inside the file ----------------------------- */
        ;WITH d AS (
            SELECT RN, REJECT_REASON, HASH_DIFF,
                   ROW_NUMBER()  OVER (PARTITION BY HASH_KEY ORDER BY SRC_ROW_NUM) AS r,
                   FIRST_VALUE(HASH_DIFF) OVER (PARTITION BY HASH_KEY ORDER BY SRC_ROW_NUM
                                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS first_diff
            FROM   #stg WHERE REJECT_REASON IS NULL
        )
        UPDATE d SET RN = r,
                     REJECT_REASON = CASE WHEN r > 1 AND HASH_DIFF <> first_diff
                                          THEN 'DUPLICATE KEY WITH DIFFERENT ATTRIBUTES' END;

        DELETE FROM #stg WHERE RN > 1 AND REJECT_REASON IS NULL;   -- exact duplicates: silently collapsed
        SET @Dups = @@ROWCOUNT;

        /* ---- 5. rejects ------------------------------------------------- */
        INSERT INTO MATMAS.MATERIAL_MASTER_REJECT (BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM, REJECT_REASON, RAW_RECORD)
        SELECT @BatchId, @IntegrationId, s.SRC_FILE_NAME, s.SRC_ROW_NUM, s.REJECT_REASON,
               CONCAT_WS('|', l.COL01,l.COL02,l.COL03,l.COL04,l.COL05,l.COL06,l.COL07,l.COL08,l.COL09,l.COL10,
                              l.COL11,l.COL12,l.COL13,l.COL14,l.COL15,l.COL16,l.COL17,l.COL18,l.COL19,l.COL20,
                              l.COL21,l.COL22,l.COL23,l.COL24,l.COL25,l.COL26,l.COL27,l.COL28,l.COL29,l.COL30)
        FROM   #stg s
        JOIN   MATMAS.LANDING_RAW l
               ON l.BATCH_ID = @BatchId AND l.INTEGRATION_ID = @IntegrationId AND l.SRC_ROW_NUM = s.SRC_ROW_NUM
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

        -- 6c. FULL load: keys that disappeared from the extract -> new INACTIVE version, END_DATE = today
        IF @LoadType = 'FULL'
        BEGIN
            SELECT mm.HASH_KEY, mm.VALID_FROM_TS
            INTO   #gone
            FROM   MATMAS.MATERIAL_MASTER mm
            WHERE  mm.CURRENT_FLAG = 'Y' AND mm.SOURCE_SYSTEM = @Src AND mm.INTEGRATION_ID = @IntegrationId
              AND  mm.BATCH_ID <> @BatchId AND ISNULL(mm.ITEM_STATUS,'ACTIVE') <> 'INACTIVE'
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
        SET @Message = CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
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
   sp_Publish  (TARGET_TYPE = TABLE only; FILE/IDOC/API routes are
   executed by a CDI publish mapping and are reported as SKIPPED here)
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

    IF NOT EXISTS (SELECT 1 FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='PUBLISH')
        INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS) VALUES (@BatchId, @IntegrationId, 'PUBLISH', 'RUNNING');

    IF @TgtType <> 'TABLE'
    BEGIN
        SET @Status = 'SKIPPED';
        SET @Message = CONCAT('Target type ', @TgtType, ' is published by the CDI publish mapping, not by SQL');
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS='SKIPPED', END_TS=SYSUTCDATETIME(), MESSAGE=@Message
        WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='PUBLISH';
        RETURN;
    END

    IF OBJECT_ID(@TgtObj, 'U') IS NULL
    BEGIN
        SET @Err = CONCAT('Target table ', @TgtObj, ' does not exist in this database'); THROW 50012, @Err, 1;
    END

    CREATE TABLE #pub (HASH_KEY VARCHAR(32), VALID_FROM_TS DATETIME2(3));

    BEGIN TRY
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
            SET @Sql = N'TRUNCATE TABLE ' + @TgtObj;   -- @TgtObj validated above with OBJECT_ID
            EXEC sp_executesql @Sql;
            DELETE FROM MATMAS.MATERIAL_MASTER_OUTBOUND WHERE INTEGRATION_ID = @IntegrationId;
        END

        SET @Sql = N'INSERT INTO ' + @TgtObj + N' (' + @ColList + N') SELECT ' + @SelList
                 + N' FROM MATMAS.MATERIAL_MASTER mm JOIN #pub p ON p.HASH_KEY = mm.HASH_KEY AND p.VALID_FROM_TS = mm.VALID_FROM_TS';
        EXEC sp_executesql @Sql;
        SET @RowsInserted = @@ROWCOUNT;

        DELETE ob FROM MATMAS.MATERIAL_MASTER_OUTBOUND ob JOIN #pub p ON p.HASH_KEY = ob.HASH_KEY AND p.VALID_FROM_TS = ob.VALID_FROM_TS
        WHERE ob.INTEGRATION_ID = @IntegrationId;
        INSERT INTO MATMAS.MATERIAL_MASTER_OUTBOUND (INTEGRATION_ID, HASH_KEY, VALID_FROM_TS, BATCH_ID, PUBLISH_STATUS, TARGET_REFERENCE)
        SELECT @IntegrationId, p.HASH_KEY, p.VALID_FROM_TS, @BatchId, 'SUCCESS', @TgtObj FROM #pub p;

        UPDATE MATMAS.CTL_OUTBOUND_INTEGRATION
        SET LAST_PUBLISHED_TS = @Now, LAST_RUN_BATCH_ID = @BatchId, LAST_RUN_STATUS = 'SUCCESS'
        WHERE INTEGRATION_ID = @IntegrationId;

        COMMIT;

        SET @Status = 'OK';
        SET @Message = CONCAT('published=', @RowsInserted, ' mode=', @Mode, ' target=', @TgtObj);
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS='SUCCESS', END_TS=SYSUTCDATETIME(), ROWS_INSERTED=@RowsInserted, MESSAGE=@Message
        WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='PUBLISH';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Status = 'FAILED';
        SET @Message = CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS='FAILED', END_TS=SYSUTCDATETIME(), MESSAGE=@Message
        WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='PUBLISH';
        UPDATE MATMAS.CTL_OUTBOUND_INTEGRATION SET LAST_RUN_BATCH_ID=@BatchId, LAST_RUN_STATUS='FAILED' WHERE INTEGRATION_ID=@IntegrationId;
        THROW;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_Run - the ONE procedure the CDI mapping calls.
   @Stage:
     GET_IN_ROUTE  (@RunGroup | @IntegrationId, @Iteration) -> route N of the inbound list
     GET_OUT_ROUTE (@RunGroup | @IntegrationId, @Iteration) -> route N of the outbound list
     LAND_START    (@BatchId, @IntegrationId)               -> log LAND RUNNING
     LAND_END      (@BatchId, @IntegrationId, @RowsRead, @RowsLoaded) -> log LAND SUCCESS
     HARMONIZE     (@BatchId, @IntegrationId)               -> sp_Harmonize
     PUBLISH       (@BatchId, @IntegrationId)               -> sp_Publish
     FAIL          (@BatchId, @IntegrationId, @Message)     -> log FAILED for the running stage
   Always returns ONE row with the same 16 columns.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_Run
    @Stage          VARCHAR(20),
    @BatchId        VARCHAR(40)    = NULL,
    @RunGroup       VARCHAR(30)    = 'DAILY',
    @Iteration      INT            = 1,
    @IntegrationId  VARCHAR(60)    = NULL,
    @RowsRead       INT            = NULL,
    @RowsLoaded     INT            = NULL,
    @Message        NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (
        STATUS VARCHAR(10), MESSAGE NVARCHAR(2000), INTEGRATION_ID VARCHAR(60), SOURCE_SYSTEM VARCHAR(20),
        SOURCE_CONNECTION VARCHAR(100), SOURCE_OBJECT VARCHAR(200), SOURCE_FOLDER NVARCHAR(500), ARCHIVE_FOLDER NVARCHAR(500),
        TARGET_CONNECTION VARCHAR(100), TARGET_OBJECT VARCHAR(200), TARGET_TYPE VARCHAR(10), TOTAL_ROUTES INT,
        ROWS_READ INT, ROWS_INSERTED INT, ROWS_UPDATED INT, ROWS_REJECTED INT);
    DECLARE @rr INT, @ri INT, @ru INT, @rj INT, @msg NVARCHAR(2000), @st VARCHAR(10);
    SET @IntegrationId = NULLIF(LTRIM(RTRIM(@IntegrationId)), '');

    IF @Stage = 'GET_IN_ROUTE'
    BEGIN
        ;WITH q AS (
            SELECT INTEGRATION_ID, SOURCE_SYSTEM, SOURCE_CONNECTION, SOURCE_OBJECT, SOURCE_FOLDER, ARCHIVE_FOLDER, SOURCE_TYPE,
                   ROW_NUMBER() OVER (ORDER BY RUN_SEQUENCE, INTEGRATION_ID) AS rn, COUNT(*) OVER () AS total
            FROM   MATMAS.CTL_INBOUND_INTEGRATION
            WHERE  ACTIVE_FLAG = 'Y'
              AND  ((@IntegrationId IS NULL AND RUN_GROUP = @RunGroup) OR INTEGRATION_ID = @IntegrationId))
        INSERT INTO @r
        SELECT 'OK', CONCAT('inbound route ', rn, ' of ', total), INTEGRATION_ID, SOURCE_SYSTEM,
               SOURCE_CONNECTION, SOURCE_OBJECT, SOURCE_FOLDER, ARCHIVE_FOLDER, NULL, NULL, SOURCE_TYPE, total, 0, 0, 0, 0
        FROM   q WHERE rn = @Iteration;
        IF NOT EXISTS (SELECT 1 FROM @r)
            INSERT INTO @r (STATUS, MESSAGE, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES ('NONE', 'no inbound route for this iteration', 0, 0, 0, 0, 0);
    END
    ELSE IF @Stage = 'GET_OUT_ROUTE'
    BEGIN
        ;WITH q AS (
            SELECT INTEGRATION_ID, TARGET_SYSTEM, TARGET_CONNECTION, TARGET_OBJECT, TARGET_TYPE,
                   ROW_NUMBER() OVER (ORDER BY RUN_SEQUENCE, INTEGRATION_ID) AS rn, COUNT(*) OVER () AS total
            FROM   MATMAS.CTL_OUTBOUND_INTEGRATION
            WHERE  ACTIVE_FLAG = 'Y'
              AND  ((@IntegrationId IS NULL AND RUN_GROUP = @RunGroup) OR INTEGRATION_ID = @IntegrationId))
        INSERT INTO @r
        SELECT 'OK', CONCAT('outbound route ', rn, ' of ', total), INTEGRATION_ID, TARGET_SYSTEM,
               NULL, NULL, NULL, NULL, TARGET_CONNECTION, TARGET_OBJECT, TARGET_TYPE, total, 0, 0, 0, 0
        FROM   q WHERE rn = @Iteration;
        IF NOT EXISTS (SELECT 1 FROM @r)
            INSERT INTO @r (STATUS, MESSAGE, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES ('NONE', 'no outbound route for this iteration', 0, 0, 0, 0, 0);
    END
    ELSE IF @Stage = 'LAND_START'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID=@BatchId AND INTEGRATION_ID=@IntegrationId AND STAGE='LAND')
            INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS, SRC_FILE_NAME)
            SELECT @BatchId, @IntegrationId, 'LAND', 'RUNNING', SOURCE_OBJECT
            FROM   MATMAS.CTL_INBOUND_INTEGRATION WHERE INTEGRATION_ID = @IntegrationId;
        INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
        VALUES ('OK', 'land started', @IntegrationId, 0, 0, 0, 0, 0);
    END
    ELSE IF @Stage = 'LAND_END'
    BEGIN
        UPDATE MATMAS.CTL_BATCH_RUN
        SET    STATUS = 'SUCCESS', END_TS = SYSUTCDATETIME(), ROWS_READ = @RowsRead, ROWS_INSERTED = @RowsLoaded
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STAGE = 'LAND';
        INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
        VALUES ('OK', 'land finished', @IntegrationId, 0, ISNULL(@RowsRead,0), ISNULL(@RowsLoaded,0), 0, 0);
    END
    ELSE IF @Stage = 'HARMONIZE'
    BEGIN
        BEGIN TRY
            EXEC MATMAS.sp_Harmonize @IntegrationId, @BatchId, @rr OUTPUT, @ri OUTPUT, @ru OUTPUT, @rj OUTPUT, @msg OUTPUT;
            INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES ('OK', @msg, @IntegrationId, 0, @rr, @ri, @ru, @rj);
        END TRY
        BEGIN CATCH
            INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES ('FAILED', ERROR_MESSAGE(), @IntegrationId, 0, 0, 0, 0, 0);
        END CATCH
    END
    ELSE IF @Stage = 'PUBLISH'
    BEGIN
        BEGIN TRY
            EXEC MATMAS.sp_Publish @IntegrationId, @BatchId, @ri OUTPUT, @st OUTPUT, @msg OUTPUT;
            INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES (@st, @msg, @IntegrationId, 0, 0, @ri, 0, 0);
        END TRY
        BEGIN CATCH
            INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
            VALUES ('FAILED', ERROR_MESSAGE(), @IntegrationId, 0, 0, 0, 0, 0);
        END CATCH
    END
    ELSE IF @Stage = 'FAIL'
    BEGIN
        UPDATE MATMAS.CTL_BATCH_RUN SET STATUS = 'FAILED', END_TS = SYSUTCDATETIME(), MESSAGE = @Message
        WHERE  BATCH_ID = @BatchId AND INTEGRATION_ID = @IntegrationId AND STATUS = 'RUNNING';
        IF @@ROWCOUNT = 0
            INSERT INTO MATMAS.CTL_BATCH_RUN (BATCH_ID, INTEGRATION_ID, STAGE, STATUS, END_TS, MESSAGE)
            VALUES (ISNULL(@BatchId,'?'), ISNULL(@IntegrationId,'?'), 'TASKFLOW', 'FAILED', SYSUTCDATETIME(), @Message);
        UPDATE MATMAS.CTL_INBOUND_INTEGRATION SET LAST_RUN_BATCH_ID=@BatchId, LAST_RUN_STATUS='FAILED', LAST_RUN_TS=SYSUTCDATETIME()
        WHERE INTEGRATION_ID = @IntegrationId;
        INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
        VALUES ('OK', 'failure logged', @IntegrationId, 0, 0, 0, 0, 0);
    END
    ELSE
        INSERT INTO @r (STATUS, MESSAGE, INTEGRATION_ID, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED)
        VALUES ('ERROR', CONCAT('unknown stage ', @Stage), @IntegrationId, 0, 0, 0, 0, 0);

    SELECT STATUS, MESSAGE, INTEGRATION_ID, SOURCE_SYSTEM, SOURCE_CONNECTION, SOURCE_OBJECT, SOURCE_FOLDER, ARCHIVE_FOLDER,
           TARGET_CONNECTION, TARGET_OBJECT, TARGET_TYPE, TOTAL_ROUTES, ROWS_READ, ROWS_INSERTED, ROWS_UPDATED, ROWS_REJECTED
    FROM   @r;
END
GO
