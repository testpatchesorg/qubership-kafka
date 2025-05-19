#!/bin/bash

if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Args:
# $1 - input items for filtering separated by line breaks
# $2 - item to exclude
filter() {
  local old_ifs=$IFS
  IFS=' '
  for item in $($1 | tr '\n' ' '); do
    if [[ "$item" != "$2" ]]; then
      echo "$item"
    fi
  done
  IFS=${old_ifs}
}

get_metadata_list() {
  kcat -L -J -b localhost:9093 -F ${KAFKA_HOME}/bin/kcat.properties -m 30 | tail -n 1
}

# Args:
# $1 - metadata list. default - get_metadata_list function execution
get_brokers() {
  local metadata_list=${1:-$(get_metadata_list)}
  echo "$metadata_list" | jq -r ".brokers[].id" | sort
}

get_topics_for_broker_releasing() {
  local topics=$(get_metadata_list | jq -r ".topics[].topic")
  local old_ifs=$IFS
  IFS=' '
  for topic in $(echo "$topics" | tr '\n' ' '); do
    if [[ "$topic" != kafka-health-broker-* ]]; then
      echo "$topic"
    fi
  done
  IFS=${old_ifs}
}

# Args:
# $1 - metadata list. default - get_metadata_list function execution
# $2 - replication factor
get_topics_for_partition_rebalancing() {
  local metadata_list=${1:-$(get_metadata_list)}
  local replication_factor=${2:-$REPLICATION_FACTOR}
  local topics=$(echo "$metadata_list" | \
    jq -r ".topics[] | select((.partitions[0].replicas | length) < $replication_factor) | .topic")
  local old_ifs=$IFS
  IFS=' '
  for topic in $(echo "$topics" | tr '\n' ' '); do
    if [[ "$topic" != kafka-health-broker-* ]]; then
      echo "$topic"
    fi
  done
  IFS=${old_ifs}
}

# Args:
# $1 - metadata list. default - get_metadata_list function execution
get_topics_for_leader_rebalancing() {
  local metadata_list=${1:-$(get_metadata_list)}
  local topics=$(echo "$metadata_list" |
    jq -r ".topics[] | .topic")
  local old_ifs=$IFS
  IFS=' '
  for topic in $(echo "$topics" | tr '\n' ' '); do
    if [[ "$topic" != kafka-health-broker-* ]]; then
      echo "$topic"
    fi
  done
  IFS=${old_ifs}
}

generate_topics_to_update_list() {
  echo "$1" | tr '\n' ' ' | head -c -1 | \
    jq -R 'split(" ") | reduce .[] as $topic ([]; . + [{"topic": $topic }]) | {"topics": . , "version": 1}' > topics_to_update_list.json
}

# Args:
# $1 - broker list
# $2 - file name for reassignment json file
# $3 - replication factor
generate_replication_factor_update_plan() {
  local replication_factor=${3:-$REPLICATION_FACTOR}
  local replicas=$(seq --separator=, 1 1 ${replication_factor})
  ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
    --bootstrap-server "localhost:9093" \
    --command-config ${KAFKA_HOME}/bin/adminclient.properties \
    --topics-to-move-json-file topics_to_update_list.json \
    --broker-list "$1" \
    --generate | tail -n 1 | jq ".partitions[].replicas |= [$replicas]" | jq ".partitions[].log_dirs |= ([$replicas] | map(\"any\"))" > "$2"

  if [[ $? -ne 0 ]]; then
    echo "Failed generating reassignment"
    return 1
  fi

  remove_dead_partitions_from_reassign_plan $2
}

# Args:
# $1 - broker list
# $2 - file name for reassignment json file
generate_rebalance_update_plan() {
  ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
    --bootstrap-server "localhost:9093" \
    --command-config ${KAFKA_HOME}/bin/adminclient.properties \
    --topics-to-move-json-file topics_to_update_list.json \
    --broker-list "$1" \
    --generate | tail -n 1 > "$2"

  if [[ $? -ne 0 ]]; then
    echo "Failed generating reassignment"
    return 1
  fi

  remove_dead_partitions_from_reassign_plan $2
}

