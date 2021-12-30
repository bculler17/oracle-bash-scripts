# Oracle_Bash_Scripts
Collection of bash scripts used for database maintenance and monitoring  

These are various bash scripts I have written to help me monitor and maintain Oracle 11g, 12c, and 19c databases on AIX and Linux systems.

1. [tablespace_growth_trender.sh](/scripts/tablespace_growth_trender.sh) : This remotely checks the size of every tablespace and the creation date of every datafile in multiple databases and records the data in a database table to trend tablespace growth over time. 

2. [alert log monitor](/scripts/alert_log_monitor/) : The alert_log_monitor.sh script will scan the db alert log of 11g+ Oracle databases for ORA- errors and instance terminations / restarts, sleep 5 minutes, then scan again. An email will be sent to alert the DBA's if anything is found within the past 5 minutes. The alert_log_CRON_mgr.sh script is scheduled in crontab to verify that the alert_log_monitor.sh is running and restart it if it is not. An email will be sent to alert the DBA's if alert_log_monitor.sh was abnormally terminated. 

3. [11g_BATCH_audit_maintenance.sh](/scripts/11g_BATCH_audit_maintenance.sh) : If the AUD$ table has grown very large, this script will archive and purge records in small batches to reduce execution time and to not overwhelm resources. It first purges everything older than 18 months from AUD$ in small batches. It then archives and purges audit records from aud$ that are older than 45 days in small batches. An archive table will need to first be created before this script can successfully execute. After execution, AUD$ records older than 45 days will have been archived, and records older than 18 months will have been deleted.  
