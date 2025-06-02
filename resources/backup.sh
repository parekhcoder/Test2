#!/bin/bash

set -uo pipefail
IFS=$'\n\t'

# Check required tools
for tool in jq aws mysql mysqldump gzip age curl sleep tee sync; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool is not installed." >&2
        exit 1
    fi
done

# Define default log directory early
LOG_DIR_PATH="${LOG_DIR:-/app/log}"

# Logging function with standardized levels and sync
log_msg() {
    local timestamp level message json_log app_name node_name pod_name
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    level="$1"
    message="$2"
    app_name="${APP_NAME:-unknown}"
    node_name="${NODE_NAME:-unknown}"
    pod_name="${POD_NAME:-unknown}"

    json_log=$(jq -n \
        --arg t "$timestamp" \
        --arg a "$app_name" \
        --arg l "$level" \
        --arg m "$message" \
        --arg n "$node_name" \
        --arg p "$pod_name" \
        '{"@timestamp": $t, "appname": $a, "level": $l, "message": $m, "nodename": $n, "podname": $p}')

    exec 3>&1 # Save stdout to fd 3

    if [[ -z "${log_file:-}" || ! -w "$LOG_DIR_PATH" ]]; then
        echo "$json_log" >&3
    else
        echo "$json_log" | tee -a "$log_file" >&3
        sync "$log_file" 2>/dev/null || echo "WARN: Failed to sync log file: $log_file" >&3
    fi

    exec 3>&- # Close fd 3
}

# Trap for cleanup with logging
cleanup_tmp() {
    log_msg "DEBUG" "Running cleanup trap."
    local tmp_dir="/tmp/backup_$$"
    if ! rm -rf "$tmp_dir" 2>/dev/null; then
        log_msg "WARN" "Failed to clean up temporary directory: $tmp_dir"
    fi
    log_msg "DEBUG" "Cleanup trap finished."
}
trap cleanup_tmp EXIT

# Create private temporary directory
tmp_dir="/tmp/backup_$$"
mkdir -p "$tmp_dir" && chmod 700 "$tmp_dir" || {
    log_msg "ERROR" "Failed to create private temporary directory: $tmp_dir"
    exit 1
}

# Validate required environment variables
validate_env_vars() {
    local required_vars=(
        "OPWD_URL"
        "OPWD_TOKEN"
        "OPWD_VAULT"
        "OPWD_MYSQL_KEY"
    )
    [[ "${CLOUD_UPLOAD:-false}" == "true" ]] && required_vars+=("OPWD_CLOUD_KEY")
    [[ "${LOCAL_UPLOAD:-false}" == "true" ]] && required_vars+=("OPWD_LOCAL_KEY")
    [[ "${AGE_ENCRYPT:-false}" == "true" ]] && required_vars+=("AGE_PUBLIC_KEY")

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        # Use eval to safely check if the variable is unset or empty
        if ! eval "[ -n \"\${$var+x}\" ]" || [ -z "$(eval echo "\${$var}")" ]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_msg "ERROR" "Missing or empty required environment variables: ${missing_vars[*]}"
        return 1
    fi
    return 0
}

# Configure S3 profile (refactored to reduce duplication)
configure_s3_profile() {
    local profile="$1" uuid="$2" vault_uuid="$3"
    local item http_code access_key secret_key url bucket bucket_path

    item=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vault_uuid/items/$uuid" \
        -H "Accept: application/json" -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$item")
    item=$(sed '$ d' <<< "$item")

    if [[ "$http_code" != "200" ]]; then
        case "$http_code" in
            401) log_msg "ERROR" "Unauthorized access to vault for $profile S3 item: $http_code" ;;
            404) log_msg "ERROR" "Vault item not found for $profile S3: $http_code" ;;
            *) log_msg "ERROR" "Failed to retrieve $profile S3 item: $http_code" ;;
        esac
        return 1
    fi

    access_key=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< "$item")
    secret_key=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< "$item")
    url=$(jq -r '.urls[0].href' <<< "$item")
    bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< "$item")
    bucket_path=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< "$item")

    if [[ -z "$access_key" || -z "$secret_key" || -z "$url" || -z "$bucket" || -z "$bucket_path" ]]; then
        log_msg "ERROR" "Missing fields in $profile S3 item."
        return 1
    fi

    aws configure set aws_access_key_id "$access_key" --profile "$profile" || {
        log_msg "ERROR" "Failed to configure $profile aws access key id."
        return 1
    }
    aws configure set aws_secret_access_key "$secret_key" --profile "$profile" || {
        log_msg "ERROR" "Failed to configure $profile aws secret access key."
        return 1
    }

    # Return values via global variables (avoiding eval)
    case "$profile" in
        cloud)
            cloud_s3_url="$url"
            cloud_s3_bucket="$bucket"
            cloud_s3_bucket_path="$bucket_path"
            ;;
        local)
            local_s3_url="$url"
            local_s3_bucket="$bucket"
            local_s3_bucket_path="$bucket_path"
            ;;
    esac

    log_msg "DEBUG" "$profile S3 profile configured."
    return 0
}

