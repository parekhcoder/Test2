#!/bin/bash

CRON_SCHEDULE=${CRON_SCHEDULE:-"5 9 * * *"}

echo "Using CRON_SCHEDULE: ${CRON_SCHEDULE}"

# Remove existing crontab to avoid duplicates if container restarts
crontab -r 2>/dev/null || true

# Add the cron job
#(crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} /app/backup.sh > /dev/null 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} /app/backup.sh >> /var/log/cron.log 2>&1") | crontab -


echo "Crontab setup complete. Starting cron daemon."

#echo "Attempting to start rsyslogd..."
#rsyslogd -n & 
#RSYSLOG_PID=$!
#echo "rsyslogd started with PID: $RSYSLOG_PID"

#sleep 2

# Start cron in the foreground
#echo "Starting cron daemon in foreground..."
exec cron -f -d SCH,PROC,EXT

#echo "Error: Failed to start cron."
#kill $RSYSLOG_PID 
#exit 1
