"""
API Routes for SAP AI Fabric Console
"""

from . import auth
from . import models
from . import rag
from . import deployments
from . import datasources
from . import lineage
from . import governance
from . import metrics

__all__ = [
    "auth",
    "models", 
    "rag",
    "deployments",
    "datasources",
    "lineage",
    "governance",
    "metrics",
]