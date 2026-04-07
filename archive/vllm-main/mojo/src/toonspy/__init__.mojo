# ===----------------------------------------------------------------------=== #
# ToonSPy - DSPy-style framework with TOON output for SAP AI Core
#
# A declarative AI programming framework that combines:
# - DSPy patterns (Signatures, Modules)
# - TOON format (40-60% token savings)
# - Mangle rules (validation, schemas)
# - SAP AI Core integration
#
# ===----------------------------------------------------------------------=== #

from .signature import Signature, InputField, OutputField, Field
from .predict import Predict
from .chain_of_thought import ChainOfThought
from .react import ReAct
from .aicore import AICoreAdapter

# Version
alias VERSION = "0.1.0"

# Re-export common types
alias ToonSignature = Signature
alias ToonPredict = Predict
alias ToonCoT = ChainOfThought


fn get_version() -> String:
    """Return ToonSPy version."""
    return VERSION