create table ORACLE_DB_WORKLOAD_TREND (
  EVENT_DATE DATE,
  DB_NAME VARCHAR2(50),
  INST_ID NUMBER,
  AVG_HOURLY_TOT_USER CALLS VARCHAR2(50),
  AVG_HOURLY_DML_TX VARCHAR2(50),
  AVG_HOURLY_READONLY VARCHAR2(50)
  );
  -- WHERE EVENT_DATE = when the data was recorded
  -- DB_NAME = the name of the database being monitored
  -- INST_ID = the database instance being monitored
  -- AVG_HOURLY_TOT_USER CALLS = the average number of both DML and select statements executed each hour since startup time
  -- AVG_HOURLY_DML_TX = the average number of 'User Commits' and 'User Rollbacks' executed each hour since startup time
  -- AVG_HOURLY_READONLY = the average number of select statements executed each hour since startup time
