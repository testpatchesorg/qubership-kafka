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
  kcat_ready_check
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
