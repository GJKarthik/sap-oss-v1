#!/usr/bin/env python3
"""
Real Schema Metadata Parser.

Parses the 4 actual metadata pipelines to extract real table names, column names,
descriptions, hierarchy values, and lineage mappings for training data generation.

Pipelines:
  1. Treasury Data Dictionary (DATA_DICTIONARY__Dictionary.csv, Filters.csv)
  2. ESG Data Dictionary (ESG__DATA_DICTIONARY__*.csv)
  3. Performance/NFRP Star Schema (CRD Fact + 5 dimension hierarchies)
  4. Staging/Lineage (1_register, 2_stagingschema, 3_validations)
"""

import csv
import os
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field


@dataclass
class ColumnDef:
    """A real column definition from the metadata."""
    technical_name: str
    business_name: str
    description: str = ""
    long_description: str = ""
    data_type: str = ""
    field_type: str = ""  # dimension, measure
    model: str = ""       # Net Zero, Client, Sustainable, Treasury
    domain: str = ""      # treasury, esg, performance, staging


@dataclass
class HierarchyNode:
    """A node in a dimension hierarchy."""
    levels: Dict[str, str] = field(default_factory=dict)  # {L0: val, L1: val, ...}
    indicator: str = ""  # CRD_INDICATOR (CIB, WRB, FPNA)
    pk: str = ""


@dataclass
class StagingMapping:
    """A source-to-BTP field mapping."""
    use_case: str = ""
    source_system: str = ""
    source_table: str = ""
    source_field: str = ""
    btp_schema: str = ""
    btp_table: str = ""
    btp_field: str = ""
    description: str = ""
    data_type: str = ""


@dataclass
class RealSchemaMetadata:
    """Container for all parsed real-schema metadata."""
    # Pipeline 1: Treasury
    treasury_columns: List[ColumnDef] = field(default_factory=list)
    treasury_filter_countries: List[str] = field(default_factory=list)
    treasury_filter_dates: List[str] = field(default_factory=list)
    treasury_filter_products: List[str] = field(default_factory=list)

    # Pipeline 2: ESG
    esg_columns: List[ColumnDef] = field(default_factory=list)
    esg_client_fields: List[ColumnDef] = field(default_factory=list)
    esg_netzero_fields: List[ColumnDef] = field(default_factory=list)
    esg_sustainable_fields: List[ColumnDef] = field(default_factory=list)

    # Pipeline 3: Performance/NFRP
    crd_fact_attrs: List[ColumnDef] = field(default_factory=list)
    account_hierarchy: List[HierarchyNode] = field(default_factory=list)
    location_hierarchy: List[HierarchyNode] = field(default_factory=list)
    product_hierarchy: List[HierarchyNode] = field(default_factory=list)
    segment_hierarchy: List[HierarchyNode] = field(default_factory=list)
    cost_hierarchy: List[HierarchyNode] = field(default_factory=list)

    # Pipeline 4: Staging/Lineage
    staging_mappings: List[StagingMapping] = field(default_factory=list)
    source_systems: List[str] = field(default_factory=list)
    btp_tables: List[str] = field(default_factory=list)
    validation_enums: Dict[str, List[str]] = field(default_factory=dict)


def _read_csv_safe(path: str) -> List[List[str]]:
    """Read CSV handling BOM, encoding issues, and ragged rows."""
    rows = []
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            reader = csv.reader(f)
            for row in reader:
                rows.append(row)
    except (FileNotFoundError, UnicodeDecodeError):
        pass
    return rows


def _clean(val: str) -> str:
    """Strip whitespace and quotes."""
    return val.strip().strip('"').strip()


