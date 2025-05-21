#!/usr/bin/env bash

if $(grep -q "Completed migration of metadata from ZooKeeper to KRaft." "${KAFKA_LOG_DIRS}/migration.log"); then
    echo "true"
else
    echo "false"
fi