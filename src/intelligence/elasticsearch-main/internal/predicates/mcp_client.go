// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type mcpJSONRPCRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      int            `json:"id"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params"`
}

type mcpJSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpJSONRPCResponse struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      int              `json:"id"`
	Result  any              `json:"result"`
	Error   *mcpJSONRPCError `json:"error,omitempty"`
}

func normalizeMCPAddress(address string) string {
	trimmed := strings.TrimSpace(address)
	if trimmed == "" {
		return ""
	}
	trimmed = strings.TrimRight(trimmed, "/")
	if strings.HasSuffix(trimmed, "/mcp") {
		return trimmed
	}
	return trimmed + "/mcp"
}

func callMCPTool(address, authToken, toolName string, args map[string]any) (map[string]any, error) {
	endpoint := normalizeMCPAddress(address)
	if endpoint == "" {
		return nil, fmt.Errorf("mcp endpoint is empty")
	}

	payload := mcpJSONRPCRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "tools/call",
		Params: map[string]any{
			"name":      toolName,
			"arguments": args,
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if authToken != "" {
		req.Header.Set("Authorization", "Bearer "+authToken)
	}

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("mcp tools/call http %d: %s", resp.StatusCode, string(data))
	}

	var rpcResp mcpJSONRPCResponse
	if err := json.Unmarshal(data, &rpcResp); err != nil {
		return nil, err
	}
	if rpcResp.Error != nil {
		return nil, fmt.Errorf("mcp rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	resultMap, ok := rpcResp.Result.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("unexpected mcp result payload type")
	}
	return extractMCPToolPayload(resultMap)
}

func extractMCPToolPayload(result map[string]any) (map[string]any, error) {
	contentRaw, ok := result["content"]
	if !ok {
		return result, nil
	}
	contentArr, ok := contentRaw.([]any)
	if !ok || len(contentArr) == 0 {
		return result, nil
	}
	first, ok := contentArr[0].(map[string]any)
	if !ok {
		return result, nil
	}
	text, ok := first["text"].(string)
	if !ok || strings.TrimSpace(text) == "" {
		return result, nil
	}

	var decoded map[string]any
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		return map[string]any{"text": text}, nil
	}
	return decoded, nil
}

func legacyMCPHTTPCall(address, authToken, path string, body []byte) (map[string]any, error) {
	if strings.TrimSpace(address) == "" {
		return nil, fmt.Errorf("mcp endpoint is empty")
	}
	url := strings.TrimRight(address, "/") + path
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if authToken != "" {
		req.Header.Set("Authorization", "Bearer "+authToken)
	}

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("legacy mcp http %d: %s", resp.StatusCode, string(data))
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func stringField(m map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := m[key]
		if !ok {
			continue
		}
		if s, ok := value.(string); ok {
			s = strings.TrimSpace(s)
			if s != "" {
				return s
			}
		}
	}
	return ""
}

func floatField(m map[string]any, keys ...string) float64 {
	for _, key := range keys {
		value, ok := m[key]
		if !ok {
			continue
		}
		switch v := value.(type) {
		case float64:
			return v
		case float32:
			return float64(v)
		case int:
			return float64(v)
		case int64:
			return float64(v)
		}
	}
	return 0
}
