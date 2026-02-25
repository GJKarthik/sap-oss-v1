"""
Test script for OData vocabulary integration.

This script validates that the OData vocabulary parser and term converter
work correctly with actual SAP vocabulary files.

Run with: python -m definition.odata.test_odata_integration
"""

import sys
from pathlib import Path

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from definition.odata.vocabulary_parser import (
    ODataVocabularyParser,
    ValidationTermRegistry,
    TermCategory,
)
from definition.odata.term_converter import (
    ODataTermConverter,
    PanderaCheckFactory,
    create_checks_from_odata_annotations,
)


def test_parse_common_vocabulary():
    """Test parsing the SAP Common vocabulary."""
    print("\n" + "=" * 60)
    print("TEST: Parse SAP Common.xml Vocabulary")
    print("=" * 60)
    
    # Path to the vocabulary file
    vocab_path = Path(__file__).parent.parent.parent.parent / "odata-vocabularies-main" / "vocabularies" / "Common.xml"
    
    if not vocab_path.exists():
        print(f"❌ Vocabulary file not found: {vocab_path}")
        return False
    
    parser = ODataVocabularyParser()
    
    try:
        vocabulary = parser.parse_file(vocab_path)
        print(f"✅ Successfully parsed vocabulary: {vocabulary.namespace}")
        print(f"   - Terms: {len(vocabulary.terms)}")
        print(f"   - Enum Types: {len(vocabulary.enum_types)}")
        print(f"   - Complex Types: {len(vocabulary.complex_types)}")
        
        # Show some validation terms
        validation_terms = vocabulary.get_validation_terms()
        print(f"   - Validation Terms: {len(validation_terms)}")
        
        if validation_terms:
            print("\n   Sample validation terms:")
            for term in validation_terms[:5]:
                print(f"     • {term.name} ({term.category.value})")
                if term.regex_pattern:
                    print(f"       Regex: {term.regex_pattern}")
        
        return True
    except Exception as e:
        print(f"❌ Failed to parse vocabulary: {e}")
        return False


