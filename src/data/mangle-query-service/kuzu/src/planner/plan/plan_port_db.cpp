#include "binder/bound_export_database.h"
#include "binder/bound_import_database.h"
#include "catalog/catalog.h"
#include "common/file_system/virtual_file_system.h"
#include "common/string_utils.h"
#include "function/built_in_function_utils.h"
#include "planner/operator/persistent/logical_copy_to.h"
#include "planner/operator/simple/logical_export_db.h"
#include "planner/operator/simple/logical_import_db.h"
#include "planner/planner.h"
#include "transaction/transaction.h"

using namespace kuzu::binder;
using namespace kuzu::storage;
using namespace kuzu::catalog;
using namespace kuzu::common;
using namespace kuzu::transaction;

namespace kuzu {
namespace planner {

std::vector<std::shared_ptr<LogicalOperator>> Planner::planExportTableData(
    const BoundStatement& statement) {
    std::vector<std::shared_ptr<LogicalOperator>> logicalOperators;
    auto& boundExportDatabase = statement.constCast<BoundExportDatabase>();
    auto fileTypeStr = FileTypeUtils::toString(boundExportDatabase.getFileType());
    StringUtils::toLower(fileTypeStr);
    /**
     * P2-87: Binder vs Planner Responsibility for Export Function Lookup
     * 
     * This TODO questions whether the export function lookup should be done in
     * the Binder rather than in the Planner.
     * 
     * What's Happening Here:
     * 1. Building function name from file type: "COPY_CSV", "COPY_PARQUET", etc.
     * 2. Looking up function in catalog
     * 3. Matching function signature
     * 4. Using function to create LogicalCopyTo
     * 
     * Arguments for Moving to Binder:
     * | Reason | Explanation |
     * |--------|-------------|
     * | Semantic validation | Binder validates syntax and semantics |
     * | Early error detection | Function not found errors caught earlier |
     * | Consistency | Other function lookups happen in Binder |
     * | Bound data completeness | ExportFunc should be part of BoundExportDatabase |
     * 
     * Arguments for Keeping in Planner:
     * | Reason | Explanation |
     * |--------|-------------|
     * | Planning needs context | Planner has clientContext readily available |
     * | Late binding | Function resolution might need planning info |
     * | Historical design | Current architecture works correctly |
     * 
     * What Moving to Binder Would Look Like:
     * ```cpp
     * // In Binder (bind_export_database.cpp):
     * auto exportFunc = lookupExportFunction(fileType);
     * boundExportDatabase.setExportFunction(exportFunc);
     * 
     * // In Planner (this file):
     * auto exportFunc = boundExportDatabase.getExportFunction();
     * // No lookup needed - already resolved
     * ```
     * 
     * Benefits of Binder Approach:
     * - Cleaner separation of concerns
     * - All function resolution in one place
     * - BoundExportDatabase becomes self-contained
     * 
     * Current Status:
     * Works correctly. Refactor would improve architecture consistency.
     */
    std::string name =
        stringFormat("COPY_{}", FileTypeUtils::toString(boundExportDatabase.getFileType()));
    auto entry =
        Catalog::Get(*clientContext)->getFunctionEntry(Transaction::Get(*clientContext), name);
    auto func = function::BuiltInFunctionsUtils::matchFunction(name,
        entry->ptrCast<FunctionCatalogEntry>());
    KU_ASSERT(func != nullptr);
    auto exportFunc = *func->constPtrCast<function::ExportFunction>();
    for (auto& exportTableData : *boundExportDatabase.getExportData()) {
        auto regularQuery = exportTableData.getRegularQuery();
        KU_ASSERT(regularQuery->getStatementType() == StatementType::QUERY);
        auto tablePlan = planStatement(*regularQuery);
        auto path = VirtualFileSystem::GetUnsafe(*clientContext)
                        ->joinPath(boundExportDatabase.getFilePath(), exportTableData.fileName);
        function::ExportFuncBindInput bindInput{exportTableData.columnNames, std::move(path),
            boundExportDatabase.getExportOptions()};
        auto copyTo = std::make_shared<LogicalCopyTo>(exportFunc.bind(bindInput), exportFunc,
            tablePlan.getLastOperator());
        logicalOperators.push_back(std::move(copyTo));
    }
    return logicalOperators;
}

LogicalPlan Planner::planExportDatabase(const BoundStatement& statement) {
    auto& boundExportDatabase = statement.constCast<BoundExportDatabase>();
    auto logicalOperators = std::vector<std::shared_ptr<LogicalOperator>>();
    auto plan = LogicalPlan();
    if (!boundExportDatabase.exportSchemaOnly()) {
        logicalOperators = planExportTableData(statement);
    }
    auto exportDatabase =
        std::make_shared<LogicalExportDatabase>(boundExportDatabase.getBoundFileInfo()->copy(),
            std::move(logicalOperators), boundExportDatabase.exportSchemaOnly());
    plan.setLastOperator(std::move(exportDatabase));
    return plan;
}

LogicalPlan Planner::planImportDatabase(const BoundStatement& statement) {
    auto& boundImportDatabase = statement.constCast<BoundImportDatabase>();
    auto plan = LogicalPlan();
    auto importDatabase = std::make_shared<LogicalImportDatabase>(boundImportDatabase.getQuery(),
        boundImportDatabase.getIndexQuery());
    plan.setLastOperator(std::move(importDatabase));
    return plan;
}

} // namespace planner
} // namespace kuzu
