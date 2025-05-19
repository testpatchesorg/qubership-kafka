# Copyright 2024-2025 NetCracker Technology Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from kafka import KafkaConsumer, KafkaProducer

# Kafka configuration
kafka_server = 'localhost:9094'  # Change this to your Kafka server address
sasl_plain_username = ''  # SASL username
sasl_plain_password = ''  # SASL password
kafka_topic = "test"

# Create a Kafka consumer without subscribing to any topic
consumer = KafkaConsumer(kafka_topic,
                         bootstrap_servers=kafka_server,
                         security_protocol='PLAINTEXT',
                         auto_offset_reset='earliest',
                         consumer_timeout_ms=1000
                         # sasl_mechanism='SCRAM-SHA-512',
                         # sasl_plain_username=sasl_plain_username,
                         # sasl_plain_password=sasl_plain_password,

                         )

# Create a Kafka producer without subscribing to any topic
producer = KafkaProducer(bootstrap_servers=kafka_server,
                         security_protocol='PLAINTEXT',
                         # sasl_mechanism='SCRAM-SHA-512',
                         # sasl_plain_username=sasl_plain_username,
                         # sasl_plain_password=sasl_plain_password,
                         )


# Retrieve and print the list of topics
topics = consumer.topics()
print(f"List of topics: {topics}")

print("Producer test")
future = producer.send('test', key=b'key', value=b'value')
record_metadata = future.get(timeout=10)
# Successful result returns assigned partition and offset
print(record_metadata)

print("Consumer test")
for message in consumer:
  # message value and key are raw bytes -- decode if necessary!
  # e.g., for unicode: `message.value.decode('utf-8')`
  print ("%s:%d:%d: key=%s value=%s" % (message.topic, message.partition,
                                        message.offset, message.key,
                                        message.value))

# Don't forget to close the consumer
consumer.close()