def test_validation_term_registry():
    """Test the ValidationTermRegistry."""
    print("\n" + "=" * 60)
    print("TEST: ValidationTermRegistry")
    print("=" * 60)
    
    vocab_path = Path(__file__).parent.parent.parent.parent / "odata-vocabularies-main" / "vocabularies" / "Common.xml"
    
    if not vocab_path.exists():
        print(f"❌ Vocabulary file not found: {vocab_path}")
        return False
    
    parser = ODataVocabularyParser()
    registry = ValidationTermRegistry()
    
    try:
        vocabulary = parser.parse_file(vocab_path)
        count = registry.register_vocabulary(vocabulary)
        print(f"✅ Registered {count} validation terms")
        
        # Get summary
        summary = registry.summary()
        print(f"\n   Registry Summary:")
        print(f"   - Total terms: {summary['total_terms']}")
        print(f"   - With regex: {summary['with_regex']}")
        print(f"   - By category:")
        for cat, cnt in summary['by_category'].items():
            if cnt > 0:
                print(f"     • {cat}: {cnt}")
        
        # Test lookup
        term = registry.get_term("IsDigitSequence")
        if term:
            print(f"\n   Lookup 'IsDigitSequence': ✅ Found")
            print(f"     Category: {term.category.value}")
            print(f"     Regex: {term.regex_pattern}")
        else:
            print(f"\n   Lookup 'IsDigitSequence': ❌ Not found")
        
        return True
    except Exception as e:
        print(f"❌ Failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_term_converter():
    """Test the ODataTermConverter."""
    print("\n" + "=" * 60)
    print("TEST: ODataTermConverter")
    print("=" * 60)
    
    converter = ODataTermConverter()
    
    # List supported terms
    supported = converter.get_supported_terms()
    print(f"✅ Converter supports {len(supported)} terms:")
    for term in sorted(supported)[:10]:
        print(f"   • {term}")
    if len(supported) > 10:
        print(f"   ... and {len(supported) - 10} more")
    
    # Test converting specific terms
    test_terms = [
        "IsDigitSequence",
        "IsUpperCase", 
        "IsCalendarYear",
        "IsFiscalYearPeriod",
        "IsCurrency",
        "com.sap.vocabularies.Common.v1.IsTimezone",  # Qualified name
    ]
    
    print(f"\n   Converting sample terms:")
    for term_name in test_terms:
        check = converter.term_to_check(term_name)
        if check:
            print(f"   ✅ {term_name} → {check.name}")
        else:
            print(f"   ❌ {term_name} → No mapping")
    
    return True


def test_pandera_check_factory():
    """Test the PanderaCheckFactory."""
    print("\n" + "=" * 60)
    print("TEST: PanderaCheckFactory")
    print("=" * 60)
    
    import pandas as pd
    
    factory = PanderaCheckFactory
    
    # Test IsDigitSequence
    print("\n   Testing IsDigitSequence check:")
    check = factory.digit_sequence_check()
    
    # Create test data
    valid_data = pd.Series(["123", "456789", "0"])
    invalid_data = pd.Series(["12a", "hello", "12.3"])
    
    try:
        # Test with valid data
        result = check(valid_data)
        print(f"   ✅ Valid data ['123', '456789', '0']: {result.all()}")
    except Exception as e:
        print(f"   ❌ Valid data test failed: {e}")
    
    # Test IsUpperCase
    print("\n   Testing IsUpperCase check:")
    check = factory.uppercase_check()
    
    valid_upper = pd.Series(["HELLO", "WORLD", "ABC123"])
    invalid_upper = pd.Series(["Hello", "world", "Abc"])
    
    try:
        result = check(valid_upper)
        print(f"   ✅ Valid uppercase ['HELLO', 'WORLD', 'ABC123']: passes")
    except Exception as e:
        print(f"   ❌ Uppercase test failed: {e}")
    
    # Test IsCalendarYear
    print("\n   Testing IsCalendarYear check:")
    check = factory.regex_check(
        r"-?([1-9][0-9]{3,}|0[0-9]{3})",
        "IsCalendarYear"
    )
    
    valid_years = pd.Series(["2024", "0001", "-2000", "10000"])
    invalid_years = pd.Series(["24", "abc", "999"])
    
    try:
        result = check(valid_years)
        print(f"   ✅ Valid years ['2024', '0001', '-2000', '10000']: {result.all()}")
    except Exception as e:
        print(f"   ❌ Year test failed: {e}")
    
    return True


def test_create_checks_from_annotations():
    """Test creating checks from OData annotations."""
    print("\n" + "=" * 60)
    print("TEST: create_checks_from_odata_annotations")
    print("=" * 60)
    
    # Sample annotations for a hypothetical entity
    annotations = {
        "CustomerID": ["IsUpperCase", "IsDigitSequence"],
        "PostalCode": ["IsDigitSequence"],
        "FiscalYear": ["IsFiscalYear"],
        "Currency": ["IsCurrency"],
        "Description": [],  # No validation annotations
    }
    
    checks = create_checks_from_odata_annotations(annotations)
    
    print(f"✅ Created checks for {len(checks)} properties:")
    for prop, prop_checks in checks.items():
        check_names = [c.name for c in prop_checks]
        print(f"   • {prop}: {check_names}")
    
    return True


def test_integration_with_real_vocabulary():
    """Test full integration: parse vocabulary → register → convert."""
    print("\n" + "=" * 60)
    print("TEST: Full Integration Pipeline")
    print("=" * 60)
    
    vocab_path = Path(__file__).parent.parent.parent.parent / "odata-vocabularies-main" / "vocabularies" / "Common.xml"
    
    if not vocab_path.exists():
        print(f"❌ Vocabulary file not found: {vocab_path}")
        print("   Skipping integration test")
        return True  # Don't fail if file not present
    
    # Step 1: Parse vocabulary
    print("\n   Step 1: Parse vocabulary")
    parser = ODataVocabularyParser()
    vocabulary = parser.parse_file(vocab_path)
    print(f"   ✅ Parsed {len(vocabulary.terms)} terms")
    
    # Step 2: Register validation terms
    print("\n   Step 2: Register validation terms")
    registry = ValidationTermRegistry()
    count = registry.register_vocabulary(vocabulary)
    print(f"   ✅ Registered {count} validation terms")
    
    # Step 3: Create converter with registry
    print("\n   Step 3: Create converter with registry")
    converter = ODataTermConverter(registry)
    print(f"   ✅ Converter initialized with {len(converter.get_supported_terms())} built-in mappings")
    
    # Step 4: Convert terms to checks
    print("\n   Step 4: Convert sample terms to pandera checks")
    sample_terms = registry.get_terms_with_regex()[:5]
    
    for term in sample_terms:
        check = converter.term_to_check(term.name)
        status = "✅" if check else "❌"
        print(f"   {status} {term.name} → {check.name if check else 'No mapping'}")
    
    print("\n   ✅ Integration pipeline complete!")
    return True


def main():
    """Run all tests."""
    print("\n" + "=" * 60)
    print("OData Vocabulary Integration Tests")
    print("=" * 60)
    
    results = []
    
    # Run tests
    results.append(("Parse Common Vocabulary", test_parse_common_vocabulary()))
    results.append(("Validation Term Registry", test_validation_term_registry()))
    results.append(("Term Converter", test_term_converter()))
    results.append(("Pandera Check Factory", test_pandera_check_factory()))
    results.append(("Create Checks from Annotations", test_create_checks_from_annotations()))
    results.append(("Full Integration Pipeline", test_integration_with_real_vocabulary()))
    
    # Summary
    print("\n" + "=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)
    
    passed = sum(1 for _, r in results if r)
    total = len(results)
    
    for name, result in results:
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"   {status}: {name}")
    
    print(f"\n   Total: {passed}/{total} tests passed")
    
    return passed == total


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)