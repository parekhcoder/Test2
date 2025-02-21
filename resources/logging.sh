# !/bin/bash

function InitializeLog
{
    logJSON='{"Events":[]}'
}

function AddLog
{
    if [ -z "$logJSON" ];
        then
            logJSON='{"Events":[]}'
    fi
    cdate=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    logMsg=$1
    logLevel=$2
 
    case $logLevel in

    D)
        logLevel="Debug"
    ;;

    E)
        logLevel="Error"
    ;;

    I)
        logLevel="Information"
    ;;

    W)
        logLevel="Warning"
    ;;

    *)
        logLevel="Information"
    ;;
    esac  
    
    log=$(sed -e "s/##T##/$cdate/g;s/##level##/$logLevel/g" <<< $LOGFMT)   
    logMsg=$(echo $logMsg|tr -d '\n')
    logMsgCopy=$logMsg
    if ! logMsg=$(jq '@json' <<< $logMsg 2>&1); then          
   
          logMsg=$(jq -R <<< $logMsgCopy)
    fi
   
    log=$(jq --arg logMsg "$logMsg" ".\"@mt\" = $logMsg" <<< $log)        
    echo "log: $log"
    #logJSON=$(jq ".Events[.Events | length] |= . + $log" <<< $logJSON)        
}
