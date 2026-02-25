// Package main is the entry point for the Mangle Query Service server.
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/sap-oss/mangle-query-service/internal/config"
)

func main() {
	var cfg config.Config

	if path := os.Getenv("MQS_CONFIG"); path != "" {
		loaded, err := config.Load(path)
		if err != nil {
			log.Fatalf("Failed to load config from %s: %v", path, err)
		}
		cfg = loaded
		log.Printf("Loaded configuration from %s", path)
	} else {
		cfg = config.Default()
		log.Println("No MQS_CONFIG set, using default configuration")
	}

	fmt.Printf("Mangle Query Service starting — gRPC :%d  HTTP :%d  rules=%s\n",
		cfg.GRPCPort, cfg.HTTPPort, cfg.RulesDir)
}
