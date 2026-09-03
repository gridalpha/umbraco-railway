-- Creates Umbraco's database and a login scoped to it. Idempotent: safe on every boot.
-- Values arrive as sqlcmd variables so nothing is string-concatenated from the environment.
SET NOCOUNT ON;
GO

USE [master];
GO

IF DB_ID(N'$(DBNAME)') IS NULL
BEGIN
    DECLARE @createDb nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(N'$(DBNAME)');
    EXEC sp_executesql @createDb;
    PRINT 'created database $(DBNAME)';
END
ELSE
    PRINT 'database $(DBNAME) already exists';
GO

-- The login password tracks the Railway variable, which is the only place it is defined,
-- so it is re-applied on every boot rather than drifting after a rotation.
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$(DBUSER)')
BEGIN
    DECLARE @createLogin nvarchar(max) =
        N'CREATE LOGIN ' + QUOTENAME(N'$(DBUSER)') +
        N' WITH PASSWORD = ' + QUOTENAME(N'$(DBPASS)', '''') +
        N', CHECK_POLICY = OFF, DEFAULT_DATABASE = ' + QUOTENAME(N'$(DBNAME)');
    EXEC sp_executesql @createLogin;
    PRINT 'created login $(DBUSER)';
END
ELSE
BEGIN
    DECLARE @alterLogin nvarchar(max) =
        N'ALTER LOGIN ' + QUOTENAME(N'$(DBUSER)') +
        N' WITH PASSWORD = ' + QUOTENAME(N'$(DBPASS)', '''');
    EXEC sp_executesql @alterLogin;
    PRINT 'refreshed password for login $(DBUSER)';
END
GO

USE [$(DBNAME)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(DBUSER)')
BEGIN
    DECLARE @createUser nvarchar(max) =
        N'CREATE USER ' + QUOTENAME(N'$(DBUSER)') + N' FOR LOGIN ' + QUOTENAME(N'$(DBUSER)');
    EXEC sp_executesql @createUser;
    PRINT 'created database user $(DBUSER)';
END
GO

-- Umbraco's documented minimum is db_owner on its own database (or db_datareader +
-- db_datawriter + db_ddladmin). It has no rights anywhere else on the instance.
IF IS_ROLEMEMBER('db_owner', N'$(DBUSER)') = 0
BEGIN
    DECLARE @grant nvarchar(max) =
        N'ALTER ROLE [db_owner] ADD MEMBER ' + QUOTENAME(N'$(DBUSER)');
    EXEC sp_executesql @grant;
    PRINT 'granted db_owner on $(DBNAME) to $(DBUSER)';
END
GO
