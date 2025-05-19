#!/usr/bin/env bash

#exec 2>>"kafka-health.log"
if [[ "$DEBUG" == true ]]; then
  set -x
fi

create_topic() {
  # Create topic with a single partition and replica assigned to the BROKER_ID for guarantee
  # that read/write operation will be applied on current node
  ${KAFKA_HOME}/bin/kafka-topics.sh \
    --bootstrap-server "localhost:9093" \
    --command-config ${KAFKA_HOME}/bin/adminclient.properties \
    --create \
    --topic "$TOPIC_NAME" \
    --replica-assignment "$BROKER_ID" \
    --config min.insync.replicas=1 \
    --config retention.ms=300000 \
    --config segment.ms=300000 \
    --config cleanup.policy=delete
}

assign_topic_to_node() {
  ${KAFKA_HOME}/bin/kafka-topics.sh \
    --bootstrap-server "localhost:9093" \
    --command-config ${KAFKA_HOME}/bin/adminclient.properties \
    --describe \
    --topic "$TOPIC_NAME" | grep "Leader: $BROKER_ID"
  if [[ $? -ne 0 ]]; then
    echo "{\"partitions\": [{\"topic\": \"$TOPIC_NAME\", \"partition\": 0,\"replicas\":[$BROKER_ID]}]}" > health-topic-reassigment.json
    ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
      --bootstrap-server "localhost:9093" \
      --command-config ${KAFKA_HOME}/bin/adminclient.properties \
      --reassignment-json-file health-topic-reassigment.json \
      --execute
    if [[ $? -ne 0 ]]; then
      echo "Unable to reassign health topic $TOPIC_NAME to broker $BROKER_ID"
      return 1
    fi
    # Wait until reassignment completed
    while true; do
      ${KAFKA_HOME}/bin/kafka-reassign-partitions.sh \
        --bootstrap-server "localhost:9093" \
        --command-config ${KAFKA_HOME}/bin/adminclient.properties \
        --reassignment-json-file health-topic-reassigment.json \
        --verify > health_reassignment_status.log
      if [[ $? -ne 0 ]]; then
        echo "Health partition reassignment failed"
        cat health_reassignment_status.log
        return 1
      fi
      # Check that reassign completed, sometimes kafka during create topic assign it to not alive node
      # as a result reassignment can be failed we not retry it again, because leader not not alive
      # instead we will try write some data to this node, and report controller about not alive node
      cat health_reassignment_status.log | grep -oE "^Reassignment of partition $TOPIC_NAME-0 (completed successfully)|(failed)$" > /dev/null
      if [[ $? -ne 0 ]]; then
        sleep 1s
      else
        break
      fi
    done
    ${KAFKA_HOME}/bin/kafka-leader-election.sh \
    --bootstrap-server "localhost:9093" \
    --admin.config ${KAFKA_HOME}/bin/adminclient.properties \
    --all-topic-partitions \
    --election-type preferred
  fi
}

need_to_start_health_check_server() {
  local is_process_present=$(ps aux | grep "/kafka-assistant -c health" | grep ${TOPIC_NAME})
  if [[ -z "${is_process_present}" ]]; then
    return 0
  fi
  return 1
}

start_health_check_server() {
  create_topic
  assign_topic_to_node
  if [[ "$DISABLE_SECURITY" == "false" ]]; then
    nohup /kafka-assistant -c health -b localhost:9093 -t ${TOPIC_NAME} \
      -u ${CLIENT_USERNAME} -p ${CLIENT_PASSWORD} \
      -ct ${READINESS_PERIOD} \
      -timeout ${READINESS_PERIOD_MILLI} &> output_health_check.log &
  else
    nohup /kafka-assistant -c health -b localhost:9093 -t ${TOPIC_NAME} \
      -ct ${READINESS_PERIOD} \
      -timeout ${READINESS_PERIOD_MILLI} &> output_health_check.log &
  fi
  while true; do
    curl -X GET "http://localhost:8081/" 2>server_errors.log
    cat server_errors.log | grep -o "Failed to connect to localhost port 8081"
    if [[ $? -eq 0 ]]; then
      sleep 1s
    else
      echo "" > server_errors.log
      break
    fi
  done
}

# Health check via producing and consuming by Go Kafka client.
# Server with producer and consumer starts and serve requests to produce and consume.
go_ready_check() {
  READINESS_PERIOD_MILLI=$(( ${READINESS_PERIOD} * 1000 / 2 ))
  TOPIC_NAME="kafka-health-broker-$BROKER_ID"
  if need_to_start_health_check_server; then
    start_health_check_server
  fi
  local timestamp=$(date +%s%N)
  local url="http://localhost:8081/healthcheck?message=$timestamp"
  local response=$(curl -s -X GET -H "Accept:application/json" -H "Content-Type:application/json" "$url")
  local status=$(echo "$response" | jq -r ".status")
  if [[ "$status" == "OK" ]]; then
    echo "Success"
    return 0
  else
    echo "Failure, response: [$response]"
    return 1
  fi
}

# Health check via kcat cluster metadata request
kcat_ready_check() {
  if [[ -z "$HEALTH_CHECK_TIMEOUT" ]]; then
    HEALTH_CHECK_TIMEOUT=30
    echo "WARNING: Using default HEALTH_CHECK_TIMEOUT=30."
  fi
  broker_info=$(kcat -L -J -b localhost:9093 -F ${KAFKA_HOME}/bin/kcat.properties -m ${HEALTH_CHECK_TIMEOUT} | jq '.brokers[].id' | grep ${BROKER_ID})
  code=$?
  if [[ ${code} -ne 0 ]]; then
    echo "Failure, kcat is not accessible, status code: [${code}]"
    return 1
  fi
  if [[ "${broker_info}" == "${BROKER_ID}" ]]; then
    echo "Success"
    return 0
  else
    echo "Failure, broker_info=[${broker_info}], BROKER_ID=[${BROKER_ID}]"
    return 1
  fi
}

ready_check() {
  if [[ "$HEALTH_CHECK_TYPE" == "consumer_producer" ]]; then
    go_ready_check
  else
    kcat_ready_check
  fi
}

# Check that port is open
live_check() {
  nc -z -w10 localhost 9092
  if [[ $? -ne 0 ]]; then
    echo "Kafka public port closed"
    return 1
  fi
  if [[ -f ${KAFKA_HOME}/logs/errors.log ]]; then
    cat ${KAFKA_HOME}/logs/errors.log | grep "a fault occurred in a recent unsafe memory access operation in compiled Java code"
    if [[ $? -eq 0 ]]; then
      echo "Found unsafe memory access error, Kafka broker is not fully operated"
      return 1
    fi
  fi
}

case $1 in
  live)
    live_check
    exit $?
    ;;
  ready)
    ready_check
    exit $?
    ;;
esac

live_check
