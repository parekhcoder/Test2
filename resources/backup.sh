#!/bin/bash

set -uo pipefail
IFS=$'\n\t'

# Check required tools
for tool in jq aws mysql mysqldump gzip age curl sleep tee; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool is not installed." >&2
        exit 1
    fi
done

# Define default log directory early
LOG_DIR_PATH="${LOG_DIR:-/app/log}"

# Logging function
function LogMsg() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level="$1"
    local message="$2"
    local jsonLog

    local APP_NAME="${App_Name:-unknown}"
    local NODE_NAME_VAR="${NODE_NAME:-unknown}"
    local POD_NAME_VAR="${POD_NAME:-unknown}"

    jsonLog=$(jq -n \
        --arg t "$timestamp" \
        --arg a "$APP_NAME" \
        --arg l "$level" \
        --arg m "$message" \
        --arg n "$NODE_NAME_VAR" \
        --arg p "$POD_NAME_VAR" \
        '{"@timestamp": $t, "appname": $a, "level": $l, "message": $m, "nodename": $n, "podname": $p }')

    exec 3>&1 # Save stdout to fd 3

    if [[ -z "${logFile:-}" || ! -w "$LOG_DIR_PATH" ]]; then
        echo "$jsonLog" >&2
    else
        echo "$jsonLog" | tee -a "$logFile" >&3
    fi

    exec 3>&- # Close fd 3
}

# Trap for cleanup
function cleanup_tmp {
    echo "DEBUG: Running cleanup trap." >&2
    rm -f /tmp/backup_*.sql /tmp/backup_*.gz /tmp/backup_*.age 2>/dev/null || true
    echo "DEBUG: Cleanup trap finished." >&2
}
trap cleanup_tmp EXIT


