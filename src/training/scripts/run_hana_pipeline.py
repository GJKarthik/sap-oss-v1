#!/usr/bin/env python3
"""
run_hana_pipeline.py — CLI orchestrator for HANA-Direct + Simula training data pipeline.

This script orchestrates the full pipeline:
1. Extract schemas from HANA Cloud via AI Core PAL MCP
2. Build taxonomies using reasoning-driven approach
3. Generate training data with Simula framework
4. Output to JSONL for model training

Usage:
    python run_hana_pipeline.py \
        --hana-schemas PAL_STORE,ESG_METRICS \
        --llm-url http://localhost:8000/v1 \
        --target-count 10000 \
        --output data/hana_generated/

Environment Variables:
    AICORE_PAL_MCP_URL: AI Core PAL MCP endpoint
    VLLM_BASE_URL: vLLM TurboQuant endpoint
    VLLM_MODEL: Model name for generation
    SIMULA_* : Various Simula configuration options
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from datetime import datetime
from pathlib import Path

# Add parent directories to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from pipeline.simula_config import SimulaConfig, HanaSourceConfig, LLMConfig, TaxonomyConfig, GenerationConfig
from pipeline.hana_schema_extractor import HanaSchemaExtractor
from pipeline.simula_taxonomy_builder import SimulaTaxonomyBuilder
from pipeline.simula_data_generator import SimulaDataGenerator


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler()],
)
logger = logging.getLogger("hana_pipeline")


async def run_pipeline(config: SimulaConfig) -> dict:
    """
    Run the full HANA-Direct + Simula pipeline.
    
    Args:
        config: Pipeline configuration
        
    Returns:
        Statistics dict
    """
    stats = {
        "start_time": datetime.now().isoformat(),
        "config": config.to_dict(),
    }
    
    # =========================================================================
    # Phase 1: Extract schemas from HANA Cloud
    # =========================================================================
    logger.info("=" * 60)
    logger.info("PHASE 1: Extracting schemas from HANA Cloud")
    logger.info("=" * 60)
    logger.info(f"MCP URL: {config.hana.mcp_url}")
    logger.info(f"Schemas: {config.hana.schemas}")
    
    extractor = HanaSchemaExtractor(config.hana)
    try:
        registry = await extractor.extract_all()
        stats["tables_extracted"] = registry.table_count()
        logger.info(f"Extracted {registry.table_count()} tables")
        
        if registry.table_count() == 0:
            logger.error("No tables extracted! Check HANA connection and schema names.")
            return stats
            
    except Exception as e:
        logger.error(f"Schema extraction failed: {e}")
        stats["error"] = f"Schema extraction failed: {e}"
        return stats
    finally:
        await extractor.close()
    
    # Save extracted schema for reference
    output_dir = Path(config.generation.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    schema_file = output_dir / "extracted_schema.json"
    with open(schema_file, "w") as f:
        json.dump(registry.to_dict(), f, indent=2)
    logger.info(f"Saved schema to {schema_file}")

    # =========================================================================
    # Phase 1.5: NL Readiness Assessment
    # =========================================================================
    logger.info("=" * 60)
    logger.info("PHASE 1.5: Assessing Natural Language Readiness")
    logger.info("=" * 60)

    spec_drift_dir = Path(__file__).resolve().parents[3] / "scripts" / "spec-drift"
    if str(spec_drift_dir) not in sys.path:
        sys.path.insert(0, str(spec_drift_dir))
    from nl_readiness_assessor import assess_schema_readiness, load_vocabulary_registry

    vocab_registry = load_vocabulary_registry()
    readiness_report = assess_schema_readiness(str(schema_file), vocab_registry)

    stats["nl_readiness"] = readiness_report.to_dict()
    logger.info(f"Readiness Score: {readiness_report.overall_score}/100")
    logger.info(f"Readiness Grade: {readiness_report.readiness_grade}")

    if not readiness_report.agent_ready:
        error_msg = (
            f"Pipeline halted: Schema readiness ({readiness_report.overall_score}) "
            f"is below AGENT_READY threshold. Please add business descriptions."
        )
        logger.error(error_msg)
        stats["error"] = error_msg
        return stats

    if not readiness_report.human_ready:
        logger.warning(
            f"Schema readiness ({readiness_report.overall_score}) is below HUMAN_READY threshold. "
            f"Human-facing artifacts will be degraded."
        )

    # =========================================================================
    # Phase 2: Build taxonomies
    # =========================================================================
    logger.info("=" * 60)
    logger.info("PHASE 2: Building taxonomies")
    logger.info("=" * 60)
    logger.info(f"Taxonomy depth: {config.taxonomy.depth}")
    logger.info(f"Best-of-N: {config.taxonomy.best_of_n}")
    logger.info(f"Critic enabled: {config.taxonomy.enable_critic}")
    
    builder = SimulaTaxonomyBuilder(config.llm, config.taxonomy)
    try:
        taxonomies = await builder.build_all_taxonomies(
            registry,
            domain_description="SAP BTP financial and analytics data",
            max_taxonomies=15,
        )
        stats["taxonomies_built"] = len(taxonomies)
        stats["taxonomy_details"] = [
            {"name": t.factor_name, "depth": t.depth, "nodes": t.node_count}
            for t in taxonomies
        ]
        logger.info(f"Built {len(taxonomies)} taxonomies")
        
        # Save taxonomies
        taxonomy_file = output_dir / "taxonomies.json"
        builder.save_taxonomies(taxonomies, taxonomy_file)
        
    except Exception as e:
        logger.error(f"Taxonomy building failed: {e}")
        stats["error"] = f"Taxonomy building failed: {e}"
        return stats
    finally:
        await builder.close()
    
    # =========================================================================
    # Phase 3: Generate training data
    # =========================================================================
    logger.info("=" * 60)
    logger.info("PHASE 3: Generating training data")
    logger.info("=" * 60)
    logger.info(f"Target count: {config.generation.target_count}")
    logger.info(f"Complexity ratio: {config.generation.complexity_ratio}")
    logger.info(f"Critic enabled: {config.generation.enable_critic}")
    
    generator = SimulaDataGenerator(
        taxonomies=taxonomies,
        registry=registry,
        llm_config=config.llm,
        generation_config=config.generation,
    )
    try:
        examples = await generator.generate_examples()
        stats["examples_generated"] = len(examples)
        stats["by_difficulty"] = {}
        stats["by_domain"] = {}
        stats["complexified_count"] = sum(1 for e in examples if e.is_complexified)
        
        for example in examples:
            stats["by_difficulty"][example.difficulty] = stats["by_difficulty"].get(example.difficulty, 0) + 1
            stats["by_domain"][example.domain] = stats["by_domain"].get(example.domain, 0) + 1
        
        # Save examples
        output_file = generator.save_examples(examples, output_dir)
        stats["output_file"] = str(output_file)
        
        logger.info(f"Generated {len(examples)} examples")
        logger.info(f"Saved to {output_file}")
        
    except Exception as e:
        logger.error(f"Data generation failed: {e}")
        stats["error"] = f"Data generation failed: {e}"
        return stats
    finally:
        await generator.close()
    
    # =========================================================================
    # Summary
    # =========================================================================
    stats["end_time"] = datetime.now().isoformat()
    stats["success"] = True
    
    # Save stats
    stats_file = output_dir / "pipeline_stats.json"
    with open(stats_file, "w") as f:
        json.dump(stats, f, indent=2)
    
    logger.info("=" * 60)
    logger.info("PIPELINE COMPLETE")
    logger.info("=" * 60)
    logger.info(f"Tables extracted: {stats.get('tables_extracted', 0)}")
    logger.info(f"Taxonomies built: {stats.get('taxonomies_built', 0)}")
    logger.info(f"Examples generated: {stats.get('examples_generated', 0)}")
    logger.info(f"Output: {stats.get('output_file', 'N/A')}")
    
    return stats


def main():
    parser = argparse.ArgumentParser(
        description="HANA-Direct + Simula training data pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic usage with default settings
  python run_hana_pipeline.py

  # Custom HANA schemas and output
  python run_hana_pipeline.py \\
      --hana-schemas PAL_STORE,ESG_METRICS \\
      --output data/my_training/

  # Full customization
  python run_hana_pipeline.py \\
      --hana-schemas PAL_STORE \\
      --mcp-url https://ai-core-pal.example.com/mcp \\
      --llm-url http://localhost:8000/v1 \\
      --llm-model Qwen/Qwen2.5-7B-Instruct \\
      --target-count 50000 \\
      --complexity-ratio 0.5 \\
      --taxonomy-depth 3 \\
      --output data/training/

Environment Variables:
  AICORE_PAL_MCP_URL     AI Core PAL MCP endpoint
  VLLM_BASE_URL          vLLM TurboQuant endpoint  
  VLLM_MODEL             Model name
  SIMULA_TARGET_COUNT    Target example count
  SIMULA_COMPLEXITY_RATIO Complexification ratio
""",
    )
    
    # HANA source options
    hana_group = parser.add_argument_group("HANA Source")
    hana_group.add_argument(
        "--hana-schemas",
        default=None,
        help="Comma-separated HANA schema names (default: from env or PAL_STORE)",
    )
    hana_group.add_argument(
        "--mcp-url",
        default=None,
        help="AI Core PAL MCP endpoint URL",
    )
    hana_group.add_argument(
        "--table-pattern",
        default=None,
        help="SQL LIKE pattern to filter table names",
    )
    
    # LLM options
    llm_group = parser.add_argument_group("LLM Configuration")
    llm_group.add_argument(
        "--llm-url",
        default=None,
        help="vLLM TurboQuant base URL (default: http://localhost:8000/v1)",
    )
    llm_group.add_argument(
        "--llm-model",
        default=None,
        help="Model name (default: Qwen/Qwen2.5-7B-Instruct)",
    )
    llm_group.add_argument(
        "--temperature",
        type=float,
        default=None,
        help="Generation temperature",
    )
    
    # Taxonomy options
    tax_group = parser.add_argument_group("Taxonomy Generation")
    tax_group.add_argument(
        "--taxonomy-depth",
        type=int,
        default=None,
        help="Maximum taxonomy depth (default: 3)",
    )
    tax_group.add_argument(
        "--best-of-n",
        type=int,
        default=None,
        help="Best-of-N sampling count (default: 5)",
    )
    tax_group.add_argument(
        "--no-taxonomy-critic",
        action="store_true",
        help="Disable taxonomy critic refinement",
    )
    
    # Generation options
    gen_group = parser.add_argument_group("Data Generation")
    gen_group.add_argument(
        "--target-count",
        type=int,
        default=None,
        help="Target number of training examples (default: 100000)",
    )
    gen_group.add_argument(
        "--complexity-ratio",
        type=float,
        default=None,
        help="Fraction of examples to complexify (default: 0.5)",
    )
    gen_group.add_argument(
        "--no-generation-critic",
        action="store_true",
        help="Disable generation critic filtering",
    )
    gen_group.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducibility",
    )
    
    # Output options
    out_group = parser.add_argument_group("Output")
    out_group.add_argument(
        "--output",
        "-o",
        default=None,
        help="Output directory (default: data/hana_generated)",
    )
    
    # General options
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose logging",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print configuration and exit without running",
    )
    
    args = parser.parse_args()
    
    # Set log level
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Build configuration from CLI args (with env fallback)
    config = SimulaConfig.from_env()
    
    # Apply CLI overrides
    if args.hana_schemas:
        config.hana.schemas = [s.strip() for s in args.hana_schemas.split(",")]
    if args.mcp_url:
        config.hana.mcp_url = args.mcp_url
    if args.table_pattern:
        config.hana.table_pattern = args.table_pattern
    
    if args.llm_url:
        config.llm.base_url = args.llm_url
    if args.llm_model:
        config.llm.model = args.llm_model
    if args.temperature is not None:
        config.llm.temperature = args.temperature
    
    if args.taxonomy_depth is not None:
        config.taxonomy.depth = args.taxonomy_depth
    if args.best_of_n is not None:
        config.taxonomy.best_of_n = args.best_of_n
    if args.no_taxonomy_critic:
        config.taxonomy.enable_critic = False
    
    if args.target_count is not None:
        config.generation.target_count = args.target_count
    if args.complexity_ratio is not None:
        config.generation.complexity_ratio = args.complexity_ratio
    if args.no_generation_critic:
        config.generation.enable_critic = False
    if args.seed is not None:
        config.generation.seed = args.seed
    if args.output:
        config.generation.output_dir = args.output
    
    # Print configuration
    logger.info("Pipeline Configuration:")
    logger.info(json.dumps(config.to_dict(), indent=2))
    
    if args.dry_run:
        logger.info("Dry run mode - exiting without execution")
        return
    
    # Run pipeline
    try:
        stats = asyncio.run(run_pipeline(config))
        
        if stats.get("success"):
            logger.info("Pipeline completed successfully!")
            sys.exit(0)
        else:
            logger.error(f"Pipeline failed: {stats.get('error', 'Unknown error')}")
            sys.exit(1)
            
    except KeyboardInterrupt:
        logger.info("Pipeline interrupted by user")
        sys.exit(130)
    except Exception as e:
        logger.exception(f"Pipeline crashed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
