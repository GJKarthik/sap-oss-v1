#include "storage/storage_version_info.h"

/**
 * P2-135: Storage Version Info - Database Format Compatibility
 * 
 * Purpose:
 * Manages storage format versioning to ensure database file compatibility
 * across different Kuzu versions. Enables detection of incompatible database
 * formats and supports future format upgrades.
 * 
 * Architecture:
 * ```
 * StorageVersionInfo
 *   ├── getStorageVersion(): storage_version_t
 *   └── getStorageVersionInfo(): map<string, storage_version_t>
 *         └── Maps KUZU_CMAKE_VERSION → storage_version_t
 * 
 * Storage Version = Numeric identifier for on-disk format
 * ```
 * 
 * Version Resolution:
 * ```
 * getStorageVersion()
 *         │
 *         ├── Lookup KUZU_CMAKE_VERSION in map
 *         │     └── Found: Return mapped version
 *         │
 *         └── Not found (development build):
 *               └── Return max version in map
 * ```
 * 
 * Use Cases:
 * 
 * 1. Database Open:
 *    - Read stored version from database header
 *    - Compare with getStorageVersion()
 *    - Reject if incompatible
 * 
 * 2. New Database Creation:
 *    - Write current getStorageVersion() to header
 * 
 * 3. Version Compatibility:
 *    - Same version: Full read/write access
 *    - Different version: Reject with error message
 * 
 * Version History:
 * ```
 * (Defined in header's getStorageVersionInfo())
 * Example:
 *   "0.0.1" → 1
 *   "0.0.2" → 2
 *   "0.1.0" → 10  // Format change
 *   ...
 * ```
 * 
 * Development Builds:
 * - When KUZU_CMAKE_VERSION not in map (e.g., local builds)
 * - Falls back to maximum known version
 * - Ensures development works with latest format
 * 
 * Integration with DatabaseHeader:
 * ```cpp
 * // On database open
 * auto storedVersion = header.storageVersion;
 * auto currentVersion = StorageVersionInfo::getStorageVersion();
 * if (storedVersion != currentVersion) {
 *     throw IncompatibleVersionError(...);
 * }
 * ```
 * 
 * Future Considerations:
 * - Migration support for version upgrades
 * - Backward compatibility ranges
 * - Feature flags per version
 */

namespace kuzu {
namespace storage {

storage_version_t StorageVersionInfo::getStorageVersion() {
    auto storageVersionInfo = getStorageVersionInfo();
    if (!storageVersionInfo.contains(KUZU_CMAKE_VERSION)) {
        // If the current KUZU_CMAKE_VERSION is not in the map,
        // then we must run the newest version of kuzu
        // LCOV_EXCL_START
        storage_version_t maxVersion = 0;
        for (auto& [_, versionNumber] : storageVersionInfo) {
            maxVersion = std::max(maxVersion, versionNumber);
        }
        return maxVersion;
        // LCOV_EXCL_STOP
    }
    return storageVersionInfo.at(KUZU_CMAKE_VERSION);
}

} // namespace storage
} // namespace kuzu