# Get secrets from vault and set S3 profiles
function GetVaultItemsNSetS3Profiles() {
    LogMsg "Debug" "Starting GetVaultItemsNSetS3Profiles function."
    local vaults http_code vaultUUID vaultItems cloudS3UUID localS3UUID mysqlUUID agePublicKeyUUID

    vaults=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vaults")
    vaults=$(sed '$ d' <<< "$vaults")
    if [[ "$http_code" != "200" ]]; then
        LogMsg "Error" "Get Vault: $http_code"
        return 1
    fi
    LogMsg "Debug" "Got Vault list successfully."

    vaultUUID=$(jq -r '.[] | select(.name=="'"$OPWD_VAULT"'") | .id' <<< "$vaults")
    if [[ -z "$vaultUUID" ]]; then
        LogMsg "Error" "Vault UUID not found for vault name: $OPWD_VAULT"
        return 1
    fi
    LogMsg "Debug" "Found vault UUID: $vaultUUID"

    vaultItems=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vaultUUID/items" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vaultItems")
    vaultItems=$(sed '$ d' <<< "$vaultItems")
    if [[ "$http_code" != "200" ]]; then
        LogMsg "Error" "Get Vault Items: $http_code"
        return 1
    fi
    LogMsg "Debug" "Got Vault Items list successfully."

    cloudS3UUID=$(jq -r '.[] | select(.title=="'"${OPWD_CLOUD_KEY:-}"'") | .id' <<< "$vaultItems")
    localS3UUID=$(jq -r '.[] | select(.title=="'"${OPWD_LOCAL_KEY:-}"'") | .id' <<< "$vaultItems")
    mysqlUUID=$(jq -r '.[] | select(.title=="'"${OPWD_MYSQL_KEY:-}"'") | .id' <<< "$vaultItems")
    agePublicKeyUUID=$(jq -r '.[] | select(.title=="'"${AGE_PUBLIC_KEY:-}"'") | .id' <<< "$vaultItems")

    if [[ "${CLOUD_UPLOAD:-false}" == "true" && -z "$cloudS3UUID" ]]; then LogMsg "Error" "Cloud S3 Key '${OPWD_CLOUD_KEY:-}' not found in vault items."; return 1; fi
    if [[ "${LOCAL_UPLOAD:-false}" == "true" && -z "$localS3UUID" ]]; then LogMsg "Error" "Local S3 Key '${OPWD_LOCAL_KEY:-}' not found in vault items."; return 1; }
    if [[ -z "$mysqlUUID" ]]; then LogMsg "Error" "MySQL Key '${OPWD_MYSQL_KEY:-}' not found in vault items."; return 1; fi

    LogMsg "Debug" "Item UUIDs found."

    if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
        local cloudS3Item httpCode
        cloudS3Item=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$cloudS3UUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
        httpCode=$(tail -n1 <<< "$cloudS3Item")
        cloudS3Item=$(sed '$ d' <<< "$cloudS3Item")
        if [[ "$httpCode" != "200" ]]; then
            LogMsg "Error" "Get CloudS3Item: $httpCode. Response: $cloudS3Item"
            return 1
        fi
        cloudS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< "$cloudS3Item")
        cloudS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< "$cloudS3Item")
        cloudS3URL=$(jq -r '.urls[0].href' <<< "$cloudS3Item")
        cloudS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< "$cloudS3Item")
        cloudS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< "$cloudS3Item")
        if [[ -z "$cloudS3AccessKey" || -z "$cloudS3SecretKey" || -z "$cloudS3URL" || -z "$cloudS3Bucket" || -z "$cloudS3BucketPath" ]]; then
             LogMsg "Error" "Missing fields in Cloud S3 item."
             return 1
        fi
        LogMsg "Debug" "Cloud S3 details retrieved."
        aws configure set aws_access_key_id "$cloudS3AccessKey" --profile cloud || { LogMsg "Error" "Failed to configure cloud aws access key id."; return 1; }
        aws configure set aws_secret_access_key "$cloudS3SecretKey" --profile cloud || { LogMsg "Error" "Failed to configure cloud aws secret access key."; return 1; }
        LogMsg "Debug" "Cloud S3 profile configured."
    fi

    if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
        local localS3Item httpCode
        localS3Item=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$localS3UUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
        httpCode=$(tail -n1 <<< "$localS3Item")
        localS3Item=$(sed '$ d' <<< "$localS3Item")
        if [[ "$httpCode" != "200" ]]; then
            LogMsg "Error" "Get LocalS3Item: $httpCode. Response: $localS3Item"
            return 1
        fi
        localS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< "$localS3Item")
        localS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< "$localS3Item")
        localS3URL=$(jq -r '.urls[0].href' <<< "$localS3Item")
        localS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< "$localS3Item")
        localS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< "$localS3Item")
         if [[ -z "$localS3AccessKey" || -z "$localS3SecretKey" || -z "$localS3URL" || -z "$localS3Bucket" || -z "$localS3BucketPath" ]]; then
             LogMsg "Error" "Missing fields in Local S3 item."
             return 1
        fi
        LogMsg "Debug" "Local S3 details retrieved."
        aws configure set aws_access_key_id "$localS3AccessKey" --profile local || { LogMsg "Error" "Failed to configure local aws access key id."; return 1; }
        aws configure set aws_secret_access_key "$localS3SecretKey" --profile local || { LogMsg "Error" "Failed to configure local aws secret access key."; return 1; }
        LogMsg "Debug" "Local S3 profile configured."
    fi

    if [[ "${AGE_Encrypt:-false}" == "true" ]]; then
        local agePublicKeyItem httpCode
        if [[ -z "$agePublicKeyUUID" ]]; then LogMsg "Error" "Age Public Key '${AGE_PUBLIC_KEY:-}' not found in vault items."; return 1; fi
        agePublicKeyItem=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$agePublicKeyUUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
        httpCode=$(tail -n1 <<< "$agePublicKeyItem")
        agePublicKeyItem=$(sed '$ d' <<< "$agePublicKeyItem")
        if [[ "$httpCode" != "200" ]]; then
            LogMsg "Error" "Get agePublicKeyItem: $httpCode. Response: $agePublicKeyItem"
            return 1
        fi
        agePublicKey=$(jq -r '.fields[] | select(.id=="credential") | .value' <<< "$agePublicKeyItem")
         if [[ -z "$agePublicKey" ]]; then
             LogMsg "Error" "Missing public key field in Age Public Key item."
             return 1
        fi
        LogMsg "Debug" "Age public key retrieved."
    fi

    local mysqlItem httpCode
    if [[ -z "$mysqlUUID" ]]; then LogMsg "Error" "MySQL Key '${OPWD_MYSQL_KEY:-}' not found in vault items."; return 1; fi
    mysqlItem=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$mysqlUUID" -H "Accept: application/json"  H "Authorization: Bearer $OPWD_TOKEN")
    httpCode=$(tail -n1 <<< "$mysqlItem")
    mysqlItem=$(sed '$ d' <<< "$mysqlItem")
    if [[ "$httpCode" != "200" ]]; then
        LogMsg "Error" "Get MySQLItem: $httpCode. Response: $mysqlItem"
        return 1
    fi
    dbHost=$(jq -r '.fields[] | select(.label=="dbhost") | .value' <<< "$mysqlItem")
    dbUser=$(jq -r '.fields[] | select(.label=="dbuser") | .value' <<< "$mysqlItem")
    dbPwd=$(jq -r '.fields[] | select(.label=="dbpwd") | .value' <<< "$mysqlItem")
    dbPort=$(jq -r '.fields[] | select(.label=="dbport") | .value' <<< "$mysqlItem")
     if [[ -z "$dbHost" || -z "$dbUser" || -z "$dbPwd" || -z "$dbPort" ]]; then
         LogMsg "Error" "Missing fields in MySQL item."
         return 1
    fi
    LogMsg "Debug" "MySQL details retrieved."

    LogMsg "Debug" "Get Items from Vault and Set S3 Profiles Completed"
    return 0
}

