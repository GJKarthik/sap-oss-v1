import os
import requests
import json
import sys

# Load credentials from .env if possible, otherwise use provided values directly
AICORE_CLIENT_ID = "sb-524de71c-6fdc-42f9-9ca3-1aa049f9521f!b37640|xsuaa_std!b15301"
AICORE_CLIENT_SECRET = "8af14c56-5dc4-4c94-a612-7dde03a44b5c$1QiN4na__SQJQor4ETgHi0XnNysczycHflQcYw9PcEo="
AICORE_AUTH_URL = "https://fin-analytical-svc-rnd.authentication.ap11.hana.ondemand.com/oauth/token"
AICORE_BASE_URL = "https://api.ai.prod-ap11.ap-southeast-1.aws.ml.hana.ondemand.com"

DEPLOYMENT_ID_LLM = "d08cd08073c92a85"
DEPLOYMENT_ID_EMBEDDING = "dc9b452a67bfcaa5"

PAL_MCP_URL = "https://ai-core-pal.c-054c570.kyma.ondemand.com"
HANA_MCP_URL = "http://localhost:9160"

def get_token():
    response = requests.post(
        AICORE_AUTH_URL,
        data={"grant_type": "client_credentials", "client_id": AICORE_CLIENT_ID, "client_secret": AICORE_CLIENT_SECRET},
    )
    response.raise_for_status()
    return response.json()["access_token"]

def test_llm(token):
    url = f"{AICORE_BASE_URL}/v2/inference/deployments/{DEPLOYMENT_ID_LLM}/v1/chat/completions"
    print(f"Testing LLM (Qwen3.5) at {url}...")
    payload = {
        "model": "Qwen/Qwen3.5-35B-A3B-FP8",
        "messages": [{"role": "user", "content": "Say 'SAP AI Suite Connectivity Test Passed'"}],
        "stream": False
    }
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "ai-resource-group": "default"}
    try:
        response = requests.post(url, json=payload, headers=headers)
        if response.ok:
            print(f"PASS: LLM Response received.")
        else:
            print(f"FAIL: LLM HTTP {response.status_code}")
    except Exception as e:
        print(f"FAIL: LLM error: {e}")

def test_embeddings(token):
    url = f"{AICORE_BASE_URL}/v2/inference/deployments/{DEPLOYMENT_ID_EMBEDDING}/v1/embeddings"
    print(f"Testing Embeddings at {url}...")
    payload = {"input": "Connectivity test"}
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "ai-resource-group": "default"}
    try:
        response = requests.post(url, json=payload, headers=headers)
        if response.ok:
            print(f"PASS: Embedding generated.")
        else:
            print(f"FAIL: Embedding HTTP {response.status_code}")
    except Exception as e:
        print(f"FAIL: Embedding error: {e}")

def test_health(name, url, headers=None):
    health_url = f"{url}/health"
    print(f"Testing {name} health at {health_url}...")
    try:
        response = requests.get(health_url, headers=headers)
        if response.ok:
            print(f"PASS: {name} is healthy.")
        else:
            print(f"FAIL: {name} health HTTP {response.status_code}")
    except Exception as e:
        print(f"FAIL: {name} health error: {e}")

def test_mcp_list(name, url, auth_header_value):
    mcp_url = f"{url}/mcp"
    print(f"Testing {name} tools list at {mcp_url}...")
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {}
    }
    
    # Try multiple header variants for ES MCP
    variants = [
        {"Authorization": auth_header_value},
        {"X-API-Key": auth_header_value.replace("Apikey ", "")},
        {"apikey": auth_header_value.replace("Apikey ", "")}
    ]
    
    for headers in variants:
        headers["Content-Type"] = "application/json"
        try:
            response = requests.post(mcp_url, json=payload, headers=headers)
            if response.ok:
                tools = [t['name'] for t in response.json().get('result', {}).get('tools', [])]
                print(f"PASS: {name} tools found with header {list(headers.keys())[0]}: {', '.join(tools)}")
                return
        except:
            pass
            
    print(f"FAIL: {name} MCP tools list could not be authorized.")

if __name__ == "__main__":
    try:
        token = get_token()
        print("OAuth Token obtained.\n")
        
        test_llm(token)
        test_embeddings(token)
        print("")
        
        test_health("PAL MCP", PAL_MCP_URL)
        test_mcp_list("PAL MCP", PAL_MCP_URL, "None") # PAL doesn't need auth here
        print("")
        
        test_health("HANA MCP", HANA_MCP_URL)
        test_mcp_list("HANA MCP", HANA_MCP_URL, "None")
        
    except Exception as e:
        print(f"CRITICAL ERROR: {e}")
        sys.exit(1)
