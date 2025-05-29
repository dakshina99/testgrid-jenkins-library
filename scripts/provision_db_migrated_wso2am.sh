#!/bin/bash
# -------------------------------------------------------------------------------------
# Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org) All Rights Reserved.
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# --------------------------------------------------------------------------------------
set -e

# Database and WSO2 Product Configs
DB_ENGIN='&CF_DB_NAME'
DB_ENGINE_VERSION='&CF_DB_VERSION'
WSO2_PRODUCT_VERSION='&PRODUCT_VERSION'

# Logging function
log_info() {
  echo "[INFO][$(date '+%Y-%m-%d %H:%M:%S')]: $1"
}

if [[ $DB_ENGIN = "mysql" ]]; then
    log_info "Mysql DB is selected. Running Oracle scripts for APIM version ${WSO2_PRODUCT_VERSION}"
    # create databases
    log_info "[Mysql] Droping Databases if exist"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "DROP DATABASE IF EXISTS WSO2AM_COMMON_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "DROP DATABASE IF EXISTS WSO2AM_APIMGT_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "DROP DATABASE IF EXISTS WSO2AM_STAT_DB"

    log_info "[Mysql] Creating Databases"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "CREATE DATABASE WSO2AM_COMMON_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "CREATE DATABASE WSO2AM_APIMGT_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -e "CREATE DATABASE WSO2AM_STAT_DB"

    cat <<'EOF' > reg.sql

DELIMITER $$

DROP PROCEDURE IF EXISTS create_index_if_not_exists $$
CREATE PROCEDURE create_index_if_not_exists(
	in theTable varchar(128),
    in theIndexName varchar(128),
    in column_1 varchar(128),
    in column_2 varchar(128))
BEGIN
 IF((SELECT COUNT(*) AS index_exists
		FROM information_schema.statistics
        WHERE TABLE_SCHEMA = DATABASE()
        AND table_name = theTable
        AND index_name = theIndexName) = 0) THEN
   SET @s = CONCAT('CREATE INDEX `' , theIndexName , '` ON `' , theTable, '` (`', column_1, '`, `', column_2, '`)');
   PREPARE stmt FROM @s;
   EXECUTE stmt;
 END IF;
END $$

DELIMITER ;

CALL create_index_if_not_exists("REG_RESOURCE_TAG", "REG_RESOURCE_TAG_IND_BY_REG_TAG_ID", "REG_TAG_ID", "REG_TENANT_ID");
CALL create_index_if_not_exists("REG_RESOURCE_PROPERTY", "REG_RESOURCE_PROPERTY_IND_BY_REG_PROP_ID", "REG_TENANT_ID", "REG_PROPERTY_ID");

DROP PROCEDURE IF EXISTS create_index_if_not_exists;
EOF


    sudo mkdir -p /tmp/mysql/
    aws s3 cp s3://integration-testgrid-resources/apim-migration-dumps/320/mysql/ /tmp/mysql/ --recursive
    find /tmp/mysql/ -type f -exec chmod 644 {} \;

    log_info "[Mysql] Povisioning WSO2AM_APIMGT_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -D WSO2AM_APIMGT_DB <  /tmp/mysql/apim_db_dump_mysql_320.sql
    log_info "[Mysql] Povisioning WSO2AM_COMMON_DB"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -D WSO2AM_COMMON_DB <  /tmp/mysql/shared_db_dump_mysql_320.sql
    log_info "[Mysql] run reg.sql"
    mysql -u &CF_DB_USERNAME -p&CF_DB_PASSWORD -h &CF_DB_HOST -P &CF_DB_PORT -D WSO2AM_COMMON_DB < reg.sql

    log_info "Setup completed for Mysql DB migration."

