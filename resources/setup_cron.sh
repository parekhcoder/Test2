#!/bin/bash

CRON_SCHEDULE=${CRON_SCHEDULE:-"5 9 * * *"}

echo "Using CRON_SCHEDULE: ${CRON_SCHEDULE}"

# Remove existing crontab to avoid duplicates if container restarts
crontab -r 2>/dev/null || true

# Add the cron job
#(crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} /app/backup.sh > /dev/null 2>&1") | crontab -
#(crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} /app/backup.sh >> /var/log/cron.log 2>&1") | crontab -
CRONTAB_CONTENT="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/go/bin:/app/google-cloud-sdk/bin
OPWD_TOKEN=\"${OPWD_TOKEN}\"
OPWD_URL=\"${OPWD_URL}\"
OPWD_VAULT=\"${OPWD_VAULT}\"
CLOUD_UPLOAD=\"${CLOUD_UPLOAD}\"
LOCAL_UPLOAD=\"${LOCAL_UPLOAD}\"
OPWD_CLOUD_KEY=\"${OPWD_CLOUD_KEY}\"
OPWD_LOCAL_KEY=\"${OPWD_LOCAL_KEY}\"
OPWD_MYSQL_KEY=\"${OPWD_MYSQL_KEY}\"
AGE_PUBLIC_KEY=\"${AGE_PUBLIC_KEY}\"
TARGET_ALL_DATABASES=\"${TARGET_ALL_DATABASES}\"
TARGET_DATABASE_NAMES=\"${TARGET_DATABASE_NAMES}\"
BACKUP_CREATE_DATABASE_STATEMENT=\"${BACKUP_CREATE_DATABASE_STATEMENT}\"
BACKUP_ADDITIONAL_PARAMS=\"${BACKUP_ADDITIONAL_PARAMS}\"
BACKUP_TIMESTAMP=\"${BACKUP_TIMESTAMP}\"
BACKUP_COMPRESS=\"${BACKUP_COMPRESS}\"
AGE_ENCRYPT=\"${AGE_ENCRYPT}\"
TENANT=\"${TENANT}\"
POD_NAME=\"${POD_NAME}\"
NODE_NAME=\"${NODE_NAME}\"
APP_NAME=\"${APP_NAME}\"
LOG_DIR=\"${LOG_DIR}\"
SCRIPT_POST_RUN_SLEEP_SECONDS=\"${SCRIPT_POST_RUN_SLEEP_SECONDS}\"
AWS_CA_BUNDLE=\"${AWS_CA_BUNDLE}\"
LOCAL_S3_SIGNATURE_VERSION=\"${LOCAL_S3_SIGNATURE_VERSION}\"

${CRON_SCHEDULE} /app/backup.sh > /dev/null 2>&1"

echo "${CRONTAB_CONTENT}" | crontab -

crontab -l
echo "Crontab setup complete. Starting cron daemon."

#echo "Attempting to start rsyslogd..."
#rsyslogd -n & 
#RSYSLOG_PID=$!
#echo "rsyslogd started with PID: $RSYSLOG_PID"

#sleep 2

# Start cron in the foreground
#echo "Starting cron daemon in foreground..."
exec cron -f 

#echo "Error: Failed to start cron."
#kill $RSYSLOG_PID 
#exit 1
