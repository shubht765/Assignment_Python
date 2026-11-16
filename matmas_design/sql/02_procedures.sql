/* =====================================================================
   MATMAS - 02: procedures
   sp_MATMAS_ApplyStage : Post SQL of the generic load mapping. Applies every
                          NEW staged row, route by route, and raises at the end
                          if any route failed (so the CDI task shows failed).
   sp_MATMAS_ApplyRoute : one run + route: validate, reject, skip duplicate
                          files, de-duplicate, then INSERT / UPSERT / UPDATE /
                          DELETE / TRUNCATE_INSERT into the route's ERP table.
   sp_MATMAS_ReapplyRun : retry a failed run/route after fixing configuration.
   sp_MATMAS_LogEvent   : write an event by hand (same table CDI writes to).
   ===================================================================== */

/* ---------------------------------------------------------------------
   sp_MATMAS_ApplyRoute
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_ApplyRoute
    @RunId   VARCHAR(30),
    @RouteId VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @schema SYSNAME, @table SYSNAME, @op VARCHAR(20), @keys NVARCHAR(500), @skipdup CHAR(1),
            @tgt NVARCHAR(300), @sql NVARCHAR(MAX), @err NVARCHAR(2048),
            @rej NVARCHAR(MAX), @keylist NVARCHAR(MAX), @on NVARCHAR(MAX), @set NVARCHAR(MAX),
            @staged INT = 0, @rejected INT = 0, @dupfiles INT = 0, @duprows INT = 0, @collapsed INT = 0,
            @ins INT = 0, @upd INT = 0, @del INT = 0, @dupnames NVARCHAR(2000), @msg NVARCHAR(4000);

    SELECT @schema = TARGET_SCHEMA, @table = TARGET_TABLE, @op = LOAD_OPERATION,
           @keys = KEY_COLUMNS, @skipdup = SKIP_DUPLICATE_FILE
    FROM   MATMAS.CTL_MATMAS_ROUTE WHERE ROUTE_ID = @RouteId;

    BEGIN TRY
        /* ---- 0. configuration checks ----------------------------------- */
        IF @op IS NULL
        BEGIN SET @err = CONCAT('Route ', @RouteId, ' not found in MATMAS.CTL_MATMAS_ROUTE'); THROW 50101, @err, 1; END

        SET @tgt = QUOTENAME(@schema) + N'.' + QUOTENAME(@table);
        IF OBJECT_ID(@tgt, 'U') IS NULL
        BEGIN SET @err = CONCAT('Target table ', @tgt, ' does not exist (create it with MATMAS.sp_MATMAS_CreateErpTable)'); THROW 50102, @err, 1; END

        DECLARE @biz TABLE (COL SYSNAME PRIMARY KEY, ORD INT, MAXLEN INT);
        INSERT INTO @biz (COL, ORD) VALUES ('ERP_ITEM_NUMBER',1),('MATERIAL_DESCRIPTION',2),('PLANT_CODE',3),
                                           ('SUPPLIER_PART_NUMBER',4),('SUPPLIER_NUMBER',5),('MANUFACTURING_PART_NUMBER',6);
        -- every ERP table must have the template columns; capture their length (nvarchar bytes / 2)
        IF EXISTS (SELECT 1 FROM @biz WHERE COL_LENGTH(@tgt, COL) IS NULL)
           OR COL_LENGTH(@tgt, 'START_DATE') IS NULL OR COL_LENGTH(@tgt, 'END_DATE') IS NULL
        BEGIN SET @err = CONCAT('Target table ', @tgt, ' does not have the MATMAS template columns'); THROW 50103, @err, 1; END
        UPDATE @biz SET MAXLEN = CASE WHEN COL_LENGTH(@tgt, COL) = -1 THEN NULL ELSE COL_LENGTH(@tgt, COL) / 2 END;

        DECLARE @k TABLE (COL SYSNAME, ORD INT);
        INSERT INTO @k SELECT LTRIM(RTRIM(value)), ordinal FROM STRING_SPLIT(@keys, ',', 1) WHERE LTRIM(RTRIM(value)) <> '';
        IF EXISTS (SELECT 1 FROM @k k WHERE NOT EXISTS (SELECT 1 FROM @biz b WHERE b.COL = k.COL))
        BEGIN SET @err = CONCAT('KEY_COLUMNS of ', @RouteId, ' must be among the 6 business columns: ', @keys); THROW 50104, @err, 1; END
        IF @op IN ('UPSERT','UPDATE','DELETE') AND NOT EXISTS (SELECT 1 FROM @k)
        BEGIN SET @err = CONCAT('Operation ', @op, ' needs KEY_COLUMNS for route ', @RouteId); THROW 50105, @err, 1; END

        /* ---- 1. working set -------------------------------------------- */
        CREATE TABLE #s (
            STAGE_ID BIGINT, SOURCE_FILE_NAME NVARCHAR(500),
            ERP_ITEM_NUMBER NVARCHAR(1000), MATERIAL_DESCRIPTION NVARCHAR(1000), PLANT_CODE NVARCHAR(1000),
            SUPPLIER_PART_NUMBER NVARCHAR(1000), SUPPLIER_NUMBER NVARCHAR(1000), MANUFACTURING_PART_NUMBER NVARCHAR(1000),
            START_DATE DATE, END_DATE DATE, REJECT_REASON NVARCHAR(500), IS_DUP_FILE BIT NOT NULL DEFAULT 0, RN INT);

        INSERT INTO #s (STAGE_ID, SOURCE_FILE_NAME, ERP_ITEM_NUMBER, MATERIAL_DESCRIPTION, PLANT_CODE,
                        SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER, START_DATE, END_DATE)
        SELECT STAGE_ID, SOURCE_FILE_NAME,
               NULLIF(LTRIM(RTRIM(ERP_ITEM_NUMBER)), N''), NULLIF(LTRIM(RTRIM(MATERIAL_DESCRIPTION)), N''),
               NULLIF(LTRIM(RTRIM(PLANT_CODE)), N''), NULLIF(LTRIM(RTRIM(SUPPLIER_PART_NUMBER)), N''),
               NULLIF(LTRIM(RTRIM(SUPPLIER_NUMBER)), N''), NULLIF(LTRIM(RTRIM(MANUFACTURING_PART_NUMBER)), N''),
               ISNULL(START_DATE, CAST(SYSUTCDATETIME() AS DATE)), ISNULL(END_DATE, CAST('9999-12-31' AS DATE))
        FROM   MATMAS.MATERIAL_MASTER_STAGE
        WHERE  RUN_ID = @RunId AND ROUTE_ID = @RouteId AND STAGE_STATUS = 'NEW';
        SET @staged = @@ROWCOUNT;

        IF @staged = 0
        BEGIN
            INSERT INTO MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, EVENT, ROWS_STAGED, MESSAGE)
            VALUES (@RunId, @RouteId, 'LOADED', 0, N'no staged rows (empty file?)');
            RETURN;
        END

        /* ---- 2. validation: mandatory = keys + target NOT NULL columns, lengths */
        SELECT @rej = STRING_AGG(CAST(r AS NVARCHAR(MAX)), N', ')
        FROM (
            SELECT N'CASE WHEN ' + QUOTENAME(COL) + N' IS NULL THEN ''MISSING ' + COL + N''' END' AS r
            FROM  (SELECT COL FROM @k UNION SELECT 'ERP_ITEM_NUMBER' UNION SELECT 'PLANT_CODE') m
            UNION ALL
            SELECT N'CASE WHEN LEN(' + QUOTENAME(COL) + N') > ' + CAST(MAXLEN AS NVARCHAR(10))
                 + N' THEN ''TOO LONG ' + COL + N''' END'
            FROM  @biz WHERE MAXLEN IS NOT NULL
        ) x;
        SET @sql = N'UPDATE #s SET REJECT_REASON = NULLIF(CONCAT_WS(''; '', ' + @rej + N', NULL), '''')';
        EXEC sp_executesql @sql;

        /* ---- 3. duplicate files (same content already applied for this route) */
        CREATE TABLE #f (SOURCE_FILE_NAME NVARCHAR(500), FP VARCHAR(64), CNT INT, IS_DUP BIT NOT NULL DEFAULT 0);
        INSERT INTO #f (SOURCE_FILE_NAME, FP, CNT)
        SELECT SOURCE_FILE_NAME,
               CONVERT(VARCHAR(64), HASHBYTES('SHA2_256',
                   STRING_AGG(CAST(CONCAT(ISNULL(ERP_ITEM_NUMBER,N''), N'|', ISNULL(MATERIAL_DESCRIPTION,N''), N'|',
                                          ISNULL(PLANT_CODE,N''), N'|', ISNULL(SUPPLIER_PART_NUMBER,N''), N'|',
                                          ISNULL(SUPPLIER_NUMBER,N''), N'|', ISNULL(MANUFACTURING_PART_NUMBER,N''))
                                   AS NVARCHAR(MAX)), NCHAR(10)) WITHIN GROUP (ORDER BY STAGE_ID)), 2),
               COUNT(*)
        FROM   #s GROUP BY SOURCE_FILE_NAME;

        IF @skipdup = 'Y'
        BEGIN
            UPDATE f SET IS_DUP = 1
            FROM   #f f
            WHERE  EXISTS (SELECT 1 FROM MATMAS.CTL_MATMAS_FILE_HISTORY h WHERE h.ROUTE_ID = @RouteId AND h.FILE_FINGERPRINT = f.FP);
            UPDATE s SET IS_DUP_FILE = 1 FROM #s s JOIN #f f ON f.SOURCE_FILE_NAME = s.SOURCE_FILE_NAME WHERE f.IS_DUP = 1;
            SELECT @dupfiles = COUNT(*), @dupnames = LEFT(STRING_AGG(CAST(SOURCE_FILE_NAME AS NVARCHAR(MAX)), N', '), 2000)
            FROM   #f WHERE IS_DUP = 1;
            SELECT @duprows = COUNT(*) FROM #s WHERE IS_DUP_FILE = 1;
        END

        /* ---- 4. rows to apply: valid, not from a duplicate file, de-duplicated */
        SELECT * INTO #a FROM #s WHERE REJECT_REASON IS NULL AND IS_DUP_FILE = 0;

        ;WITH d AS (SELECT RN, ROW_NUMBER() OVER (PARTITION BY ERP_ITEM_NUMBER, MATERIAL_DESCRIPTION, PLANT_CODE,
                                                  SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER
                                                  ORDER BY STAGE_ID) AS r FROM #a)
        UPDATE d SET RN = r;
        DELETE FROM #a WHERE RN > 1;                 -- exact duplicate lines
        SET @collapsed = @@ROWCOUNT;

        SELECT @keylist = STRING_AGG(CAST(QUOTENAME(COL) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ORD),
               @on      = STRING_AGG(CAST(N't.' + QUOTENAME(COL) + N' = s.' + QUOTENAME(COL) AS NVARCHAR(MAX)), N' AND ') WITHIN GROUP (ORDER BY ORD)
        FROM   @k;

        IF @op IN ('UPSERT','UPDATE','DELETE')
        BEGIN
            -- one row per key: the last one in the file wins
            SET @sql = N';WITH d AS (SELECT RN, ROW_NUMBER() OVER (PARTITION BY ' + @keylist + N' ORDER BY STAGE_ID DESC) AS r FROM #a) UPDATE d SET RN = r';
            EXEC sp_executesql @sql;
            DELETE FROM #a WHERE RN > 1;
            SET @collapsed += @@ROWCOUNT;
        END

        SELECT @set = STRING_AGG(CAST(N't.' + QUOTENAME(b.COL) + N' = s.' + QUOTENAME(b.COL) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY b.ORD)
        FROM   @biz b WHERE NOT EXISTS (SELECT 1 FROM @k k WHERE k.COL = b.COL);
        SET @set = CONCAT_WS(N', ', @set, N't.END_DATE = s.END_DATE', N't.SOURCE_FILE_NAME = s.SOURCE_FILE_NAME',
                             N't.RUN_ID = @r', N't.UPDATED_TS = SYSUTCDATETIME()');   -- START_DATE kept on update

        DECLARE @cols NVARCHAR(MAX) = N'ERP_ITEM_NUMBER, MATERIAL_DESCRIPTION, PLANT_CODE, SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER, START_DATE, END_DATE, SOURCE_FILE_NAME, RUN_ID';
        DECLARE @vals NVARCHAR(MAX) = N's.ERP_ITEM_NUMBER, s.MATERIAL_DESCRIPTION, s.PLANT_CODE, s.SUPPLIER_PART_NUMBER, s.SUPPLIER_NUMBER, s.MANUFACTURING_PART_NUMBER, s.START_DATE, s.END_DATE, s.SOURCE_FILE_NAME, @r';

        SET @sql = CASE @op
            WHEN 'INSERT' THEN
                N'INSERT INTO ' + @tgt + N' (' + @cols + N') SELECT ' + @vals + N' FROM #a s; SET @i = @@ROWCOUNT;'
            WHEN 'TRUNCATE_INSERT' THEN
                N'DELETE FROM ' + @tgt + N'; SET @d = @@ROWCOUNT; '
              + N'INSERT INTO ' + @tgt + N' (' + @cols + N') SELECT ' + @vals + N' FROM #a s; SET @i = @@ROWCOUNT;'
            WHEN 'UPSERT' THEN
                N'CREATE TABLE #act (ACT NVARCHAR(10)); '
              + N'MERGE ' + @tgt + N' AS t USING #a AS s ON ' + @on
              + N' WHEN MATCHED THEN UPDATE SET ' + @set
              + N' WHEN NOT MATCHED BY TARGET THEN INSERT (' + @cols + N') VALUES (' + @vals + N')'
              + N' OUTPUT $action INTO #act; '
              + N'SELECT @i = SUM(CASE WHEN ACT = ''INSERT'' THEN 1 ELSE 0 END), @u = SUM(CASE WHEN ACT = ''UPDATE'' THEN 1 ELSE 0 END) FROM #act;'
            WHEN 'UPDATE' THEN
                N'UPDATE t SET ' + @set + N' FROM ' + @tgt + N' t JOIN #a s ON ' + @on + N'; SET @u = @@ROWCOUNT;'
            WHEN 'DELETE' THEN
                N'DELETE t FROM ' + @tgt + N' t JOIN #a s ON ' + @on + N'; SET @d = @@ROWCOUNT;'
        END;

        /* ---- 5. apply in one transaction -------------------------------- */
        BEGIN TRAN;

        INSERT INTO MATMAS.MATERIAL_MASTER_REJECT (RUN_ID, ROUTE_ID, SOURCE_FILE_NAME, REJECT_REASON, ERP_ITEM_NUMBER,
               MATERIAL_DESCRIPTION, PLANT_CODE, SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER)
        SELECT @RunId, @RouteId, SOURCE_FILE_NAME, REJECT_REASON, ERP_ITEM_NUMBER, MATERIAL_DESCRIPTION, PLANT_CODE,
               SUPPLIER_PART_NUMBER, SUPPLIER_NUMBER, MANUFACTURING_PART_NUMBER
        FROM   #s WHERE REJECT_REASON IS NOT NULL AND IS_DUP_FILE = 0;
        SET @rejected = @@ROWCOUNT;

        EXEC sp_executesql @sql, N'@r VARCHAR(30), @i INT OUTPUT, @u INT OUTPUT, @d INT OUTPUT',
                           @r = @RunId, @i = @ins OUTPUT, @u = @upd OUTPUT, @d = @del OUTPUT;

        INSERT INTO MATMAS.CTL_MATMAS_FILE_HISTORY (ROUTE_ID, FILE_FINGERPRINT, SOURCE_FILE_NAME, ROW_COUNT, RUN_ID)
        SELECT @RouteId, FP, MIN(SOURCE_FILE_NAME), MIN(CNT), @RunId
        FROM   #f f
        WHERE  f.IS_DUP = 0
          AND  NOT EXISTS (SELECT 1 FROM MATMAS.CTL_MATMAS_FILE_HISTORY h WHERE h.ROUTE_ID = @RouteId AND h.FILE_FINGERPRINT = f.FP)
        GROUP  BY FP;

        UPDATE st SET STAGE_STATUS = CASE WHEN s.IS_DUP_FILE = 1 THEN 'DUPLICATE'
                                          WHEN s.REJECT_REASON IS NOT NULL THEN 'REJECTED'
                                          ELSE 'APPLIED' END
        FROM   MATMAS.MATERIAL_MASTER_STAGE st JOIN #s s ON s.STAGE_ID = st.STAGE_ID;

        COMMIT;

        SET @msg = CONCAT(@op, ' into ', @tgt, ': staged=', @staged, ' inserted=', ISNULL(@ins,0), ' updated=', ISNULL(@upd,0),
                          ' deleted=', ISNULL(@del,0), ' rejected=', @rejected, ' duplicates_collapsed=', @collapsed,
                          CASE WHEN @dupfiles > 0 THEN CONCAT(' skipped_duplicate_files=', @dupfiles, ' (', @dupnames, ')') ELSE '' END);

        IF @dupfiles > 0
            INSERT INTO MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, EVENT, FILE_COUNT, ROWS_STAGED, MESSAGE)
            VALUES (@RunId, @RouteId, 'DUPLICATE_FILE', @dupfiles, @duprows,
                    CONCAT(N'already loaded earlier, skipped: ', @dupnames));

        INSERT INTO MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, EVENT, FILE_COUNT, ROWS_STAGED, ROWS_INSERTED,
                                               ROWS_UPDATED, ROWS_DELETED, ROWS_REJECTED, MESSAGE)
        VALUES (@RunId, @RouteId, 'LOADED', (SELECT COUNT(*) FROM #f), @staged, ISNULL(@ins,0), ISNULL(@upd,0),
                ISNULL(@del,0), @rejected, @msg);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = LEFT(CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);
        UPDATE MATMAS.MATERIAL_MASTER_STAGE SET STAGE_STATUS = 'FAILED'
        WHERE  RUN_ID = @RunId AND ROUTE_ID = @RouteId AND STAGE_STATUS = 'NEW';
        INSERT INTO MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, EVENT, ROWS_STAGED, MESSAGE)
        VALUES (@RunId, @RouteId, 'APPLY_FAILED', @staged, @msg);
        THROW;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_ApplyStage - Post SQL of m_MATMAS_LOAD
   Safe under JDBC autocommit=false: commits the driver's open transaction
   (the mapping's inserts are complete) and restores the count on exit.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_ApplyStage
    @RunId   VARCHAR(30) = NULL,
    @RouteId VARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    SET IMPLICIT_TRANSACTIONS OFF;
    WHILE @@TRANCOUNT > 0 COMMIT;

    DECLARE @r VARCHAR(30), @rt VARCHAR(60), @fails INT = 0, @failed NVARCHAR(2000) = N'', @err NVARCHAR(2048);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT RUN_ID, ROUTE_ID
        FROM   MATMAS.MATERIAL_MASTER_STAGE
        WHERE  STAGE_STATUS = 'NEW'
          AND  (@RunId IS NULL OR RUN_ID = @RunId)
          AND  (@RouteId IS NULL OR ROUTE_ID = @RouteId);
    OPEN c; FETCH NEXT FROM c INTO @r, @rt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC MATMAS.sp_MATMAS_ApplyRoute @r, @rt;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @fails += 1;
            SET @failed = LEFT(CONCAT(@failed, CASE WHEN @failed = N'' THEN N'' ELSE N', ' END, @rt), 2000);
        END CATCH
        FETCH NEXT FROM c INTO @r, @rt;
    END
    CLOSE c; DEALLOCATE c;

    WHILE @@TRANCOUNT < @tc BEGIN TRAN;

    IF @fails > 0
    BEGIN
        SET @err = LEFT(CONCAT('MATMAS apply failed for route(s): ', @failed, '. See MATMAS.CTL_MATMAS_RUN_LOG (event APPLY_FAILED).'), 2048);
        THROW 50110, @err, 1;
    END
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_ReapplyRun - retry after fixing the route configuration or
   creating a missing target table. Only rows that FAILED are retried.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_ReapplyRun
    @RunId   VARCHAR(30),
    @RouteId VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE MATMAS.MATERIAL_MASTER_STAGE SET STAGE_STATUS = 'NEW'
    WHERE  RUN_ID = @RunId AND ROUTE_ID = @RouteId AND STAGE_STATUS = 'FAILED';
    PRINT CONCAT(@@ROWCOUNT, ' row(s) reset to NEW');
    EXEC MATMAS.sp_MATMAS_ApplyStage @RunId, @RouteId;
END
GO

/* ---------------------------------------------------------------------
   sp_MATMAS_LogEvent - manual event (CDI writes the same table directly)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE MATMAS.sp_MATMAS_LogEvent
    @RunId VARCHAR(30), @RouteId VARCHAR(60), @Event VARCHAR(30), @Message NVARCHAR(4000) = NULL, @FileCount INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO MATMAS.CTL_MATMAS_RUN_LOG (RUN_ID, ROUTE_ID, EVENT, FILE_COUNT, MESSAGE)
    VALUES (@RunId, @RouteId, @Event, @FileCount, @Message);
END
GO