# Get secrets from vault and set S3 profiles
get_vault_items_n_set_s3_profiles() {
    log_msg "DEBUG" "Starting get_vault_items_n_set_s3_profiles function."
    local vaults http_code vault_uuid vault_items cloud_s3_uuid local_s3_uuid mysql_uuid age_public_key_uuid

    vaults=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults" \
        -H "Accept: application/json" -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vaults")
    vaults=$(sed '$ d' <<< "$vaults")
    if [[ "$http_code" != "200" ]]; then
        case "$http_code" in
            401) log_msg "ERROR" "Unauthorized access to vault: $http_code" ;;
            404) log_msg "ERROR" "Vault not found: $http_code" ;;
            *) log_msg "ERROR" "Failed to retrieve vaults: $http_code" ;;
        esac
        return 1
    fi
    log_msg "DEBUG" "Got vault list successfully."

    vault_uuid=$(jq -r '.[] | select(.name=="'"$OPWD_VAULT"'") | .id' <<< "$vaults")
    if [[ -z "$vault_uuid" ]]; then
        log_msg "ERROR" "Vault UUID not found for vault name: $OPWD_VAULT"
        return 1
    fi
    log_msg "DEBUG" "Found vault UUID: $vault_uuid"

    vault_items=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vault_uuid/items" \
        -H "Accept: application/json" -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$vault_items")
    vault_items=$(sed '$ d' <<< "$vault_items")
    if [[ "$http_code" != "200" ]]; then
        case "$http_code" in
            401) log_msg "ERROR" "Unauthorized access to vault items: $http_code" ;;
            404) log_msg "ERROR" "Vault items not found: $http_code" ;;
            *) log_msg "ERROR" "Failed to retrieve vault items: $http_code" ;;
        esac
        return 1
    fi
    log_msg "DEBUG" "Got vault items list successfully."

    cloud_s3_uuid=$(jq -r '.[] | select(.title=="'"${OPWD_CLOUD_KEY:-}"'") | .id' <<< "$vault_items")
    local_s3_uuid=$(jq -r '.[] | select(.title=="'"${OPWD_LOCAL_KEY:-}"'") | .id' <<< "$vault_items")
    mysql_uuid=$(jq -r '.[] | select(.title=="'"${OPWD_MYSQL_KEY:-}"'") | .id' <<< "$vault_items")
    age_public_key_uuid=$(jq -r '.[] | select(.title=="'"${AGE_PUBLIC_KEY:-}"'") | .id' <<< "$vault_items")

    if [[ "${CLOUD_UPLOAD:-false}" == "true" && -z "$cloud_s3_uuid" ]]; then
        log_msg "ERROR" "Cloud S3 key '${OPWD_CLOUD_KEY:-}' not found in vault items."
        return 1
    fi
    if [[ "${LOCAL_UPLOAD:-false}" == "true" && -z "$local_s3_uuid" ]]; then
        log_msg "ERROR" "Local S3 key '${OPWD_LOCAL_KEY:-}' not found in vault items."
        return 1
    fi
    if [[ -z "$mysql_uuid" ]]; then
        log_msg "ERROR" "MySQL key '${OPWD_MYSQL_KEY:-}' not found in vault items."
        return 1
    fi
    if [[ "${AGE_ENCRYPT:-false}" == "true" && -z "$age_public_key_uuid" ]]; then
        log_msg "ERROR" "Age public key '${AGE_PUBLIC_KEY:-}' not found in vault items."
        return 1
    fi

    log_msg "DEBUG" "Item UUIDs found."

    if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
        configure_s3_profile "cloud" "$cloud_s3_uuid" "$vault_uuid" || return 1
    fi

    if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
        configure_s3_profile "local" "$local_s3_uuid" "$vault_uuid" || return 1
    fi

    if [[ "${AGE_ENCRYPT:-false}" == "true" ]]; then
        local age_public_key_item http_code
        age_public_key_item=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vault_uuid/items/$age_public_key_uuid" \
            -H "Accept: application/json" -H "Authorization: Bearer $OPWD_TOKEN")
        http_code=$(tail -n1 <<< "$age_public_key_item")
        age_public_key_item=$(sed '$ d' <<< "$age_public_key_item")
        if [[ "$http_code" != "200" ]]; then
            case "$http_code" in
                401) log_msg "ERROR" "Unauthorized access to age public key: $http_code" ;;
                404) log_msg "ERROR" "Age public key item not found: $http_code" ;;
                *) log_msg "ERROR" "Failed to retrieve age public key: $http_code" ;;
            esac
            return 1
        fi
        age_public_key=$(jq -r '.fields[] | select(.id=="credential") | .value' <<< "$age_public_key_item")
        if [[ -z "$age_public_key" ]]; then
            log_msg "ERROR" "Missing public key field in age public key item."
            return 1
        fi
        log_msg "DEBUG" "Age public key retrieved."
    fi

    local mysql_item http_code
    mysql_item=$(curl -s -w "\n%{response_code}\n" "$OPWD_URL/v1/vaults/$vault_uuid/items/$mysql_uuid" \
        -H "Accept: application/json" -H "Authorization: Bearer $OPWD_TOKEN")
    http_code=$(tail -n1 <<< "$mysql_item")
    mysql_item=$(sed '$ d' <<< "$mysql_item")
    if [[ "$http_code" != "200" ]]; then
        case "$http_code" in
            401) log_msg "ERROR" "Unauthorized access to MySQL item: $http_code" ;;
            404) log_msg "ERROR" "MySQL item not found: $http_code" ;;
            *) log_msg "ERROR" "Failed to retrieve MySQL item: $http_code" ;;
        esac
        return 1
    fi
    db_host=$(jq -r '.fields[] | select(.label=="dbhost") | .value' <<< "$mysql_item")
    db_user=$(jq -r '.fields[] | select(.label=="dbuser") | .value' <<< "$mysql_item")
    db_pwd=$(jq -r '.fields[] | select(.label=="dbpwd") | .value' <<< "$mysql_item")
    db_port=$(jq -r '.fields[] | select(.label=="dbport") | .value' <<< "$mysql_item")
    if [[ -z "$db_host" || -z "$db_user" || -z "$db_pwd" || -z "$db_port" ]]; then
        log_msg "ERROR" "Missing fields in MySQL item."
        return 1
    fi
    log_msg "DEBUG" "MySQL details retrieved."

    # Create MySQL config file for secure credential passing
    mysql_cnf="$tmp_dir/mysql.cnf"
    cat > "$mysql_cnf" << EOF
