#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Check required tools
for tool in jq aws mysql mysqldump gzip age curl sleep; do 
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool is not installed." >&2
        exit 1
    fi
done

# Logging function
function LogMsg() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level="$1"
    local message="$2"
    local jsonLog    
    local jsonLog=$(jq -n --arg t "$timestamp" --arg a "$appName" --arg l "$level" --arg m "$message" --arg n "$nodeName" --arg p "$podName"  '{"@timestamp": $t, "appname": $a, "level": $l, "message": $m, "nodename": $n, "podname": $p }')
    echo "$jsonLog" | tee -a "$logFile"
}

# Trap for cleanup
function cleanup_tmp {
    rm -f /tmp/backup_*.sql /tmp/backup_*.gz /tmp/backup_*.age 2>/dev/null || true
}
trap cleanup_tmp EXIT

# Get secrets from vault and set S3 profiles
function GetVaultItemsNSetS3Profiles() {
    local vaults http_code vaultUUID vaultItems cloudS3UUID localS3UUID mysqlUUID agePublicKeyUUID
    vaults=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults" -H "Accept: application/json"  H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vaults")
    vaults=$(sed '$ d' <<< "$vaults")
    if [[ "$http_code" != "200" ]]; then
        LogMsg "Error" "Get Vault: $http_code"
        return 1
    fi
    LogMsg "Debug" "Got Vault"
    vaultUUID=$(jq -r '.[] | select(.name=="'"$OPWD_VAULT"'") | .id' <<< "$vaults")
    if [[ -z "$vaultUUID" ]]; then
        LogMsg "Error" "Vault UUID not found"
        return 1
    fi
    vaultItems=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vaultUUID/items" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vaultItems")
    vaultItems=$(sed '$ d' <<< "$vaultItems")
    if [[ "$http_code" != "200" ]]; then
        LogMsg "Error" "Get Vault Items: $http_code"
        return 1
    fi
    LogMsg "Debug" "Got Vault Items"
    cloudS3UUID=$(jq -r '.[] | select(.title=="'"$OPWD_CLOUD_KEY"'") | .id' <<< "$vaultItems")
    localS3UUID=$(jq -r '.[] | select(.title=="'"$OPWD_LOCAL_KEY"'") | .id' <<< "$vaultItems")
    mysqlUUID=$(jq -r '.[] | select(.title=="'"$OPWD_MYSQL_KEY"'") | .id' <<< "$vaultItems")
    agePublicKeyUUID=$(jq -r '.[] | select(.title=="'"$AGE_PUBLIC_KEY"'") | .id' <<< "$vaultItems")
    if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
        local cloudS3Item httpCode
        cloudS3Item=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$cloudS3UUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
        httpCode=$(tail -n1 <<< "$cloudS3Item")
        cloudS3Item=$(sed '$ d' <<< "$cloudS3Item")
        if [[ "$httpCode" != "200" ]]; then
            LogMsg "Error" "Get CloudS3Item: $cloudS3Item"
            return 1
        fi
        cloudS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< "$cloudS3Item")
        cloudS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< "$cloudS3Item")
        cloudS3URL=$(jq -r '.urls[0].href' <<< "$cloudS3Item")
        cloudS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< "$cloudS3Item")
        cloudS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< "$cloudS3Item")
        aws configure set aws_access_key_id "$cloudS3AccessKey" --profile cloud
        aws configure set aws_secret_access_key "$cloudS3SecretKey" --profile cloud
    fi
    if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
        local localS3Item httpCode
        localS3Item=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$localS3UUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
        httpCode=$(tail -n1 <<< "$localS3Item")
        localS3Item=$(sed '$ d' <<< "$localS3Item")
        if [[ "$httpCode" != "200" ]]; then
            LogMsg "Error" "Get LocalS3Item: $localS3Item"
            return 1
        fi
        localS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< "$localS3Item")
        localS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< "$localS3Item")
        localS3URL=$(jq -r '.urls[0].href' <<< "$localS3Item")
        localS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< "$localS3Item")
        localS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< "$localS3Item")
        aws configure set aws_access_key_id "$localS3AccessKey" --profile local
        aws configure set aws_secret_access_key "$localS3SecretKey" --profile local
    fi
    local agePublicKeyItem httpCode
    agePublicKeyItem=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$agePublicKeyUUID" -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    httpCode=$(tail -n1 <<< "$agePublicKeyItem")
    agePublicKeyItem=$(sed '$ d' <<< "$agePublicKeyItem")
    if [[ "$httpCode" != "200" ]]; then
        LogMsg "Error" "Get agePublicKeyItem: $agePublicKeyItem"
        return 1
    fi
    agePublicKey=$(jq -r '.fields[] | select(.id=="credential") | .value' <<< "$agePublicKeyItem")
    local mysqlItem
    mysqlItem=$(curl -w "\n%{response_code}\\n" -s "$OPWD_URL/v1/vaults/$vaultUUID/items/$mysqlUUID" -H "Accept: application/json"  H "Authorization: Bearer $OPWD_TOKEN")
    httpCode=$(tail -n1 <<< "$mysqlItem")
    mysqlItem=$(sed '$ d' <<< "$mysqlItem")
    if [[ "$httpCode" != "200" ]]; then
        LogMsg "Error" "Get MySQLItem: $mysqlItem"
        return 1
    fi
    dbHost=$(jq -r '.fields[] | select(.label=="dbhost") | .value' <<< "$mysqlItem")
    dbUser=$(jq -r '.fields[] | select(.label=="dbuser") | .value' <<< "$mysqlItem")
    dbPwd=$(jq -r '.fields[] | select(.label=="dbpwd") | .value' <<< "$mysqlItem")
    dbPort=$(jq -r '.fields[] | select(.label=="dbport") | .value' <<< "$mysqlItem")
    LogMsg "Debug" "Get Items from Vault and Set S3 Profiles Completed"
}

