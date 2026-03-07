# OData Vocabularies Integration for Data Cleaning Copilot

This module provides integration between SAP OData vocabularies and the data-cleaning-copilot validation framework.

## Overview

The OData integration module enables:
- **Parsing** OData vocabulary definitions (XML/JSON format)
- **Converting** OData validation terms to pandera checks
- **Generating** Table classes from OData `$metadata` documents
- **Integrating** with Database's rule-based check system

## Installation

The module is part of data-cleaning-copilot. Ensure you have the required dependencies:

```bash
pip install pandera pandas loguru
```

## Quick Start

### 1. Parse OData Vocabulary

```python
from definition.odata import ODataVocabularyParser, ValidationTermRegistry

# Parse SAP Common vocabulary
parser = ODataVocabularyParser()
vocab = parser.parse_file("odata-vocabularies-main/vocabularies/Common.xml")

# Register validation terms
registry = ValidationTermRegistry()
registry.register_vocabulary(vocab)

# List available validation terms
for term in registry.get_all_terms():
    print(f"{term.name}: {term.category.value}")
```

### 2. Convert OData Terms to Pandera Checks

```python
from definition.odata import ODataTermConverter

converter = ODataTermConverter()

# Convert single term
check = converter.term_to_check("IsDigitSequence")
# Returns: pa.Check.str_matches(r'^\d+$', name="IsDigitSequence")

# Convert multiple terms
checks = converter.annotations_to_checks([
    "IsUpperCase",
    "IsDigitSequence",
    "IsFiscalYear"
])
```

### 3. Generate Table Classes from OData Metadata

```python
from definition.odata import ODataTableGenerator

generator = ODataTableGenerator()

# From URL
tables = generator.generate_from_url("https://services.odata.org/V4/Northwind/$metadata")

# From file
tables = generator.generate_from_file("path/to/metadata.xml")

# Access generated table
CustomerTable = tables["Customer"]
print(f"Primary keys: {CustomerTable._primary_keys}")
print(f"Foreign keys: {CustomerTable._foreign_keys}")
```

### 4. Add OData Checks to Database

```python
from definition.base.database import Database
from definition.odata import add_odata_checks_to_database

# Create database
db = Database("my_database")
# ... register tables and load data ...

# Add OData-derived checks
add_odata_checks_to_database(
    database=db,
    annotations={
        "Customer": {
            "CustomerID": ["IsUpperCase", "IsDigitSequence"],
            "PostalCode": ["IsDigitSequence"],
            "Currency": ["IsCurrency"],
        },
        "Order": {
            "FiscalYear": ["IsFiscalYear"],
            "FiscalPeriod": ["IsFiscalPeriod"],
        },
    },
    vocabulary_path="odata-vocabularies-main/vocabularies/Common.xml"
)

# Validate
results = db.validate()

# Results include OData checks:
# - OData_Customer_CustomerID_IsUpperCase
# - OData_Customer_PostalCode_IsDigitSequence
# - OData_Order_FiscalYear_IsFiscalYear
```

### 5. Using ODataDatabaseExtension

```python
from definition.base.database import Database
from definition.odata import ODataDatabaseExtension

db = Database("my_database")
odata_ext = ODataDatabaseExtension(db)

# Load vocabulary
odata_ext.load_vocabulary("odata-vocabularies-main/vocabularies/Common.xml")

# Set annotations
odata_ext.set_column_annotations("Customer", "CustomerID", ["IsUpperCase"])
odata_ext.set_table_annotations("Order", {
    "FiscalYear": ["IsFiscalYear"],
    "FiscalPeriod": ["IsFiscalPeriod"],
})

# Derive and add checks
odata_ext.derive_odata_checks()

# Get summary
print(odata_ext.summary())
```

## Supported OData Terms

### String Format Terms
| Term | Description | Validation |
|------|-------------|------------|
| `IsDigitSequence` | Contains only digits | Regex: `^\d+$` |
| `IsUpperCase` | Contains only uppercase characters | Custom string check |

### Semantic Type Terms
| Term | Description | Validation |
|------|-------------|------------|
| `IsCurrency` | ISO 4217 currency code | Regex: `^[A-Z]{3}$` |
| `IsUnit` | Unit of measure code | Regex: `^[A-Za-z0-9]{1,3}$` |
| `IsLanguageIdentifier` | BCP 47 language tag | Regex pattern |
| `IsTimezone` | IANA timezone identifier | Regex pattern |

### Calendar Date Terms
| Term | Description | Regex Pattern |
|------|-------------|---------------|
| `IsCalendarYear` | Year number | `-?([1-9][0-9]{3,}\|0[0-9]{3})` |
| `IsCalendarHalfyear` | Half-year (1-2) | `[1-2]` |
| `IsCalendarQuarter` | Quarter (1-4) | `[1-4]` |
| `IsCalendarMonth` | Month (01-12) | `0[1-9]\|1[0-2]` |
| `IsCalendarWeek` | Week (01-53) | `0[1-9]\|[1-4][0-9]\|5[0-3]` |
| `IsCalendarYearHalfyear` | Year + halfyear | Pattern |
| `IsCalendarYearQuarter` | Year + quarter | Pattern |
| `IsCalendarYearMonth` | Year + month | Pattern |
| `IsCalendarYearWeek` | Year + week | Pattern |
| `IsCalendarDate` | Full calendar date | Pattern |
| `IsDayOfCalendarMonth` | Day of month (1-31) | Numeric range |
| `IsDayOfCalendarYear` | Day of year (1-366) | Numeric range |