# List all DBs 
function ListAllDBs() {
    LogMsg "Debug" "Starting ListAllDBs function."
	if [[ "${TARGET_ALL_DATABASES:-false}" == "true" ]]; then
		if [[ -n "${TARGET_DATABASE_NAMES:-}" ]]; then
			LogMsg "Debug" "TARGET_ALL_DATABASES is true and TARGET_DATABASE_NAMES isn't empty, ignoring TARGET_DATABASE_NAMES"
			TARGET_DATABASE_NAMES=""
		fi
		local dbExclusionList="'mysql','sys','tmp','information_schema','performance_schema'"
		local dbSQLCmd="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${dbExclusionList})"
		LogMsg "Debug" "Executing SQL to list databases: $dbSQLCmd"
		if ! mapfile -t dbList < <(mysql -u "$dbUser" -h "$dbHost" -p"$dbPwd" -P "$dbPort" -ANe"$dbSQLCmd" 2>&1); then
            local mysql_error="${dbList[*]}"
			LogMsg "Error" "Building list of all databases failed. MySQL error: $mysql_error"
			return 1
		fi
		TARGET_DATABASE_NAMES=("${dbList[@]}")
		if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 && "${TARGET_ALL_DATABASES:-false}" == "true" ]]; then
             LogMsg "Warning" "No databases found to backup after exclusions or MySQL query returned no results."
        fi
		LogMsg "Debug" "Built list of all databases (${TARGET_DATABASE_NAMES[*]})"
	else
        if [[ -z "${TARGET_DATABASE_NAMES:-}" ]]; then
             LogMsg "Error" "TARGET_DATABASE_NAMES is not set and TARGET_ALL_DATABASES is not true."
             return 1
        fi
		IFS=',' read -ra TARGET_DATABASE_NAMES <<< "${TARGET_DATABASE_NAMES:-}"
        if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 ]]; then
             LogMsg "Error" "TARGET_DATABASE_NAMES is set but appears empty or only contains delimiters."
             return 1
        fi
        LogMsg "Debug" "Target databases specified: ${TARGET_DATABASE_NAMES[*]}"
	fi
    LogMsg "Debug" "ListAllDBs function completed."
    return 0
}


