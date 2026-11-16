/* =====================================================================
   matmas - 00: DROP EVERYTHING created by 01..03 (re-deploy helper)
   DESTRUCTIVE: deletes all matmas tables, views, procedures and data.
   Only run this on DEV for a clean re-install of 01..03, for example
   after an earlier version (upper-case names) was installed.

   drops: every object in schema matmas (also the old MATMAS objects),
          cfg.matmas_* tables, stg.matmas_* views.
   ===================================================================== */
DECLARE @sql NVARCHAR(MAX) = N'';

-- stg.matmas_* interface views
SELECT @sql += N'DROP VIEW stg.' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.views
WHERE  schema_id = SCHEMA_ID('stg') AND LOWER(name) LIKE 'matmas[_]%';

-- procedures and views in schema matmas
SELECT @sql += N'DROP PROCEDURE matmas.' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.procedures
WHERE  schema_id = SCHEMA_ID('matmas');

SELECT @sql += N'DROP VIEW matmas.' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.views
WHERE  schema_id = SCHEMA_ID('matmas');

-- foreign keys first, then tables in schema matmas
SELECT @sql += N'ALTER TABLE matmas.' + QUOTENAME(OBJECT_NAME(parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.foreign_keys
WHERE  schema_id = SCHEMA_ID('matmas');

SELECT @sql += N'DROP TABLE matmas.' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.tables
WHERE  schema_id = SCHEMA_ID('matmas');

-- cfg.matmas_* config tables (other cfg tables are not touched)
SELECT @sql += N'DROP TABLE cfg.' + QUOTENAME(name) + N';' + CHAR(10)
FROM   sys.tables
WHERE  schema_id = SCHEMA_ID('cfg') AND LOWER(name) LIKE 'matmas[_]%';

PRINT @sql;
EXEC sp_executesql @sql;
GO
