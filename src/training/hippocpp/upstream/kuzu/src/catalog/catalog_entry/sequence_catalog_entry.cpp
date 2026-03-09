#include "catalog/catalog_entry/sequence_catalog_entry.h"

/**
 * P3-143: SequenceCatalogEntry - Sequence (Auto-Increment) Metadata
 * 
 * Purpose:
 * Manages sequence objects that generate unique integer values.
 * Used for SERIAL columns (auto-increment) and explicit sequences.
 * Thread-safe with transactional rollback support.
 * 
 * Architecture:
 * ```
 * CatalogEntry (base)
 *   └── SequenceCatalogEntry
 *         ├── sequenceData: SequenceData
 *         │     ├── usageCount: uint64_t   // Number of nextval calls
 *         │     ├── currVal: int64_t       // Current sequence value
 *         │     ├── increment: int64_t     // Step size (can be negative)
 *         │     ├── startValue: int64_t    // Initial value
 *         │     ├── minValue: int64_t      // Lower bound
 *         │     ├── maxValue: int64_t      // Upper bound
 *         │     └── cycle: bool            // Wrap around at bounds
 *         └── mtx: mutex                   // Thread-safe access
 * ```
 * 
 * Sequence State:
 * ```
 * CREATE SEQUENCE counter START 1 INCREMENT 1 MINVALUE 1 MAXVALUE 1000
 *   ├── startValue = 1
 *   ├── increment = 1
 *   ├── minValue = 1
 *   ├── maxValue = 1000
 *   └── cycle = false (default)
 * ```
 * 
 * Key Operations:
 * 
 * 1. currVal():
 *    - Return current value
 *    - Throws if sequence never used (usageCount == 0)
 * 
 * 2. nextValNoLock():
 *    - Advance sequence by increment
 *    - Handle overflow with cycle or throw error
 *    - First call initializes to startValue
 * 
 * 3. nextKVal(transaction, count, [resultVector]):
 *    - Advance K values in batch
 *    - Push rollback data to transaction
 *    - Optionally fill result vector with values
 * 
 * 4. rollbackVal(usageCount, currVal):
 *    - Restore sequence state on transaction rollback
 * 
 * Cycle Behavior:
 * ```
 * cycle = true:
 *   At maxValue → wrap to minValue
 *   At minValue (negative increment) → wrap to maxValue
 * 
 * cycle = false:
 *   At bounds → throw CatalogException
 * ```
 * 
 * SERIAL Integration:
 * ```
 * CREATE TABLE Person (id SERIAL, ...)
 *   └── Creates internal sequence: __serial_Person_id
 *   └── INSERT auto-calls nextval('__serial_Person_id')
 * ```
 * 
 * Thread Safety:
 * - std::lock_guard on mtx for all operations
 * - Ensures atomic sequence value generation
 * 
 * Transactional Rollback:
 * ```
 * nextKVal() → transaction.pushSequenceChange()
 *   └── On rollback: rollbackVal(savedUsageCount, savedCurrVal)
 * ```
 * 
 * Entry Type:
 * - CatalogEntryType::SEQUENCE_ENTRY
 */

#include "binder/ddl/bound_create_sequence_info.h"
#include "common/exception/catalog.h"
#include "common/exception/overflow.h"
#include "common/serializer/deserializer.h"
#include "common/vector/value_vector.h"
#include "function/arithmetic/add.h"
#include "transaction/transaction.h"

using namespace kuzu::binder;
using namespace kuzu::common;

