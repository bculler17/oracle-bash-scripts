create table ORACLE_DATABASES(
  APPLICATION_NAME VARCHAR2(150),
	ID NUMBER, 
	NAME VARCHAR2(10) not null,
	DBTYPE VARCHAR2(35),
  VERSION VARCHAR2(50),
  CURRENT_SIZE VARCHAR2(1000),
  TOTAL_DB_FILES NUMBER,
  MAX_DB_FILES NUMBER,
	NODE1 VARCHAR2(35) not null,
	NODE2 VARCHAR2(35) not null default 'N/A',
  UP_TIME1 VARCHAR2(35);
  UP_TIME2 VARCHAR2(35);
  STATUS VARCHAR2(10) not null CHECK (status='ACTIVE' OR status='INACTIVE' OR status='TEST'),
  ONLINE_STATUS VARCHAR2(10),
  ALERT_STATUS VARCHAR2(10) CHECK (alert_status='YES' OR alert_status='NO'),
	RECORD_CREATED DATE default SYSDATE,
	RECORD_CREATOR VARCHAR2(25) not null,
	RECORD_UPDATED DATE,
	RECORD_UPDATED_BY VARCHAR2(1000),
	constraint oracle_databases_PK PRIMARY KEY(id),
	constraint oracle_databases_FK1 FOREIGN KEY(node1) REFERENCES oracle_servers(hostname),
	constraint oracle_databases_FK2 FOREIGN KEY(node2) REFERENCES oracle_servers(hostname)
);
-- WHERE application_name = the name of the application that this database supports
-- name = the name of the database
-- dbtype = will be autopopulated by my it_reaches_out.sh script ('RAC' or 'standalone')
-- version = will be autopopulated by my it_reaches_out.sh script
-- current_size = will be autopopulated by my it_reaches_out.sh script
-- total_db_files = will be autopopulated by my it_reaches_out.sh script (the number of datafiles currently being used by the database)
-- max_db_files = will be autopopulated by my it_reaches_out.sh script (the maximum number of datafiles the database is configured to use. The database will not be able to expand anymore once this parameter is reached. total_db_files will show us how close we are to reaching max_db_files)
-- node1 = the hostname of the database server that the first database instance resides on
-- node2 = the hostname of the database server that the second database instance resides on
-- up_time1 = will be autopopulated by my it_reaches_out.sh script (the uptime of the first database server - node1)
-- up_time2 = will be autopopulated by my it_reaches_out.sh script (the uptime of the second database server - node2)
-- status = determines if the database is still in use ('ACTIVE'), has been decommissioned ('INACTIVE'), or if it is a test environment ('TEST')
-- online_status = will be autopopulated by my it_reaches_out.sh script ('YES' = the database is online, 'NO' = the database is not online)
-- alert_status = determines if my it_reaches_out.sh script will email alerts if the database is offline ('YES' = emails will be sent, 'NO' = you will not be alerted/emailed if the database is down)
-- record_created = the date the record was first added
-- record_creator = the name of the DBA that created the record
-- record_updated = the date the record was updated
-- record_updated_by = the name of the DBA or script that updated the record 
