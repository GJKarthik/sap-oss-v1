#include "planner/operator/persistent/logical_copy_to.h"
#include "processor/operator/persistent/copy_to.h"
#include "processor/plan_mapper.h"
#include "storage/buffer_manager/memory_manager.h"

using namespace kuzu::common;
using namespace kuzu::planner;
using namespace kuzu::storage;

namespace kuzu {
namespace processor {

std::unique_ptr<PhysicalOperator> PlanMapper::mapCopyTo(const LogicalOperator* logicalOperator) {
    auto& logicalCopyTo = logicalOperator->constCast<LogicalCopyTo>();
    auto childSchema = logicalOperator->getChild(0)->getSchema();
    auto prevOperator = mapOperator(logicalOperator->getChild(0).get());
    std::vector<DataPos> vectorsToCopyPos;
    std::vector<bool> isFlat;
    std::vector<LogicalType> types;
    for (auto& expression : childSchema->getExpressionsInScope()) {
        vectorsToCopyPos.emplace_back(childSchema->getExpressionPos(*expression));
        isFlat.push_back(childSchema->getGroup(expression)->isFlat());
        types.push_back(expression->dataType.copy());
    }
    auto exportFunc = logicalCopyTo.getExportFunc();
    auto bindData = logicalCopyTo.getBindData();
    /**
     * P2-76: ANY Type Resolution in COPY TO
     * 
     * This TODO asks whether ANY type should be resolved at binder time.
     * 
     * Example Query:
     * ```sql
     * COPY (RETURN null) TO '/tmp/1.parquet'
     * ```
     * 
     * The Problem:
     * - `RETURN null` has type ANY (unresolved type)
     * - Parquet format needs a concrete type for each column
     * - Currently, ANY type flows through to the mapper
     * - We set the type here, but should it happen earlier?
     * 
     * Where Type Resolution Could Happen:
     * | Stage | Pros | Cons |
     * |-------|------|------|
     * | Binder | Early error detection, cleaner pipeline | Binder doesn't know file format |
     * | Planner | Has schema context | Still before format is known |
     * | Mapper (here) | Knows export format | Late in pipeline, may miss optimizations |
     * 
     * Why Binder Might Be Better:
     * 1. Early validation: "Cannot export ANY type to Parquet"
     * 2. Type inference: Could default ANY to STRING or error
     * 3. Consistent with other type resolution
     * 
     * Why Current Approach Works:
     * - Mapper has access to all expression types
     * - Export function can handle type conversion
     * - Some formats (CSV) might accept ANY as string
     * 
     * What "Solving at Binder" Would Mean:
     * ```cpp
     * // In binder for COPY TO:
     * for (auto& expr : expressions) {
     *     if (expr->dataType.getLogicalTypeID() == LogicalTypeID::ANY) {
     *         throw BinderException("Cannot export untyped NULL");
     *         // Or: expr->dataType = LogicalType::STRING();  // Default
     *     }
     * }
     * ```
     * 
     * Current Status:
     * Works for most cases; edge case (pure NULL) could benefit from binder handling.
     */
    bindData->setDataType(std::move(types));
    auto sharedState = exportFunc.createSharedState();
    auto info =
        CopyToInfo{exportFunc, std::move(bindData), std::move(vectorsToCopyPos), std::move(isFlat)};
    auto printInfo =
        std::make_unique<CopyToPrintInfo>(info.bindData->columnNames, info.bindData->fileName);
    auto copyTo = std::make_unique<CopyTo>(std::move(info), std::move(sharedState),
        std::move(prevOperator), getOperatorID(), std::move(printInfo));
    copyTo->setDescriptor(std::make_unique<ResultSetDescriptor>(childSchema));
    return createEmptyFTableScan(FactorizedTable::EmptyTable(MemoryManager::Get(*clientContext)), 0,
        std::move(copyTo));
}

} // namespace processor
} // namespace kuzu
