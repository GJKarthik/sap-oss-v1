#!/usr/bin/env python3
"""
Live SAP AI Core Integration Test

Tests the mangle-query-service against real SAP AI Core backend.
Requires valid credentials in .env file.
"""

import asyncio
import os
import sys
import json
import time
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx
from dotenv import load_dotenv

# Load environment variables
load_dotenv()


class AICoreTestClient:
    """Test client for SAP AI Core."""
    
    def __init__(self):
        self.client_id = os.getenv("AICORE_CLIENT_ID")
        self.client_secret = os.getenv("AICORE_CLIENT_SECRET")
        self.auth_url = os.getenv("AICORE_AUTH_URL")
        self.base_url = os.getenv("AICORE_BASE_URL")
        self.resource_group = os.getenv("AICORE_RESOURCE_GROUP", "default")
        self.access_token = None
        self.token_expires = 0
        
    def validate_config(self) -> bool:
        """Validate required configuration."""
        missing = []
        if not self.client_id:
            missing.append("AICORE_CLIENT_ID")
        if not self.client_secret:
            missing.append("AICORE_CLIENT_SECRET")
        if not self.auth_url:
            missing.append("AICORE_AUTH_URL")
        if not self.base_url:
            missing.append("AICORE_BASE_URL")
        
        if missing:
            print(f"❌ Missing configuration: {', '.join(missing)}")
            return False
        
        print(f"✅ Configuration validated")
        print(f"   Base URL: {self.base_url}")
        print(f"   Auth URL: {self.auth_url}")
        print(f"   Resource Group: {self.resource_group}")
        return True
    
    async def get_access_token(self) -> str:
        """Get OAuth2 access token from XSUAA."""
        if self.access_token and time.time() < self.token_expires - 60:
            return self.access_token
        
        print("\n🔐 Authenticating with SAP AI Core...")
        
        async with httpx.AsyncClient() as client:
            response = await client.post(
                self.auth_url,
                data={
                    "grant_type": "client_credentials",
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                },
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                timeout=30.0,
            )
            
            if response.status_code != 200:
                print(f"❌ Authentication failed: {response.status_code}")
                print(f"   Response: {response.text[:200]}")
                raise Exception(f"OAuth2 authentication failed: {response.status_code}")
            
            data = response.json()
            self.access_token = data["access_token"]
            self.token_expires = time.time() + data.get("expires_in", 3600)
            
            print(f"✅ Authentication successful")
            print(f"   Token expires in: {data.get('expires_in', 3600)} seconds")
            
            return self.access_token
    
    async def list_deployments(self) -> dict:
        """List available AI Core deployments."""
        token = await self.get_access_token()
        
        print("\n📋 Listing AI Core deployments...")
        
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{self.base_url}/v2/lm/deployments",
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": self.resource_group,
                },
                timeout=30.0,
            )
            
            if response.status_code != 200:
                print(f"❌ Failed to list deployments: {response.status_code}")
                print(f"   Response: {response.text[:500]}")
                return {"error": response.text}
            
            data = response.json()
            deployments = data.get("resources", [])
            
            print(f"✅ Found {len(deployments)} deployment(s)")
            for dep in deployments:
                status = dep.get("status", "unknown")
                deployment_id = dep.get("id", "N/A")
                scenario = dep.get("scenarioId", "N/A")
                print(f"   - {deployment_id}: {scenario} [{status}]")
            
            return data
    
    async def list_scenarios(self) -> dict:
        """List available scenarios."""
        token = await self.get_access_token()
        
        print("\n📋 Listing AI Core scenarios...")
        
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{self.base_url}/v2/lm/scenarios",
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": self.resource_group,
                },
                timeout=30.0,
            )
            
            if response.status_code != 200:
                print(f"❌ Failed to list scenarios: {response.status_code}")
                return {"error": response.text}
            
            data = response.json()
            scenarios = data.get("resources", [])
            
            print(f"✅ Found {len(scenarios)} scenario(s)")
            for scenario in scenarios:
                scenario_id = scenario.get("id", "N/A")
                name = scenario.get("name", "N/A")
                print(f"   - {scenario_id}: {name}")
            
            return data
    
    async def test_chat_completion(self, deployment_id: str, prompt: str = "Hello, what can you help me with?") -> dict:
        """Test chat completion against a deployment."""
        token = await self.get_access_token()
        
        print(f"\n💬 Testing chat completion...")
        print(f"   Deployment: {deployment_id}")
        print(f"   Prompt: {prompt[:50]}...")
        
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{self.base_url}/v2/inference/deployments/{deployment_id}/chat/completions",
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": self.resource_group,
                    "Content-Type": "application/json",
                },
                json={
                    "messages": [
                        {"role": "user", "content": prompt}
                    ],
                    "max_tokens": 100,
                    "temperature": 0.7,
                },
                timeout=60.0,
            )
            
            if response.status_code != 200:
                print(f"❌ Chat completion failed: {response.status_code}")
                print(f"   Response: {response.text[:500]}")
                return {"error": response.text}
            
            data = response.json()
            
            if "choices" in data and data["choices"]:
                content = data["choices"][0].get("message", {}).get("content", "No content")
                print(f"✅ Chat completion successful")
                print(f"   Response: {content[:200]}...")
            else:
                print(f"⚠️ Unexpected response format")
                print(f"   Response: {json.dumps(data)[:500]}")
            
            return data
    
    async def test_embeddings(self, deployment_id: str, text: str = "Test embedding text") -> dict:
        """Test embeddings against a deployment."""
        token = await self.get_access_token()
        
        print(f"\n🔢 Testing embeddings...")
        print(f"   Deployment: {deployment_id}")
        print(f"   Text: {text[:50]}...")
        
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{self.base_url}/v2/inference/deployments/{deployment_id}/embeddings",
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": self.resource_group,
                    "Content-Type": "application/json",
                },
                json={
                    "input": text,
                },
                timeout=60.0,
            )
            
            if response.status_code != 200:
                print(f"❌ Embeddings failed: {response.status_code}")
                print(f"   Response: {response.text[:500]}")
                return {"error": response.text}
            
            data = response.json()
            
            if "data" in data and data["data"]:
                embedding = data["data"][0].get("embedding", [])
                print(f"✅ Embeddings successful")
                print(f"   Dimensions: {len(embedding)}")
                print(f"   First 5 values: {embedding[:5]}")
            else:
                print(f"⚠️ Unexpected response format")
            
            return data