### Fiscal Date Terms
| Term | Description | Regex Pattern |
|------|-------------|---------------|
| `IsFiscalYear` | Fiscal year | `[1-9][0-9]{3}` |
| `IsFiscalPeriod` | Fiscal period | `[0-9]{3}` |
| `IsFiscalYearPeriod` | Year + period | Pattern |
| `IsFiscalQuarter` | Fiscal quarter | `[1-4]` |
| `IsFiscalYearQuarter` | Year + quarter | Pattern |
| `IsFiscalWeek` | Fiscal week | Pattern |
| `IsFiscalYearWeek` | Year + week | Pattern |
| `IsDayOfFiscalYear` | Day of fiscal year | Numeric range |

## API Reference

### Classes

#### `ODataVocabularyParser`
Parses OData vocabulary XML files.

```python
parser = ODataVocabularyParser()
vocab = parser.parse_file("path/to/vocabulary.xml")
vocab = parser.parse_string(xml_content)
```

#### `ODataTermConverter`
Converts OData terms to pandera checks.

```python
converter = ODataTermConverter(registry=None)
check = converter.term_to_check("IsDigitSequence")
checks = converter.annotations_to_checks(["Term1", "Term2"])
supported = converter.get_supported_terms()
```

#### `ODataTableGenerator`
Generates Table classes from OData metadata.

```python
generator = ODataTableGenerator(vocabularies=None, term_converter=None)
tables = generator.generate_from_file("metadata.xml")
tables = generator.generate_from_url("https://service/$metadata")
tables = generator.generate_from_string(xml_content)
```

#### `ODataDatabaseExtension`
Extension class for Database with OData support.

```python
ext = ODataDatabaseExtension(database)
ext.load_vocabulary("path/to/vocabulary.xml")
ext.set_column_annotations("Table", "Column", ["Term1", "Term2"])
ext.set_table_annotations("Table", {"Col1": ["Term1"], "Col2": ["Term2"]})
ext.derive_odata_checks()
ext.get_available_terms()
ext.summary()
```

### Functions

#### `add_odata_checks_to_database()`
Add OData-derived checks to a Database instance.

```python
count = add_odata_checks_to_database(
    database=db,
    annotations={"Table": {"Column": ["Term1"]}},
    vocabulary_path="path/to/vocabulary.xml"  # Optional
)
```

#### `derive_odata_checks()`
Derive CheckLogic objects from annotations.

```python
checks = derive_odata_checks(
    table_annotations={"Table": {"Column": ["Term1"]}},
    vocabulary_registry=registry  # Optional
)
```

#### `generate_table_from_vocabulary()`
Generate a Table class from column definitions and annotations.

```python
TableClass = generate_table_from_vocabulary(
    columns={"Col1": "Edm.String", "Col2": "Edm.Int32"},
    annotations={"Col1": ["IsUpperCase"]},
    table_name="MyTable",
    primary_keys=["Col1"],
    foreign_keys={"Col2": ("OtherTable", "ID")}
)
```

## Architecture

```
definition/odata/
├── __init__.py              # Public API exports
├── vocabulary_parser.py     # Parse OData vocabulary XML
├── term_converter.py        # Convert terms to pandera checks
├── table_generator.py       # Generate Table classes from metadata
├── database_integration.py  # Database CheckLogic integration
├── test_odata_integration.py # Integration tests
└── README.md                # This documentation
```

### Data Flow

```
┌─────────────────┐
│  OData Vocab    │
│  (Common.xml)   │
└────────┬────────┘
         │ parse
         ▼
┌─────────────────┐
│ ODataVocabulary │
│ ODataTerm[]     │
└────────┬────────┘
         │ register
         ▼
┌─────────────────┐     ┌─────────────────┐
│ ValidationTerm  │     │ ODataMetadata   │
│ Registry        │     │ (from $metadata)│
└────────┬────────┘     └────────┬────────┘
         │                       │
         │ convert               │ generate
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ pandera Check   │     │ Table Classes   │
│ objects         │     │ (DataFrameModel)│
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     │ integrate
                     ▼
              ┌─────────────────┐
              │    Database     │
              │ rule_based_     │
              │ checks          │
              └────────┬────────┘
                       │ validate
                       ▼
              ┌─────────────────┐
              │  Violations     │
              │  DataFrame      │
              └─────────────────┘
```

## Testing

Run the integration tests:

```bash
cd data-cleaning-copilot-main
python -m definition.odata.test_odata_integration
```

## References

- [OData CSDL XML Specification](https://docs.oasis-open.org/odata/odata-csdl-xml/v4.01/)
- [SAP OData Vocabularies](https://github.com/SAP/odata-vocabularies)
- [Pandera Documentation](https://pandera.readthedocs.io/)

## License

Apache 2.0 - See LICENSE file in the repository root.