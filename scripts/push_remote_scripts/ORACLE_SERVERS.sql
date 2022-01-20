create table ORACLE_SERVERS (
  	ID NUMBER,
  	HOSTNAME VARCHAR2(35) not null unique,
  	IPADDRESS VARCHAR2(15) not null unique,
  	OS_VERSION VARCHAR2(100),
  	UP_TIME VARCHAR2(35),
  	FUNCTION VARCHAR2(25) CHECK (function='PROD' OR function='DEV/TEST'),
  	STATUS VARCHAR2(10) not null CHECK (status='ACTIVE' OR status='INACTIVE' OR status='TEST'),
  	ONLINE_STATUS VARCHAR2(10),
  	ALERT_STATUS VARCHAR2(10) CHECK (alert_status='YES' OR alert_status='NO'),
  	RECORD_CREATED DATE default SYSDATE,
	RECORD_CREATOR VARCHAR2(25) not null,
	RECORD_UPDATED DATE,
	RECORD_UPDATED_BY VARCHAR2(1000),
  	constraint oracle_servers_PK PRIMARY KEY(id)
);
-- WHERE os_version =  will be autopopulated by my it_reaches_out.sh script (the current version of the operating system used by the database server)
-- up_time = will be autopopulated by my it_reaches_out.sh script (the number of days the server has been online)
-- function = determine if the server hosts a production database environment ('PROD') or a non-prod database environment ('DEV/TEST')
-- status = determines if the server is still in use ('ACTIVE'), has been decommissioned ('INACTIVE'), or if it is a test environment ('TEST')
-- online_status = will be autopopulated by my it_reaches_out.sh script ('YES' = the server is online, 'NO' = the server is not online)
-- alert_status = determines if my it_reaches_out.sh script will email alerts if the server is offline ('YES' = emails will be sent, 'NO' = you will not be alerted/emailed if the server is down)
-- record_created = the date the record was first added
-- record_creator = the name of the DBA that created the record
-- record_updated = the date the record was updated
-- record_updated_by = the name of the DBA or script that updated the record 