elif [[ "${DB_ENGIN}" =~ "oracle-se" ]]; then
  export ORACLE_HOME=/usr/lib/oracle/19.27/client64/
  export PATH=$PATH:/usr/lib/oracle/19.27/client64/bin/
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$ORACLE_HOME/lib:$ORACLE_HOME

  log_info "Oracle DB is selected. Running Oracle scripts for APIM version ${WSO2_PRODUCT_VERSION}"

  echo "DECLARE USER_EXIST INTEGER;"$'\n'"BEGIN SELECT COUNT(*) INTO USER_EXIST FROM dba_users WHERE username='WSO2AM_APIMGT_DB';"$'\n'"IF (USER_EXIST > 0) THEN EXECUTE IMMEDIATE 'DROP USER WSO2AM_APIMGT_DB CASCADE';"$'\n'"END IF;"$'\n'"END;"$'\n'"/" > apim_oracle_user.sql
  echo "DECLARE USER_EXIST INTEGER;"$'\n'"BEGIN SELECT COUNT(*) INTO USER_EXIST FROM dba_users WHERE username='WSO2AM_COMMON_DB';"$'\n'"IF (USER_EXIST > 0) THEN EXECUTE IMMEDIATE 'DROP USER WSO2AM_COMMON_DB CASCADE';"$'\n'"END IF;"$'\n'"END;"$'\n'"/" >> apim_oracle_user.sql
  echo "DECLARE USER_EXIST INTEGER;"$'\n'"BEGIN SELECT COUNT(*) INTO USER_EXIST FROM dba_users WHERE username='WSO2AM_STAT_DB';"$'\n'"IF (USER_EXIST > 0) THEN EXECUTE IMMEDIATE 'DROP USER WSO2AM_STAT_DB CASCADE';"$'\n'"END IF;"$'\n'"END;"$'\n'"/" >> apim_oracle_user.sql
  echo "ALTER SYSTEM SET open_cursors = 3000 SCOPE=BOTH;">> apim_oracle_user.sql

  # Generate Oracle User Creation SQL
  cat <<EOF > apim_oracle_user.sql

-- Create and grant privileges
CREATE USER WSO2AM_COMMON_DB IDENTIFIED BY &CF_DB_PASSWORD QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, DBA TO WSO2AM_COMMON_DB;
GRANT UNLIMITED TABLESPACE TO WSO2AM_COMMON_DB;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO WSO2AM_COMMON_DB;
GRANT DATAPUMP_EXP_FULL_DATABASE TO WSO2AM_COMMON_DB;

CREATE USER WSO2AM_APIMGT_DB IDENTIFIED BY &CF_DB_PASSWORD QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, DBA TO WSO2AM_APIMGT_DB;
GRANT UNLIMITED TABLESPACE TO WSO2AM_APIMGT_DB;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO WSO2AM_APIMGT_DB;
GRANT DATAPUMP_EXP_FULL_DATABASE TO WSO2AM_APIMGT_DB;

CREATE USER WSO2AM_STAT_DB IDENTIFIED BY &CF_DB_PASSWORD QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, DBA TO WSO2AM_STAT_DB;
GRANT UNLIMITED TABLESPACE TO WSO2AM_STAT_DB;
EOF

  # Create Users
  log_info "Creating Oracle users..."
  sudo mkdir -p /tmp/datapump/
  aws s3 cp s3://integration-testgrid-resources/apim-migration-dumps/320/oracle/ /tmp/datapump/ --recursive
  find /tmp/datapump/ -type f -exec chmod 644 {} \;

  echo exit | sqlplus64 "&CF_DB_USERNAME/&CF_DB_PASSWORD@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(Host=&CF_DB_HOST)(Port=&CF_DB_PORT))(CONNECT_DATA=(SID=WSO2AMDB)))" @apim_oracle_user.sql

  # Import Dumps
  log_info "Importing Oracle DB dumps..."
  cd /tmp/datapump/
  echo exit | impdp "WSO2AM_APIMGT_DB/&CF_DB_PASSWORD@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=&CF_DB_HOST)(PORT=&CF_DB_PORT))(CONNECT_DATA=(SID=WSO2AMDB)))" DIRECTORY=DATA_PUMP_DIR DUMPFILE=apim_db18.dmp LOGFILE=apim_db18_imp.log REMAP_SCHEMA=APIM_DB:WSO2AM_APIMGT_DB
  echo exit | impdp "WSO2AM_COMMON_DB/&CF_DB_PASSWORD@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=&CF_DB_HOST)(PORT=&CF_DB_PORT))(CONNECT_DATA=(SID=WSO2AMDB)))" DIRECTORY=DATA_PUMP_DIR DUMPFILE=shared_db18.dmp LOGFILE=common_db18_imp.log REMAP_SCHEMA=SHARED_DB:WSO2AM_COMMON_DB
fi