#Remove dead partitions from reassign, because if leader will not available or count in-sync replicas
#too small reassignment can stuck
remove_dead_partitions_from_reassign_plan() {
  while IFS= read -r line; do
    local topic=$(echo "$line" | cut -d";" -f1)
    local partition=$(echo "$line" | cut -d";" -f2)
    cat "$1" | jq -c "del(.partitions[] | select((.topic==\"$topic\") and (.partition==$partition)))" > "$1.temp"
    mv "$1.temp" "$1"
  done < <( \
    ${KAFKA_HOME}/bin/kafka-topics.sh \
      --bootstrap-server "localhost:9093" \
      --command-config ${KAFKA_HOME}/bin/adminclient.properties \
      --describe \
      --unavailable-partitions | \
    sed -e 's/.*Topic: \(\S*\).*Partition: \(\S*\).*/\1;\2/p' | sort | uniq)
}
# Args:
# $1 - reassignment file name. default - topic_reassignment.json
# $2 - timeout in seconds. default - 0 (no timeout)
wait_complete_reassignment() {
  local reassignment_file=${1:-topic_reassignment.json}
  local timeout=${2:-0}

  local start_time=$SECONDS
  local spent_time=0

  while [[ ${spent_time} -le ${timeout} ]] || [[ ${timeout} -eq 0 ]]; do

    ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
      --bootstrap-server "localhost:9093" \
      --command-config ${KAFKA_HOME}/bin/adminclient.properties \
      --reassignment-json-file "$reassignment_file" \
      --verify > "$reassignment_file.verify.status"

    if [[ $? -ne 0 ]]; then
      echo "Partition reassignment failed"
      cat "$reassignment_file.verify.status"
      return 1
    fi

    spent_time=$(( SECONDS - start_time ))

    if cat "$reassignment_file.verify.status" | grep "^Reassignment of partition .* is still in progress$" > /dev/null; then
      sleep 1s
    else
      break
    fi
  done

  if [[ ${spent_time} -ge ${timeout} ]] && [[ ${timeout} -ne 0 ]]; then
    echo "Timeout occurs during wait complete reassignment, spend time $spent_time seconds"
    cat "$reassignment_file"
    return 1
  else
    echo "Partition reassignment completed"
    echo "Was spend $spent_time seconds on partition reassignment"
    cat "$reassignment_file"
    cat "$reassignment_file.verify.status"
    return 0
  fi
}

# Args:
# $1 - reassignment file name. default - topic_reassignment.json
perform_reassignment() {
  local reassignment_file=${1:-topic_reassignment.json}

  ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
    --bootstrap-server "localhost:9093" \
    --command-config ${KAFKA_HOME}/bin/adminclient.properties \
    --reassignment-json-file "$reassignment_file" \
    --execute > "$reassignment_file.execute.status"
  if [[ $? -ne 0 ]]; then
    echo "Partition reassignment failed"
    cat "$reassignment_file"
    cat "$reassignment_file.execute.status"
    return 1
  fi

  if cat "$reassignment_file.execute.status" | grep "Successfully started reassignment of partitions." > /dev/null; then
    :
  else
    echo "Partition reassignment failed"
    cat "$reassignment_file"
    cat "$reassignment_file.execute.status"
    return 1
  fi
}

# Updates replication factor of all topics (except special broker-specific health-check topics) to the number of brokers
# Args:
# $1 - reassignment file name. default - topic_reassignment.json
# $2 - timeout in seconds. default - 0 (no timeout)
update_replication_factor() {
  local reassignment_file=${1:-topic_reassignment.json}
  local timeout=${2:-0}

  local metadata_list=$(get_metadata_list)
  local topics=$(get_topics_for_partition_rebalancing "$metadata_list")
  if [[ -n "$topics" ]]; then
    local broker_list=$(get_brokers "$metadata_list" | tr '\n' ',' | head -c -1)
    generate_topics_to_update_list "$topics"
    generate_replication_factor_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"

    #Allow Kafka to prepare correct assignment plan for replicas and run reassign again to reach balanced leader assignment
    generate_rebalance_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"
  fi
}

