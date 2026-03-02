#include "storage/storage_utils.h"

/**
 * P3-200: StorageUtils - Extended Implementation Documentation (Day 200 Milestone! 🎉)
 * 
 * Additional Details (see P2-125 for architecture overview)
 * 
 * getColumnName() Switch Logic:
 * ```
 * getColumnName(propertyName, type, prefix):
 *   SWITCH type:
 *     DATA:       RETURN "{property}_data"
 *     NULL_MASK:  RETURN "{property}_null"
 *     INDEX:      RETURN "{property}_index"
 *     OFFSET:     RETURN "{property}_offset"
 *     CSR_OFFSET: RETURN "{prefix}_csr_offset"
 *     CSR_LENGTH: RETURN "{prefix}_csr_length"
 *     STRUCT_CHILD: RETURN "{property}_{prefix}_child"
 *     DEFAULT:
 *       IF prefix.empty(): RETURN propertyName
 *       ELSE: RETURN "{prefix}_{property}"
 * ```
 * 
 * Column Naming Examples:
 * ```
 * getColumnName("age", DATA, "")         → "age_data"
 * getColumnName("age", NULL_MASK, "")    → "age_null"
 * getColumnName("", CSR_OFFSET, "fwd")   → "fwd_csr_offset"
 * getColumnName("addr", STRUCT_CHILD, "city") → "addr_city_child"
 * getColumnName("name", DEFAULT, "")     → "name"
 * getColumnName("name", DEFAULT, "pk")   → "pk_name"
 * ```
 * 
 * expandPath() Algorithm:
 * ```
 * expandPath(context, path):
 *   IF isDBPathInMemory(path):
 *     RETURN path  // ":memory:" unchanged
 *   
 *   fullPath = path
 *   IF path.starts_with('~'):
 *     home = context.getSetting(HomeDirectorySetting)
 *     fullPath = home + path.substr(1)
 *   
 *   // Normalize: resolve '.', '..', ensure absolute
 *   normalizedPath = filesystem::absolute(fullPath).lexically_normal()
 *   RETURN normalizedPath.string()
 * ```
 * 
 * Path Expansion Examples:
 * ```
 * expandPath(ctx, ":memory:")      → ":memory:"
 * expandPath(ctx, "~/mydb")        → "/home/user/mydb"
 * expandPath(ctx, "./data/mydb")   → "/cwd/data/mydb"
 * expandPath(ctx, "../sibling/db") → "/parent/sibling/db"
 * expandPath(ctx, "data/../db")    → "/cwd/db"
 * ```
 * 
 * getDataTypeSize() Logic:
 * ```
 * getDataTypeSize(type):
 *   SWITCH type.getPhysicalType():
 *     STRING: RETURN sizeof(ku_string_t)  // 16 bytes
 *     LIST:
 *     ARRAY:  RETURN sizeof(ku_list_t)    // 16 bytes
 *     STRUCT:
 *       size = 0
 *       FOR field in struct.fields:
 *         size += getDataTypeSize(field.type)
 *       size += NullBuffer::getNumBytesForNullValues(fields.size())
 *       RETURN size
 *     DEFAULT:
 *       RETURN PhysicalTypeUtils::getFixedTypeSize(type)
 * ```
 * 
 * Data Type Size Examples:
 * ```
 * INT64:  8 bytes
 * DOUBLE: 8 bytes
 * BOOL:   1 byte
 * STRING: 16 bytes (ku_string_t)
 * LIST:   16 bytes (ku_list_t)
 * STRUCT{a: INT64, b: BOOL}: 8 + 1 + ceil(2/8) = 10 bytes
 * ```
 * 
 * ====================================
 * 
 * P2-125: Storage Utils - Storage Layer Utility Functions
 * 
 * Purpose:
 * Provides common utility functions for the storage layer including
 * column naming conventions, path handling, and data type size calculations.
 * Used throughout storage components for consistent behavior.
 * 
 * Key Functions:
 * 
 * 1. getColumnName(propertyName, type, prefix):
 *    Generates standardized column names for storage files.
 *    
 *    | ColumnType | Format |
 *    |------------|--------|
 *    | DATA | "{property}_data" |
 *    | NULL_MASK | "{property}_null" |
 *    | INDEX | "{property}_index" |
 *    | OFFSET | "{property}_offset" |
 *    | CSR_OFFSET | "{prefix}_csr_offset" |
 *    | CSR_LENGTH | "{prefix}_csr_length" |
 *    | STRUCT_CHILD | "{property}_{prefix}_child" |
 *    | DEFAULT | "{prefix}_{property}" or "{property}" |
 * 
 * 2. expandPath(context, path):
 *    Expands and normalizes database file paths.
 *    - Handles in-memory databases (returns as-is)
 *    - Expands '~' to home directory from settings
 *    - Resolves '.' and '..' using std::filesystem
 *    - Returns absolute normalized path
 *    
 *    Example:
 *    "~/mydb" → "/home/user/mydb"
 *    "./data/../mydb" → "/current/mydb"
 * 
 * 3. getDataTypeSize(type):
 *    Calculates in-memory size for data types.
 *    
 *    | Type | Size |
 *    |------|------|
 *    | STRING | sizeof(ku_string_t) = 16 bytes |
 *    | LIST/ARRAY | sizeof(ku_list_t) = 16 bytes |
 *    | STRUCT | Sum of field sizes + null buffer |
 *    | Fixed types | PhysicalTypeUtils::getFixedTypeSize() |
 *    
 *    Struct calculation:
 *    ```
 *    total = 0
 *    for field in struct.fields:
 *        total += getDataTypeSize(field.type)
 *    total += NullBuffer::getNumBytesForNullValues(num_fields)
 *    ```
 * 
 * Usage Patterns:
 * 
 * Column Naming:
 * ```cpp
 * // For property "name" with data column
 * getColumnName("name", ColumnType::DATA, "") → "name_data"
 * 
 * // For null mask
 * getColumnName("name", ColumnType::NULL_MASK, "") → "name_null"
 * 
 * // For CSR structures
 * getColumnName("", ColumnType::CSR_OFFSET, "rel") → "rel_csr_offset"
 * ```
 * 
 * Path Handling:
 * ```cpp
 * expandPath(ctx, "~/mydb")     → "/home/user/mydb"
 * expandPath(ctx, ":memory:")   → ":memory:"
 * expandPath(ctx, "./rel/path") → "/absolute/rel/path"
 * ```
 * 
 * Notes:
 * - Column naming ensures unique, predictable file names
 * - Path expansion is context-aware for home directory
 * - Data type sizes match ValueVector storage requirements
 */

