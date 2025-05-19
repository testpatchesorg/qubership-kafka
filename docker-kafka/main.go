// Copyright 2024-2025 NetCracker Technology Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"github.com/confluentinc/confluent-kafka-go/kafka"
	"github.com/gorilla/handlers"
	"github.com/gorilla/mux"
	"golang.org/x/sync/errgroup"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var (
	command         = flag.String("c", "", "The command to run Kafka assistant application (health - to perform health check)")
	broker          = flag.String("b", "", "Used Kafka broker")
	topic           = flag.String("t", "", "Topic to check health")
	saslUsername    = flag.String("u", "", "Username to be used when connecting to Kafka")
	saslPassword    = flag.String("p", "", "Password to be used when connecting to Kafka")
	consumerTimeout = flag.Int("ct", 10000, "Client group session and failure detection timeout in ms")
	timeout         = flag.Int("timeout", 2000, "Timeout in milliseconds")

	verbose          = getEnv("DEBUG", "false")
	sslEnabled       = getBoolEnv("ENABLE_SSL", "false")
	twoWaySslEnabled = getBoolEnv("ENABLE_2WAY_SSL", "false")
	g                errgroup.Group
)

func getEnv(key, defaultValue string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return defaultValue
}

func getBoolEnv(key string, defaultValue string) bool {
	return strings.ToLower(getEnv(key, defaultValue)) == "true"
}

type HealthCheckContext struct {
	Producer kafka.Producer
	Consumer kafka.Consumer
}

type Health struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

type State struct {
	Status string `json:"status"`
}

func main() {
	flag.Parse()

	if *command == "health" {
		healthCheckContext := createContext()

		defer func() {
			healthCheckContext.Producer.Close()
			healthCheckContext.Consumer.Close()
		}()

		server := &http.Server{
			Addr:    ":8081",
			Handler: healthCheckHandlers(&healthCheckContext),
		}

		g.Go(func() error {
			return server.ListenAndServe()
		})

		if err := g.Wait(); err != nil {
			log.Fatal(err)
		}
	}
}

func createContext() HealthCheckContext {
	if *broker == "" || *topic == "" {
		fmt.Fprintf(os.Stderr, "Incorrect input parameters: broker->'%s', topic->'%s'\n", *broker, *topic)
		os.Exit(1)
	}

	producerConfigMap := kafka.ConfigMap{
		"bootstrap.servers": *broker,
	}
	enrichConfigMapWithSecurityConfigs(producerConfigMap)
	producer, err := kafka.NewProducer(&producerConfigMap)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create producer: %s\n", err)
		os.Exit(1)
	}
	fmt.Printf("Producer is created: %v\n", producer)

	sessionTimeout := *consumerTimeout * 1000
	heartbeatInterval := *consumerTimeout * 1000 / 3

	consumerConfigMap := kafka.ConfigMap{
		"bootstrap.servers":        *broker,
		"group.id":                 *topic,
		"auto.offset.reset":        "earliest",
		"session.timeout.ms":       sessionTimeout,
		"heartbeat.interval.ms":    heartbeatInterval,
		"allow.auto.create.topics": "false",
		// similar option should be enabled for producer, when it is implemented:
		// https://cwiki.apache.org/confluence/display/KAFKA/KIP-487%3A+Client-side+Automatic+Topic+Creation+on+Producer
	}
	log.Println("Consumer configuration - ", consumerConfigMap)
	enrichConfigMapWithSecurityConfigs(consumerConfigMap)
	consumer, err := kafka.NewConsumer(&consumerConfigMap)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create consumer: %s\n", err)
		os.Exit(1)
	}
	fmt.Printf("Consumer is created: %v\n", consumer)

	consumer.SubscribeTopics([]string{*topic}, nil)

	return HealthCheckContext{
		Producer: *producer,
		Consumer: *consumer,
	}
}

// Resolve security protocol.
func resolveSecurityProtocol(securityProtocolWithoutSsl string, securityProtocolWithSsl string) string {
	if sslEnabled {
		return securityProtocolWithSsl
	} else {
		return securityProtocolWithoutSsl
	}
}