# Backup DBs
function BackupDBs() {
    LogMsg "Debug" "Starting BackupDBs function."
    if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 ]]; then
        LogMsg "Warning" "No databases specified or found to backup. Skipping backup process."
        return 0
    fi

    local create_db_stmt=""
    if [[ "${BACKUP_CREATE_DATABASE_STATEMENT:-false}" == "true" ]]; then
        create_db_stmt="--databases"
    fi

    local overall_backup_status=0

    for db in "${TARGET_DATABASE_NAMES[@]}"; do
        LogMsg "Information" "Starting backup for database: $db"
        local dump="backup_${db}_$(date +${BACKUP_TIMESTAMP:-%Y%m%d%H%M%S}).sql"
        local tmp_err_file="/tmp/${dump}.err"

        LogMsg "Debug" "Running mysqldump for $db..."
        if ! mysqldump -u "$dbUser" -h "$dbHost" -p"$dbPwd" -P "$dbPort" ${BACKUP_ADDITIONAL_PARAMS:-} $create_db_stmt "$db" > "/tmp/$dump" 2> >(tee "$tmp_err_file" >&2); then
            LogMsg "Error" "mysqldump failed for DB: $db. Message: $(cat "$tmp_err_file")"
            rm -f "/tmp/$dump" "$tmp_err_file"
            overall_backup_status=1
            continue
        fi
        rm -f "$tmp_err_file"
        LogMsg "Debug" "DB backup created at /tmp/$dump"

        local dumpfile="/tmp/$dump"
        local final_dumpname="$dump"

        if [[ "${BACKUP_COMPRESS:-false}" == "true" ]]; then
            LogMsg "Debug" "Compressing $db backup..."
            local level="${BACKUP_COMPRESS_LEVEL:-9}"
            if ! gzip -${level} -c "$dumpfile" > "$dumpfile.gz"; then
                LogMsg "Error" "gzip failed for DB: $db."
                rm -f "$dumpfile" "$dumpfile.gz"
                 overall_backup_status=1
                continue
            fi
            LogMsg "Debug" "Compression completed."
            rm -f "$dumpfile"
            dumpfile="$dumpfile.gz"
            final_dumpname="$dump.gz"
        fi

        if [[ "${AGE_Encrypt:-false}" == "true" ]]; then
            LogMsg "Debug" "Encrypting $db backup..."
            if [[ -z "${agePublicKey:-}" ]]; then
                 LogMsg "Error" "Age public key not found for encryption. Skipping encryption for $db."
                 rm -f "$dumpfile"
                 overall_backup_status=1
                 continue
            fi
            if ! age -a -r "$agePublicKey" < "$dumpfile" > "$dumpfile.age"; then
                LogMsg "Error" "age encryption failed for DB: $db."
                rm -f "$dumpfile" "$dumpfile.age"
                 overall_backup_status=1
                continue
            fi
            LogMsg "Debug" "Age encrypt completed."
            rm -f "$dumpfile"
            dumpfile="$dumpfile.age"
            final_dumpname="$dump.age"
        fi

        local cdate cyear cmonth
        cdate=$(date -u)
        cyear=$(date --date="$cdate" +%Y)
        cmonth=$(date --date="$cdate" +%m)

        if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
            LogMsg "Debug" "Uploading $db backup to cloud S3..."
            if ! aws --no-verify-ssl --only-show-errors --endpoint-url="$cloudS3URL" s3 cp "$dumpfile" "s3://$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$final_dumpname" --profile cloud; then
                LogMsg "Error" "Cloud s3 upload failed for DB: $db."
                overall_backup_status=1
            else
                LogMsg "Information" "Cloud Upload DB: $db Path:$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$final_dumpname"
            fi
        fi

        if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
             LogMsg "Debug" "Uploading $db backup to local S3..."
             if [[ "${CLOUD_UPLOAD:-false}" == "true" && "$cloudS3URL" == "$localS3URL" && "$cloudS3Bucket" == "$localS3Bucket" && "$cloudS3BucketPath" == "$localS3BucketPath" ]]; then
                  LogMsg "Debug" "Local and Cloud S3 destinations are the same, skipping duplicate local upload for $db."
             else
                if ! aws --no-verify-ssl --only-show-errors --endpoint-url="$localS3URL" s3 cp "$dumpfile" "s3://$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$final_dumpname" --profile local; then
                    LogMsg "Error" "Local s3 upload failed for DB: $db."
                    overall_backup_status=1
                else
                    LogMsg "Information" "Local Upload DB: $db Path:$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$final_dumpname"
                fi
             fi
        fi

        rm -f "$dumpfile"
        LogMsg "Information" "Finished processing database: $db"

    done

    LogMsg "Debug" "Backup process completed."
    return "$overall_backup_status"
}