#include <filesystem>

#include "common/null_buffer.h"
#include "common/string_format.h"
#include "common/types/ku_list.h"
#include "common/types/ku_string.h"
#include "common/types/types.h"
#include "main/client_context.h"
#include "main/db_config.h"
#include "main/settings.h"

using namespace kuzu::common;

namespace kuzu {
namespace storage {

std::string StorageUtils::getColumnName(const std::string& propertyName, ColumnType type,
    const std::string& prefix) {
    switch (type) {
    case ColumnType::DATA: {
        return stringFormat("{}_data", propertyName);
    }
    case ColumnType::NULL_MASK: {
        return stringFormat("{}_null", propertyName);
    }
    case ColumnType::INDEX: {
        return stringFormat("{}_index", propertyName);
    }
    case ColumnType::OFFSET: {
        return stringFormat("{}_offset", propertyName);
    }
    case ColumnType::CSR_OFFSET: {
        return stringFormat("{}_csr_offset", prefix);
    }
    case ColumnType::CSR_LENGTH: {
        return stringFormat("{}_csr_length", prefix);
    }
    case ColumnType::STRUCT_CHILD: {
        return stringFormat("{}_{}_child", propertyName, prefix);
    }
    default: {
        if (prefix.empty()) {
            return propertyName;
        }
        return stringFormat("{}_{}", prefix, propertyName);
    }
    }
}

std::string StorageUtils::expandPath(const main::ClientContext* context, const std::string& path) {
    if (main::DBConfig::isDBPathInMemory(path)) {
        return path;
    }
    auto fullPath = path;
    // Handle '~' for home directory expansion
    if (path.starts_with('~')) {
        fullPath =
            context->getCurrentSetting(main::HomeDirectorySetting::name).getValue<std::string>() +
            fullPath.substr(1);
    }
    // Normalize the path to resolve '.' and '..'
    std::filesystem::path normalizedPath = std::filesystem::absolute(fullPath).lexically_normal();
    return normalizedPath.string();
}

uint32_t StorageUtils::getDataTypeSize(const LogicalType& type) {
    switch (type.getPhysicalType()) {
    case PhysicalTypeID::STRING: {
        return sizeof(ku_string_t);
    }
    case PhysicalTypeID::ARRAY:
    case PhysicalTypeID::LIST: {
        return sizeof(ku_list_t);
    }
    case PhysicalTypeID::STRUCT: {
        uint32_t size = 0;
        const auto fieldsTypes = StructType::getFieldTypes(type);
        for (const auto& fieldType : fieldsTypes) {
            size += getDataTypeSize(*fieldType);
        }
        size += NullBuffer::getNumBytesForNullValues(fieldsTypes.size());
        return size;
    }
    default: {
        return PhysicalTypeUtils::getFixedTypeSize(type.getPhysicalType());
    }
    }
}

} // namespace storage
} // namespace kuzu
