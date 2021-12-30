#!/bin/bash
#
# To execute this script, three database tables will need to already exist in an Oracle database: oracle_databases, oracle_tablespaces, and oracle_datafiles
# oracle_databases records all of the databases needing to be managed and monitored
#
# Goal 1 of this script: The size of every tablespace in each database recorded in the oracle_databases table will be automatically checked twice a day by scheduling this script in crontab 
# The data collected will be recorded in the oracle_tablespaces table 
# Purpose: To trend tablespace growth over time   
#
# Goal 2 of this script: The creation dates of each datafile in every database recorded in the oracle_databases table will be recorded in the oracle_datafiles table 
# Purpose: To display this data on a dashboard for an additional visual of how the tablespaces have grown over time 
#
# Author: Beth Culler
# ---------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
SYSID=`uname -a |awk '{print $2}'`
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export HOST_NAME=`uname -a |awk '{print $2}'`
export ORACLE_HOME=<ENTER_YOUR_HOME>
export ORACLE_SID=<ENTER_YOUR_SID>
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/lib32:$PATH:
export ORA_NLS11=$ORACLE_HOME/nls/data
export SQLUSER="<username/password>"
# Build list of databases to monitor
SQL_OUT=`sqlplus -S /nolog<<EOF
         connect $SQLUSER
         set feedback off
         set echo off
         set pages 0
         set lines 1000
         col node1 format a25
         col node2 format a25
         spool /tmp/oracle_dblist_tbspchk.txt
         select distinct name from oracle_databases where status='ACTIVE' order by  1;
         spool off;
         exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export DBLIST=/tmp/oracle_dblist_tbspchk.txt
export TEST=`grep 'ORA-' $DBLIST`
case $TEST in
        *ORA-*)
                # An ORA- error occurred.
                rm -f $DBLIST
esac
if [ -f $DBLIST ]; then
	cat $DBLIST | sed 's/^[ \t]*//;s/[ \t]*$//' | while read DB; do
		DBNAME=`echo $DB | awk '{print $1}'`
		if [ $DBNAME == '<db-name>' ]; then
                	RMSQLUSER="<username/password>@<TNSNAMES_ID>"
    		else
                	RMSQLUSER="<username/password>@${DBNAME}_TNSNAMES_ID"
    		fi
   		SQL_OUT=`sqlplus -S /nolog<<EOF
             		connect $RMSQLUSER
             		set feedback off
             		set echo off
             		set pages 0
             		set lines 1000
             		spool /tmp/oracle_datafile_list.txt
             		select TO_CHAR(df.creation_time, 'DD-MON-YYYY,HH24:MI:SS'), ts.name ts_name, df.name df_name from v\\$datafile df, v\\$tablespace ts where df.ts#=ts.ts# union select TO_CHAR(tmp.creation_time, 'DD-MON-YYYY,HH24:MI:SS'), ts.name ts_name, tmp.name df_name from v\\$tempfile tmp, v\\$tablespace ts where tmp.ts#=ts.ts# order by 2,1,3;
             		spool off;
             		exit;
EOF
`
   		if [ -f /tmp/oracle_datafile_list.txt ]; then
                	cat /tmp/oracle_datafile_list.txt | while read DBDF; do
		        	TS_NAME=`echo $DBDF | awk '{print $2}'`
                          	DF_NAME=`echo $DBDF | awk '{print $3}'| xargs`
                          	CR8TION=`echo $DBDF | awk '{print $1}'| sed 's/,/ /g'`
                          	SQL_OUT=`sqlplus -S /nolog<<EOF
                                  	connect $SQLUSER
                                  	delete from oracle_datafiles where DB_NAME='$DBNAME' and DF_NAME='$DF_NAME';
                                  	insert into oracle_datafiles VALUES ('$DBNAME', '$TS_NAME', '$DF_NAME', TO_DATE('$CR8TION', 'DD-MON-YYYY HH24:MI:SS'));
                                  	commit;
                                  	exit;
EOF
`
                	done
                fi
                SQL_OUT=`sqlplus -S /nolog<<EOF
                	connect $RMSQLUSER
                        set feedback off
                        set echo off
                        set pages 0
                        set lines 1000
                        spool /tmp/oracle_tbsp_list.txt
                        SELECT df.tablespace_name tablespace_name,round(df.maxbytes / (1024 * 1024 *1024), 2) max_ts_size,round((df.bytes - sum(fs.bytes)) / (df.maxbytes) * 100, 2) max_ts_pct_used, round((df.bytes - sum(fs.bytes)) / (1024 * 1024 * 1024), 2) used_ts_size FROM dba_free_space fs, (select tablespace_name, sum(bytes) bytes, sum(decode(maxbytes, 0, bytes, maxbytes)) maxbytes from dba_data_files group by tablespace_name) df WHERE fs.tablespace_name (+) = df.tablespace_name GROUP BY df.tablespace_name, df.bytes, df.maxbytes UNION ALL SELECT df.tablespace_name tablespace_name, round(df.maxbytes / (1024 * 1024 * 1024), 2) max_ts_size,round((df.bytes - sum(fs.bytes)) / (df.maxbytes) * 100, 2) max_ts_pct_used, round((df.bytes - sum(fs.bytes)) / (1024 * 1024 * 1024), 2) used_ts_size FROM (select tablespace_name, bytes_used bytes from V\\$temp_space_header group by tablespace_name, bytes_free, bytes_used) fs,(select tablespace_name, sum(bytes) bytes, sum(decode(maxbytes, 0, bytes, maxbytes)) maxbytes from dba_temp_files group by tablespace_name) df WHERE fs.tablespace_name (+) = df.tablespace_name GROUP BY df.tablespace_name, df.bytes, df.maxbytes ORDER BY 3 DESC;
                        spool off;
                        exit;
EOF
`
                if [ -f /tmp/oracle_tbsp_list.txt ]; then
                        cat /tmp/oracle_tbsp_list.txt | while read TBSP; do
                        	TBNAME=`echo $TBSP | awk '{print $1}'`
                                TOTSIZE=`echo $TBSP | awk '{print $2}'`
                                USEDSIZE=`echo $TBSP | awk '{print $4}'`
                                PERCUSED=`echo $TBSP | awk '{print $3}'`
                                SQL_OUT=`sqlplus -S /nolog<<EOF
                                        connect $SQLUSER
                                        insert into oracle_tablespaces VALUES (sysdate, '$DBNAME', '$TBNAME', '$TOTSIZE', '$USEDSIZE', '$PERCUSED');
                                        commit;
                                        exit;
EOF
`
                        done
                fi
	done	
  SQL_OUT=`sqlplus -S /nolog<<EOF
          connect $SQLUSER
          delete oracle_tablespaces where trunc(event_date)<trunc(sysdate-548);
          commit;
          exit;
EOF
`
  rm -f /tmp/oracle_tbsp_list.txt
  rm -f /tmp/oracle_dblist_tbspchk.txt 
  rm -f /tmp/oracle_datafile_list.txt
fi
#set +x
exit