[client]
user=$db_user
password=$db_pwd
host=$db_host
port=$db_port
EOF
    chmod 600 "$mysql_cnf" || {
        log_msg "ERROR" "Failed to set permissions on MySQL config file."
        return 1
    }

    # Verify MySQL connectivity
    if ! mysql --defaults-file="$mysql_cnf" -e "SELECT 1" >/dev/null 2>&1; then
        log_msg "ERROR" "Failed to connect to MySQL server."
        return 1
    fi

    log_msg "DEBUG" "Vault items retrieved and S3 profiles configured."
    return 0
}

# List all databases
list_all_dbs() {
    log_msg "DEBUG" "Starting list_all_dbs function."
    local db_list
    if [[ "${TARGET_ALL_DATABASES:-false}" == "true" ]]; then
        if [[ -n "${TARGET_DATABASE_NAMES:-}" ]]; then
            log_msg "INFO" "TARGET_ALL_DATABASES is true; ignoring TARGET_DATABASE_NAMES."
            TARGET_DATABASE_NAMES=""
        fi
        local db_exclusion_list="'mysql','sys','tmp','information_schema','performance_schema'"
        local db_sql_cmd="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($db_exclusion_list)"
        log_msg "DEBUG" "Executing SQL to list databases: $db_sql_cmd"
        if ! mapfile -t db_list < <(mysql --defaults-file="$mysql_cnf" -ANe"$db_sql_cmd" 2>&1); then
            log_msg "ERROR" "Failed to list databases."
            return 1
        fi
        TARGET_DATABASE_NAMES=("${db_list[@]}")
        if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 ]]; then
            log_msg "WARN" "No databases found to backup after exclusions."
        fi
        log_msg "DEBUG" "Built list of databases: ${TARGET_DATABASE_NAMES[*]}"
    else
        if [[ -z "${TARGET_DATABASE_NAMES:-}" ]]; then
            log_msg "ERROR" "TARGET_DATABASE_NAMES is not set and TARGET_ALL_DATABASES is not true."
            return 1
        fi
        IFS=',' read -ra TARGET_DATABASE_NAMES <<< "${TARGET_DATABASE_NAMES}"
        if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 ]]; then
            log_msg "ERROR" "TARGET_DATABASE_NAMES is empty or contains only delimiters."
            return 1
        fi
        log_msg "DEBUG" "Target databases specified: ${TARGET_DATABASE_NAMES[*]}"
    fi
    log_msg "DEBUG" "list_all_dbs function completed."
    return 0
}

