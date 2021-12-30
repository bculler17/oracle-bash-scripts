# Oracle_Bash_Scripts
Collection of bash scripts used for database maintenance and monitoring  

These are various bash scripts I have written to help me monitor and maintain Oracle 11g, 12c, and 19c databases on AIX and Linux systems.

1. [tablespace_growth_trender.sh](/scripts/tablespace_growth_trender.sh) : This remotely checks the size of every tablespace and the creation date of every datafile in multiple databases and records the data in a database table to trend tablespace growth over time. 
