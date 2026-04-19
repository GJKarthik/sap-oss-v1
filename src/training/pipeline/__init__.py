# =============================================================================
# Text-to-SQL Pipeline — Python Implementation
# Replaces the former Zig pipeline with pure Python + SAP HANA Cloud backend
# =============================================================================

__version__ = "0.5.0"  # v1.2: Added adaptive features, taxonomy evaluator, diversity optimizer

# Core schema registry
from .schema_registry import SchemaRegistry, TableSchema, Column, Domain

# Template-based generation (legacy)
from .template_parser import Template, TemplateParam, parse_templates_csv as parse_templates
from .template_expander import TrainingPair, expand_template, expand_all

# Simula Framework — HANA-Direct Training Data Pipeline
from .simula_config import (
    SimulaConfig,
    HanaSourceConfig,
    LLMConfig,
    TaxonomyConfig,
    GenerationConfig,
    TrainingConfig,
    LLMProvider,
)
from .simula_llm_client import SimulaLLMClient, LLMResponse
from .hana_schema_extractor import (
    HanaSchemaExtractor,
    extract_hana_schemas,
    extract_hana_schemas_sync,
)
from .simula_taxonomy_builder import (
    SimulaTaxonomyBuilder,
    Taxonomy,
    TaxonomyNode,
    Factor,
    build_taxonomies,
    build_taxonomies_sync,
)
from .simula_data_generator import (
    SimulaDataGenerator,
    TrainingExample,
    SamplingStrategy,
    generate_training_data,
    generate_training_data_sync,
)

# Simula Evaluation Framework (Section 2.3, 3.1, 3.3 from 6171 paper)
from .simula_complexity_calibrator import (
    SimulaComplexityCalibrator,
    ComplexityConfig,
    ComplexityScore,
)
from .simula_coverage_evaluator import (
    SimulaCoverageEvaluator,
    CoverageConfig,
    CoverageReport,
    identify_coverage_gaps,
)
from .simula_diversity_analyzer import (
    SimulaDiversityAnalyzer,
    DiversityConfig,
    DiversityReport,
)
from .simula_critic_validator import (
    SimulaCriticValidator,
    CriticValidationConfig,
    CriticValidationReport,
)

# v1.2 Additions — Address Review Gaps (10/10 target)
from .simula_taxonomy_evaluator import (
    SimulaTaxonomyEvaluator,
    TaxonomyQualityReport,
    TaxonomyEvaluatorConfig,
    TaxonomyQualityError,
)
from .simula_coverage_evaluator import fill_coverage_gaps
from .simula_diversity_optimizer import (
    SimulaDiversityOptimizer,
    DiversityTargets,
    WeightAdjustment,
)

__all__ = [
    # Version
    "__version__",
    # Schema registry
    "SchemaRegistry",
    "TableSchema",
    "Column",
    "Domain",
    # Template-based (legacy)
    "Template",
    "TemplateParam",
    "parse_templates",
    "TrainingPair",
    "expand_template",
    "expand_all",
    # Simula config
    "SimulaConfig",
    "HanaSourceConfig",
    "LLMConfig",
    "TaxonomyConfig",
    "GenerationConfig",
    "TrainingConfig",
    "LLMProvider",
    # Simula LLM client
    "SimulaLLMClient",
    "LLMResponse",
    # HANA schema extraction
    "HanaSchemaExtractor",
    "extract_hana_schemas",
    "extract_hana_schemas_sync",
    # Taxonomy builder
    "SimulaTaxonomyBuilder",
    "Taxonomy",
    "TaxonomyNode",
    "Factor",
    "build_taxonomies",
    "build_taxonomies_sync",
    # Data generator
    "SimulaDataGenerator",
    "TrainingExample",
    "SamplingStrategy",
    "generate_training_data",
    "generate_training_data_sync",
    # Evaluation framework (6171 paper compliance)
    "SimulaComplexityCalibrator",
    "ComplexityConfig",
    "ComplexityScore",
    "SimulaCoverageEvaluator",
    "CoverageConfig",
    "CoverageReport",
    "identify_coverage_gaps",
    "SimulaDiversityAnalyzer",
    "DiversityConfig",
    "DiversityReport",
    "SimulaCriticValidator",
    "CriticValidationConfig",
    "CriticValidationReport",
    # v1.2 additions (10/10 compliance)
    "SimulaTaxonomyEvaluator",
    "TaxonomyQualityReport",
    "TaxonomyEvaluatorConfig",
    "TaxonomyQualityError",
    "fill_coverage_gaps",
    "SimulaDiversityOptimizer",
    "DiversityTargets",
    "WeightAdjustment",
]
