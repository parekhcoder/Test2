# !/bin/bash

function LogMsg() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$2"
    local level="$1"
    local jsonLog=$(jq -n --arg t "$timestamp" --arg a "$App_Name" --arg l "$level" --arg m "$message" --arg n "$NODE_NAME" --arg p "$POD_NAME"  '{@timestamp: $t, appname: $App_Name, level:$l, message: $m, nodename: $n, podname: $p }')
    echo "$jsonLog" | tee -a "$logFile"
}

function GetVaultItemsNSetS3Profiles()
{
    local vaults=$(curl -s -w "\n%{response_code}\n" $OPWD_URL/v1/vaults -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    local http_code=$(tail -n1 <<< "$vaults")
    vaults=$(sed '$ d' <<< "$vaults")
    
    if [ "$http_code" != 200 ];
        then
	    LogMsg "Error" "Get Vault: $http_code"
            return -1
    fi

    LogMsg "Debug" "Got Vault"
    
    local vaultUUID=$(jq -r '.[] | select(.name=="'$OPWD_VAULT'") | .id' <<< $vaults)  
    
    local vaultItems=$(curl -s -w "\n%{response_code}\n" $OPWD_URL/v1/vaults/$vaultUUID/items -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    
    http_code=$(tail -n1 <<< "$vaultItems")
    vaultItems=$(sed '$ d' <<< "$vaultItems")
    if [ "$http_code" != 200 ];
        then
	    LogMsg "Error" "Get Vault Items: $http_code"
            return -1
    fi

    LogMsg "Debug" "Got Vault Items"    
    
    local cloudS3UUID=$(jq -r '.[] | select(.title=="'$OPWD_CLOUD_KEY'") | .id' <<< $vaultItems)
    local localS3UUID=$(jq -r '.[] | select(.title=="'$OPWD_LOCAL_KEY'") | .id' <<< $vaultItems)  
    local mysqlUUID=$(jq -r '.[] | select(.title=="'$OPWD_MYSQL_KEY'") | .id' <<< $vaultItems)  
    local agePublicKeyUUID=$(jq -r '.[] | select(.title=="'$AGE_PUBLIC_KEY'") | .id' <<< $vaultItems)    

    if [ "$CLOUD_UPLOAD" = "true" ]; 
    	then
    
	    local cloudS3Item=$(curl -w "\n%{response_code}\n" -s $OPWD_URL/v1/vaults/$vaultUUID/items/$cloudS3UUID -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
	
	    httpCode=$(tail -n1 <<< "$cloudS3Item")
	    cloudS3Item=$(sed '$ d' <<< "$cloudS3Item")
	
	    if [ "$httpCode" != 200 ];
	        then
	            LogMsg "Error" "Get CloudS3Item: $cloudS3Item"
	            return -1
	    fi    
	
	    local cloudS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< $cloudS3Item)
	    local cloudS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< $cloudS3Item)
	    cloudS3URL=$(jq -r '.urls[0].href' <<< $cloudS3Item)
	    cloudS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< $cloudS3Item)
	    cloudS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< $cloudS3Item)
	
	    aws configure set aws_access_key_id $cloudS3AccessKey --profile cloud
	    aws configure set aws_secret_access_key $cloudS3SecretKey --profile cloud
     fi

    
    if [ "$LOCAL_UPLOAD" = "true" ]; 
    	then
    		local localS3Item=$(curl -w "\n%{response_code}\n" -s $OPWD_URL/v1/vaults/$vaultUUID/items/$localS3UUID -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")

      		httpCode=$(tail -n1 <<< "$localS3Item")
    		localS3Item=$(sed '$ d' <<< "$localS3Item")

    		if [ "$httpCode" != 200 ];
        		then
            			LogMsg "Error" "Get LocalS3Item: $localS3Item"
            			return -1
		fi

      		local localS3AccessKey=$(jq -r '.fields[] | select(.label=="accesskey") | .value' <<< $localS3Item)
	    	local localS3SecretKey=$(jq -r '.fields[] | select(.label=="secretkey") | .value' <<< $localS3Item)
	    	localS3URL=$(jq -r '.urls[0].href' <<< $localS3Item)
      		localS3Bucket=$(jq -r '.fields[] | select(.label=="bucket") | .value' <<< $localS3Item)
		localS3BucketPath=$(jq -r '.fields[] | select(.label=="bucketpath") | .value' <<< $localS3Item)
	
	    	aws configure set aws_access_key_id $localS3AccessKey --profile local
	    	aws configure set aws_secret_access_key $localS3SecretKey --profile local
    fi        

    local agePublicKeyItem=$(curl -s $OPWD_URL/v1/vaults/$vaultUUID/items/$agePublicKeyUUID -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")
    httpCode=$(tail -n1 <<< "$agePublicKeyItem")    

    if [ "$httpCode" != 200 ];
	then
		LogMsg "Error" "Get agePublicKeyItem: $agePublicKeyItem"
		return -1
    fi
    agePublicKey=$(jq -r '.fields[] | select(.id=="credential") | .value' <<< $agePublicKeyItem)

    local mysqlItem=$(curl -w "\n%{response_code}\n" -s $OPWD_URL/v1/vaults/$vaultUUID/items/$mysqlUUID -H "Accept: application/json"  -H "Authorization: Bearer $OPWD_TOKEN")

    httpCode=$(tail -n1 <<< "$mysqlItem")
    mysqlItem=$(sed '$ d' <<< "$mysqlItem")

    if [ "$httpCode" != 200 ];
	then
		LogMsg "Error" "Get MySQLItem: $mysqlItem"
		return -1
    fi
    dbHost=$(jq -r '.fields[] | select(.label=="dbhost") | .value' <<< $mysqlItem)
    dbUser=$(jq -r '.fields[] | select(.label=="dbuser") | .value' <<< $mysqlItem)
    dbPwd=$(jq -r '.fields[] | select(.label=="dbpwd") | .value' <<< $mysqlItem)
    dbPort=$(jq -r '.fields[] | select(.label=="dbport") | .value' <<< $mysqlItem)

    LogMsg "Debug" "Get Items from Vault and Set S3 Profiles Completed"
}


function ListAllDBs()
{
	if [ "$TARGET_ALL_DATABASES" = "true" ]; 
	
		then
    
			if [ ! -z "$TARGET_DATABASE_NAMES" ];
				then        
					LogMsg "Debug" "TARGET_ALL_DATABASES is true and TARGET_DATABASE_NAMES isn't empty, ignoring TARGET_DATABASE_NAMES"
					TARGET_DATABASE_NAMES=""
			fi
		
			dbExclusionList="'mysql','sys','tmp','information_schema','performance_schema'"
			dbSQLCmd="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${dbExclusionList})"
			
			if ! dbList=`mysql -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT -ANe"${dbSQLCmd}"`
				then        
					LogMsg "Debug" "Error: Building list of all databases failed"
					isSuccess=false
					return -1
			fi
			
			TARGET_DATABASE_NAMES=$dbList        
			
			LogMsg "Debug" "Built list of all databases (${TARGET_DATABASE_NAMES})"
	
			
	fi			
	
}

function BackupDBs()
{
	if [ "$BACKUP_CREATE_DATABASE_STATEMENT" = "true" ]; 
 		then
  		  BACKUP_CREATE_DATABASE_STATEMENT="--databases"
	else
    		BACKUP_CREATE_DATABASE_STATEMENT=""
	fi
	
	for db in ${TARGET_DATABASE_NAMES} 
    	do
        
        dump=$db$(date +$BACKUP_TIMESTAMP).sql        
        
        if ! sqlOutput=$(mysqldump -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT $db 2>&1 > /tmp/$dump); then
			LogMsg "Error" "failed DB: $db msg: $sqloutput"			
			continue
		fi            
            
		LogMsg "Debug" "DB backup $db $dump"
		
		BACKUP_COMPRESS=$(echo "$BACKUP_COMPRESS" | awk '{print tolower($0)}')
		
		if [ "$BACKUP_COMPRESS" = true ]; then
			if [ -z "$BACKUP_COMPRESS_LEVEL" ]; then
				BACKUP_COMPRESS_LEVEL="9"
			fi
			if ! gzipOutput=$(gzip -${BACKUP_COMPRESS_LEVEL} -c /tmp/"$dump" >/tmp/"$dump".gz 2>&1);
				then					
					LogMsg "Error" "gzip DB: $db msg: $gzipOutput"
					rm /tmp/"$dump"
					/tmp/"$dump".gz
					continue
			fi
			rm /tmp/"$dump"
			dump="$dump".gz
		fi

  		LogMsg "Debug" "gzip completed"

		# encrypt the backup
  		AGE_Encrypt=$(echo "$AGE_Encrypt" | awk '{print tolower($0)}')		
  
		if [ "$AGE_Encrypt" = "true" ]; then
			if ! ageOutput=$(cat /tmp/"$dump" | age -a -r "$agePublicKey" >/tmp/"$dump".age 2>&1);
				then					
					LogMsg "Error" "age encyrption DB: $db msg: $ageOutput"
					rm /tmp/"$dump"
					rm /tmp/"$dump".age
					continue
			fi
			rm /tmp/"$dump"
			dump="$dump".age
		fi				

  		LogMsg "Debug" "Age encrypt completed"
    
		cdate=$(date -u)
		cyear=$(date --date="$cdate" +%Y)
		cmonth=$(date --date="$cdate" +%m)

  	        if [ "$CLOUD_UPLOAD" = "true" ]; 
			then
				if awsOutput=$(aws --no-verify-ssl  --only-show-errors --endpoint-url=$cloudS3URL s3 cp /tmp/$dump s3://$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$dump --profile cloud 2>&1); 
		  		      then
			  			LogMsg "Information" "Cloud Upload DB: $db Path:$cloudS3Bucket$cloudS3BucketPath/$cyear/$cmonth/$dump "
		                      else		                        	
						LogMsg "Error" "s3upload DB: $db msg: $awsOutput"
		                fi
		fi
    
	      if [ "$LOCAL_UPLOAD" = "true" ]; 
		then
		      if awsOutput=$(aws --no-verify-ssl --only-show-errors --endpoint-url=$localS3URL s3 cp /tmp/$dump s3://$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$dump --profile local 2>&1); 
			then
			 	 LogMsg "Information" "Local Upload DB: $db Path:$localS3Bucket$localS3BucketPath/$cyear/$cmonth/$dump"
			else			  	
      				LogMsg "Error" "Local Upload DB: $db msg: $awsOutput"
		      fi
	      fi		
		
		rm /tmp/"$dump"     

    done
}

function Main()
{    
    mkdir -p "$LOG_DIR"
    year=$(date +%Y)
    month=$(date +%m)

    podName=${POD_NAME:-$(hostname)} 
    nodeName=${NODE_NAME:-"unknown"}

    logFile="$LOG_DIR/${year}_${month}_${podName}.log"
    
    GetVaultItemsNSetS3Profiles
    local status=$?
    LogMsg "Debug" "GetVaultItemsNSetS3Profiles done status:$status"
    if [ "$status" != 0 ];
        then
            exit -1;            
            
    fi
    ListAllDBs
    status=$?
    LogMsg "Debug" "ListAllDBs done status:$status"
    if [ "$status" != 0 ];
        then            
            exit -1;
    fi
	
    BackupDBs
    status=$?
    LogMsg "Debug" "BackupDBs done status:$status"
    if [ "$status" != 0 ];
        then                        
            exit -1;
    fi	
}
Main