def parse_treasury_dictionary(csv_dir: str) -> Tuple[List[ColumnDef], List[str], List[str], List[str]]:
    """Parse Treasury DATA_DICTIONARY csvs."""
    columns = []
    dict_path = os.path.join(csv_dir, "DATA_DICTIONARY__Dictionary.csv")
    rows = _read_csv_safe(dict_path)
    for row in rows[1:]:  # skip header
        if len(row) >= 3 and _clean(row[0]):
            col = ColumnDef(
                technical_name=_clean(row[0]),
                business_name=_clean(row[1]),
                long_description=_clean(row[2]) if len(row) > 2 else "",
                domain="treasury",
                model="Treasury",
            )
            columns.append(col)

    # Parse filters
    countries, dates, products = [], [], []
    filter_path = os.path.join(csv_dir, "DATA_DICTIONARY__Filters.csv")
    frows = _read_csv_safe(filter_path)
    for row in frows[1:]:
        if len(row) >= 1 and _clean(row[0]):
            d = _clean(row[0]).split(" ")[0]
            if d and d[0].isdigit():
                dates.append(d)
        if len(row) >= 3 and _clean(row[2]):
            countries.append(_clean(row[2]))
        if len(row) >= 2 and _clean(row[1]):
            products.append(_clean(row[1]))

    return columns, list(set(countries)), list(set(dates)), list(set(products))


def parse_esg_dictionary(csv_dir: str) -> Tuple[List[ColumnDef], List[ColumnDef], List[ColumnDef], List[ColumnDef]]:
    """Parse ESG DATA_DICTIONARY csvs."""
    # Main dictionary (177 field defs)
    esg_cols = []
    dict_path = os.path.join(csv_dir, "ESG__DATA_DICTIONARY__Dictionary.csv")
    rows = _read_csv_safe(dict_path)
    for row in rows[2:]:  # skip 2 header rows
        if len(row) >= 6 and _clean(row[3]):  # COLUMN is col index 3
            col = ColumnDef(
                technical_name=_clean(row[3]),
                business_name=_clean(row[4]),
                description=_clean(row[5]) if len(row) > 5 else "",
                long_description=_clean(row[6]) if len(row) > 6 else "",
                field_type=_clean(row[2]) if len(row) > 2 else "",  # Measures/Dimension
                model=_clean(row[1]) if len(row) > 1 else "",
                domain="esg",
            )
            esg_cols.append(col)

    # Sub-model field mappings (tech_name → business_name)
    def _parse_field_map(filename: str) -> List[ColumnDef]:
        fields = []
        path = os.path.join(csv_dir, filename)
        rows = _read_csv_safe(path)
        for row in rows[2:]:  # skip header rows
            tech = _clean(row[1]) if len(row) > 1 else ""
            biz = _clean(row[2]) if len(row) > 2 else ""
            if tech and tech != "Technical name":
                fields.append(ColumnDef(
                    technical_name=tech.rstrip(","),
                    business_name=biz,
                    domain="esg",
                ))
        return fields

    client = _parse_field_map("ESG__DATA_DICTIONARY__Client.csv")
    netzero = _parse_field_map("ESG__DATA_DICTIONARY__NetZero.csv")
    sustainable = _parse_field_map("ESG__DATA_DICTIONARY__Sustainable.csv")

    return esg_cols, client, netzero, sustainable