# Main function
function Main() {
    # Define log directory path and create it
    mkdir -p "$LOG_DIR_PATH"
    local mkdir_status=$?

    # Explicitly check if the log directory was created/exists and is writable
    if [[ "$mkdir_status" -ne 0 ]]; then
        echo "ERROR: Failed to create log directory: $LOG_DIR_PATH. mkdir exit status: $mkdir_status" >&2
        # We cannot log to file, but we must exit here as logging is fundamental
        exit 1
    fi

    if [[ ! -w "$LOG_DIR_PATH" ]]; then
        echo "ERROR: Log directory is not writable by the current user: $LOG_DIR_PATH" >&2
        echo "DEBUG: Attempting test write to $LOG_DIR_PATH to get specific error..." >&2
        echo "Test write to $LOG_DIR_PATH" > "$LOG_DIR_PATH/test_write_$$.log" 2>&1 || true
        if [[ -f "$LOG_DIR_PATH/test_write_$$.log" ]]; then
            echo "DEBUG: Test write output:" >&2
            cat "$LOG_DIR_PATH/test_write_$$.log" >&2
            rm -f "$LOG_DIR_PATH/test_write_$$.log"
        fi
         # Exit here as logging is fundamental
        exit 1
    fi
   
    local year month podName nodeName
    year=$(date +%Y)
    month=$(date +%m)
    podName="${POD_NAME:-$(hostname)}"
    nodeName="${NODE_NAME:-unknown}"
    appName="${APP_NAME:-unknown}"
    logFile="$LOG_DIR_PATH/${year}_${month}_${podName}.log"

    local overall_script_status=0 

    LogMsg "Information" "Script started. Log file set to $logFile"
    echo "DEBUG: Script started execution." >&2

    echo "DEBUG: Required Environment Variables Check:" >&2
    echo "DEBUG: OPWD_URL is set: ${OPWD_URL:+true}" >&2
    echo "DEBUG: OPWD_TOKEN is set: ${OPWD_TOKEN:+true}" >&2
    echo "DEBUG: OPWD_VAULT is set: ${OPWD_VAULT:+true}" >&2
    echo "DEBUG: OPWD_CLOUD_KEY is set: ${OPWD_CLOUD_KEY:+true}" >&2
    echo "DEBUG: OPWD_LOCAL_KEY is set: ${OPWD_LOCAL_KEY:+true}" >&2
    echo "DEBUG: OPWD_MYSQL_KEY is set: ${OPWD_MYSQL_KEY:+true}" >&2
    echo "DEBUG: AGE_PUBLIC_KEY is set: ${AGE_PUBLIC_KEY:+true}" >&2
    echo "DEBUG: CLOUD_UPLOAD is set: ${CLOUD_UPLOAD:+true} (Value: ${CLOUD_UPLOAD:-false})" >&2
    echo "DEBUG: LOCAL_UPLOAD is set: ${LOCAL_UPLOAD:+true} (Value: ${LOCAL_UPLOAD:-false})" >&2
    echo "DEBUG: AGE_Encrypt is set: ${AGE_Encrypt:+true} (Value: ${AGE_Encrypt:-false})" >&2
    echo "DEBUG: TARGET_ALL_DATABASES is set: ${TARGET_ALL_DATABASES:+true} (Value: ${TARGET_ALL_DATABASES:-false})" >&2
    echo "DEBUG: TARGET_DATABASE_NAMES is set: ${TARGET_DATABASE_NAMES:+true} (Value: ${TARGET_DATABASE_NAMES:-})" >&2
    echo "DEBUG: LOG_DIR is set: ${LOG_DIR:+true} (Value: $LOG_DIR_PATH)" >&2
    echo "DEBUG: SCRIPT_POST_RUN_SLEEP_SECONDS is set: ${SCRIPT_POST_RUN_SLEEP_SECONDS:+true} (Value: ${SCRIPT_POST_RUN_SLEEP_SECONDS:-0})" >&2
    echo "DEBUG: Check complete." >&2


    LogMsg "Debug" "Calling GetVaultItemsNSetS3Profiles..."
    GetVaultItemsNSetS3Profiles
    local status=$?
    LogMsg "Debug" "GetVaultItemsNSetS3Profiles done status:$status"
    if [[ "$status" -ne 0 ]]; then
        LogMsg "Error" "Initialization (Vault/S3 config) failed."
        overall_script_status=1 
    fi

    # Only proceed to ListAllDBs if initialization was successful (or we decide to continue anyway)
    # if init fails, we just check status and proceed
    if [[ "$overall_script_status" -eq 0 ]]; then
        LogMsg "Debug" "Calling ListAllDBs..."
        ListAllDBs
        status=$?
        LogMsg "Debug" "ListAllDBs done status:$status"
        if [[ "$status" -ne 0 ]]; then
            LogMsg "Error" "Listing databases failed."
            overall_script_status=1 
        fi
    else
        LogMsg "Warning" "Skipping ListAllDBs due to previous initialization failure."
    fi


    # Only proceed to BackupDBs if listing was successful (or we decide to continue anyway)
     if [[ "$overall_script_status" -eq 0 || "${#TARGET_DATABASE_NAMES[@]}" -gt 0 ]]; then
        LogMsg "Debug" "Calling BackupDBs..."
        BackupDBs 
        status=$?
        LogMsg "Debug" "BackupDBs done status:$status"
        if [[ "$status" -ne 0 ]]; then
             LogMsg "Warning" "One or more database backups failed."
             overall_script_status=1 
        fi
    else
        LogMsg "Warning" "Skipping BackupDBs as no databases were found or specified and previous steps failed."
    fi


    LogMsg "Information" "Script finished main tasks."

    # Add sleep time if SCRIPT_POST_RUN_SLEEP_SECONDS is set and is a positive number
    if [[ -n "${SCRIPT_POST_RUN_SLEEP_SECONDS:-}" && "${SCRIPT_POST_RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ && "${SCRIPT_POST_RUN_SLEEP_SECONDS}" -gt 0 ]]; then
        LogMsg "Information" "Sleeping for ${SCRIPT_POST_RUN_SLEEP_SECONDS} seconds to allow log processing."
        echo "DEBUG: Sleeping for $SCRIPT_POST_RUN_SLEEP_SECONDS seconds." >&2
        sleep "$SCRIPT_POST_RUN_SLEEP_SECONDS" || LogMsg "Warning" "Sleep command interrupted or failed." # Add basic check for sleep command
        LogMsg "Information" "Sleep completed."
        echo "DEBUG: Sleep completed." >&2
    fi

    LogMsg "Information" "Script is exiting with overall status: $overall_script_status"
    echo "DEBUG: Script is exiting with overall status: $overall_script_status" >&2

    # --- End of Main logic ---
    return "$overall_script_status" 
}

exec bash -c 'Main'
# This line is only reached if 'exec' fails
echo "FATAL ERROR: exec bash -c 'Main' failed." >&2
exit 1 
