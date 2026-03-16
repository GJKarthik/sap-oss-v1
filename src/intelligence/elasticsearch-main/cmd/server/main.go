// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package main is the entry point for the Mangle Query Service server.
package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/config"
	"github.com/sap-oss/mangle-query-service/internal/es"
	"github.com/sap-oss/mangle-query-service/internal/server"
	"github.com/sap-oss/mangle-query-service/internal/sync"
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

	// Create ES client
	esClient, err := es.NewClient(cfg.ESAddress)
	if err != nil {
		log.Fatalf("failed to create ES client: %v", err)
	}

	srv, err := server.NewGRPCServer(cfg.RulesDir, &server.ServerOptions{
		ESClient:   esClient.Raw(),
		MCPAddress: cfg.MCPAddress,
		MCPToken:   cfg.MCPAuthToken,
	})
	if err != nil {
		log.Fatalf("failed to create server: %v", err)
	}

	// Start batch ETL sync pipeline
	etl := sync.NewBatchETL(esClient.Raw(), 5*time.Minute)
	etl.Start()

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.GRPCPort))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterQueryServiceServer(grpcServer, srv)

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		log.Println("Shutting down...")
		etl.Stop()
		grpcServer.GracefulStop()
	}()

	log.Printf("Mangle Query Service listening on gRPC port %d", cfg.GRPCPort)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