def parse_nfrp_star_schema(csv_dir: str) -> Tuple[
    List[ColumnDef], List[HierarchyNode], List[HierarchyNode],
    List[HierarchyNode], List[HierarchyNode], List[HierarchyNode]
]:
    """Parse Performance CRD Fact + 5 NFRP dimension hierarchies."""
    # CRD Fact definitions
    fact_attrs = []
    fact_path = os.path.join(csv_dir, "Performance_CRD_-_Fact_table__Fact_table_-_definitions.csv")
    rows = _read_csv_safe(fact_path)
    for row in rows[1:]:
        if len(row) >= 2 and _clean(row[0]):
            fact_attrs.append(ColumnDef(
                technical_name=_clean(row[0]),
                business_name=_clean(row[0]),
                description=_clean(row[1]),
                domain="performance",
            ))

    def _parse_hierarchy(data_file: str, prefix: str, num_levels: int) -> List[HierarchyNode]:
        """Parse a dimension hierarchy CSV into HierarchyNode objects."""
        nodes = []
        path = os.path.join(csv_dir, data_file)
        rows = _read_csv_safe(path)
        if not rows:
            return nodes
        header = rows[0]
        for row in rows[1:]:
            if len(row) < num_levels + 1:
                continue
            levels = {}
            for i in range(num_levels):
                level_name = f"{prefix} (L{i})" if prefix != "M_SEGMENT" else f"M_SEGMENT_{i}"
                val = _clean(row[i]) if i < len(row) else ""
                if val:
                    levels[f"L{i}"] = val
            indicator = ""
            pk = ""
            # Indicator and PK are typically the last two columns
            if len(row) > num_levels:
                indicator = _clean(row[num_levels])
            if len(row) > num_levels + 1:
                pk = _clean(row[num_levels + 1])
            if levels:
                nodes.append(HierarchyNode(levels=levels, indicator=indicator, pk=pk))
        return nodes

    account = _parse_hierarchy("NFRP_Account_AM__NFRP_Account_AM.csv", "ACCOUNT", 6)
    location = _parse_hierarchy("NFRP_Location_AM__NFRP_Location_AM.csv", "LOCATION", 7)
    product = _parse_hierarchy("NFRP_Product_AM__NFRP_Product_AM.csv", "PRODUCT", 5)
    # Segment has different column naming: E_SEGMENT_0, M_SEGMENT_0..4, M_SEGMENT_CONCAT
    segment = _parse_segment_hierarchy(csv_dir)
    # Cost has COSTCLUSTER_CRD_INDICATOR as first col, then PK, then L0-L5
    cost = _parse_cost_hierarchy(csv_dir)

    return fact_attrs, account, location, product, segment, cost


def _parse_segment_hierarchy(csv_dir: str) -> List[HierarchyNode]:
    """Parse segment hierarchy with its unique column naming."""
    nodes = []
    path = os.path.join(csv_dir, "NFRP_Segment_AM__NFRP_Segment_AM.csv")
    rows = _read_csv_safe(path)
    for row in rows[1:]:
        if len(row) < 6:
            continue
        levels = {}
        # E_SEGMENT_0, M_SEGMENT_0, M_SEGMENT_1, M_SEGMENT_2, M_SEGMENT_3, M_SEGMENT_4, CONCAT
        indicator = _clean(row[0])  # E_SEGMENT_0
        for i in range(5):
            val = _clean(row[i + 1]) if i + 1 < len(row) else ""
            if val:
                levels[f"L{i}"] = val
        pk = _clean(row[6]) if len(row) > 6 else ""
        if levels:
            nodes.append(HierarchyNode(levels=levels, indicator=indicator, pk=pk))
    return nodes


def _parse_cost_hierarchy(csv_dir: str) -> List[HierarchyNode]:
    """Parse cost hierarchy with indicator and PK as first two cols."""
    nodes = []
    path = os.path.join(csv_dir, "NFRP_Cost_AM__NFRP_Cost_AM.csv")
    rows = _read_csv_safe(path)
    for row in rows[1:]:
        if len(row) < 8:
            continue
        indicator = _clean(row[0])  # COSTCLUSTER_CRD_INDICATOR
        pk = _clean(row[1])         # COSTCLUSTER_PK
        levels = {}
        for i in range(6):
            val = _clean(row[i + 2]) if i + 2 < len(row) else ""
            if val:
                levels[f"L{i}"] = val
        if levels:
            nodes.append(HierarchyNode(levels=levels, indicator=indicator, pk=pk))
    return nodes


