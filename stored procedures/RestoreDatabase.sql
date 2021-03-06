USE [master]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('[dbo].[RestoreDatabase]') IS NOT NULL DROP PROCEDURE [dbo].[RestoreDatabase]
GO
CREATE PROCEDURE [dbo].[RestoreDatabase]

/* 
Purpose: This procedure can be used for regular restores of database that is part of availability group. Taking 
care of all actions needed for proper restore proccess of database in Availability group. It is also writing its actions 
to CommandLog which is able from popular Olla Hallengreen's maintenance.
	
Author:	Tomas Rybnicky
Date of last update: 
	v1.3.0	- 20.08.2020 - added possiblity to preserve original database permissions settings inlcuding custom roles and users with all securables (RestoreDatabase stored procedure)

List of previous revisions:
	v1.2.1	- 04.05.2020 - SnapshotUrl in RESTORE FILELISTONLY condition changed to SQL Server version < 13
	v1.2	- 09.09.2019 - added possiblity to set autogrowth for restored database based on model database settings (RestoreDatabase stored procedure)
	v1.0	- 01.11.2018 - stored procedures cleaned and tested. Solution is usable now.
	v0.1	- 31.10.2018 - Initial solution containing all not necesary scripting from testing and development work
	
Execution example:
	-- restore database and set up autogrowth based on model database
	EXEC [master].[dbo].[RestoreDatabase]
	@BackupFile = N'\\Path\To\BackupFile\Backup.bak',
	@Database	= N'TestDB',
	@LogToTable = 'Y',
	@CheckModel = 'Y'

	-- restore database preserving database permissions
	EXEC [master].[dbo].[RestoreDatabase]
	@BackupFile = N'\\Path\To\BackupFile\Backup.bak',
	@Database	= N'TestDB',
	@LogToTable = 'Y',
	@PreservePermissions = 'Y'

	-- restore database and add to Availability Group
	EXEC [master].[dbo].[RestoreDatabase]
	@BackupFile = N'\\Path\To\BackupFile\Backup.bak',
	@Database	= N'TestDB',
	@AvailabilityGroup = N'AvailabilityGroupName',
	@SharedFolder = N'\\Path\To\AGShare',
	@LogToTable = 'Y'
*/

@BackupFile				NVARCHAR(1024),			-- Backup file that is to be used for restore
@Database				SYSNAME,				-- Name of restored database
@CheckModel				CHAR(1)			= 'N',	-- Flag if restored database has to attach model database properties (autogrowth for files)
@AvailabilityGroup		SYSNAME			= NULL,	-- Name of Availability Group that is to be used for database. When NULL then normal restore operation happening
@SharedFolder			NVARCHAR(2048)	= NULL,	-- Path to shared network location acessible by all replicas. Required when adding to Availability group
@PreservePermissions	CHAR(1)			= 'N',	-- Flag if current database users and roles has to be preserved after restore (user mapping, owned schemas, database roles, securables, extended properties). Since v1.3
@LogToTable				CHAR(1)			= 'N'	-- Flag if restore commands are to be tracked in CommandLog table

AS

