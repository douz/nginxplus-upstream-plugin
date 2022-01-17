#!/bin/bash

set -e

#Give execution permissions to jq binary
chmod +x $RD_PLUGIN_BASE/jq

#Define authentication method
if [ "$RD_CONFIG_AUTHENTICATION_METHOD" = "password" ] ; then
     if [ -z $RD_CONFIG_USERNAME ] ; then
        echo "You need to specify a username for Authentication Method: $RD_CONFIG_AUTHENTICATION_METHOD"
        exit 1
    elif [ -z $RD_CONFIG_PASSWORD ] ; then
        echo "You need to specify a password for Authentication Method: $RD_CONFIG_AUTHENTICATION_METHOD"
        exit 1
    fi
    USE_PASSWORD=true
fi

#Define if backup url is provided
if [ -n $RD_CONFIG_BACKUP_API_URL ] ; then
    USE_BACKUP_URL=true
fi

#Force HTTPS
if [ "${RD_CONFIG_API_URL:0:7}" = "http://" ] ; then
     RD_CONFIG_API_URL="https://${RD_CONFIG_API_URL:7}"
fi
if [ "${RD_CONFIG_BACKUP_API_URL:0:7}" = "http://" ] ; then
     RD_CONFIG_BACKUP_API_URL="https://${RD_CONFIG_BACKUP_API_URL:7}"
fi

#Usage get_curl API_URL
get_curl () {
    METHOD="-X GET"
    HEADERS="-H \"accept: application/json\""
    RETRIES=3
    until [ "$RETRIES" = "0" ] ; do
        if [ "$USE_PASSWORD" = "true" ] ; then
            eval curl $METHOD $HEADERS --user $RD_CONFIG_USERNAME:$RD_CONFIG_PASSWORD --silent --insecure $1
        else
            eval curl $METHOD $HEADERS --silent --insecure $1
        fi

        #Retry if curl fail
        if [ "$?" = "0" ] ; then
            RETRIES=0
        else
            (( RETRIES -= 1 ))
            sleep 3s
        fi
    done
}

#Usage patch_curl PAYLOAD API_URL
#Make sure to scape single and double quotes inside PAYLOAD with a backslash "\"
patch_curl () {
    METHOD="-X PATCH"
    HEADERS="-H \"accept: application/json\""
    RETRIES=3
    until [ "$RETRIES" = "0" ] ; do
        if [ "$USE_PASSWORD" = "true" ] ; then
            eval curl $METHOD $HEADERS --data \'$1\' --user $RD_CONFIG_USERNAME:$RD_CONFIG_PASSWORD --silent --insecure $2
        else
            eval curl $METHOD $HEADERS --data \'$1\' --silent --insecure $2
        fi

        #Retry if curl fail
        if [ "$?" = "0" ] ; then
            RETRIES=0
        else
            (( RETRIES -= 1 ))
            sleep 3s
        fi
    done
}

#Usage get_server_state API_URL SERVER_IP
get_server_state () {
    echo "Getting current server state"

    SERVER_STATE=$(get_curl $1/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/ | $RD_PLUGIN_BASE/jq -r ".peers[] | select( .server | contains(\"$2\")) | .state")

    #Validate if server state request was successful
    if [ -z "$SERVER_STATE" ] ; then
        echo "Couldn't retreive current server state"
        exit 1
    fi

    echo "SERVER_STATE=$SERVER_STATE"
}

#Usage put_server_down SERVER_IP
put_server_down () {
    SERVER_ID=$(get_curl $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/ | $RD_PLUGIN_BASE/jq -r ".peers[] | select( .server | contains(\"$1\")) | .id")
    PAYLOAD="{\"down\":true}"

    echo "Setting $1 down from upstream $RD_CONFIG_UPSTREAM"

    if [ "$USE_BACKUP_URL" = "true" ] ; then
        patch_curl $PAYLOAD $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
        patch_curl $PAYLOAD $RD_CONFIG_BACKUP_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
    else
        patch_curl $PAYLOAD $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
    fi

    #Validate if down request was successful
    sleep 3s #Waiting 3 seconds before getting server state
    NEW_SERVER_STATE=$(get_server_state $RD_CONFIG_API_URL $1 | tail -1 | awk -F "=" '{print $2}')
    if [ "$NEW_SERVER_STATE" != "down" ] ; then
        echo "Down request for server $1 failed"
        exit 1
    else
        echo "$1 is down from upstream $RD_CONFIG_UPSTREAM"
    fi
}

#Usage put_server_up SERVER_IP
put_server_up () {
    SERVER_ID=$(get_curl $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/ | $RD_PLUGIN_BASE/jq -r ".peers[] | select( .server | contains(\"$1\")) | .id")
    PAYLOAD="{\"down\":false}"
    echo "Restoring initial state of $1 in upstream $RD_CONFIG_UPSTREAM"

    if [ "$USE_BACKUP_URL" = "true" ] ; then
        patch_curl $PAYLOAD $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
        patch_curl $PAYLOAD $RD_CONFIG_BACKUP_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
    else
        patch_curl $PAYLOAD $RD_CONFIG_API_URL/api/3/http/upstreams/$RD_CONFIG_UPSTREAM/servers/$SERVER_ID | $RD_PLUGIN_BASE/jq -r "."
    fi

    #Validate if up request was successful
    sleep 3s #Waiting 3 seconds before getting server state
    NEW_SERVER_STATE=$(get_server_state $RD_CONFIG_API_URL $1 | tail -1 | awk -F "=" '{print $2}')
    if [ "$NEW_SERVER_STATE" != "up" ] ; then
        echo "Restore state request for server $1 failed"
        exit 1
    else
        echo "Server state is \"$NEW_SERVER_STATE\""
    fi
}