async def main():
    """Run live integration tests."""
    print("=" * 60)
    print("SAP AI Core Live Integration Test")
    print("=" * 60)
    
    client = AICoreTestClient()
    
    # Step 1: Validate configuration
    if not client.validate_config():
        print("\n❌ Test aborted: Invalid configuration")
        return 1
    
    # Step 2: Authenticate
    try:
        await client.get_access_token()
    except Exception as e:
        print(f"\n❌ Test aborted: Authentication failed - {e}")
        return 1
    
    # Step 3: List scenarios
    try:
        await client.list_scenarios()
    except Exception as e:
        print(f"\n⚠️ Failed to list scenarios: {e}")
    
    # Step 4: List deployments
    try:
        deployments_data = await client.list_deployments()
        deployments = deployments_data.get("resources", [])
        
        # Find a running deployment
        running_deployments = [d for d in deployments if d.get("status") == "RUNNING"]
        
        if running_deployments:
            deployment_id = running_deployments[0]["id"]
            
            # Step 5: Test chat completion
            try:
                await client.test_chat_completion(deployment_id)
            except Exception as e:
                print(f"\n⚠️ Chat completion test failed: {e}")
            
            # Step 6: Test embeddings (may fail if not an embedding model)
            try:
                await client.test_embeddings(deployment_id)
            except Exception as e:
                print(f"\n⚠️ Embeddings test skipped (deployment may not support embeddings): {e}")
        else:
            print("\n⚠️ No RUNNING deployments found. Please deploy a model first.")
            print("   Use SAP AI Launchpad to create a deployment.")
            
    except Exception as e:
        print(f"\n⚠️ Failed to list deployments: {e}")
    
    print("\n" + "=" * 60)
    print("Test Complete")
    print("=" * 60)
    
    return 0


if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)