func enrichConfigMapWithSecurityConfigs(configMap kafka.ConfigMap) {
	if *saslUsername != "" && *saslPassword != "" {
		configMap.SetKey("security.protocol", resolveSecurityProtocol("SASL_PLAINTEXT", "SASL_SSL"))
		configMap.SetKey("sasl.mechanisms", "SCRAM-SHA-512")
		configMap.SetKey("sasl.username", *saslUsername)
		configMap.SetKey("sasl.password", *saslPassword)
	} else {
		configMap.SetKey("security.protocol", resolveSecurityProtocol("PLAINTEXT", "SSL"))
	}
	if sslEnabled {
		configMap.SetKey("ssl.ca.location", "/opt/kafka/tls/ca.crt")
		if twoWaySslEnabled {
			configMap.SetKey("ssl.key.location", "/opt/kafka/tls/tls.key")
			configMap.SetKey("ssl.certificate.location", "/opt/kafka/tls/tls.crt")
		}
	}
}

func healthCheckHandlers(healthCheckContext *HealthCheckContext) http.Handler {
	r := mux.NewRouter()
	r.Handle("/healthcheck", http.HandlerFunc(healthCheckContext.Execute())).Methods("GET")
	r.Handle("/", http.HandlerFunc(healthCheckContext.GetState())).Methods("GET")
	return jsonContentType(handlers.CompressHandler(r))
}

func jsonContentType(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		h.ServeHTTP(w, r)
	})
}

func (healthCheckContext *HealthCheckContext) Execute() func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if r := recover(); r != nil {
				response := Health{Status: "Error", Message: fmt.Sprint(r)}
				w.WriteHeader(500)
				resbody, marshalerr := json.Marshal(response)
				if marshalerr != nil {
					log.Print("Failed to marshal response to json: ", marshalerr)
					return
				}
				w.Write(resbody)
				return
			}
		}()

		sentMessage := r.URL.Query().Get("message")
		err := healthCheckContext.Producer.Produce(&kafka.Message{
			TopicPartition: kafka.TopicPartition{Topic: topic, Partition: kafka.PartitionAny},
			Value:          []byte(sentMessage),
		}, nil)

		response := Health{}
		if err != nil {
			response = Health{Status: "Error", Message: err.Error()}
		} else {
			response = checkMessageIsReceived(healthCheckContext, sentMessage)
		}

		w.WriteHeader(200)
		responseBody, _ := json.Marshal(response)
		if verbose == "true" {
			fmt.Printf("Response body: %s\n", responseBody)
		}
		w.Write(responseBody)
	}
}

func (healthCheckContext *HealthCheckContext) GetState() func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if r := recover(); r != nil {
				response := State{Status: "Error"}
				w.WriteHeader(500)
				resbody, marshalerr := json.Marshal(response)
				if marshalerr != nil {
					log.Print("Failed to marshal response to json: ", marshalerr)
					return
				}
				w.Write(resbody)
				return
			}
		}()

		response := State{Status: "Running"}
		w.WriteHeader(200)
		responseBody, _ := json.Marshal(response)
		w.Write(responseBody)
	}
}

func checkMessageIsReceived(healthCheckContext *HealthCheckContext, sentMessage string) Health {
	response := Health{}
	deadline := time.Now().Add(time.Duration(*timeout) * time.Millisecond)
	for time.Now().Before(deadline) {
		msg, err := healthCheckContext.Consumer.ReadMessage(time.Duration(*timeout) * time.Millisecond)
		if err == nil {
			if string(msg.Value) == sentMessage {
				return Health{Status: "OK", Message: fmt.Sprintf("Consumer has got message '%s'", sentMessage)}
			} else {
				response = Health{Status: "Error",
					Message: fmt.Sprintf("Consumer has got message '%s' instead of '%s'", string(msg.Value),
						sentMessage)}
			}
		} else {
			return Health{Status: "Error", Message: err.Error()}
		}
	}
	return response
}