# Updates replication factor of given topic to the number of brokers
# Args:
# $1 - name of topic for which partitions should be updated
# $2 - reassignment file name. default - topic_reassignment.json
# $3 - timeout in seconds. default - 0 (no timeout)
update_replication_factor_for_topic() {
  local topic=${1}
  local reassignment_file=${2:-topic_reassignment.json}
  local timeout=${3:-0}

  if [[ -n "$topic" ]]; then
    local broker_list=$(get_brokers | tr '\n' ',' | head -c -1)
    generate_topics_to_update_list "$topic"
    generate_replication_factor_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"

    #Allow Kafka to prepare correct assignment plan for replicas and run reassign again to reach balanced leader assignment
    generate_rebalance_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"
  fi
}

# Allow Kafka to prepare correct assignment plan for replicas and run reassign to reach balanced leader assignment
# Args:
# $1 - reassignment file name. default - topic_reassignment.json
# $2 - timeout in seconds. default - 0 (no timeout)
rebalance_leaders() {
  local reassignment_file=${1:-topic_reassignment.json}
  local timeout=${2:-0}

  local metadata_list=$(get_metadata_list)
  local topics=$(get_topics_for_leader_rebalancing "$metadata_list")
  if [[ -n "$topics" ]]; then
    local broker_list=$(get_brokers "$metadata_list" | tr '\n' ',' | head -c -1)
    generate_topics_to_update_list "$topics"
    generate_rebalance_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"
  fi
}

# Allow Kafka to prepare correct assignment plan for replicas and run reassign to reach balanced leader assignment
# Args:
# $1 - name of topic for which partitions should be updated
# $2 - reassignment file name. default - topic_reassignment.json
# $3 - timeout in seconds. default - 0 (no timeout)
rebalance_leaders_for_topic() {
  local topic=${1}
  local reassignment_file=${2:-topic_reassignment.json}
  local timeout=${3:-0}

  if [[ -n "$topic" ]]; then
    local broker_list=$(get_brokers | tr '\n' ',' | head -c -1)
    generate_topics_to_update_list "$topic"
    generate_rebalance_update_plan "$broker_list" "$reassignment_file"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"
  fi
}

# Performs topic partitions reassignment to remove all partitions from specified broker
# Args:
# $1 - id of broker from which partitions should be removed
# $2 - reassignment file name. default - topic_reassignment.json
# $3 - timeout in seconds. default - 0 (no timeout)
prepare_broker_decommission() {
  local reassignment_file=${2:-topic_reassignment.json}
  local timeout=${3:-0}

  local topics=$(get_topics_for_broker_releasing)
  if [[ -n "$topics" ]]; then
    generate_topics_to_update_list "$topics"
    generate_rebalance_update_plan "$(filter get_brokers $1 | tr '\n' ',' | head -c -1)" "topic_reassignment.json"
    perform_reassignment "$reassignment_file"
    wait_complete_reassignment "$reassignment_file" "$timeout"
  fi
}

case $1 in
  get_topics)
    shift
    get_topics_for_partition_rebalancing "$@"
    exit $?
    ;;
  rebalance)
    shift
    update_replication_factor "$@"
    exit $?
    ;;
  rebalance_topic)
    shift
    update_replication_factor_for_topic "$@"
    exit $?
    ;;
  rebalance_leaders)
    shift
    rebalance_leaders "$@"
    exit $?
    ;;
  rebalance_leaders_topic)
    shift
    rebalance_leaders_for_topic "$@"
    exit $?
    ;;
  release_broker)
    shift
    prepare_broker_decommission "$@"
    exit $?
    ;;
esac