# List all DBs if needed
function ListAllDBs() {
    if [[ "${TARGET_ALL_DATABASES:-false}" == "true" ]]; then
        if [[ -n "${TARGET_DATABASE_NAMES:-}" ]]; then
            LogMsg "Debug" "TARGET_ALL_DATABASES is true and TARGET_DATABASE_NAMES isn't empty, ignoring TARGET_DATABASE_NAMES"
            TARGET_DATABASE_NAMES=""
        fi
        local dbExclusionList="'mysql','sys','tmp','information_schema','performance_schema'"
        local dbSQLCmd="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${dbExclusionList})"
        if ! mapfile -t dbList < <(mysql -u "$dbUser" -h "$dbHost" -p"$dbPwd" -P "$dbPort" -ANe"$dbSQLCmd"); then
            LogMsg "Error" "Building list of all databases failed"
            return 1
        fi
        TARGET_DATABASE_NAMES=("${dbList[@]}")
        LogMsg "Debug" "Built list of all databases (${TARGET_DATABASE_NAMES[*]})"
    else
        # If not all DBs, split TARGET_DATABASE_NAMES into array
        IFS=',' read -ra TARGET_DATABASE_NAMES <<< "${TARGET_DATABASE_NAMES:-}"
    fi
}

# Backup DBs
function BackupDBs() {
    local create_db_stmt=""
    if [[ "${BACKUP_CREATE_DATABASE_STATEMENT:-false}" == "true" ]]; then
        create_db_stmt="--databases"
    fi
    for db in "${TARGET_DATABASE_NAMES[@]}"; do
        local dump="backup_${db}_$(date +${BACKUP_TIMESTAMP:-%Y%m%d%H%M%S}).sql"
        local tmp_err_file="/tmp/${dump}.err"
        if ! mysqldump -u "$dbUser" -h "$dbHost" -p"$dbPwd" -P "$dbPort" ${BACKUP_ADDITIONAL_PARAMS:-} $create_db_stmt "$db" > "/tmp/$dump" 2> >(tee "$tmp_err_file" >&2); then
            LogMsg "Error" "failed DB: $db msg: $(cat "$tmp_err_file")"
            rm -f "/tmp/$dump" "$tmp_err_file"
            continue
        fi
        rm -f "$tmp_err_file"
        LogMsg "Debug" "DB backup $db $dump"
        local dumpfile="/tmp/$dump"
        if [[ "${BACKUP_COMPRESS:-false}" == "true" ]]; then
            local level="${BACKUP_COMPRESS_LEVEL:-9}"
            if ! gzip -${level} -c "$dumpfile" > "$dumpfile.gz"; then
                LogMsg "Error" "gzip DB: $db failed"
                rm -f "$dumpfile" "$dumpfile.gz"
                continue
            fi
            rm -f "$dumpfile"
            dumpfile="$dumpfile.gz"
            dump="$dump.gz"
            LogMsg "Debug" "gzip completed"
        fi
        if [[ "${AGE_Encrypt:-false}" == "true" ]]; then
            if ! age -a -r "$agePublicKey" < "$dumpfile" > "$dumpfile.age"; then
                LogMsg "Error" "age encryption DB: $db failed"
                rm -f "$dumpfile" "$dumpfile.age"
                continue
            fi
            rm -f "$dumpfile"
            dumpfile="$dumpfile.age"
            dump="$dump.age"
            LogMsg "Debug" "Age encrypt completed"
        fi
        local cdate cyear cmonth
        cdate=$(date -u)
        cyear=$(date --date="$cdate" +%Y)
        cmonth=$(date --date="$cdate" +%m)
        if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
            if aws --no-verify-ssl --only-show-errors --endpoint-url="$cloudS3URL" s3 cp "$dumpfile" "s3://$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$dump" --profile cloud; then
                LogMsg "Information" "Cloud Upload DB: $db Path:$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$dump"
            else
                LogMsg "Error" "Cloud s3 upload DB: $db failed"
            fi
        fi
        if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
            if aws --no-verify-ssl --only-show-errors --endpoint-url="$localS3URL" s3 cp "$dumpfile" "s3://$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$dump" --profile local; then
                LogMsg "Information" "Local Upload DB: $db Path:$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$dump"
            else
                LogMsg "Error" "Local s3 upload DB: $db failed"
            fi
        fi
        rm -f "$dumpfile"
    done
}