backup_dbs() {
    log_msg "DEBUG" "Starting backup_dbs function."
    if [[ "${#TARGET_DATABASE_NAMES[@]}" -eq 0 ]]; then
        log_msg "WARN" "No databases specified or found to backup. Skipping backup process."
        return 0
    fi

    local create_db_stmt=""
    [[ "${BACKUP_CREATE_DATABASE_STATEMENT:-false}" == "true" ]] && create_db_stmt="--databases"

    # Split and validate BACKUP_ADDITIONAL_PARAMS
    local additional_params=()
    if [[ -n "${BACKUP_ADDITIONAL_PARAMS:-}" ]]; then
        # Remove leading/trailing whitespace
        BACKUP_ADDITIONAL_PARAMS=$(echo "${BACKUP_ADDITIONAL_PARAMS}" | tr -s ' ' | sed 's/^ *//;s/ *$//')
        # Split into array
        IFS=' ' read -ra additional_params <<< "${BACKUP_ADDITIONAL_PARAMS}"
        # Validate each parameter
        for param in "${additional_params[@]}"; do
            if [[ ! "$param" =~ ^--[a-zA-Z0-9_-]+(=.*)?$ ]]; then
                log_msg "ERROR" "Invalid mysqldump parameter: '$param'. Must start with '--'."
                return 1
            fi
            # Warn about redundant options
            if [[ "$param" == "--quick" || "$param" == "--skip-lock-tables" ]]; then
                log_msg "WARN" "Redundant option '$param' in BACKUP_ADDITIONAL_PARAMS; already handled by script."
            fi
        done
    fi

    local overall_backup_status=0

    for db in "${TARGET_DATABASE_NAMES[@]}"; do
        log_msg "INFO" "Starting backup for database: $db"
        local dump="$tmp_dir/backup_${db}_$(date +${BACKUP_TIMESTAMP:-%Y%m%d%H%M%S}).sql"
        local tmp_err_file="$tmp_dir/${db}_err.log"

        log_msg "DEBUG" "Running mysqldump for $db with params: --defaults-file=$mysql_cnf --single-transaction --quick ${additional_params[*]} $create_db_stmt $db"
        # Use array expansion for additional_params
        if ! mysqldump --defaults-file="$mysql_cnf" --single-transaction --quick \
            "${additional_params[@]}" "$create_db_stmt" "$db" > "$dump" 2> >(tee "$tmp_err_file" >&2); then
            log_msg "ERROR" "mysqldump failed for database: $db. Error: $(cat "$tmp_err_file" | head -n 1)"
            rm -f "$dump" "$tmp_err_file"
            overall_backup_status=1
            continue
        fi
        rm -f "$tmp_err_file"
        log_msg "DEBUG" "Database backup created at $dump"

        if [[ ! -s "$dump" ]]; then
            log_msg "ERROR" "Backup file for $db is empty."
            rm -f "$dump"
            overall_backup_status=1
            continue
        fi

        local dump_file="$dump"
        local final_dump_name=$(basename "$dump")

        if [[ "${BACKUP_COMPRESS:-false}" == "true" ]]; then
            log_msg "DEBUG" "Compressing $db backup..."
            local level="${BACKUP_COMPRESS_LEVEL:-6}"
            if ! gzip -"$level" -c "$dump_file" > "$dump_file.gz"; then
                log_msg "ERROR" "gzip failed for database: $db."
                rm -f "$dump_file" "$dump_file.gz"
                overall_backup_status=1
                continue
            fi
            log_msg "DEBUG" "Compression completed."
            rm -f "$dump_file"
            dump_file="$dump_file.gz"
            final_dump_name="$final_dump_name.gz"
        fi

        if [[ "${AGE_ENCRYPT:-false}" == "true" ]]; then
            log_msg "DEBUG" "Encrypting $db backup..."
            if [[ -z "${age_public_key:-}" ]]; then
                log_msg "ERROR" "Age public key not found for encryption. Skipping encryption for $db."
                rm -f "$dump_file"
                overall_backup_status=1
                continue
            fi
            if ! age -a -r "$age_public_key" < "$dump_file" > "$dump_file.age"; then
                log_msg "ERROR" "Age encryption failed for database: $db."
                rm -f "$dump_file" "$dump_file.age"
                overall_backup_status=1
                continue
            fi
            log_msg "DEBUG" "Age encryption completed."
            rm -f "$dump_file"
            dump_file="$dump_file.age"
            final_dump_name="$final_dump_name.age"
        fi

        local cdate cyear cmonth
        cdate=$(date -u)
        cyear=$(date --date="$cdate" +%Y)
        cmonth=$(date --date="$cdate" +%m)

       if [[ "${CLOUD_UPLOAD:-false}" == "true" ]]; then
            log_msg "DEBUG" "Uploading $db backup to cloud S3..."
            local s3_error
            s3_error=$(aws --no-verify-ssl --endpoint-url="$cloud_s3_url" \
                s3 cp "$dump_file" "s3://$cloud_s3_bucket$cloud_s3_bucket_path/$cyear/$cmonth/$final_dump_name" \
                --profile cloud --tries 3 2>&1)
            aws_exit_status=$?
            if [[ $aws_exit_status -ne 0 ]]; then
                log_msg "ERROR" "Cloud S3 upload failed for database: $db. Error: $s3_error"
                overall_backup_status=1
            else
                log_msg "INFO" "Cloud upload completed for $db: $cloud_s3_bucket$cloud_s3_bucket_path/$cyear/$cmonth/$final_dump_name Output: $s3_error"
            fi
        fi        

        if [[ "${LOCAL_UPLOAD:-false}" == "true" ]]; then
            log_msg "DEBUG" "Uploading $db backup to local S3..."
            if [[ "${CLOUD_UPLOAD:-false}" == "true" && "$cloud_s3_url" == "$local_s3_url" && \
                "$cloud_s3_bucket" == "$local_s3_bucket" && "$cloud_s3_bucket_path" == "$local_s3_bucket_path" ]]; then
                log_msg "DEBUG" "Local and cloud S3 destinations are identical; skipping duplicate upload for $db."
            else
                local s3_error
                s3_error=$(aws --no-verify-ssl --endpoint-url="$local_s3_url" \
                    s3 cp "$dump_file" "s3://$local_s3_bucket$local_s3_bucket_path/$cyear/$cmonth/$final_dump_name" \
                    --profile local --tries 3 2>&1)
                aws_exit_status=$?
                if [[ $aws_exit_status -ne 0 ]]; then
                    log_msg "ERROR" "Local S3 upload failed for database: $db. Error: $s3_error"
                    overall_backup_status=1
                else
                    log_msg "INFO" "Local upload completed for $db: $local_s3_bucket$local_s3_bucket_path/$cyear/$cmonth/$final_dump_name Output: $s3_error"
                fi
            fi
        fi
        rm -f "$dump_file"
        log_msg "INFO" "Finished processing database: $db"
    done

    log_msg "DEBUG" "Backup process completed."
    return "$overall_backup_status"
}

