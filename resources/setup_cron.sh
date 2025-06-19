#!/bin/bash

CRON_SCHEDULE=${CRON_SCHEDULE:-"5 9 * * *"}

echo "Using CRON_SCHEDULE: ${CRON_SCHEDULE}"

# Remove existing crontab to avoid duplicates if container restarts
crontab -r 2>/dev/null || true

# Add the cron job
(crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} /app/backup.sh > /dev/null 2>&1") | crontab -

echo "Crontab setup complete. Starting cron daemon."

# Start cron in the foreground
exec cron -f
