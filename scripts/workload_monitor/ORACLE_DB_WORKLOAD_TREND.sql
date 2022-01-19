create table ORACLE_DB_WORKLOAD_TREND (
  EVENT_DATE DATE,
  DB_NAME VARCHAR2(50),
  INST_ID NUMBER,
  AVG_HOURLY_TOT_USER CALLS VARCHAR2(50),
  AVG_HOURLY_DML_TX VARCHAR2(50),
  AVG_HOURLY_READONLY VARCHAR2(50)
  );
  -- where AVG_HOURLY_TOT_USER CALLS = the average number of both DML and select statements executed each hour
  -- AVG_HOURLY_DML_TX = the average number of only DML statements executed each hour (insert, update, deletes)
  -- AVG_HOURLY_READONLY = the average number of select statements executed each hour 