# Main function (including the fix for the syntax error)
main() {
    # Validate environment variables
    validate_env_vars || {
        log_msg "FATAL" "Environment variable validation failed. Exiting."
        exit 1
    }

    # Create and verify log directory
    mkdir -p "$LOG_DIR_PATH" || {
        log_msg "FATAL" "Failed to create log directory: $LOG_DIR_PATH"
        exit 1
    }
    chmod 700 "$LOG_DIR_PATH" || {
        log_msg "FATAL" "Failed to set permissions on log directory: $LOG_DIR_PATH"
        exit 1
    }
    if [[ ! -w "$LOG_DIR_PATH" ]]; then
        log_msg "FATAL" "Log directory is not writable: $LOG_DIR_PATH"
        exit 1
    fi  # Fixed from }

    local year month pod_name node_name
    year=$(date +%Y)
    month=$(date +%m)
    pod_name="${POD_NAME:-$(hostname)}"
    node_name="${NODE_NAME:-unknown}"
    log_file="$LOG_DIR_PATH/${year}_${month}_${pod_name}.log"

    # Check log file size and rotate if necessary
    if [[ -f "$log_file" && $(stat -c %s "$log_file" 2>/dev/null || stat -f %z "$log_file" 2>/dev/null) -gt $((10*1024*1024)) ]]; then
        mv "$log_file" "${log_file}.$(date +%s)" || log_msg "WARN" "Failed to rotate log file."
    fi

    log_msg "INFO" "Script started. Log file: $log_file"

    local overall_script_status=0

    log_msg "DEBUG" "Calling get_vault_items_n_set_s3_profiles..."
    get_vault_items_n_set_s3_profiles
    local status=$?
    log_msg "DEBUG" "get_vault_items_n_set_s3_profiles completed with status: $status"
    if [[ "$status" -ne 0 ]]; then
        log_msg "ERROR" "Vault/S3 configuration failed."
        overall_script_status=1
    fi

    if [[ "$overall_script_status" -eq 0 ]]; then
        log_msg "DEBUG" "Calling list_all_dbs..."
        list_all_dbs
        status=$?
        log_msg "DEBUG" "list_all_dbs completed with status: $status"
        if [[ "$status" -ne 0 ]]; then
            log_msg "ERROR" "Listing databases failed."
            overall_script_status=1
        fi
    else
        log_msg "WARN" "Skipping list_all_dbs due to previous failure."
    fi

    if [[ "$overall_script_status" -eq 0 || "${#TARGET_DATABASE_NAMES[@]}" -gt 0 ]]; then
        log_msg "DEBUG" "Calling backup_dbs..."
        backup_dbs
        status=$?
        log_msg "DEBUG" "backup_dbs completed with status: $status"
        if [[ "$status" -ne 0 ]]; then
            log_msg "WARN" "One or more database backups failed."
            overall_script_status=1
        fi
    else
        log_msg "WARN" "Skipping backup_dbs as no databases were found or specified."
    fi

    log_msg "INFO" "Script finished main tasks."

    # Handle sleep with validation
    if [[ -n "${SCRIPT_POST_RUN_SLEEP_SECONDS:-}" && "${SCRIPT_POST_RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ ]]; then
        if [[ "${SCRIPT_POST_RUN_SLEEP_SECONDS}" -gt 300 ]]; then
            log_msg "WARN" "SCRIPT_POST_RUN_SLEEP_SECONDS is set to ${SCRIPT_POST_RUN_SLEEP_SECONDS}s, which is unusually long."
        fi
        log_msg "INFO" "Sleeping for ${SCRIPT_POST_RUN_SLEEP_SECONDS} seconds to allow log processing."
        sleep "$SCRIPT_POST_RUN_SLEEP_SECONDS" || log_msg "WARN" "Sleep command interrupted or failed."
        log_msg "INFO" "Sleep completed."
    fi

    log_msg "INFO" "Script exiting with overall status: $overall_script_status"
    return "$overall_script_status"
}

# Main function
main() {
    # Validate environment variables
    validate_env_vars || {
        log_msg "FATAL" "Environment variable validation failed. Exiting."
        exit 1
    }

    # Create and verify log directory
    mkdir -p "$LOG_DIR_PATH" || {
        log_msg "FATAL" "Failed to create log directory: $LOG_DIR_PATH"
        exit 1
    }
    chmod 700 "$LOG_DIR_PATH" || {
        log_msg "FATAL" "Failed to set permissions on log directory: $LOG_DIR_PATH"
        exit 1
    }
    if [[ ! -w "$LOG_DIR_PATH" ]]; then
        log_msg "FATAL" "Log directory is not writable: $LOG_DIR_PATH"
        exit 1
    fi

    local year month pod_name node_name
    year=$(date +%Y)
    month=$(date +%m)
    pod_name="${POD_NAME:-$(hostname)}"
    node_name="${NODE_NAME:-unknown}"
    log_file="$LOG_DIR_PATH/${year}_${month}_${pod_name}.log"

    # Check log file size and rotate if necessary
    if [[ -f "$log_file" && $(stat -c %s "$log_file" 2>/dev/null || stat -f %z "$log_file" 2>/dev/null) -gt $((10*1024*1024)) ]]; then
        mv "$log_file" "${log_file}.$(date +%s)" || log_msg "WARN" "Failed to rotate log file."
    fi

    log_msg "INFO" "Script started. Log file: $log_file"

    local overall_script_status=0

    log_msg "DEBUG" "Calling get_vault_items_n_set_s3_profiles..."
    get_vault_items_n_set_s3_profiles
    local status=$?
    log_msg "DEBUG" "get_vault_items_n_set_s3_profiles completed with status: $status"
    if [[ "$status" -ne 0 ]]; then
        log_msg "ERROR" "Vault/S3 configuration failed."
        overall_script_status=1
    fi

    if [[ "$overall_script_status" -eq 0 ]]; then
        log_msg "DEBUG" "Calling list_all_dbs..."
        list_all_dbs
        status=$?
        log_msg "DEBUG" "list_all_dbs completed with status: $status"
        if [[ "$status" -ne 0 ]]; then
            log_msg "ERROR" "Listing databases failed."
            overall_script_status=1
        fi
    else
        log_msg "WARN" "Skipping list_all_dbs due to previous failure."
    fi

    if [[ "$overall_script_status" -eq 0 || "${#TARGET_DATABASE_NAMES[@]}" -gt 0 ]]; then
        log_msg "DEBUG" "Calling backup_dbs..."
        backup_dbs
        status=$?
        log_msg "DEBUG" "backup_dbs completed with status: $status"
        if [[ "$status" -ne 0 ]]; then
            log_msg "WARN" "One or more database backups failed."
            overall_script_status=1
        fi
    else
        log_msg "WARN" "Skipping backup_dbs as no databases were found or specified."
    fi

    log_msg "INFO" "Script finished main tasks."

    # Handle sleep with validation
    if [[ -n "${SCRIPT_POST_RUN_SLEEP_SECONDS:-}" && "${SCRIPT_POST_RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ ]]; then
        if [[ "${SCRIPT_POST_RUN_SLEEP_SECONDS}" -gt 300 ]]; then
            log_msg "WARN" "SCRIPT_POST_RUN_SLEEP_SECONDS is set to ${SCRIPT_POST_RUN_SLEEP_SECONDS}s, which is unusually long."
        fi
        log_msg "INFO" "Sleeping for ${SCRIPT_POST_RUN_SLEEP_SECONDS} seconds to allow log processing."
        sleep "$SCRIPT_POST_RUN_SLEEP_SECONDS" || log_msg "WARN" "Sleep command interrupted or failed."
        log_msg "INFO" "Sleep completed."
    fi

    log_msg "INFO" "Script exiting with overall status: $overall_script_status"
    return "$overall_script_status"
}

main
status=$?
if [[ $status -ne 0 ]]; then
    log_msg "FATAL" "main function failed with status: $status"
    exit $status
fi
exit 0