BEGIN
	
	SET NOCOUNT ON
	----------------------------------------------------------------------------------------
	-- declare variables used in script
	----------------------------------------------------------------------------------------
	DECLARE @ErrorMessage			NVARCHAR(MAX)
	DECLARE @InstanceDataPath		VARCHAR(1024)
	DECLARE @InstanceTlogPath		VARCHAR(1024)
	DECLARE @InstanceBackupPath		VARCHAR(1024)
	DECLARE @xp_cmd					VARCHAR(512)
	DECLARE @Version				NUMERIC(18,10)
	DECLARE @Tsql					NVARCHAR(MAX)
	DECLARE @Msg					VARCHAR(MAX)
	DECLARE @PrimaryReplica			SYSNAME
	DECLARE @DatabaseinAG			BIT
	DECLARE @FullBackupPath			NVARCHAR(1024)
	DECLARE @TlogBackupPath			NVARCHAR(1024)

	-- set defaults
	SET @DatabaseinAG = 0

	
	SET @Msg = @@SERVERNAME + ' : Restore database ' + @Database + ' from file ' + @BackupFile
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	SET @Msg =  CHAR(13) + CHAR(10) + 'STEP (' + @@SERVERNAME + '): Checking'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	----------------------------------------------------------------------------------------
	-- check requirements
	----------------------------------------------------------------------------------------	
	SET @Msg = ' - permissions'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;
	IF IS_SRVROLEMEMBER('sysadmin') = 0
	BEGIN
		SET @ErrorMessage = 'You need to be a member of the sysadmin server role to run this procedure.'
		GOTO QuitWithRollback
	END

	SET @Msg = ' - procedure CommandExecute'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;	
	IF NOT EXISTS (SELECT * FROM sys.objects objects INNER JOIN sys.schemas schemas ON objects.[schema_id] = schemas.[schema_id] WHERE objects.[type] = 'P' AND schemas.[name] = 'dbo' AND objects.[name] = 'CommandExecute')
	BEGIN
		SET @ErrorMessage = 'The stored procedure CommandExecute is missing. Download https://ola.hallengren.com/scripts/CommandExecute.sql.' + CHAR(13) + CHAR(10) + ' '
		GOTO QuitWithRollback
	END
	
	SET @Msg = ' - table CommandLog'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;	
	IF @LogToTable = 'Y' AND NOT EXISTS (SELECT * FROM sys.objects objects INNER JOIN sys.schemas schemas ON objects.[schema_id] = schemas.[schema_id] WHERE objects.[type] = 'U' AND schemas.[name] = 'dbo' AND objects.[name] = 'CommandLog')
	BEGIN
		SET @ErrorMessage = 'The table CommandLog is missing. Download https://ola.hallengren.com/scripts/CommandLog.sql.' + CHAR(13) + CHAR(10) + ' '
		GOTO QuitWithRollback
	END
	
	SET @Msg = ' - parameters'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;
	IF @PreservePermissions = 'Y' AND NOT EXISTS (SELECT 1 FROM sys.databases WHERE [name] = @Database)
	BEGIN
		SET @ErrorMessage = 'Parameter @PreservePermissions can not be used when database soes not exist yet! Please check if database ' + @Database + ' exists and rerun procedure.'
		GOTO QuitWithRollback
	END

	----------------------------------------------------------------------------------------
	-- create tables used in script
	----------------------------------------------------------------------------------------
	IF OBJECT_ID('tempdb..#FileListTable') IS NOT NULL DROP TABLE #FileListTable
	CREATE TABLE #FileListTable (
		[LogicalName]           NVARCHAR(128),
		[PhysicalName]          NVARCHAR(260),
		[Type]                  CHAR(1),
		[FileGroupName]         NVARCHAR(128),
		[Size]                  NUMERIC(20,0),
		[MaxSize]               NUMERIC(20,0),
		[FileID]                BIGINT,
		[CreateLSN]             NUMERIC(25,0),
		[DropLSN]               NUMERIC(25,0),
		[UniqueID]              UNIQUEIDENTIFIER,
		[ReadOnlyLSN]           NUMERIC(25,0),
		[ReadWriteLSN]          NUMERIC(25,0),
		[BackupSizeInBytes]     BIGINT,
		[SourceBlockSize]       INT,
		[FileGroupID]           INT,
		[LogGroupGUID]          UNIQUEIDENTIFIER,
		[DifferentialBaseLSN]   NUMERIC(25,0),
		[DifferentialBaseGUID]  UNIQUEIDENTIFIER,
		[IsReadOnly]            BIT,
		[IsPresent]             BIT,
		[TDEThumbprint]         VARBINARY(32), -- remove this column if using SQL 2005
		[SnapshotUrl]			NVARCHAR(360)
	)

	IF OBJECT_ID('tempdb..#LogicalFilesTable') IS NOT NULL DROP TABLE #LogicalFilesTable
	CREATE TABLE #LogicalFilesTable (
		FileName NVARCHAR(128),
		FileType TINYINT,
		FileId INT,
		FileSize INT
	)

	-- START Since v1.3
	IF @PreservePermissions = 'Y'
	BEGIN
		IF OBJECT_ID('tempdb..#DatabaseRoleCreateOrder') IS NOT NULL DROP TABLE #DatabaseRoleCreateOrder
		CREATE TABLE #DatabaseRoleCreateOrder (
			[RoleId]		INT,
			[RoleName]		SYSNAME,
			[CreateOrder]	INT
		)

		IF OBJECT_ID('tempdb..#DatabasePrincipals') IS NOT NULL DROP TABLE #DatabasePrincipals
		CREATE TABLE #DatabasePrincipals (
			[PrincipalId]	INT,
			[PrincipalSid]	VARBINARY(85),
			[PrincipalName]	SYSNAME,
			[PrincipalType]	CHAR(1),
			[DefaultSchema]	SYSNAME NULL,
			[LoginName]     SYSNAME NULL,
			[LoginType]     CHAR(1) NULL,
			[OwnerId]		INT NULL,
			[OwnerName]		SYSNAME NULL,
			[CreateOrder]	SMALLINT,
			[Processed]		BIT DEFAULT 0
		)

		IF OBJECT_ID('tempdb..#DatabaseOwnedSchemas') IS NOT NULL DROP TABLE #DatabaseOwnedSchemas
		CREATE TABLE #DatabaseOwnedSchemas (
			[PrincipalId]	INT,
			[PrincipalName]	SYSNAME,
			[SchemaId]		INT,
			[SchemaName]    SYSNAME
		)

		IF OBJECT_ID('tempdb..#DatabaseRoleMembers') IS NOT NULL DROP TABLE #DatabaseRoleMembers
		CREATE TABLE #DatabaseRoleMembers (
			[PrincipalId]	INT,
			[PrincipalName]	SYSNAME,
			[RoleId]		INT,
			[RoleName]		SYSNAME
		)

		IF OBJECT_ID('tempdb..#DatabaseExplicitPermissions') IS NOT NULL DROP TABLE #DatabaseExplicitPermissions
		CREATE TABLE #DatabaseExplicitPermissions (
			[PrincipalId]	INT,
			[CommandState]	NVARCHAR(60),
			[Permission]    NVARCHAR(128),
			[Securable]		NVARCHAR(258),
			[Grantee]		NVARCHAR(258),
			[GrantOption]	NVARCHAR(60),
			[Grantor]		NVARCHAR(258)
		)

		IF OBJECT_ID('tempdb..#DatabaseExtendedProperties') IS NOT NULL DROP TABLE #DatabaseExtendedProperties
		CREATE TABLE #DatabaseExtendedProperties (
			[PrincipalId]	INT,
			[PrincipalName]	SYSNAME,
			[PropertyName]	SYSNAME,
			[PropertyValue]	SQL_VARIANT
		)
	END
	-- END Since v1.3

	----------------------------------------------------------------------------------------
	-- check availability group
	----------------------------------------------------------------------------------------
	IF @AvailabilityGroup IS NOT NULL
	BEGIN	
		SET @Msg = ' - availability group'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		-- check if required shared folder given and available 
		IF @SharedFolder IS NULL GOTO SharedFolderNotSpecified

		-- check if HADR enabled
		IF (SELECT SERVERPROPERTY ('IsHadrEnabled')) <> 1 GOTO HadrNotEnabled

		-- check given AG name
		IF NOT EXISTS (SELECT name FROM master.sys.availability_groups WHERE name = @AvailabilityGroup) GOTO UnknownAvailabilityGroup

		-- check primary replica
		SELECT 
			@PrimaryReplica = hags.primary_replica 
		FROM 
			sys.dm_hadr_availability_group_states hags
			INNER JOIN sys.availability_groups ag ON ag.group_id = hags.group_id
		WHERE
			ag.name = @AvailabilityGroup;
		IF @PrimaryReplica <> @@SERVERNAME GOTO NotPrimaryReplica

		-- check if database already part of AG
		SELECT 
			@DatabaseInAG = COUNT(*)			
		FROM 
			master.sys.dm_hadr_database_replica_states drs
			INNER JOIN master.sys.databases db ON drs.database_id = db.database_id
			INNER JOIN master.sys.availability_groups ag ON ag.group_id = drs.group_id
			INNER JOIN master.sys.availability_replicas ar ON ar.replica_id = drs.replica_id
		WHERE replica_server_name = @@SERVERNAME
			AND is_local = 1
			AND is_primary_replica = 1
			AND ag.name = @AvailabilityGroup
			AND db.name = @Database
	END

	SET @Msg = CHAR(13) + CHAR(10) + 'STEP (' + @@SERVERNAME + '): Preparing'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	----------------------------------------------------------------------------------------
	-- get instance configuration info
	----------------------------------------------------------------------------------------
	SET @Msg = ' - gathering instance info'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	SET @Version = CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)),CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max))) - 1) + '.' + REPLACE(RIGHT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)), LEN(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max))) - CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))),'.','') AS numeric(18,10))
	IF @Version < 10 AND OBJECT_ID('tempdb..#FileListTable') IS NOT NULL ALTER TABLE #FileListTable DROP COLUMN [TDEThumbprint]; 
	IF @Version < 13 AND OBJECT_ID('tempdb..#FileListTable') IS NOT NULL ALTER TABLE #FileListTable DROP COLUMN [SnapshotUrl]; 

	SET @InstanceDataPath = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS VARCHAR(1024))
	SET @InstanceTlogPath = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS VARCHAR(1024))
	
	EXEC master.dbo.xp_instance_regread
		N'HKEY_LOCAL_MACHINE',
		N'Software\Microsoft\MSSQLServer\MSSQLServer',
		N'BackupDirectory', 
		@InstanceBackupPath OUTPUT

	----------------------------------------------------------------------------------------
	-- get backup file info
	----------------------------------------------------------------------------------------
	SET @Msg = ' - gathering backup file info'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	BEGIN TRY
		INSERT INTO #FileListTable EXEC('RESTORE FILELISTONLY FROM DISK = N''' + @BackupFile + '''')
	END TRY
	BEGIN CATCH
		SET @ErrorMessage = ERROR_MESSAGE() + ' Please check if file ' + @BackupFile + ' exists and if not used by another proccess.'
		GOTO QuitWithRollback
	END CATCH	

	-- START Since v1.3
	----------------------------------------------------------------------------------------
	-- get database users info
	----------------------------------------------------------------------------------------
	IF @PreservePermissions = 'Y'
	BEGIN		
		SET @Msg = ' - gathering current database users info'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		-- gatger database roles create order - this important and role membership can be hierarchical
		IF OBJECT_ID('tempdb..#TmpRoles') IS NOT NULL DROP TABLE #TmpRoles
		CREATE TABLE #TmpRoles (
			RoleId INT,
			RoleName SYSNAME,
			ParentRoleId INT NULL,
			ParentRoleName SYSNAME NULL
		)

		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + '
		SELECT 
			dp.principal_id AS RoleId,
			dp.name AS RoleName,
			rm.role_principal_id AS ParentRoleId,
			dr.name AS ParentRoleName
		FROM sys.database_principals dp
			LEFT JOIN sys.database_role_members rm ON dp.principal_id = rm.member_principal_id
			LEFT JOIN sys.database_principals dr ON dr.principal_id = rm.role_principal_id
		WHERE dp.type in (''R'')
			AND dp.is_fixed_role = 0
			AND dp.principal_id > 4;'
		INSERT INTO #TmpRoles EXEC(@Tsql);		

		WITH cteRolesHierarchy AS (
			SELECT
				RoleId,
				RoleName,
				ParentRoleId,
				ParentRoleName,
				0 AS CreateOrder
			FROM #TmpRoles
			WHERE ParentRoleId IS NULL

			UNION ALL
	 
			SELECT
				r.RoleId,
				r.RoleName,
				r.ParentRoleId,
				r.ParentRoleName,
				rh.CreateOrder + 1 AS CreateOrder
			FROM #TmpRoles r
				INNER JOIN cteRolesHierarchy rh ON r.ParentRoleId = rh.RoleId

		)
		
		INSERT INTO #DatabaseRoleCreateOrder
		SELECT DISTINCT 
			RoleId, 
			RoleName, 
			CreateOrder 
		FROM cteRolesHierarchy 
		ORDER BY CreateOrder ASC

		IF OBJECT_ID('tempdb..#TmpRoles') IS NOT NULL DROP TABLE #TmpRoles

		-- gather database principals
		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + 
		'SELECT 
			dp.principal_id AS PrincipalId,
			dp.sid AS PrincipalSid,
			dp.name AS PrincipalName,
			dp.type AS PrincipalType,
			dp.default_schema_name AS DefaultSchema,
			sp.name AS LoginName,
			sp.type AS LoginType,
			dp.owning_principal_id AS OwnerId,
			dpo.name AS OwnerName,
			CASE
				WHEN dp.type = ''A'' THEN 0
				WHEN dp.type = ''R'' THEN 1
				ELSE 2
			END AS CreateOrder,
			0 AS Processed
		FROM sys.database_principals AS dp
			LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
			LEFT JOIN sys.database_principals dpo ON dp.owning_principal_id = dpo.principal_id
		WHERE dp.type in (''S'', ''G'', ''U'', ''E'', ''R'')
			AND dp.name NOT LIKE ''##%##''
			AND dp.name NOT LIKE ''NT AUTHORITY%''
			AND dp.name NOT LIKE ''NT SERVICE%''
			AND dp.principal_id > 4
			AND dp.is_fixed_role = 0'
		INSERT INTO #DatabasePrincipals EXEC(@Tsql)		

		-- gather owned schemas
		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + 		
		'SELECT
			s.principal_id AS PrincipalId,
			dp.name AS PrincipalName,
			s.schema_id AS SchemaId,
			s.name AS SchemaName
		FROM sys.schemas AS s 
			INNER JOIN sys.database_principals AS dp ON s.principal_id = dp.principal_id
		WHERE dp.type in (''S'', ''G'', ''U'', ''E'', ''R'')
			AND dp.name NOT LIKE ''##%##''
			AND dp.name NOT LIKE ''NT AUTHORITY%''
			AND dp.name NOT LIKE ''NT SERVICE%''
			AND dp.principal_id > 4
			AND dp.is_fixed_role = 0'
		INSERT INTO #DatabaseOwnedSchemas EXEC(@Tsql)

		-- gather roles membership
		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + 
		'SELECT
			dp.principal_id AS PrincipalId,
			dp.name AS PrincipalNamePrincipal,
			role.principal_id AS RoleId,
			role.name AS RoleName
		FROM sys.database_role_members AS drm
			INNER JOIN sys.database_principals AS dp ON drm.member_principal_id = dp.principal_id
			INNER JOIN sys.database_principals AS role ON role.principal_id = drm.role_principal_id
		WHERE dp.type in (''S'', ''G'', ''U'', ''E'', ''R'')
			AND dp.name NOT LIKE ''##%##''
			AND dp.name NOT LIKE ''NT AUTHORITY%''
			AND dp.name NOT LIKE ''NT SERVICE%''
			AND dp.principal_id > 4
			AND dp.is_fixed_role = 0'
		INSERT INTO #DatabaseRoleMembers EXEC(@Tsql)

		-- gather explicit permissions on securables
		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + 
		'SELECT 
			dp.principal_id AS PrincipalId,
			CASE 
				WHEN p.state_desc = ''GRANT_WITH_GRANT_OPTION'' THEN ''GRANT'' 
				ELSE p.state_desc 
			END AS CommandState,
			p.permission_name AS Permission,
			CASE p.class_desc
				WHEN ''DATABASE'' THEN ''DATABASE::'' + QUOTENAME(DB_NAME())
				WHEN ''SCHEMA'' THEN ''SCHEMA::'' + QUOTENAME(s.name)
				WHEN ''OBJECT_OR_COLUMN'' THEN ''OBJECT::'' + QUOTENAME(os.name) + ''.'' + QUOTENAME(o.name) +
					CASE 
						WHEN p.minor_id <> 0 THEN ''('' + QUOTENAME(c.name) + '')'' 
						ELSE '''' 
					END
				WHEN ''DATABASE_PRINCIPAL'' THEN 
					CASE pr.type_desc 
						WHEN ''SQL_USER'' THEN ''USER''
						WHEN ''DATABASE_ROLE'' THEN ''ROLE''
						WHEN ''APPLICATION_ROLE'' THEN ''APPLICATION ROLE''
					END + ''::'' + QUOTENAME(pr.name)
				WHEN ''ASSEMBLY'' THEN ''ASSEMBLY::'' + QUOTENAME(a.name)
				WHEN ''TYPE'' THEN ''TYPE::'' + QUOTENAME(ts.name) + ''.'' + QUOTENAME(t.name)
				WHEN ''XML_SCHEMA_COLLECTION'' THEN ''XML SCHEMA COLLECTION::'' + QUOTENAME(xss.name) + ''.'' + QUOTENAME(xsc.name)
				WHEN ''SERVICE_CONTRACT'' THEN ''CONTRACT::'' + QUOTENAME(sc.name)
				WHEN ''MESSAGE_TYPE'' THEN ''MESSAGE TYPE::'' + QUOTENAME(smt.name)
				WHEN ''REMOTE_SERVICE_BINDING'' THEN ''REMOTE SERVICE BINDING::'' + QUOTENAME(rsb.name)
				WHEN ''ROUTE'' THEN ''ROUTE::'' + QUOTENAME(r.name)
				WHEN ''SERVICE'' THEN ''SERVICE::'' + QUOTENAME(sbs.name)
				WHEN ''FULLTEXT_CATALOG'' THEN ''FULLTEXT CATALOG::'' + QUOTENAME(fc.name)
				WHEN ''FULLTEXT_STOPLIST'' THEN ''FULLTEXT STOPLIST::'' + QUOTENAME(fs.name)
				WHEN ''SYMMETRIC_KEYS'' THEN ''SYMMETRIC KEY::'' + QUOTENAME(sk.name)
				WHEN ''CERTIFICATE'' THEN ''CERTIFICATE::'' + QUOTENAME(cer.name)
				WHEN ''ASYMMETRIC_KEY'' THEN ''ASYMMETRIC KEY::'' + QUOTENAME(ak.name)
			END COLLATE Latin1_General_100_BIN AS Securable,
			dp.name AS Grantee,
			CASE 
				WHEN p.state_desc = ''GRANT_WITH_GRANT_OPTION'' THEN ''WITH GRANT OPTION'' 
				ELSE '''' 
			END AS GrantOption,
			g.name AS Grantor
		FROM sys.database_permissions AS p
			LEFT JOIN sys.schemas AS s ON p.major_id = s.schema_id
			LEFT JOIN sys.all_objects AS o 
				INNER JOIN sys.schemas AS os ON o.schema_id = os.schema_id 
					ON p.major_id = o.object_id
			LEFT JOIN sys.types AS t 
				INNER JOIN sys.schemas AS ts ON t.schema_id = ts.schema_id 
					ON p.major_id = t.user_type_id
			LEFT JOIN sys.xml_schema_collections AS xsc     
				INNER JOIN sys.schemas AS xss ON xsc.schema_id = xss.schema_id
					ON p.major_id = xsc.xml_collection_id
			LEFT JOIN sys.columns AS c ON o.object_id = c.object_id AND p.minor_id = c.column_id
			LEFT JOIN sys.database_principals AS pr ON p.major_id = pr.principal_id
			LEFT JOIN sys.assemblies AS A ON p.major_id = a.assembly_id
			LEFT JOIN sys.service_contracts AS sc ON p.major_id = sc.service_contract_id
			LEFT JOIN sys.service_message_types AS smt ON p.major_id = smt.message_type_id
			LEFT JOIN sys.remote_service_bindings AS rsb ON p.major_id = rsb.remote_service_binding_id
			LEFT JOIN sys.services AS sbs ON p.major_id = sbs.service_id
			LEFT JOIN sys.routes AS r ON p.major_id = r.route_id
			LEFT JOIN sys.fulltext_catalogs AS fc ON p.major_id = fc.fulltext_catalog_id
			LEFT JOIN sys.fulltext_stoplists AS fs ON p.major_id = fs.stoplist_id
			LEFT JOIN sys.asymmetric_keys AS ak ON p.major_id = ak.asymmetric_key_id
			LEFT JOIN sys.certificates AS cer ON p.major_id = cer.certificate_id
			LEFT JOIN sys.symmetric_keys AS sk ON p.major_id = sk.symmetric_key_id
			INNER JOIN sys.database_principals AS dp ON p.grantee_principal_id = dp.principal_id
			INNER JOIN sys.database_principals AS g ON p.grantor_principal_id = g.principal_id
		WHERE dp.type in (''S'', ''G'', ''U'', ''E'', ''R'')
			AND dp.name NOT LIKE ''##%##''
			AND dp.name NOT LIKE ''NT AUTHORITY%''
			AND dp.name NOT LIKE ''NT SERVICE%''
			AND dp.principal_id > 4
			AND dp.is_fixed_role = 0
			AND (p.permission_name <> ''CONNECT'' AND p.class_desc <> ''DATABASE'')'
		INSERT INTO #DatabaseExplicitPermissions EXEC(@Tsql)

		-- gather extended properties for users
		SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';'
		SET @Tsql = @Tsql + 		
		'SELECT 
			dp.principal_id AS PrincipalId,
			dp.name AS PrincipalName,
			ep.name AS PropertyName,
			ep.value AS PropertyValue
		FROM sys.extended_properties AS ep
			INNER JOIN sys.database_principals AS dp ON ep.major_id = dp.principal_id
		WHERE dp.type in (''S'', ''G'', ''U'', ''E'', ''R'')
			AND dp.name NOT LIKE ''##%##''
			AND dp.name NOT LIKE ''NT AUTHORITY%''
			AND dp.name NOT LIKE ''NT SERVICE%''
			AND dp.principal_id > 4
			AND dp.is_fixed_role = 0
			AND ep.class = 4'
		INSERT INTO #DatabaseExtendedProperties EXEC(@Tsql)
	END
	-- END Since v1.3

	----------------------------------------------------------------------------------------
	-- remove database from Availability Group if all requirements are met
	-- requirements:
	--  - need to be called as restore to AG (given by @AvailabilityGroup parameter value)
	--  - instance need to be primary replica
	--  - database need to be already included in AG
	----------------------------------------------------------------------------------------
	IF @AvailabilityGroup IS NOT NULL AND @SharedFolder IS NOT NULL AND @DatabaseinAG = 1
	BEGIN 
		SET @Msg = ' - removing database ' + @Database + ' from Availability Group ' + @AvailabilityGroup
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		SET @Tsql = 'ALTER AVAILABILITY GROUP [' + @AvailabilityGroup + '] REMOVE DATABASE [' + @Database + ']'

		EXEC [master].[dbo].[CommandExecute]
		@Command = @Tsql,
		@CommandType = 'AG_REMOVE_DATABASE',
		@DatabaseName = @Database,
		@Mode = 2,
		@LogToTable = @LogToTable,
		@Execute = 'Y'
	END		

	----------------------------------------------------------------------------------------
	-- build restore command
	----------------------------------------------------------------------------------------
	SET @Msg = ' - building restore command'	
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	SET @Tsql = N'RESTORE DATABASE ' + @Database + ' FROM DISK = N''' + @BackupFile + ''' WITH  FILE = 1, NOUNLOAD, REPLACE'

	SELECT @Tsql = @Tsql + 
		CASE 
			WHEN [Type] = 'D' THEN ', MOVE ''' + LogicalName + ''' TO ''' + @InstanceDataPath
			WHEN [Type] = 'L' THEN ', MOVE ''' + LogicalName + ''' TO ''' + @InstanceTlogPath
		END + '\\' + @Database + RIGHT(PhysicalName,4) + ''''
	FROM #FileListTable

	----------------------------------------------------------------------------------------
	-- take database offline and drop it if exist
	----------------------------------------------------------------------------------------
	IF DB_ID(@Database) IS NOT NULL EXECUTE('ALTER DATABASE [' + @Database + '] SET OFFLINE WITH ROLLBACK IMMEDIATE;')
	IF DB_ID(@Database) IS NOT NULL EXECUTE('DROP DATABASE [' + @Database + '];')	
	
	----------------------------------------------------------------------------------------
	-- restore database
	----------------------------------------------------------------------------------------
	SET @Msg = CHAR(13) + CHAR(10) + 'STEP (' + @@SERVERNAME + '): Restoring database'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	EXEC [master].[dbo].[CommandExecute]
	@Command = @Tsql,
	@CommandType = 'RESTORE_DATABASE',
	@DatabaseName = @Database,
	@Mode = 1,
	@LogToTable = @LogToTable,
	@Execute = 'Y'

	INSERT INTO #LogicalFilesTable EXEC('SELECT [name], [type], [file_id], [size] FROM [' + @Database + '].[sys].[database_files]')

	SET @Msg = 'STEP (' + @@SERVERNAME + '): Post configuration'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	----------------------------------------------------------------------------------------
	-- set files autogrowth based on model database if given by parameter
	----------------------------------------------------------------------------------------
	IF @CheckModel = 'Y'
	BEGIN 
		SET @Msg = ' - set autogrowth values based on model database'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		DECLARE @DataFileGrowth INT
		DECLARE @LogFileGrowth INT
		DECLARE @DataFileIsPercentGrowth INT
		DECLARE @LogFileIsPercentGrowth INT

		-- gather model database properties
		SELECT 
			@DataFileGrowth = growth,
			@DataFileIsPercentGrowth = is_percent_growth
		FROM master.sys.master_files mf
		INNER JOIN master.sys.databases db ON mf.database_id = db.database_id
		WHERE db.name = 'model' AND mf.type = 0

		SELECT 
			@LogFileGrowth = growth,
			@LogFileIsPercentGrowth = is_percent_growth
		FROM master.sys.master_files mf
		INNER JOIN master.sys.databases db ON mf.database_id = db.database_id
		WHERE db.name = 'model' AND mf.type = 1

		SET @Tsql = ''
		SELECT @Tsql = @Tsql +
			CASE
				WHEN FileType = 0 AND @DataFileIsPercentGrowth = 0 THEN 'ALTER DATABASE [' + @Database + '] MODIFY FILE ( NAME = N''' + FileName + ''', FILEGROWTH = ' + CAST(@DataFileGrowth * 8 AS VARCHAR) + 'KB );'
				WHEN FileType = 0 AND @DataFileIsPercentGrowth = 1 THEN 'ALTER DATABASE [' + @Database + '] MODIFY FILE ( NAME = N''' + FileName + ''', FILEGROWTH = ' + CAST(@DataFileGrowth AS VARCHAR) + '% );'
				WHEN FileType = 1 AND @LogFileIsPercentGrowth  = 0 THEN 'ALTER DATABASE [' + @Database + '] MODIFY FILE ( NAME = N''' + FileName + ''', FILEGROWTH = ' + CAST(@LogFileGrowth * 8 AS VARCHAR) + 'KB );'
				WHEN FileType = 1 AND @LogFileIsPercentGrowth  = 1 THEN 'ALTER DATABASE [' + @Database + '] MODIFY FILE ( NAME = N''' + FileName + ''', FILEGROWTH = ' +CAST( @LogFileGrowth AS VARCHAR) + '% );'
			END
		FROM #LogicalFilesTable
		EXECUTE(@Tsql)
	END

	----------------------------------------------------------------------------------------
	-- shrink log files
	----------------------------------------------------------------------------------------
	SET @Msg = ' - shrink log file'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	SET @Tsql = 'ALTER DATABASE [' + @Database + '] SET RECOVERY SIMPLE WITH NO_WAIT'
	EXECUTE(@Tsql)

	SET @Tsql = ''
	SELECT @Tsql = @Tsql + 
		CASE
			WHEN (FileSize * 8/1024) > 256 THEN 'USE [' + @Database + ']; DBCC SHRINKFILE (N''' + FileName + ''' , 256);'							-- shrink log file to 256 MB
			WHEN (FileSize * 8/1024) < 256 THEN 'ALTER DATABASE [' + @Database + '] MODIFY FILE ( NAME = N''' + FileName + ''', SIZE = 256MB );'	-- set log file size to 256 MB
		END
	FROM #LogicalFilesTable WHERE FileType = 1
	EXECUTE(@Tsql)

	SET @Tsql = 'ALTER DATABASE [' + @Database + '] SET RECOVERY FULL WITH NO_WAIT'
	EXECUTE(@Tsql)

	----------------------------------------------------------------------------------------
	-- rename logical files
	----------------------------------------------------------------------------------------
	SET @Msg = ' - rename files'	
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	SET @Tsql = 'SET NOCOUNT ON;'

	SELECT @Tsql = @Tsql + 
		'IF NOT EXISTS (SELECT [name] FROM [' + @Database + '].[sys].[database_files] WHERE [name] = ''' +
		@Database  +
		CASE
			WHEN [FileType] = 0 THEN '_Data'
			WHEN [FileType] = 1 THEN '_Log'
		END + 
		CHOOSE(ROW_NUMBER() OVER (PARTITION BY [FileType] ORDER BY [FileId]), '', '_' + CAST(ROW_NUMBER() OVER (PARTITION BY [FileType] ORDER BY [FileId]) AS VARCHAR)) +
		''') ' +
		'ALTER DATABASE ' + @Database + ' MODIFY FILE (NAME=N''' + [FileName] + ''', NEWNAME=N''' + @Database  +
		CASE
			WHEN [FileType] = 0 THEN '_Data'
			WHEN [FileType] = 1 THEN '_Log'
		END + 
		CHOOSE(ROW_NUMBER() OVER (PARTITION BY [FileType] ORDER BY [FileId]), '', '_' + CAST(ROW_NUMBER() OVER (PARTITION BY [FileType] ORDER BY [FileId]) AS VARCHAR)) + 
		''');'
	FROM #LogicalFilesTable
	ORDER BY [FileType]

	EXECUTE(@Tsql)

	-- START Since v1.3
	----------------------------------------------------------------------------------------
	-- preserve users and roles with permissions from original database
	----------------------------------------------------------------------------------------
	IF @PreservePermissions = 'Y'
	BEGIN

		-- This need to be done to give creation scripts right order (important for hierarchy of roles)
		UPDATE #DatabasePrincipals
		SET CreateOrder = dp.CreateOrder - rco.CreateOrder
		FROM #DatabasePrincipals dp
			LEFT JOIN #DatabaseRoleCreateOrder rco ON dp.PrincipalId = rco.RoleId

		-- JUST FOR TESTING
		--SELECT * FROM #DatabaseRoleCreateOrder
		--SELECT * FROM #DatabasePrincipals
		--SELECT * FROM #DatabaseOwnedSchemas
		--SELECT * FROM #DatabaseRoleMembers
		--SELECT * FROM #DatabaseExplicitPermissions
		--SELECT * FROM #DatabaseExtendedProperties

		SET @Msg = ' - creating roles and users with permissions'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		DECLARE @PrincipalId INT
		DECLARE @PrincipalName SYSNAME
		DECLARE @PrincipalType CHAR(1)
		DECLARE @LoginName SYSNAME

		-- Process users one by one
		WHILE EXISTS(SELECT 1 FROM #DatabasePrincipals WHERE Processed = 0)
		BEGIN
			SELECT TOP 1 
				@PrincipalId = PrincipalId,
				@PrincipalName = PrincipalName,
				@PrincipalType = PrincipalType,
				@LoginName = LoginName
			FROM #DatabasePrincipals dp
			WHERE Processed = 0
			ORDER BY CreateOrder DESC

			-- Check prinsipal type first (role/user)
			IF @PrincipalType = 'R'
			BEGIN -- Database role

				-- Temp table for iteration
				IF OBJECT_ID('tempdb..#IterRoleMembers') IS NOT NULL DROP TABLE #IterRoleMembers
				CREATE TABLE #IterRoleMembers (
					[PrincipalName]	SYSNAME,
					[Processed]		BIT DEFAULT 0
				)
				
				SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' 
				SET @Tsql = @Tsql + '
				SELECT 
					[name],
					0 AS Processed
				FROM sys.database_principals 
				WHERE principal_id in (
					SELECT 
						member_principal_id
					FROM sys.database_role_members
					WHERE role_principal_id IN (
						SELECT 
							principal_id
						FROM sys.database_principals 
						WHERE [name] = N''' + @PrincipalName + ''' 
							AND type = ''R''
							AND [name] <> N''public''
					)
				)'
				INSERT INTO #IterRoleMembers EXEC(@Tsql)

				-- Iterate and drop members
				DECLARE @MemberName SYSNAME
				WHILE EXISTS(SELECT 1 FROM #IterRoleMembers WHERE Processed = 0)
				BEGIN
					SELECT TOP 1 
						@MemberName = PrincipalName
					FROM #IterRoleMembers
					WHERE Processed = 0
					ORDER BY PrincipalName ASC

					SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' 
					SET @Tsql = @Tsql + 'ALTER ROLE '+ QUOTENAME(@PrincipalName) +' DROP MEMBER '+ QUOTENAME(@MemberName)
					EXEC(@Tsql)

					-- Mark as processed for next iteration
					UPDATE #IterRoleMembers
					SET Processed = 1
					WHERE PrincipalName = @MemberName

					SET @MemberName = NULL
				END

				-- Cleanup after iteration
				IF OBJECT_ID('tempdb..#IterateRoleMembers') IS NOT NULL DROP TABLE #IterateRoleMembers

				-- Drop role
				SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' 
				SET @Tsql = @Tsql + 'IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @PrincipalName + ''' AND type = ''R'') DROP ROLE '+ QUOTENAME(@PrincipalName)
				EXEC(@Tsql)

				-- Start building T-SQL for role
				SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' + CHAR(13) + CHAR(10)
				SELECT 
					@Tsql = @Tsql + 'CREATE ROLE ' + QUOTENAME(PrincipalName)
					+ CASE 
						WHEN OwnerName IS NOT NULL THEN ' AUTHORIZATION ' + QUOTENAME(OwnerName)
						ELSE ''
					END 
				FROM #DatabasePrincipals
				WHERE PrincipalId = @PrincipalId

			END -- Database role
			ELSE
			BEGIN -- Database user
				
				SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' 
				SET @Tsql = @Tsql + 'IF DATABASE_PRINCIPAL_ID(''' + @PrincipalName + ''') IS NOT NULL DROP USER ' + QUOTENAME(@PrincipalName) + ';' 
				EXEC(@Tsql)				

				IF SUSER_ID(@LoginName) IS NOT NULL OR @LoginName IS NULL 
				BEGIN 
					
					-- Start building T-SQL for user
					SET @Tsql = 'USE ' + QUOTENAME(@Database) + ';' + CHAR(13) + CHAR(10)
					SELECT 
						@Tsql = @Tsql + 'CREATE USER ' + QUOTENAME(PrincipalName)
						+ CASE 
							WHEN @LoginName IS NOT NULL THEN ' FOR LOGIN ' + QUOTENAME(LoginName)
							ELSE ' WITHOUT LOGIN'
						END 
						+ ' WITH DEFAULT_SCHEMA=' + QUOTENAME(DefaultSchema) + ';' + CHAR(13) + CHAR(10)
					FROM #DatabasePrincipals
					WHERE PrincipalId = @PrincipalId
					
				END
			END -- Database user
			
			-- Add owned schemas
			SELECT 
				@Tsql = @Tsql + 'IF DATABASE_PRINCIPAL_ID(''' + PrincipalName + ''') IS NOT NULL AND SCHEMA_ID(''' + SchemaName + ''') IS NOT NULL ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(SchemaName) + ' TO ' + QUOTENAME(PrincipalName) + ';' + CHAR(13) + CHAR(10)
			FROM #DatabaseOwnedSchemas
			WHERE PrincipalId = @PrincipalId

			-- Add database roles membership
			SELECT
				@Tsql = @Tsql + 'IF DATABASE_PRINCIPAL_ID(''' + PrincipalName + ''') IS NOT NULL AND DATABASE_PRINCIPAL_ID(''' + RoleName + ''') IS NOT NULL ALTER ROLE ' + QUOTENAME(RoleName) + ' ADD MEMBER ' + QUOTENAME(PrincipalName) + ';' + CHAR(13) + CHAR(10)
			FROM #DatabaseRoleMembers
			WHERE PrincipalId = @PrincipalId

			-- Add explicit permissions
			SELECT
				@Tsql = @Tsql + 'IF DATABASE_PRINCIPAL_ID(''' + Grantee + ''') IS NOT NULL ' + CommandState + ' ' + Permission + ' ON ' + Securable + ' TO ' + QUOTENAME(Grantee) + ' ' + GrantOption + ' AS ' + QUOTENAME(Grantor) + ';' + CHAR(13) + CHAR(10)
			FROM #DatabaseExplicitPermissions
			WHERE PrincipalId = @PrincipalId

			-- Add extended properties
			SELECT 
				@Tsql = @Tsql + 'IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class_desc = N''DATABASE_PRINCIPAL'' AND major_id = DATABASE_PRINCIPAL_ID(''' + PrincipalName + ''') AND name = N''' + PropertyName + ''' ) '
					+ 'EXEC sys.sp_addextendedproperty '
					+ '@name=N''' + PropertyName + ''', ' 
					+ '@value=N''' + CAST(PropertyValue AS NVARCHAR(MAX)) + ''', '
					+ '@level0type=N''USER'', ' + 
					+ '@level0name=N''' + PrincipalName + '''; '
					+ CHAR(13) + CHAR(10)
			FROM #DatabaseExtendedProperties
			WHERE PrincipalId = @PrincipalId

			-- Execute whole command 
			EXEC [master].[dbo].[CommandExecute]
			@Command = @Tsql,
			@CommandType = 'PRESERVE_PERMISSIONS',
			@DatabaseName = @Database,
			@Mode = 2,
			@LogToTable = @LogToTable,
			@Execute = 'Y'

			-- Mark as processed for next iteration
			UPDATE #DatabasePrincipals
			SET Processed = 1
			WHERE PrincipalId = @PrincipalId

			SET @PrincipalId = NULL
			SET @PrincipalName = NULL
			SET @PrincipalType = NULL
			SET @LoginName = NULL
		END
	END
	-- END Since v1.3

	----------------------------------------------------------------------------------------
	-- set database to multi user mode
	----------------------------------------------------------------------------------------
	SET @Msg = ' - set multi user'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	IF DB_ID(@Database) IS NOT NULL EXEC('ALTER DATABASE [' + @Database + '] SET MULTI_USER')

	----------------------------------------------------------------------------------------
	-- set database to online mode
	----------------------------------------------------------------------------------------
	SET @Msg = ' - set online'
	RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	IF DB_ID(@Database) IS NOT NULL EXEC('ALTER DATABASE [' + @Database + '] SET ONLINE')

	----------------------------------------------------------------------------------------
	-- take full backup and backup of transaction log if database to be included in AG
	----------------------------------------------------------------------------------------
	IF @AvailabilityGroup IS NOT NULL AND @SharedFolder IS NOT NULL 
	BEGIN	
		SET @Msg = CHAR(13) + CHAR(10) + 'STEP (' + @@SERVERNAME + '): Add database ' + @Database + ' to Availability Group ' + @AvailabilityGroup
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;
		
		-- full backup
		SET @Msg = ' - take full backup'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		SET @FullBackupPath = @SharedFolder + '\' + @Database + '_AG_init.bak'
		SET @Tsql = 'BACKUP DATABASE [' + @Database +'] TO  DISK = N''' + @FullBackupPath + ''' WITH  FORMAT, INIT, SKIP, REWIND, NOUNLOAD'

		EXEC [master].[dbo].[CommandExecute]
		@Command = @Tsql,
		@CommandType = 'BACKUP_DATABASE',
		@DatabaseName = @Database,
		@Mode = 2,
		@LogToTable = @LogToTable,
		@Execute = 'Y'

		-- backup of transaction log
		SET @Msg = ' - take backup of transaction log'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		SET @TlogBackupPath = @SharedFolder + '\' + @Database + '_' + FORMAT( GETDATE(), 'yyyyMMddHHmmss') + '.trn'
		SET @Tsql = 'BACKUP LOG [' + @Database +'] TO  DISK = N''' + @TlogBackupPath + ''' WITH NOFORMAT, NOINIT, NOSKIP, REWIND, NOUNLOAD'

		EXEC [master].[dbo].[CommandExecute]
		@Command = @Tsql,
		@CommandType = 'BACKUP_LOG',
		@DatabaseName = @Database,
		@Mode = 2,
		@LogToTable = @LogToTable,
		@Execute = 'Y'
		
	END

	----------------------------------------------------------------------------------------
	-- add database to availability group on primary replica
	----------------------------------------------------------------------------------------
	IF @AvailabilityGroup IS NOT NULL AND @SharedFolder IS NOT NULL 
	BEGIN
		SET @Msg = ' - add on primary replica ' + @@SERVERNAME
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

		SET @Tsql = 'ALTER AVAILABILITY GROUP [' + @AvailabilityGroup + '] ADD DATABASE [' + @Database + '];'

		EXEC [master].[dbo].[CommandExecute]
		@Command = @Tsql,
		@CommandType = 'AG_JOIN_PRIMARY',
		@DatabaseName = @Database,
		@Mode = 2,
		@LogToTable = @LogToTable,
		@Execute = 'Y'
	END

	----------------------------------------------------------------------------------------
	-- add database to availability group on every secondary replica
	----------------------------------------------------------------------------------------
	IF @AvailabilityGroup IS NOT NULL AND @SharedFolder IS NOT NULL 
	BEGIN
		-- gather all secondary replicas
		IF OBJECT_ID('tempdb..#SecondaryReplicas') IS NOT NULL DROP TABLE #SecondaryReplicas
		CREATE TABLE #SecondaryReplicas (
			ReplicaId INT IDENTITY(1,1) PRIMARY KEY,
			ReplicaName NVARCHAR(256),
			Processed BIT DEFAULT 0
		)

		INSERT INTO #SecondaryReplicas(ReplicaName)
		SELECT ar.replica_server_name
		FROM master.sys.dm_hadr_availability_group_states hags
			INNER JOIN master.sys.availability_replicas ar ON ar.group_id = hags.group_id
			INNER JOIN master.sys.availability_groups ag ON ag.group_id = hags.group_id
		WHERE
			ag.name = @AvailabilityGroup
			AND ar.replica_server_name NOT LIKE hags.primary_replica

		-- iterate through secodary replicas
		DECLARE @CurrentReplicaId INT
		DECLARE @CurrentReplicaName NVARCHAR(256)

		WHILE EXISTS(SELECT * FROM #SecondaryReplicas WHERE Processed = 0)
		BEGIN
			SELECT TOP 1 
				@CurrentReplicaId = ReplicaId, 
				@CurrentReplicaName = ReplicaName
			FROM #SecondaryReplicas
			WHERE Processed = 0
			ORDER BY ReplicaId ASC

			--check if linked server to the secondary replica exists and add it if not
			IF NOT EXISTS ( SELECT TOP (1) * FROM master.sys.sysservers WHERE srvname = @CurrentReplicaName AND srvid <> 0 ) 
			BEGIN
				SET @Msg = ' - creating linked server for ' + @CurrentReplicaName + ' replica'
				RAISERROR(@Msg, 0, 1) WITH NOWAIT;

				EXEC master.dbo.sp_addlinkedserver @server = @CurrentReplicaName, @srvproduct=N'SQL Server'

				SET @Msg = ' - enabling RPC for linked server ' + @CurrentReplicaName
					RAISERROR(@Msg, 0, 1) WITH NOWAIT;

				EXEC master.dbo.sp_serveroption @server = @CurrentReplicaName, @optname=N'rpc out', @optvalue=N'true'
			END
			ELSE
			BEGIN
				-- ensure that RPC is enabled for linked server							
				IF NOT EXISTS ( SELECT TOP (1) * FROM master.sys.sysservers WHERE srvname = @CurrentReplicaName AND srvid <> 0 and rpcout = 1) 
				BEGIN
					SET @Msg = ' - enabling RPC Out for linked server ' + @CurrentReplicaName
					RAISERROR(@Msg, 0, 1) WITH NOWAIT;

					EXEC master.dbo.sp_serveroption @server = @CurrentReplicaName, @optname=N'rpc out', @optvalue=N'true'
				END
			END

			SET @Msg = ' - add on secondary replica ' + @CurrentReplicaName
			RAISERROR(@Msg, 0, 1) WITH NOWAIT;

			-- check if add database secondary procedure exists on secondary replica
			DECLARE @i BIT

			SET @Tsql = N'SELECT @Exists = COUNT(*) FROM [' + @CurrentReplicaName + '].[master].[sys].[objects] WHERE type = ''P'' AND name  = ''AddDatabaseOnSecondary'''

			EXEC sp_executesql
				@Tsql,
				N'@Exists INT OUTPUT',
				@i OUTPUT
			
			IF  @i = 0
			BEGIN
				SET @ErrorMessage = 'Stored procedure [master].[dbo].[AddDatabaseOnSecondary] not found on server ' + @CurrentReplicaName + ' or execution account does not have sufficient permissions. Please check procedure and account permissions and rerun or add database to secondary manually. Exitting...'
				GOTO QuitWithRollback
			END
			ELSE
			BEGIN
				-- lets execute procedure then
				SET @Tsql = 'EXEC [' + @CurrentReplicaName + '].[master].[dbo].[AddDatabaseOnSecondary]
				@FullBackupFile = N''' + @FullBackupPath + ''',
				@TlogBackupFile = N''' + @TlogBackupPath + ''',
				@Database = N''' + @Database + ''',
				@AvailabilityGroup = N''' + @AvailabilityGroup + ''',
				@LogToTable = ''Y'''

				EXEC(@Tsql)
			END

			UPDATE #SecondaryReplicas
			SET Processed = 1
			WHERE ReplicaId = @CurrentReplicaId

			SET @CurrentReplicaId = NULL
			SET @CurrentReplicaName = NULL
		END

		SET @Msg = CHAR(13) + CHAR(10) +  'STEP (' + @@SERVERNAME + '): Joining database ' + @Database + ' to all secondary replicas finished '
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;
	END
	
	----------------------------------------------------------------------------------------
	-- finish
	----------------------------------------------------------------------------------------
	GOTO Finish

	----------------------------------------------------------------------------------------
	-- skip restore because HADR is not enabled on instance
	----------------------------------------------------------------------------------------
	HadrNotEnabled:
		SET @ErrorMessage = 'HADR not enabled on instance ' + @@SERVERNAME + ', use normal restore instead of restore to AG. Exitting...'
		GOTO QuitWithRollback

	----------------------------------------------------------------------------------------
	-- skip restore because wrong Availabilit Group name given
	----------------------------------------------------------------------------------------
	UnknownAvailabilityGroup:
		SET @ErrorMessage = 'Availability group ' + @AvailabilityGroup + ' not found! Check input parameters and try again. Exitting...'
		GOTO QuitWithRollback

	----------------------------------------------------------------------------------------
	-- skip restore because this server is not primary replica
	----------------------------------------------------------------------------------------
	NotPrimaryReplica:
		SET @Msg = 'Server ' + @@SERVERNAME + ' is not primary replica of Availability Group ' + @AvailabilityGroup + '! Exitting...'
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;
		GOTO EndOfFile

	----------------------------------------------------------------------------------------
	-- handle error when @SharedFolder parameter not given when adding to Availability Group
	----------------------------------------------------------------------------------------
	SharedFolderNotSpecified:
		SET @ErrorMessage = 'Availability Group ' + @AvailabilityGroup + ' name specified, but parameter @SharedFolder is missing! Shared folder location needed to add database to Availability Group. Exitting...'
		GOTO QuitWithRollback

	----------------------------------------------------------------------------------------
	-- handle error message
	----------------------------------------------------------------------------------------
	QuitWithRollback:
		IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
		RAISERROR(@ErrorMessage, 16, 1) WITH NOWAIT
		GOTO EndOfFile

	----------------------------------------------------------------------------------------
	-- just finishing script
	----------------------------------------------------------------------------------------
	Finish:
		IF @AvailabilityGroup IS NOT NULL
		BEGIN
			SET @Msg = CHAR(13) + CHAR(10) + 'Database ' + @Database + ' sucessfully restored on server ' + @@SERVERNAME + ', and joined Availability Group ' + @AvailabilityGroup	
		END
		ELSE
		BEGIN
			SET @Msg = CHAR(13) + CHAR(10) + 'Database ' + @Database + ' sucessfully restored on server ' + @@SERVERNAME	
		END		
		RAISERROR(@Msg, 0, 1) WITH NOWAIT;

	----------------------------------------------------------------------------------------
	-- put any cleanup stuff here as script will always hit this part
	----------------------------------------------------------------------------------------
	EndOfFile:
		IF OBJECT_ID('tempdb..#FileListTable') IS NOT NULL DROP TABLE #FileListTable
		IF OBJECT_ID('tempdb..#LogicalFilesTable') IS NOT NULL DROP TABLE #LogicalFilesTable
		IF OBJECT_ID('tempdb..#SecondaryReplicas') IS NOT NULL DROP TABLE #SecondaryReplicas	
		-- START Since v1.3
		IF OBJECT_ID('tempdb..#DatabaseRoleCreateOrder') IS NOT NULL DROP TABLE #DatabaseRoleCreateOrder
		IF OBJECT_ID('tempdb..#DatabasePrincipals') IS NOT NULL DROP TABLE #DatabasePrincipals	
		IF OBJECT_ID('tempdb..#DatabaseOwnedSchemas') IS NOT NULL DROP TABLE #DatabaseOwnedSchemas	
		IF OBJECT_ID('tempdb..#DatabaseRoleMembers') IS NOT NULL DROP TABLE #DatabaseRoleMembers
		IF OBJECT_ID('tempdb..#DatabaseExplicitPermissions') IS NOT NULL DROP TABLE #DatabaseExplicitPermissions	
		IF OBJECT_ID('tempdb..#DatabaseExtendedProperties') IS NOT NULL DROP TABLE #DatabaseExtendedProperties	
		-- END Since v1.3		
END