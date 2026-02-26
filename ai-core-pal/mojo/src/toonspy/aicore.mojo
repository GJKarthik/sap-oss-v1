# ===----------------------------------------------------------------------=== #
# ToonSPy SAP AI Core Adapter
#
# LLM adapter specifically for SAP AI Core deployments.
# Handles authentication, request formatting, and TOON response parsing.
# ===----------------------------------------------------------------------=== #

from collections import Dict
from python import Python
from sys import env_get_string


@value
struct AICoreConfig:
    """Configuration for SAP AI Core connection."""
    var endpoint: String
    var deployment_id: String
    var resource_group: String
    var scenario_id: String
    var model_name: String
    var max_tokens: Int
    var temperature: Float64
    var token_ttl_seconds: Int
    var request_timeout_seconds: Int
    
    fn __init__(
        inout self,
        endpoint: String = "",
        deployment_id: String = "",
        resource_group: String = "default",
        scenario_id: String = "toonspy",
        model_name: String = "gpt-4",
        max_tokens: Int = 512,
        temperature: Float64 = 0.1,
        token_ttl_seconds: Int = 3300,
        request_timeout_seconds: Int = 30
    ):
        self.endpoint = endpoint
        self.deployment_id = deployment_id
        self.resource_group = resource_group
        self.scenario_id = scenario_id
        self.model_name = model_name
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.token_ttl_seconds = token_ttl_seconds
        self.request_timeout_seconds = request_timeout_seconds