def parse_staging_lineage(data_dir: str) -> Tuple[List[StagingMapping], List[str], List[str], Dict[str, List[str]]]:
    """Parse staging/lineage pipeline from 1_register, 2_stagingschema, 3_validations."""
    mappings = []
    source_systems = set()
    btp_tables = set()

    # 2_stagingschema.csv — field-level lineage
    staging_path = os.path.join(data_dir, "2_stagingschema.csv")
    rows = _read_csv_safe(staging_path)
    for row in rows[3:]:  # skip 2 header rows + mandatory row
        if len(row) < 10:
            continue
        use_case = _clean(row[1]) if len(row) > 1 else ""
        src_sys = _clean(row[2]) if len(row) > 2 else ""
        src_table = _clean(row[3]) if len(row) > 3 else ""
        src_field = _clean(row[4]) if len(row) > 4 else ""
        btp_schema = _clean(row[5]) if len(row) > 5 else ""
        btp_table = _clean(row[6]) if len(row) > 6 else ""
        btp_field = _clean(row[7]) if len(row) > 7 else ""
        desc = _clean(row[8]) if len(row) > 8 else ""
        dtype = _clean(row[9]) if len(row) > 9 else ""

        if btp_field or src_field:
            mappings.append(StagingMapping(
                use_case=use_case, source_system=src_sys,
                source_table=src_table, source_field=src_field,
                btp_schema=btp_schema, btp_table=btp_table,
                btp_field=btp_field, description=desc, data_type=dtype,
            ))
            if src_sys:
                source_systems.add(src_sys)
            if btp_table:
                btp_tables.add(btp_table)

    # 3_validations.csv — enumeration values
    validation_enums: Dict[str, List[str]] = {}
    val_path = os.path.join(data_dir, "3_validations.csv")
    rows = _read_csv_safe(val_path)
    if rows:
        headers = [_clean(h) for h in rows[0]]
        for col_idx, header in enumerate(headers):
            if not header:
                continue
            vals = set()
            for row in rows[1:]:
                if col_idx < len(row) and _clean(row[col_idx]):
                    vals.add(_clean(row[col_idx]))
            if vals:
                validation_enums[header] = sorted(vals)

    return mappings, sorted(source_systems), sorted(btp_tables), validation_enums


def load_all_metadata(base_dir: Optional[str] = None) -> RealSchemaMetadata:
    """Load all real schema metadata from the data directory.

    Args:
        base_dir: Path to src/training/data/. Auto-detected if None.
    """
    if base_dir is None:
        base_dir = str(Path(__file__).parent.parent / "data")

    csv_dir = os.path.join(base_dir, "csv")
    meta = RealSchemaMetadata()

    # Pipeline 1: Treasury
    try:
        cols, countries, dates, products = parse_treasury_dictionary(csv_dir)
        meta.treasury_columns = cols
        meta.treasury_filter_countries = countries
        meta.treasury_filter_dates = dates
        meta.treasury_filter_products = products
    except Exception:
        pass

    # Pipeline 2: ESG
    try:
        esg_cols, client, netzero, sustainable = parse_esg_dictionary(csv_dir)
        meta.esg_columns = esg_cols
        meta.esg_client_fields = client
        meta.esg_netzero_fields = netzero
        meta.esg_sustainable_fields = sustainable
    except Exception:
        pass

    # Pipeline 3: Performance/NFRP
    try:
        fact, account, location, product, segment, cost = parse_nfrp_star_schema(csv_dir)
        meta.crd_fact_attrs = fact
        meta.account_hierarchy = account
        meta.location_hierarchy = location
        meta.product_hierarchy = product
        meta.segment_hierarchy = segment
        meta.cost_hierarchy = cost
    except Exception:
        pass

    # Pipeline 4: Staging/Lineage
    try:
        mappings, systems, tables, enums = parse_staging_lineage(base_dir)
        meta.staging_mappings = mappings
        meta.source_systems = systems
        meta.btp_tables = tables
        meta.validation_enums = enums
    except Exception:
        pass

    return meta

