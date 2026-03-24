# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Training Integration Module.

Integrates the training data products and ModelOpt service
with the data-cleaning-copilot MCP server.
"""

from .data_products import (
    DataProduct,
    DataProductRegistry,
    QualityGateResult,
    QualityGateValidator,
    get_registry,
    get_validator,
    list_products,
    validate_product,
    get_mcp_resources,
    read_resource,
)

from .modelopt_client import (
    ModelInfo,
    InferenceRequest,
    InferenceResponse,
    ModelOptClient,
    get_client,
    infer,
    get_routing_recommendation,
    integrate_with_router,
)

__all__ = [
    # Data Products
    "DataProduct",
    "DataProductRegistry",
    "QualityGateResult",
    "QualityGateValidator",
    "get_registry",
    "get_validator",
    "list_products",
    "validate_product",
    "get_mcp_resources",
    "read_resource",
    # ModelOpt
    "ModelInfo",
    "InferenceRequest",
    "InferenceResponse",
    "ModelOptClient",
    "get_client",
    "infer",
    "get_routing_recommendation",
    "integrate_with_router",
]