struct AICoreAdapter:
    """
    SAP AI Core LLM Adapter for ToonSPy.
    
    This adapter:
    1. Handles XSUAA token authentication
    2. Formats requests for AI Core deployments
    3. Parses TOON-formatted responses
    4. Supports streaming for long responses
    
    Example:
        var adapter = AICoreAdapter()
        var response = adapter.complete("What is TOON?")
        # Returns: answer:token_efficient_format
    """
    var config: AICoreConfig
    var auth_token: String
    var _token_fetched_at: Float64
    
    fn __init__(inout self, config: AICoreConfig = AICoreConfig()):
        var endpoint = config.endpoint
        if endpoint == "":
            endpoint = env_get_string("AICORE_ENDPOINT", "")
        
        var deployment_id = config.deployment_id
        if deployment_id == "":
            deployment_id = env_get_string("AICORE_DEPLOYMENT_ID", "")
        
        var resource_group = config.resource_group
        if resource_group == "default":
            resource_group = env_get_string("AICORE_RESOURCE_GROUP", "default")
        
        self.config = AICoreConfig(
            endpoint=endpoint,
            deployment_id=deployment_id,
            resource_group=resource_group,
            scenario_id=config.scenario_id,
            model_name=config.model_name,
            max_tokens=config.max_tokens,
            temperature=config.temperature,
            token_ttl_seconds=config.token_ttl_seconds,
            request_timeout_seconds=config.request_timeout_seconds
        )
        self.auth_token = ""
        self._token_fetched_at = 0.0
    
    fn _get_auth_token(inout self) -> String:
        """Get XSUAA token for AI Core authentication."""
        if self.auth_token != "":
            try:
                var time_mod = Python.import_module("time")
                var now = Float64(time_mod.time())
                if now - self._token_fetched_at < Float64(self.config.token_ttl_seconds):
                    return self.auth_token
            except:
                pass
            self.auth_token = ""
        
        var client_id = env_get_string("AICORE_CLIENT_ID", "")
        var client_secret = env_get_string("AICORE_CLIENT_SECRET", "")
        var token_url = env_get_string("AICORE_TOKEN_URL", "")
        
        if client_id == "" or client_secret == "" or token_url == "":
            return ""
        
        try:
            var time_mod = Python.import_module("time")
            var requests = Python.import_module("requests")
            var response = requests.post(
                token_url,
                data={
                    "grant_type": "client_credentials",
                    "client_id": client_id,
                    "client_secret": client_secret
                },
                timeout=self.config.request_timeout_seconds
            )
            if response.status_code != 200:
                return ""
            var token_data = response.json()
            self.auth_token = str(token_data["access_token"])
            self._token_fetched_at = Float64(time_mod.time())
            return self.auth_token
        except:
            return ""
    
    fn _invalidate_token(inout self):
        """Invalidate the cached token (e.g. on 401 response)."""
        self.auth_token = ""
        self._token_fetched_at = 0.0
    
    fn complete(inout self, prompt: String, system_prompt: String = "") -> String:
        """
        Call AI Core deployment with TOON-optimized prompt.
        
        Args:
            prompt: The user prompt (should include TOON format instructions)
            system_prompt: Optional system prompt (default includes TOON instructions)
        
        Returns:
            TOON-formatted response string
        """
        var token = self._get_auth_token()
        if token == "":
            return "error:auth_failed"
        
        if self.config.endpoint == "" or self.config.deployment_id == "":
            return "error:missing_config fields:endpoint|deployment_id"
        
        var url = self.config.endpoint + "/v2/inference/deployments/" + self.config.deployment_id + "/chat/completions"
        
        # Default system prompt for TOON output
        var sys_prompt = system_prompt
        if sys_prompt == "":
            sys_prompt = """You are a precise assistant that responds in TOON format.
TOON format rules:
- Use key:value syntax (no quotes for simple strings)
- Arrays use pipe separator: items:a|b|c
- Null is represented as ~
- Boolean is true/false
- Only output the requested fields, nothing else."""
        
        # Build request payload
        var payload = self._build_payload(sys_prompt, prompt)
        
        # Make HTTP request using Python
        try:
            var requests = Python.import_module("requests")
            var json_mod = Python.import_module("json")
            
            var headers = {
                "Authorization": "Bearer " + token,
                "AI-Resource-Group": self.config.resource_group,
                "Content-Type": "application/json"
            }
            
            var response = requests.post(
                url, headers=headers, json=payload,
                timeout=self.config.request_timeout_seconds
            )
            
            if response.status_code == 401:
                self._invalidate_token()
                return "error:auth_expired status:401"
            
            if response.status_code != 200:
                return "error:request_failed status:" + str(response.status_code)
            
            var result = response.json()
            var content = str(result["choices"][0]["message"]["content"])
            
            return self._clean_toon_response(content)
            
        except e:
            return "error:exception message:" + str(e)
    
    fn _build_payload(self, system_prompt: String, user_prompt: String) -> PythonObject:
        """Build the JSON payload for AI Core request."""
        return {
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ],
            "max_tokens": self.config.max_tokens,
            "temperature": self.config.temperature,
            "model": self.config.model_name
        }
    
    fn _clean_toon_response(self, response: String) -> String:
        """Clean up LLM response to ensure valid TOON format."""
        var cleaned = response
        
        # Remove markdown code blocks if present
        if cleaned.startswith("```"):
            var lines = cleaned.split("\n")
            var result = String()
            var in_code = False
            for i in range(len(lines)):
                var line = lines[i]
                if line.startswith("```"):
                    in_code = not in_code
                    continue
                if in_code:
                    if result != "":
                        result += "\n"
                    result += line
            cleaned = result
        
        # Remove leading/trailing whitespace
        cleaned = cleaned.strip()
        
        return cleaned
    
    fn complete_with_retry(
        inout self,
        prompt: String,
        system_prompt: String = "",
        max_retries: Int = 3
    ) -> String:
        """
        Call AI Core with retry logic for robustness.
        
        Retries on transient failures with exponential backoff.
        """
        var retries = 0
        var last_error = String()
        
        while retries < max_retries:
            var result = self.complete(prompt, system_prompt)
            
            # Check for success
            if not result.startswith("error:"):
                return result
            
            last_error = result
            retries += 1
            
            if retries < max_retries:
                try:
                    var time_mod = Python.import_module("time")
                    var delay = Float64(1 << (retries - 1))
                    time_mod.sleep(delay)
                except:
                    pass
        
        return last_error
    
    fn stream_complete(
        inout self,
        prompt: String,
        system_prompt: String = ""
    ) -> String:
        """
        Stream completion from AI Core (for long responses).
        
        Note: Streaming returns chunks that are accumulated into final TOON.
        """
        # For now, use regular complete
        # TODO: Implement proper streaming with SSE
        return self.complete(prompt, system_prompt)


# ===----------------------------------------------------------------------=== #
# Factory functions
# ===----------------------------------------------------------------------=== #

fn create_aicore_adapter() -> AICoreAdapter:
    """Create an AI Core adapter with default configuration from environment."""
    return AICoreAdapter()


fn create_aicore_adapter_with_config(
    endpoint: String,
    deployment_id: String,
    resource_group: String = "default"
) -> AICoreAdapter:
    """Create an AI Core adapter with explicit configuration."""
    return AICoreAdapter(AICoreConfig(
        endpoint=endpoint,
        deployment_id=deployment_id,
        resource_group=resource_group
    ))