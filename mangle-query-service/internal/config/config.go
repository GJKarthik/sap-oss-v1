// Package config provides configuration loading for the Mangle Query Service.
package config

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config holds all configuration values for the Mangle Query Service.
type Config struct {
	GRPCPort     int    `json:"grpc_port"`
	HTTPPort     int    `json:"http_port"`
	RulesDir     string `json:"rules_dir"`
	ESAddress    string `json:"es_address"`
	HANAHost     string `json:"hana_host"`
	HANAPort     int    `json:"hana_port"`
	HANAUser     string `json:"hana_user"`
	HANAPassword string `json:"hana_password"`
	MCPAddress   string `json:"mcp_address"`
	MCPAuthToken string `json:"mcp_auth_token"`
}

// Default returns a Config populated with default values.
func Default() Config {
	return Config{
		GRPCPort:   50051,
		HTTPPort:   8080,
		RulesDir:   "rules/",
		ESAddress:  "http://localhost:9200",
		MCPAddress: "http://localhost:8001/mcp",
	}
}

// Load reads a JSON configuration file at the given path and returns a Config.
// Default values are applied first, then overridden by values present in the file.
func Load(path string) (Config, error) {
	cfg := Default()

	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("config: reading file %s: %w", path, err)
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("config: parsing file %s: %w", path, err)
	}

	return cfg, nil
}
