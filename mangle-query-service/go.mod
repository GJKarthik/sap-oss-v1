module github.com/sap-oss/mangle-query-service

go 1.24.0

replace github.com/google/mangle => ../mangle-main

require (
	github.com/google/mangle v0.0.0-00010101000000-000000000000
	google.golang.org/grpc v1.79.1
	google.golang.org/protobuf v1.36.11
)

require (
	bitbucket.org/creachadair/stringset v0.0.11 // indirect
	github.com/antlr4-go/antlr/v4 v4.13.1 // indirect
	github.com/chzyer/readline v1.5.1 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	golang.org/x/exp v0.0.0-20240707233637-46b078467d37 // indirect
	golang.org/x/net v0.48.0 // indirect
	golang.org/x/sys v0.39.0 // indirect
	golang.org/x/text v0.32.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251202230838-ff82c1b0f217 // indirect
)
