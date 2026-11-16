/* =====================================================================
   MATMAS - 00: DROP EVERYTHING in schema MATMAS (re-deploy helper)
   DESTRUCTIVE: deletes all MATMAS tables, views, procedures and data.
   Only run this on DEV when you want a clean re-install of 01..03.
   ===================================================================== */
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += N'DROP PROCEDURE MATMAS.' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.procedures WHERE schema_id = SCHEMA_ID('MATMAS');

SELECT @sql += N'DROP VIEW MATMAS.' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.views WHERE schema_id = SCHEMA_ID('MATMAS');

-- foreign keys first, then tables
SELECT @sql += N'ALTER TABLE MATMAS.' + QUOTENAME(OBJECT_NAME(parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.foreign_keys WHERE schema_id = SCHEMA_ID('MATMAS');

SELECT @sql += N'DROP TABLE MATMAS.' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.tables WHERE schema_id = SCHEMA_ID('MATMAS');

PRINT @sql;
EXEC sp_executesql @sql;
GO
