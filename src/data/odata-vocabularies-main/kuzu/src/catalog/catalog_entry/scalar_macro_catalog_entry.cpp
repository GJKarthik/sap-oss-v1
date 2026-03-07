#include "catalog/catalog_entry/scalar_macro_catalog_entry.h"

/**
 * P3-149: ScalarMacroCatalogEntry - Macro Metadata
 * 
 * Purpose:
 * Catalog entry for user-defined scalar macros. Stores macro name
 * and the ScalarMacroFunction containing the expression definition.
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── ScalarMacroCatalogEntry
 *         └── macroFunction: unique_ptr<ScalarMacroFunction>
 *               ├── parameters: vector<string>
 *               ├── defaultParameters: vector<ParsedExpression*>
 *               └── expression: unique_ptr<ParsedExpression>
 * ```
 * 
 * Scalar Macros:
 * ```
 * CREATE MACRO add_one(x) AS x + 1
 *   │
 *   ├── name = "add_one"
 *   └── macroFunction = ScalarMacroFunction {
 *         parameters: ["x"]
 *         defaultParameters: []
 *         expression: ParsedExpression(x + 1)
 *       }
 * 
 * CREATE MACRO greet(name := 'World') AS 'Hello ' || name
 *   │
 *   ├── name = "greet"
 *   └── macroFunction = ScalarMacroFunction {
 *         parameters: ["name"]
 *         defaultParameters: ["World"]  // Default value
 *         expression: ParsedExpression('Hello ' || name)
 *       }
 * ```
 * 
 * Key Operations:
 * 
 * 1. Constructor:
 *    - Takes name and ScalarMacroFunction
 *    - Sets type to SCALAR_MACRO_ENTRY
 * 
 * 2. serialize():
 *    - Calls CatalogEntry::serialize() for base fields
 *    - Delegates to macroFunction->serialize()
 * 
 * 3. deserialize():
 *    - Creates ScalarMacroCatalogEntry
 *    - Calls ScalarMacroFunction::deserialize()
 * 
 * 4. toCypher():
 *    - Generates CREATE MACRO statement
 *    - Delegates to macroFunction->toCypher(name)
 * 
 * Macro Expansion (during binding):
 * ```
 * SELECT add_one(5)
 *         │
 *         ├── Look up "add_one" in macros catalog
 *         ├── Get ScalarMacroCatalogEntry
 *         ├── Get expression tree from macroFunction
 *         ├── Substitute parameter x = 5
 *         └── Result: ParsedExpression(5 + 1)
 * ```
 * 
 * Difference from FunctionCatalogEntry:
 * - Functions: Compiled code (C++ implementations)
 * - Macros: Expression templates expanded at binding time
 * 
 * Entry Type:
 * - CatalogEntryType::SCALAR_MACRO_ENTRY
 */

namespace kuzu {
namespace catalog {

ScalarMacroCatalogEntry::ScalarMacroCatalogEntry(std::string name,
    std::unique_ptr<function::ScalarMacroFunction> macroFunction)
    : CatalogEntry{CatalogEntryType::SCALAR_MACRO_ENTRY, std::move(name)},
      macroFunction{std::move(macroFunction)} {}

void ScalarMacroCatalogEntry::serialize(common::Serializer& serializer) const {
    CatalogEntry::serialize(serializer);
    macroFunction->serialize(serializer);
}

std::unique_ptr<ScalarMacroCatalogEntry> ScalarMacroCatalogEntry::deserialize(
    common::Deserializer& deserializer) {
    auto scalarMacroCatalogEntry = std::make_unique<ScalarMacroCatalogEntry>();
    scalarMacroCatalogEntry->macroFunction =
        function::ScalarMacroFunction::deserialize(deserializer);
    return scalarMacroCatalogEntry;
}

std::string ScalarMacroCatalogEntry::toCypher(const ToCypherInfo& /*info*/) const {
    return macroFunction->toCypher(getName());
}

} // namespace catalog
} // namespace kuzu
