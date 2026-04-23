"""
Entity Parameters Registry
TB-HITL Specification - Entity-Params Loader

This module provides per-legal-entity configuration loading
as specified in the implementation addendum (Chapter 15).
"""

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Any
import yaml
import json
import hashlib
import subprocess

# Configure logging
logger = logging.getLogger(__name__)


@dataclass
class MaterialityThresholds:
    """Materiality thresholds for a legal entity."""
    balance_sheet_absolute: float  # e.g., $100M USD
    profit_loss_absolute: float    # e.g., $3M USD
    variance_percentage: float     # e.g., 0.10 (10%)


@dataclass
class ReviewConfig:
    """Review configuration for a legal entity."""
    review_frequency: str = "monthly"  # monthly, quarterly
    reviewer_role: str = "senior_accountant"
    escalation_threshold_days: int = 5
    auto_assign_enabled: bool = True


@dataclass
class EntityParams:
    """Parameters for a single legal entity."""
    legal_entity_code: str
    legal_entity_name: str
    currency: str
    materiality_thresholds: MaterialityThresholds
    review_config: ReviewConfig
    account_exclusions: List[str] = field(default_factory=list)
    custom_variance_types: Dict[str, Any] = field(default_factory=dict)
    source_file: Optional[str] = None
    git_sha: Optional[str] = None
    loaded_at: Optional[str] = None


class EntityParamsLoadError(Exception):
    """Exception raised when entity params fail to load."""
    pass


