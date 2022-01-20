create table ORACLE_TABLESPACES (
  EVENT_DATE DATE,
  DATABASE_NAME VARCHAR2(10) not null,
  TABLESPACE_NAME VARCHAR2(100) not null,
  TOTAL_ALLOCATED_SIZE NUMBER,
  TOTAL_USED_SIZE NUMBER,
  PERCENT_USED NUMBER,
  RECORD_UPDATED_BY VARCHAR2(1000)
);
-- WHERE event_date = the date that the tablespace was this size
-- database_name = the name of the database where the tablespace resides
-- total_allocated_size = the max bytes of all of the datafiles allocated to the tablespace
-- total_used_size = the total number of bytes that the tablespace is consuming 
-- percent_used = the percentage of how much space the tablespace is consuming out of what has been allocated to it. Once this reaches 100%, the tablespace will no longer be able to expand and will need to be given an additional datafile. 
-- record_updated_by = the name of the DBA or script that updated the record (this table was created to be regularly autopopulated by the tablespace_growth_trender.sh script). 