namespace kuzu {
namespace catalog {

SequenceData SequenceCatalogEntry::getSequenceData() {
    std::lock_guard lck(mtx);
    return sequenceData;
}

int64_t SequenceCatalogEntry::currVal() {
    std::lock_guard lck(mtx);
    if (sequenceData.usageCount == 0) {
        throw CatalogException(
            "currval: sequence \"" + name +
            "\" is not yet defined. To define the sequence, call nextval first.");
    }
    return sequenceData.currVal;
}

void SequenceCatalogEntry::nextValNoLock() {
    if (sequenceData.usageCount == 0) {
        // initialization of sequence
        sequenceData.usageCount++;
        return;
    }
    bool overflow = false;
    auto next = sequenceData.currVal;
    try {
        function::Add::operation(next, sequenceData.increment, next);
    } catch (const OverflowException&) {
        overflow = true;
    }
    if (sequenceData.cycle) {
        if (overflow) {
            next = sequenceData.increment < 0 ? sequenceData.maxValue : sequenceData.minValue;
        } else if (next < sequenceData.minValue) {
            next = sequenceData.maxValue;
        } else if (next > sequenceData.maxValue) {
            next = sequenceData.minValue;
        }
    } else {
        const bool minError = overflow ? sequenceData.increment < 0 : next < sequenceData.minValue;
        const bool maxError = overflow ? sequenceData.increment > 0 : next > sequenceData.maxValue;
        if (minError) {
            throw CatalogException("nextval: reached minimum value of sequence \"" + name + "\" " +
                                   std::to_string(sequenceData.minValue));
        }
        if (maxError) {
            throw CatalogException("nextval: reached maximum value of sequence \"" + name + "\" " +
                                   std::to_string(sequenceData.maxValue));
        }
    }
    sequenceData.currVal = next;
    sequenceData.usageCount++;
}

// referenced from DuckDB
void SequenceCatalogEntry::nextKVal(transaction::Transaction* transaction, const uint64_t& count) {
    KU_ASSERT(count > 0);
    SequenceRollbackData rollbackData{};
    {
        std::lock_guard lck(mtx);
        rollbackData = SequenceRollbackData{sequenceData.usageCount, sequenceData.currVal};
        for (auto i = 0ul; i < count; i++) {
            nextValNoLock();
        }
    }
    transaction->pushSequenceChange(this, count, rollbackData);
}

void SequenceCatalogEntry::nextKVal(transaction::Transaction* transaction, const uint64_t& count,
    ValueVector& resultVector) {
    KU_ASSERT(count > 0);
    SequenceRollbackData rollbackData{};
    {
        std::lock_guard lck(mtx);
        rollbackData = SequenceRollbackData{sequenceData.usageCount, sequenceData.currVal};
        for (auto i = 0ul; i < count; i++) {
            nextValNoLock();
            resultVector.setValue(i, sequenceData.currVal);
        }
    }
    transaction->pushSequenceChange(this, count, rollbackData);
}

void SequenceCatalogEntry::rollbackVal(const uint64_t& usageCount, const int64_t& currVal) {
    std::lock_guard lck(mtx);
    sequenceData.usageCount = usageCount;
    sequenceData.currVal = currVal;
}

void SequenceCatalogEntry::serialize(Serializer& serializer) const {
    CatalogEntry::serialize(serializer);
    serializer.writeDebuggingInfo("usageCount");
    serializer.write(sequenceData.usageCount);
    serializer.writeDebuggingInfo("currVal");
    serializer.write(sequenceData.currVal);
    serializer.writeDebuggingInfo("increment");
    serializer.write(sequenceData.increment);
    serializer.writeDebuggingInfo("startValue");
    serializer.write(sequenceData.startValue);
    serializer.writeDebuggingInfo("minValue");
    serializer.write(sequenceData.minValue);
    serializer.writeDebuggingInfo("maxValue");
    serializer.write(sequenceData.maxValue);
    serializer.writeDebuggingInfo("cycle");
    serializer.write(sequenceData.cycle);
}

std::unique_ptr<SequenceCatalogEntry> SequenceCatalogEntry::deserialize(
    Deserializer& deserializer) {
    std::string debuggingInfo;
    uint64_t usageCount = 0;
    int64_t currVal = 0;
    int64_t increment = 0;
    int64_t startValue = 0;
    int64_t minValue = 0;
    int64_t maxValue = 0;
    bool cycle = false;
    deserializer.validateDebuggingInfo(debuggingInfo, "usageCount");
    deserializer.deserializeValue(usageCount);
    deserializer.validateDebuggingInfo(debuggingInfo, "currVal");
    deserializer.deserializeValue(currVal);
    deserializer.validateDebuggingInfo(debuggingInfo, "increment");
    deserializer.deserializeValue(increment);
    deserializer.validateDebuggingInfo(debuggingInfo, "startValue");
    deserializer.deserializeValue(startValue);
    deserializer.validateDebuggingInfo(debuggingInfo, "minValue");
    deserializer.deserializeValue(minValue);
    deserializer.validateDebuggingInfo(debuggingInfo, "maxValue");
    deserializer.deserializeValue(maxValue);
    deserializer.validateDebuggingInfo(debuggingInfo, "cycle");
    deserializer.deserializeValue(cycle);
    auto result = std::make_unique<SequenceCatalogEntry>();
    result->sequenceData.usageCount = usageCount;
    result->sequenceData.currVal = currVal;
    result->sequenceData.increment = increment;
    result->sequenceData.startValue = startValue;
    result->sequenceData.minValue = minValue;
    result->sequenceData.maxValue = maxValue;
    result->sequenceData.cycle = cycle;
    return result;
}

std::string SequenceCatalogEntry::toCypher(const ToCypherInfo& /* info */) const {
    return stringFormat("DROP SEQUENCE IF EXISTS `{}`;\n"
                        "CREATE SEQUENCE IF NOT EXISTS `{}` START {} INCREMENT {} MINVALUE {} "
                        "MAXVALUE {} {} CYCLE;\n"
                        "RETURN nextval('{}');",
        getName(), getName(), sequenceData.currVal, sequenceData.increment, sequenceData.minValue,
        sequenceData.maxValue, sequenceData.cycle ? "" : "NO", getName());
}

BoundCreateSequenceInfo SequenceCatalogEntry::getBoundCreateSequenceInfo(bool isInternal) const {
    return BoundCreateSequenceInfo(name, sequenceData.startValue, sequenceData.increment,
        sequenceData.minValue, sequenceData.maxValue, sequenceData.cycle,
        ConflictAction::ON_CONFLICT_THROW, isInternal);
}

} // namespace catalog
} // namespace kuzu