# Main function
function Main() {
    mkdir -p "${LOG_DIR:-/app/log}"
    local year month podName nodeName
    year=$(date +%Y)
    month=$(date +%m)
    podName="${POD_NAME:-$(hostname)}"
    nodeName="${NODE_NAME:-unknown}"
    appName="${APP_NAME:-unknown}"
    logFile="${LOG_DIR:-/app/log}/${year}_${month}_${podName}.log"

    LogMsg "Information" "Script started."

    GetVaultItemsNSetS3Profiles
    local status=$?
    LogMsg "Debug" "GetVaultItemsNSetS3Profiles done status:$status"
    if [[ "$status" != 0 ]]; then
        LogMsg "Error" "Initialization failed."
        exit 1 # Exit on initialization failure
    fi

    ListAllDBs
    status=$?
    LogMsg "Debug" "ListAllDBs done status:$status"
    if [[ "$status" != 0 ]]; then
        LogMsg "Error" "Listing databases failed."
        exit 1 # Exit on DB listing failure
    fi

    BackupDBs
    status=$?
    LogMsg "Debug" "BackupDBs done status:$status"
    if [[ "$status" != 0 ]]; then
         LogMsg "Warning" "Database backup failed for one or more databases."
         # The script continues even if some DBs fail to backup.
         # If We want ANY DB failure to cause the script to exit with an error, uncomment the line below:
         # exit 1
    fi

    LogMsg "Information" "Script finished main tasks."
    
    if [[ -n "${SCRIPT_POST_RUN_SLEEP_SECONDS:-}" && "$SCRIPT_POST_RUN_SLEEP_SECONDS" =~ ^[0-9]+$ && "$SCRIPT_POST_RUN_SLEEP_SECONDS" -gt 0 ]]; then
        LogMsg "Debug" "Sleeping for ${SCRIPT_POST_RUN_SLEEP_SECONDS} seconds to allow log processing."
        sleep "$SCRIPT_POST_RUN_SLEEP_SECONDS"
        LogMsg "Debug" "Sleep completed."
    fi

    exit 0 
}

# Execute the Main function
Main
