#!/bin/bash

# Default retention in hours
DEFAULT_RETENTION=24
DEFAULT_MAX_PARTITIONS=10

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        --list)
            LIST=1
            shift
            ;;
        --max-partitions)
            MAX_PARTITIONS="$2"
            shift
            ;;
        --delete)
            DELETE=1
            shift
            ;;
        --topic)
            TOPIC="$2"
            shift
            ;;
        --partition)
            PARTITION="$2"
            shift
            ;;
        --all)
            ALL=1
            shift
            ;;
        --help)
            HELP=1
            shift
            ;;
        --retention)
            RETENTION="$2"
            shift
            ;;
        *) # unknown option
            UNKNOWN="$1"
            shift
            ;;
    esac
done

LOG_DIR=("$KAFKA_DATA_DIRS/${BROKER_ID}")

# List most heavy topics by partitions
if [[ -n "$LIST" ]]; then
    if [[ -z "$MAX_PARTITIONS" ]]; then
        MAX_PARTITIONS="$DEFAULT_MAX_PARTITIONS"
    fi
    cd "$LOG_DIR"
    if [[ "$MAX_PARTITIONS" -eq -1 ]]; then
        du -hsx * | sort -rh
    else
        du -hsx * | sort -rh | head -$MAX_PARTITIONS
    fi
elif [[ -n "$DELETE" ]]; then
    # Determine retention in hours
    if [[ -z "$RETENTION" ]]; then
        if [[ -n "$CONF_KAFKA_LOG_RETENTION_HOURS" ]]; then
            RETENTION="$CONF_KAFKA_LOG_RETENTION_HOURS"
        else
            RETENTION="$DEFAULT_RETENTION"
        fi
    fi

    if [[ -n "$ALL" ]]; then
        PARTITIONS=$(ls "$LOG_DIR")
    elif [[ -n "$TOPIC" && -n "$PARTITION" ]]; then
        PARTITIONS=$(ls "$LOG_DIR" | grep -w "$TOPIC-$PARTITION")
    elif [[ -n "$TOPIC" ]]; then
        PARTITIONS=$(ls "$LOG_DIR" | grep -w "$TOPIC")
    else
        echo "No topic specified."
        exit 1
    fi

    # Clean logs
    for PARTITION in $PARTITIONS; do
        SEGMENTS=$(ls -1t "$LOG_DIR/$PARTITION" | grep -E '\.log$')
        LOG_ARRAY=($SEGMENTS)
        if [[ "${#LOG_ARRAY[@]}" -eq "1" ]]; then
            continue;
        fi
        for SEGMENT in $SEGMENTS; do
            LAST_MODIFIED=$(stat -c %Y "$LOG_DIR/$PARTITION/$SEGMENT")
            ELAPSED=$(( $(date +%s) - LAST_MODIFIED ))
            if [[ $ELAPSED -gt $(( $RETENTION * 3600 )) ]]; then
                SEGMENT_NAME=$(echo $SEGMENT | grep -oP '.*?(?=\.)')
                SEGMENT_PARTS=$(ls -1t "$LOG_DIR/$PARTITION" | grep -E '\.index$|\.timeindex$|\.snapshot$' | grep -w "$SEGMENT_NAME")
                for SEGMENT_PART in $SEGMENT_PARTS; do
                    rm -f "$LOG_DIR/$PARTITION/$SEGMENT_PART"
                done
                rm -f "$LOG_DIR/$PARTITION/$SEGMENT"
            fi
        done
    done
elif [[ -n "$HELP" ]]; then
    echo "This script is used to list/delete data from topics/partitions."
    echo ""
    echo "List command:"
    echo "--list             command lists the heaviest partitions in descending order."
    echo "--max-partitions   parameter specifies the number of listed partitions. Parameter is optional, default value is 10. To list all partitions use -1 value"
    echo ""
    echo "Delete command:"
    echo "--delete           command deletes data from topic/partition by retention."
    echo "--topic            parameter specifies topic which partitions should be cleaned by retention."
    echo "--partition        parameter specifies partition number for appropriate topic to be cleaned. Parameter can only be used with --topic parameter."
    echo "--all              parameter is used to clean all topics."
    echo "--retention        parameter specifies retention time in hours after which logs can be deleted. Parameter is optional."
    echo ""
    echo "Examples:"
    echo ""
    echo "List top 5 largest partitions:"
    echo "./bin/kafka-partition-logs.sh --list --max-partitions 5"
    echo ""
    echo "Clean logs from test_topic in particular partition 4 which were updated more than 48 hours ago:"
    echo "./bin/kafka-partition-logs.sh --delete --topic test_topic --partition 4 --retention 48"
else
    echo "error: unknown command $UNKNOWN"
    echo "use --help to see appropriate commands and parameters"
    exit 1
fi
