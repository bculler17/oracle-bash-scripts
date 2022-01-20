create table ORACLE_DATAFILES (
  DB_NAME VARCHAR2(30),
  TS_NAME VARCHAR2(30),
  DF_NAME VARCHAR2(257),
  CREATION_DATE DATE
);
-- WHERE db_name = the name of the database that contains this datafile
-- ts_name = the name of the tablespace that was allocated this datafile
-- df_name = the name of the datafile
-- creation_date = the date that the datafile was allocated to the tablespace 
