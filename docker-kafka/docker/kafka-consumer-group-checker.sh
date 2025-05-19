#!/usr/bin/env bash

check_groups() {
  local need_to_delete=$1
  local group_names=($(kafkactl list consumer-groups | tail -n +2))

  local failed_groups=()
  local deleted_groups=()
  for group_name in "${group_names[@]}"; do
      echo "Check group_name: $group_name"
      kafkactl describe consumer-group "$group_name" 1> /dev/null
      if [[ $? -ne 0 ]]; then
        echo "Active members of group ${group_name}:"
        ./bin/kafka-consumer-groups.sh --bootstrap-server localhost:9093 --command-config bin/adminclient.properties --describe --members --group $group_name
        if [[ $need_to_delete == "true" ]]; then
          echo "Error: failed to get info from group $group_name. Trying to delete it"
          kafkactl delete consumer-group "$group_name"
          if [[ $? -ne 0 ]]; then
            echo "Error: failed to delete group $group_name. Please stop all consumers and try again or create necessary topics"
            failed_groups+=("${group_name}")
          else
            deleted_groups+=("${group_name}")
          fi
        else
          echo "Error: failed to get info from group $group_name. Please fix it"
          failed_groups+=("${group_name}")
        fi
      fi
  done

  echo "Failed groups: ${failed_groups[*]}"
  echo "Deleted groups: ${deleted_groups[*]}"
}

case $1 in
  check)
    shift
    check_groups
    exit $?
    ;;
  delete)
    shift
    check_groups true
    exit $?
    ;;
  *)
    shift
    check_groups
    exit $?
    ;;
esac