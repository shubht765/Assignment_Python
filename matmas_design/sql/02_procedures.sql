/* =====================================================================
   matmas - 02: procedures
   matmas.sp_apply_stage  : Post SQL of the generic load mapping. Applies every
                            NEW staged row, route by route, and raises at the
                            end if any route failed (so the CDI task fails).
   matmas.sp_apply_route  : one run + route: validate, reject, skip duplicate
                            files, de-duplicate, then INSERT / UPSERT / UPDATE /
                            DELETE / TRUNCATE_INSERT into the route's ERP table.
   matmas.sp_reapply_run  : retry a failed run + route after fixing the config.
   matmas.sp_log_event    : write an event by hand (same table CDI writes to).
   ===================================================================== */

/* ---------------------------------------------------------------------
   matmas.sp_apply_route
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE matmas.sp_apply_route
    @run_id    VARCHAR(30),
    @route_id  VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @schema     SYSNAME,
            @table      SYSNAME,
            @op         VARCHAR(20),
            @keys       NVARCHAR(500),
            @skip_dup   BIT,
            @tgt        NVARCHAR(300),
            @sql        NVARCHAR(MAX),
            @err        NVARCHAR(2048),
            @rej        NVARCHAR(MAX),
            @key_list   NVARCHAR(MAX),
            @on         NVARCHAR(MAX),
            @set        NVARCHAR(MAX),
            @staged     INT = 0,
            @rejected   INT = 0,
            @dup_files  INT = 0,
            @dup_rows   INT = 0,
            @collapsed  INT = 0,
            @ins        INT = 0,
            @upd        INT = 0,
            @del        INT = 0,
            @dup_names  NVARCHAR(2000),
            @msg        NVARCHAR(4000);

    SELECT @schema   = target_schema,
           @table    = target_table,
           @op       = load_operation,
           @keys     = key_columns,
           @skip_dup = skip_duplicate_file
    FROM   cfg.matmas_route_config
    WHERE  route_id = @route_id;

    BEGIN TRY
        /* ---- 0. configuration checks --------------------------------- */
        IF @op IS NULL
        BEGIN
            SET @err = CONCAT('Route ', @route_id, ' not found in cfg.matmas_route_config');
            THROW 50101, @err, 1;
        END

        SET @tgt = QUOTENAME(@schema) + N'.' + QUOTENAME(@table);
        IF OBJECT_ID(@tgt, 'U') IS NULL
        BEGIN
            SET @err = CONCAT('Target table ', @tgt, ' does not exist (create it with matmas.sp_create_erp_table)');
            THROW 50102, @err, 1;
        END

        DECLARE @biz TABLE (col SYSNAME PRIMARY KEY, ord INT, max_len INT);
        INSERT INTO @biz (col, ord)
        VALUES ('erp_item_number', 1), ('material_description', 2), ('plant_code', 3),
               ('supplier_part_number', 4), ('supplier_number', 5), ('manufacturing_part_number', 6);

        -- every ERP table must have the template columns; capture their length (nvarchar bytes / 2)
        IF EXISTS (SELECT 1 FROM @biz WHERE COL_LENGTH(@tgt, col) IS NULL)
           OR COL_LENGTH(@tgt, 'start_date') IS NULL
           OR COL_LENGTH(@tgt, 'end_date')   IS NULL
        BEGIN
            SET @err = CONCAT('Target table ', @tgt, ' does not have the matmas template columns');
            THROW 50103, @err, 1;
        END
        UPDATE @biz SET max_len = CASE WHEN COL_LENGTH(@tgt, col) = -1 THEN NULL ELSE COL_LENGTH(@tgt, col) / 2 END;

        DECLARE @k TABLE (col SYSNAME, ord INT);
        INSERT INTO @k (col, ord)
        SELECT LOWER(LTRIM(RTRIM(value))), ordinal
        FROM   STRING_SPLIT(@keys, ',', 1)
        WHERE  LTRIM(RTRIM(value)) <> '';

        IF EXISTS (SELECT 1 FROM @k k WHERE NOT EXISTS (SELECT 1 FROM @biz b WHERE b.col = k.col))
        BEGIN
            SET @err = CONCAT('key_columns of ', @route_id, ' must be among the 6 business columns: ', @keys);
            THROW 50104, @err, 1;
        END
        IF @op IN ('UPSERT','UPDATE','DELETE') AND NOT EXISTS (SELECT 1 FROM @k)
        BEGIN
            SET @err = CONCAT('Operation ', @op, ' needs key_columns for route ', @route_id);
            THROW 50105, @err, 1;
        END

        /* ---- 1. working set ------------------------------------------ */
        CREATE TABLE #s (
            stage_id                    BIGINT,
            source_file_name            NVARCHAR(500),
            erp_item_number             NVARCHAR(1000),
            material_description        NVARCHAR(1000),
            plant_code                  NVARCHAR(1000),
            supplier_part_number        NVARCHAR(1000),
            supplier_number             NVARCHAR(1000),
            manufacturing_part_number   NVARCHAR(1000),
            start_date                  DATE,
            end_date                    DATE,
            reject_reason               NVARCHAR(500),
            is_dup_file                 BIT NOT NULL DEFAULT 0,
            rn                          INT
        );

        INSERT INTO #s (stage_id, source_file_name, erp_item_number, material_description, plant_code,
                        supplier_part_number, supplier_number, manufacturing_part_number, start_date, end_date)
        SELECT stage_id,
               source_file_name,
               NULLIF(LTRIM(RTRIM(erp_item_number)),           N''),
               NULLIF(LTRIM(RTRIM(material_description)),      N''),
               NULLIF(LTRIM(RTRIM(plant_code)),                N''),
               NULLIF(LTRIM(RTRIM(supplier_part_number)),      N''),
               NULLIF(LTRIM(RTRIM(supplier_number)),           N''),
               NULLIF(LTRIM(RTRIM(manufacturing_part_number)), N''),
               ISNULL(start_date, CAST(SYSUTCDATETIME() AS DATE)),
               ISNULL(end_date,   CAST('9999-12-31' AS DATE))
        FROM   matmas.material_master_stage
        WHERE  run_id       = @run_id
          AND  route_id     = @route_id
          AND  stage_status = 'NEW';
        SET @staged = @@ROWCOUNT;

        IF @staged = 0
        BEGIN
            INSERT INTO matmas.run_log (run_id, route_id, event, rows_staged, message)
            VALUES (@run_id, @route_id, 'LOADED', 0, N'no staged rows (empty file?)');
            RETURN;
        END

        /* ---- 2. validation: mandatory = keys + target NOT NULL columns, lengths */
        SELECT @rej = STRING_AGG(CAST(r AS NVARCHAR(MAX)), N', ')
        FROM (
            SELECT N'CASE WHEN ' + QUOTENAME(col) + N' IS NULL THEN ''MISSING ' + col + N''' END' AS r
            FROM  (SELECT col FROM @k UNION SELECT 'erp_item_number' UNION SELECT 'plant_code') m
            UNION ALL
            SELECT N'CASE WHEN LEN(' + QUOTENAME(col) + N') > ' + CAST(max_len AS NVARCHAR(10))
                 + N' THEN ''TOO LONG ' + col + N''' END'
            FROM  @biz
            WHERE max_len IS NOT NULL
        ) x;
        SET @sql = N'UPDATE #s SET reject_reason = NULLIF(CONCAT_WS(''; '', ' + @rej + N', NULL), '''')';
        EXEC sp_executesql @sql;

        /* ---- 3. duplicate files (same content already applied for this route) */
        CREATE TABLE #f (
            source_file_name  NVARCHAR(500),
            fp                VARCHAR(64),
            cnt               INT,
            is_dup            BIT NOT NULL DEFAULT 0
        );
        INSERT INTO #f (source_file_name, fp, cnt)
        SELECT source_file_name,
               CONVERT(VARCHAR(64), HASHBYTES('SHA2_256',
                   STRING_AGG(CAST(CONCAT(ISNULL(erp_item_number, N''),      N'|', ISNULL(material_description, N''), N'|',
                                          ISNULL(plant_code, N''),           N'|', ISNULL(supplier_part_number, N''), N'|',
                                          ISNULL(supplier_number, N''),      N'|', ISNULL(manufacturing_part_number, N''))
                                   AS NVARCHAR(MAX)), NCHAR(10)) WITHIN GROUP (ORDER BY stage_id)), 2),
               COUNT(*)
        FROM   #s
        GROUP  BY source_file_name;

        IF @skip_dup = 1
        BEGIN
            UPDATE f
            SET    is_dup = 1
            FROM   #f f
            WHERE  EXISTS (SELECT 1 FROM matmas.file_history h
                           WHERE  h.route_id = @route_id AND h.file_fingerprint = f.fp);

            UPDATE s
            SET    is_dup_file = 1
            FROM   #s s
            JOIN   #f f ON f.source_file_name = s.source_file_name
            WHERE  f.is_dup = 1;

            SELECT @dup_files = COUNT(*),
                   @dup_names = LEFT(STRING_AGG(CAST(source_file_name AS NVARCHAR(MAX)), N', '), 2000)
            FROM   #f
            WHERE  is_dup = 1;

            SELECT @dup_rows = COUNT(*) FROM #s WHERE is_dup_file = 1;
        END

        /* ---- 4. rows to apply: valid, not from a duplicate file, de-duplicated */
        SELECT * INTO #a FROM #s WHERE reject_reason IS NULL AND is_dup_file = 0;

        ;WITH d AS (
            SELECT rn, ROW_NUMBER() OVER (PARTITION BY erp_item_number, material_description, plant_code,
                                                       supplier_part_number, supplier_number, manufacturing_part_number
                                          ORDER BY stage_id) AS r
            FROM   #a
        )
        UPDATE d SET rn = r;
        DELETE FROM #a WHERE rn > 1;                                -- exact duplicate lines
        SET @collapsed = @@ROWCOUNT;

        SELECT @key_list = STRING_AGG(CAST(QUOTENAME(col) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY ord),
               @on       = STRING_AGG(CAST(N't.' + QUOTENAME(col) + N' = s.' + QUOTENAME(col) AS NVARCHAR(MAX)), N' AND ') WITHIN GROUP (ORDER BY ord)
        FROM   @k;

        IF @op IN ('UPSERT','UPDATE','DELETE')
        BEGIN
            -- one row per key: the last one in the file wins
            SET @sql = N';WITH d AS (SELECT rn, ROW_NUMBER() OVER (PARTITION BY ' + @key_list
                     + N' ORDER BY stage_id DESC) AS r FROM #a) UPDATE d SET rn = r';
            EXEC sp_executesql @sql;
            DELETE FROM #a WHERE rn > 1;
            SET @collapsed += @@ROWCOUNT;
        END

        SELECT @set = STRING_AGG(CAST(N't.' + QUOTENAME(b.col) + N' = s.' + QUOTENAME(b.col) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY b.ord)
        FROM   @biz b
        WHERE  NOT EXISTS (SELECT 1 FROM @k k WHERE k.col = b.col);
        SET @set = CONCAT_WS(N', ', @set,
                             N't.end_date = s.end_date',
                             N't.source_file_name = s.source_file_name',
                             N't.run_id = @r',
                             N't.updated_ts = SYSUTCDATETIME()');      -- start_date is kept on update

        DECLARE @cols NVARCHAR(MAX) = N'erp_item_number, material_description, plant_code, supplier_part_number, supplier_number, '
                                    + N'manufacturing_part_number, start_date, end_date, source_file_name, run_id';
        DECLARE @vals NVARCHAR(MAX) = N's.erp_item_number, s.material_description, s.plant_code, s.supplier_part_number, s.supplier_number, '
                                    + N's.manufacturing_part_number, s.start_date, s.end_date, s.source_file_name, @r';

        SET @sql = CASE @op
            WHEN 'INSERT' THEN
                N'INSERT INTO ' + @tgt + N' (' + @cols + N') SELECT ' + @vals + N' FROM #a s; SET @i = @@ROWCOUNT;'
            WHEN 'TRUNCATE_INSERT' THEN
                N'DELETE FROM ' + @tgt + N'; SET @d = @@ROWCOUNT; '
              + N'INSERT INTO ' + @tgt + N' (' + @cols + N') SELECT ' + @vals + N' FROM #a s; SET @i = @@ROWCOUNT;'
            WHEN 'UPSERT' THEN
                N'CREATE TABLE #act (act NVARCHAR(10)); '
              + N'MERGE ' + @tgt + N' AS t USING #a AS s ON ' + @on
              + N' WHEN MATCHED THEN UPDATE SET ' + @set
              + N' WHEN NOT MATCHED BY TARGET THEN INSERT (' + @cols + N') VALUES (' + @vals + N')'
              + N' OUTPUT $action INTO #act; '
              + N'SELECT @i = SUM(CASE WHEN act = ''INSERT'' THEN 1 ELSE 0 END), '
              + N'@u = SUM(CASE WHEN act = ''UPDATE'' THEN 1 ELSE 0 END) FROM #act;'
            WHEN 'UPDATE' THEN
                N'UPDATE t SET ' + @set + N' FROM ' + @tgt + N' t JOIN #a s ON ' + @on + N'; SET @u = @@ROWCOUNT;'
            WHEN 'DELETE' THEN
                N'DELETE t FROM ' + @tgt + N' t JOIN #a s ON ' + @on + N'; SET @d = @@ROWCOUNT;'
        END;

        /* ---- 5. apply in one transaction ----------------------------- */
        BEGIN TRAN;

        INSERT INTO matmas.material_master_reject (run_id, route_id, source_file_name, reject_reason, erp_item_number,
                    material_description, plant_code, supplier_part_number, supplier_number, manufacturing_part_number)
        SELECT @run_id, @route_id, source_file_name, reject_reason, erp_item_number,
               material_description, plant_code, supplier_part_number, supplier_number, manufacturing_part_number
        FROM   #s
        WHERE  reject_reason IS NOT NULL
          AND  is_dup_file = 0;
        SET @rejected = @@ROWCOUNT;

        EXEC sp_executesql @sql,
             N'@r VARCHAR(30), @i INT OUTPUT, @u INT OUTPUT, @d INT OUTPUT',
             @r = @run_id, @i = @ins OUTPUT, @u = @upd OUTPUT, @d = @del OUTPUT;

        INSERT INTO matmas.file_history (route_id, file_fingerprint, source_file_name, row_count, run_id)
        SELECT @route_id, fp, MIN(source_file_name), MIN(cnt), @run_id
        FROM   #f f
        WHERE  f.is_dup = 0
          AND  NOT EXISTS (SELECT 1 FROM matmas.file_history h
                           WHERE  h.route_id = @route_id AND h.file_fingerprint = f.fp)
        GROUP  BY fp;

        UPDATE st
        SET    stage_status = CASE WHEN s.is_dup_file = 1         THEN 'DUPLICATE'
                                   WHEN s.reject_reason IS NOT NULL THEN 'REJECTED'
                                   ELSE 'APPLIED' END
        FROM   matmas.material_master_stage st
        JOIN   #s s ON s.stage_id = st.stage_id;

        COMMIT;

        SET @msg = CONCAT(@op, ' into ', @tgt, ': staged=', @staged, ' inserted=', ISNULL(@ins,0), ' updated=', ISNULL(@upd,0),
                          ' deleted=', ISNULL(@del,0), ' rejected=', @rejected, ' duplicates_collapsed=', @collapsed,
                          CASE WHEN @dup_files > 0 THEN CONCAT(' skipped_duplicate_files=', @dup_files, ' (', @dup_names, ')') ELSE '' END);

        IF @dup_files > 0
            INSERT INTO matmas.run_log (run_id, route_id, event, file_count, rows_staged, message)
            VALUES (@run_id, @route_id, 'DUPLICATE_FILE', @dup_files, @dup_rows,
                    CONCAT(N'already loaded earlier, skipped: ', @dup_names));

        INSERT INTO matmas.run_log (run_id, route_id, event, file_count, rows_staged, rows_inserted,
                                    rows_updated, rows_deleted, rows_rejected, message)
        VALUES (@run_id, @route_id, 'LOADED', (SELECT COUNT(*) FROM #f), @staged, ISNULL(@ins,0),
                ISNULL(@upd,0), ISNULL(@del,0), @rejected, @msg);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = LEFT(CONCAT('ERROR ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE()), 4000);

        UPDATE matmas.material_master_stage
        SET    stage_status = 'FAILED'
        WHERE  run_id = @run_id AND route_id = @route_id AND stage_status = 'NEW';

        INSERT INTO matmas.run_log (run_id, route_id, event, rows_staged, message)
        VALUES (@run_id, @route_id, 'APPLY_FAILED', @staged, @msg);
        THROW;
    END CATCH
END
GO

/* ---------------------------------------------------------------------
   matmas.sp_apply_stage - Post SQL of m_P2O_102_MATMAS_Load
   Safe under JDBC autocommit=false: commits the driver's open transaction
   (the mapping's inserts are complete) and restores the count on exit.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE matmas.sp_apply_stage
    @run_id    VARCHAR(30) = NULL,
    @route_id  VARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @tc INT = @@TRANCOUNT;
    SET IMPLICIT_TRANSACTIONS OFF;
    WHILE @@TRANCOUNT > 0 COMMIT;

    DECLARE @r       VARCHAR(30),
            @rt      VARCHAR(60),
            @fails   INT = 0,
            @failed  NVARCHAR(2000) = N'',
            @err     NVARCHAR(2048);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT run_id, route_id
        FROM   matmas.material_master_stage
        WHERE  stage_status = 'NEW'
          AND  (@run_id   IS NULL OR run_id   = @run_id)
          AND  (@route_id IS NULL OR route_id = @route_id);

    OPEN c;
    FETCH NEXT FROM c INTO @r, @rt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC matmas.sp_apply_route @r, @rt;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @fails += 1;
            SET @failed = LEFT(CONCAT(@failed, CASE WHEN @failed = N'' THEN N'' ELSE N', ' END, @rt), 2000);
        END CATCH
        FETCH NEXT FROM c INTO @r, @rt;
    END
    CLOSE c;
    DEALLOCATE c;

    WHILE @@TRANCOUNT < @tc BEGIN TRAN;

    IF @fails > 0
    BEGIN
        SET @err = LEFT(CONCAT('matmas apply failed for route(s): ', @failed,
                               '. See matmas.run_log (event APPLY_FAILED).'), 2048);
        THROW 50110, @err, 1;
    END
END
GO

/* ---------------------------------------------------------------------
   matmas.sp_reapply_run - retry after fixing the route config or creating
   a missing target table. Only rows that FAILED are retried.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE matmas.sp_reapply_run
    @run_id    VARCHAR(30),
    @route_id  VARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE matmas.material_master_stage
    SET    stage_status = 'NEW'
    WHERE  run_id = @run_id AND route_id = @route_id AND stage_status = 'FAILED';
    PRINT CONCAT(@@ROWCOUNT, ' row(s) reset to NEW');

    EXEC matmas.sp_apply_stage @run_id, @route_id;
END
GO

/* ---------------------------------------------------------------------
   matmas.sp_log_event - manual event (CDI writes the same table directly)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE matmas.sp_log_event
    @run_id      VARCHAR(30),
    @route_id    VARCHAR(60),
    @event       VARCHAR(30),
    @message     NVARCHAR(4000) = NULL,
    @file_count  INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO matmas.run_log (run_id, route_id, event, file_count, message)
    VALUES (@run_id, @route_id, @event, @file_count, @message);
END
GO