class EntityParamsRegistry:
    """
    Registry for loading and managing entity parameters.
    
    Implementation follows the specification in Chapter 15:
    - One YAML file per legal entity (entity-params/<LE-CODE>.yaml)
    - JSON Schema validation on check-in
    - Git SHA versioning for audit
    - Graceful handling of missing entities
    """
    
    DEFAULT_PARAMS_PATH = "docs/schema/tb/entity-params"
    SCHEMA_PATH = "docs/schema/tb/entity-params.schema.json"
    
    def __init__(
        self,
        params_path: Optional[str] = None,
        schema_path: Optional[str] = None,
        validate_on_load: bool = True,
    ):
        """
        Initialize the entity params registry.
        
        Args:
            params_path: Path to entity-params directory
            schema_path: Path to JSON Schema for validation
            validate_on_load: Whether to validate params against schema
        """
        self.params_path = Path(params_path or self.DEFAULT_PARAMS_PATH)
        self.schema_path = Path(schema_path) if schema_path else Path(self.SCHEMA_PATH)
        self.validate_on_load = validate_on_load
        
        self._cache: Dict[str, EntityParams] = {}
        self._default_params: Optional[EntityParams] = None
    
    def load_all(self) -> Dict[str, EntityParams]:
        """
        Load all entity parameters from the params directory.
        
        Returns:
            Dict mapping legal_entity_code to EntityParams
        """
        if not self.params_path.exists():
            logger.warning(f"Entity params path does not exist: {self.params_path}")
            return {}
        
        loaded = {}
        
        for yaml_file in self.params_path.glob("*.yaml"):
            try:
                entity_code = yaml_file.stem.upper()
                params = self._load_file(yaml_file)
                loaded[entity_code] = params
                self._cache[entity_code] = params
                logger.debug(f"Loaded entity params for {entity_code}")
            except Exception as e:
                logger.error(f"Failed to load {yaml_file}: {e}")
                # Continue loading other files
        
        logger.info(f"Loaded entity params for {len(loaded)} legal entities")
        return loaded
    
    def get(
        self,
        legal_entity_code: str,
        use_default: bool = True,
    ) -> Optional[EntityParams]:
        """
        Get entity parameters for a specific legal entity.
        
        Args:
            legal_entity_code: The legal entity code (e.g., "HKG")
            use_default: If True and entity not found, return default params
            
        Returns:
            EntityParams or None if not found (and use_default=False)
        """
        code = legal_entity_code.upper()
        
        # Check cache first
        if code in self._cache:
            return self._cache[code]
        
        # Try to load from file
        yaml_file = self.params_path / f"{code}.yaml"
        if yaml_file.exists():
            try:
                params = self._load_file(yaml_file)
                self._cache[code] = params
                return params
            except Exception as e:
                logger.error(f"Failed to load params for {code}: {e}")
        
        # Use default if configured
        if use_default and self._default_params:
            logger.info(f"Using default params for {code}")
            return self._get_default_params(code)
        
        logger.warning(f"No entity params found for {code}")
        return None
    
    def get_or_raise(self, legal_entity_code: str) -> EntityParams:
        """
        Get entity parameters or raise an exception.
        
        Args:
            legal_entity_code: The legal entity code
            
        Returns:
            EntityParams
            
        Raises:
            EntityParamsLoadError if entity not found
        """
        params = self.get(legal_entity_code, use_default=False)
        if params is None:
            raise EntityParamsLoadError(
                f"Entity params not found for {legal_entity_code}"
            )
        return params
    
    def set_default_params(self, params: EntityParams) -> None:
        """
        Set default parameters to use for missing entities.
        
        Args:
            params: Default EntityParams
        """
        self._default_params = params
    
    def get_materiality_threshold(
        self,
        legal_entity_code: str,
        account_type: str = "pl",
    ) -> float:
        """
        Get materiality threshold for a legal entity.
        
        Args:
            legal_entity_code: The legal entity code
            account_type: "bs" for balance sheet, "pl" for profit/loss
            
        Returns:
            Materiality threshold amount
        """
        params = self.get(legal_entity_code)
        if params is None:
            # Return conservative default
            return 3_000_000.0 if account_type == "pl" else 100_000_000.0
        
        if account_type == "bs":
            return params.materiality_thresholds.balance_sheet_absolute
        else:
            return params.materiality_thresholds.profit_loss_absolute
    
    def _load_file(self, yaml_file: Path) -> EntityParams:
        """Load entity params from a YAML file."""
        with open(yaml_file, 'r') as f:
            data = yaml.safe_load(f)
        
        # Validate against schema if enabled
        if self.validate_on_load and self.schema_path.exists():
            self._validate_schema(data, yaml_file)
        
        # Get git SHA for audit
        git_sha = self._get_git_sha(yaml_file)
        
        # Parse materiality thresholds
        mat_data = data.get("materiality_thresholds", {})
        materiality = MaterialityThresholds(
            balance_sheet_absolute=mat_data.get("balance_sheet_absolute", 100_000_000),
            profit_loss_absolute=mat_data.get("profit_loss_absolute", 3_000_000),
            variance_percentage=mat_data.get("variance_percentage", 0.10),
        )
        
        # Parse review config
        review_data = data.get("review_config", {})
        review_config = ReviewConfig(
            review_frequency=review_data.get("review_frequency", "monthly"),
            reviewer_role=review_data.get("reviewer_role", "senior_accountant"),
            escalation_threshold_days=review_data.get("escalation_threshold_days", 5),
            auto_assign_enabled=review_data.get("auto_assign_enabled", True),
        )
        
        return EntityParams(
            legal_entity_code=data.get("legal_entity_code", yaml_file.stem.upper()),
            legal_entity_name=data.get("legal_entity_name", ""),
            currency=data.get("currency", "USD"),
            materiality_thresholds=materiality,
            review_config=review_config,
            account_exclusions=data.get("account_exclusions", []),
            custom_variance_types=data.get("custom_variance_types", {}),
            source_file=str(yaml_file),
            git_sha=git_sha,
            loaded_at=str(Path(yaml_file).stat().st_mtime),
        )
    
    def _validate_schema(self, data: Dict[str, Any], yaml_file: Path) -> None:
        """Validate data against JSON Schema."""
        try:
            import jsonschema
            
            with open(self.schema_path, 'r') as f:
                schema = json.load(f)
            
            jsonschema.validate(data, schema)
            logger.debug(f"Schema validation passed for {yaml_file}")
            
        except ImportError:
            logger.warning("jsonschema not installed, skipping validation")
        except jsonschema.ValidationError as e:
            raise EntityParamsLoadError(
                f"Schema validation failed for {yaml_file}: {e.message}"
            )
    
    def _get_git_sha(self, file_path: Path) -> Optional[str]:
        """Get Git SHA for a file (for audit)."""
        try:
            result = subprocess.run(
                ["git", "log", "-1", "--format=%H", str(file_path)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                return result.stdout.strip()[:12]  # Short SHA
        except Exception:
            pass
        return None
    
    def _get_default_params(self, legal_entity_code: str) -> EntityParams:
        """Get default params with entity code substituted."""
        if self._default_params is None:
            # Create a basic default
            return EntityParams(
                legal_entity_code=legal_entity_code,
                legal_entity_name=f"Default - {legal_entity_code}",
                currency="USD",
                materiality_thresholds=MaterialityThresholds(
                    balance_sheet_absolute=100_000_000,
                    profit_loss_absolute=3_000_000,
                    variance_percentage=0.10,
                ),
                review_config=ReviewConfig(),
            )
        
        # Clone default with new code
        return EntityParams(
            legal_entity_code=legal_entity_code,
            legal_entity_name=f"{self._default_params.legal_entity_name} (default)",
            currency=self._default_params.currency,
            materiality_thresholds=self._default_params.materiality_thresholds,
            review_config=self._default_params.review_config,
            account_exclusions=self._default_params.account_exclusions.copy(),
            custom_variance_types=self._default_params.custom_variance_types.copy(),
        )


# =============================================================================
# Example Entity Params YAML Generator
# =============================================================================

def create_example_entity_params(output_path: str = "docs/schema/tb/entity-params") -> None:
    """
    Create example entity params YAML files.
    
    This creates the HKG.yaml example from the specification.
    """
    output_dir = Path(output_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # HKG example from specification
    hkg_params = {
        "legal_entity_code": "HKG",
        "legal_entity_name": "Hong Kong Entity",
        "currency": "HKD",
        "materiality_thresholds": {
            "balance_sheet_absolute": 100000000,  # $100M USD
            "profit_loss_absolute": 3000000,      # $3M USD
            "variance_percentage": 0.10,          # 10%
        },
        "review_config": {
            "review_frequency": "monthly",
            "reviewer_role": "senior_accountant",
            "escalation_threshold_days": 5,
            "auto_assign_enabled": True,
        },
        "account_exclusions": [
            "9999*",  # Intercompany elimination accounts
        ],
        "custom_variance_types": {
            "regulatory_reserve": {
                "threshold": 0.05,  # 5% for regulatory accounts
                "accounts": ["2300*", "2310*"],
            },
        },
    }
    
    with open(output_dir / "HKG.yaml", 'w') as f:
        yaml.dump(hkg_params, f, default_flow_style=False, sort_keys=False)
    
    # USA example
    usa_params = {
        "legal_entity_code": "USA",
        "legal_entity_name": "United States Entity",
        "currency": "USD",
        "materiality_thresholds": {
            "balance_sheet_absolute": 150000000,  # $150M USD (larger entity)
            "profit_loss_absolute": 5000000,      # $5M USD
            "variance_percentage": 0.10,          # 10%
        },
        "review_config": {
            "review_frequency": "monthly",
            "reviewer_role": "senior_accountant",
            "escalation_threshold_days": 3,
            "auto_assign_enabled": True,
        },
        "account_exclusions": [],
    }
    
    with open(output_dir / "USA.yaml", 'w') as f:
        yaml.dump(usa_params, f, default_flow_style=False, sort_keys=False)
    
    # DEFAULT template
    default_params = {
        "legal_entity_code": "DEFAULT",
        "legal_entity_name": "Default Template",
        "currency": "USD",
        "materiality_thresholds": {
            "balance_sheet_absolute": 100000000,
            "profit_loss_absolute": 3000000,
            "variance_percentage": 0.10,
        },
        "review_config": {
            "review_frequency": "monthly",
            "reviewer_role": "senior_accountant",
            "escalation_threshold_days": 5,
            "auto_assign_enabled": True,
        },
        "account_exclusions": [],
    }
    
    with open(output_dir / "DEFAULT.yaml", 'w') as f:
        yaml.dump(default_params, f, default_flow_style=False, sort_keys=False)
    
    print(f"Created example entity params in {output_dir}")


# =============================================================================
# Main Entry Point
# =============================================================================

if __name__ == "__main__":
    print("Entity Params Registry - TB-HITL Implementation")
    print("=" * 60)
    
    # Create example files
    create_example_entity_params()
    
    # Load and test
    registry = EntityParamsRegistry()
    
    # Try to load all
    all_params = registry.load_all()
    print(f"\nLoaded {len(all_params)} entity configurations")
    
    for code, params in all_params.items():
        print(f"\n  {code}:")
        print(f"    Name: {params.legal_entity_name}")
        print(f"    Currency: {params.currency}")
        print(f"    BS Threshold: ${params.materiality_thresholds.balance_sheet_absolute:,.0f}")
        print(f"    PL Threshold: ${params.materiality_thresholds.profit_loss_absolute:,.0f}")
        print(f"    Git SHA: {params.git_sha or 'N/A'}")