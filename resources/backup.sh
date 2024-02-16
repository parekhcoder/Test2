# !/bin/bash
. /logging.sh
isSuccess=true

function LogNExit()
{
    local status=0
    if [ "$isSuccess" != true ];
        then            
            status=1
    fi   
    
    PushLog

    exit "$status"
}

function ListAllDBs()
{
	if [ "$TARGET_ALL_DATABASES" = "true" ]; 
	
		then
    
			if [ ! -z "$TARGET_DATABASE_NAMES" ];
				then        
					AddLog "TARGET_ALL_DATABASES is true and TARGET_DATABASE_NAMES isn't empty, ignoring TARGET_DATABASE_NAMES" "D"
					TARGET_DATABASE_NAMES=""
			fi
		
			dbExclusionList="'mysql','sys','tmp','information_schema','performance_schema'"
			dbSQLCmd="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${dbExclusionList})"
			
			if ! dbList=`mysql -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT -ANe"${dbSQLCmd}"`
				then        
					AddLog "Error: Building list of all databases failed" "E"
					isSuccess=false
					return -1
			fi
			
			TARGET_DATABASE_NAMES=$dbList        
			
			AddLog "Built list of all databases (${TARGET_DATABASE_NAMES})" "D"    		
	
			
	fi			
	
}

function BackupDBs()
{
	for db in ${TARGET_DATABASE_NAMES} 
    do
        
        dump=$db$(date +$BACKUP_TIMESTAMP).sql        
        
        if ! sqlOutput=$(mysqldump -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT $BACKUP_ADDITIONAL_PARAMS $BACKUP_CREATE_DATABASE_STATEMENT $CURRENT_DATABASE 2>&1 >/tmp/$dump); then
			AddLog "Error: failed DB: $db msg: $sqloutput" "E"
			isSuccess=false
			continue
		fi            
            
		AddLog "Success: DB backup $db" "D"		
		
		BACKUP_COMPRESS=$(echo "$BACKUP_COMPRESS" | awk '{print tolower($0)}')
		
		if [ "$BACKUP_COMPRESS" = true ]; then
			if [ -z "$BACKUP_COMPRESS_LEVEL" ]; then
				BACKUP_COMPRESS_LEVEL="9"
			fi
			if ! gzipOutput=$(gzip -${BACKUP_COMPRESS_LEVEL} -c /tmp/"$dump" >/tmp/"$dump".gz 2>&1);
				then
					isSuccess=false
					AddLog "Error: gzip DB: $db msg: $gzipOutput" "E"
					rm /tmp/"$dump"
					/tmp/"$dump".gz
					continue
			fi
			rm /tmp/"$dump"
			dump="$dump".gz
		fi

		# encrypt the backup
		if [ -n "$AGE_PUBLIC_KEY" ]; then
			if ! ageOutput=$(cat /tmp/"$dump" | age -a -r "$AGE_PUBLIC_KEY" >/tmp/"$dump".age 2>&1);
				then
					isSuccess=false
					AddLog "Error: age encyrption DB: $db msg: $ageOutput" "E"
					rm /tmp/"$dump"
					rm /tmp/"$dump".age
					continue
			fi
			rm /tmp/"$dump"
			dump="$dump".age
		fi		
		
		if [ ! -z "$AWS_S3_ENDPOINT" ]; then
			endpoint="--endpoint-url=$AWS_S3_ENDPOINT"
		fi
		
		cdate=$(date -u)
		cyear=$(date --date="$cdate" +%Y)
		cmonth=$(date --date="$cdate" +%m)
		
		if ! awsOutput=$(aws $endpoint s3 cp /tmp/$dump s3://$AWS_BUCKET_NAME$AWS_BUCKET_BACKUP_PATH/$cyear/$cmonth/$dump 2>&1); 
			then
				AddLog "Success: s3upload DB: $db" "I"
			else
				isSuccess=false
				AddLog "Error: s3upload DB: $db msg: $awsOutput"			
		fi
		PushLog
		rm /tmp/"$dump"     

    done
}

function Main()
{
	ListAllDBs
	local status=$?
    AddLog "ListAllDBs done status:$status" "D"
    if [ "$status" != 0 ];
        then
            isSucess=false            
            LogNExit
    fi
	
	BackupDBs
	local status=$?
    AddLog "BackupDBs done status:$status" "D"
    if [ "$status" != 0 ];
        then
            isSucess=false            
            LogNExit
    fi
	PushLog
}
Main
