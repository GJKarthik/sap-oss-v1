// Package main is the entry point for the Mangle Query Service server.
package main

import (
	"fmt"
	"log"
	"net"
	"os"

	"google.golang.org/grpc"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/config"
	"github.com/sap-oss/mangle-query-service/internal/server"
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

	srv, err := server.NewGRPCServer(cfg.RulesDir)
	if err != nil {
		log.Fatalf("failed to create server: %v", err)
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.GRPCPort))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterQueryServiceServer(grpcServer, srv)

	log.Printf("Mangle Query Service listening on gRPC port %d", cfg.GRPCPort)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
