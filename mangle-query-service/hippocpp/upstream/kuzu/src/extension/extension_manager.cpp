#include "extension/extension_manager.h"

/**
 * P3-166: ExtensionManager - Extension Loading and Management
 * 
 * Purpose:
 * Manages the loading, registration, and lifecycle of database extensions.
 * Extensions can add new functions, storage backends, and configuration options.
 * 
 * Architecture:
 * ```
 * ExtensionManager
 *   ├── loadedExtensions: vector<LoadedExtension>
 *   ├── extensionOptions: map<name, ExtensionOption>
 *   └── storageExtensions: map<name, StorageExtension>
 * ```
 * 
 * Extension Loading Flow:
 * ```
 * LOAD EXTENSION 'extension_name'
 *   │
 *   ├── 1. Check if official extension
 *   │     └── If yes, get from official path
 *   │
 *   ├── 2. Execute extension loader (if exists)
 *   │
 *   ├── 3. Load shared library
 *   │     ├── ExtensionLibLoader loads .so/.dylib
 *   │     ├── Get name function
 *   │     └── Get init function
 *   │
 *   ├── 4. Check if already loaded
 *   │     └── If yes, unload and return
 *   │
 *   ├── 5. Call init function
 *   │
 *   ├── 6. Add to loadedExtensions
 *   │
 *   └── 7. Log to WAL if needed
 * ```
 * 
 * Extension Sources:
 * | Source | Description |
 * |--------|-------------|
 * | OFFICIAL | Built-in Kuzu extensions |
 * | USER | User-provided extensions |
 * 
 * Key Methods:
 * | Method | Description |
 * |--------|-------------|
 * | loadExtension() | Load extension from path |
 * | addExtensionOption() | Register config option |
 * | getExtensionOption() | Get option by name |
 * | registerStorageExtension() | Add storage backend |
 * | getStorageExtensions() | Get all storage backends |
 * | autoLoadLinkedExtensions() | Load linked extensions |
 * | toCypher() | Generate LOAD statements |
 * 
 * Extension Options:
 * - Extensions can register configuration options
 * - Options have name, type, default value
 * - isConfidential flag hides values from display
 * 
 * Storage Extensions:
 * - Provide custom storage backends
 * - Enable external data sources
 * - Registered by name
 * 
 * WAL Logging:
 * - Extension loads are logged to WAL
 * - Enables replay during recovery
 * - Uses logLoadExtension()
 * 
 * Usage:
 * ```sql
 * LOAD EXTENSION httpfs;
 * LOAD EXTENSION '/path/to/extension.so';
 * ```
 */

#include "common/file_system/virtual_file_system.h"
#include "common/string_utils.h"
#include "extension/extension.h"
#include "generated_extension_loader.h"
#include "storage/wal/local_wal.h"
#include "transaction/transaction_context.h"

namespace kuzu {
namespace extension {

static void executeExtensionLoader(main::ClientContext* context, const std::string& extensionName) {
    auto loaderPath = ExtensionUtils::getLocalPathForExtensionLoader(context, extensionName);
    if (common::VirtualFileSystem::GetUnsafe(*context)->fileOrPathExists(loaderPath)) {
        auto libLoader = ExtensionLibLoader(extensionName, loaderPath);
        auto load = libLoader.getLoadFunc();
        (*load)(context);
    }
}

void ExtensionManager::loadExtension(const std::string& path, main::ClientContext* context) {
    auto fullPath = path;
    bool isOfficial = ExtensionUtils::isOfficialExtension(path);
    if (isOfficial) {
        auto localPathForSharedLib = ExtensionUtils::getLocalPathForSharedLib(context);
        if (!common::VirtualFileSystem::GetUnsafe(*context)->fileOrPathExists(
                localPathForSharedLib)) {
            common::VirtualFileSystem::GetUnsafe(*context)->createDir(localPathForSharedLib);
        }
        executeExtensionLoader(context, path);
        fullPath = ExtensionUtils::getLocalPathForExtensionLib(context, path);
    }

    auto libLoader = ExtensionLibLoader(path, fullPath);
    auto name = libLoader.getNameFunc();
    std::string extensionName = (*name)();
    if (std::any_of(loadedExtensions.begin(), loadedExtensions.end(),
            [&](const LoadedExtension& ext) { return ext.getExtensionName() == extensionName; })) {
        libLoader.unload();
        return;
    }
    auto init = libLoader.getInitFunc();
    (*init)(context);
    loadedExtensions.push_back(LoadedExtension(extensionName, fullPath,
        isOfficial ? ExtensionSource::OFFICIAL : ExtensionSource::USER));
    auto transaction = transaction::Transaction::Get(*context);
    if (transaction->shouldLogToWAL()) {
        transaction->getLocalWAL().logLoadExtension(path);
    }
}

std::string ExtensionManager::toCypher() {
    std::string cypher;
    for (auto& extension : loadedExtensions) {
        cypher += extension.toCypher();
    }
    return cypher;
}

void ExtensionManager::addExtensionOption(std::string name, common::LogicalTypeID type,
    common::Value defaultValue, bool isConfidential) {
    if (getExtensionOption(name) != nullptr) {
        // One extension option can be shared by multiple extensions.
        return;
    }
    common::StringUtils::toLower(name);
    extensionOptions.emplace(name,
        main::ExtensionOption{name, type, std::move(defaultValue), isConfidential});
}

const main::ExtensionOption* ExtensionManager::getExtensionOption(std::string name) const {
    common::StringUtils::toLower(name);
    return extensionOptions.contains(name) ? &extensionOptions.at(name) : nullptr;
}

void ExtensionManager::registerStorageExtension(std::string name,
    std::unique_ptr<storage::StorageExtension> storageExtension) {
    if (storageExtensions.contains(name)) {
        return;
    }
    storageExtensions.emplace(std::move(name), std::move(storageExtension));
}

std::vector<storage::StorageExtension*> ExtensionManager::getStorageExtensions() {
    std::vector<storage::StorageExtension*> storageExtensionsToReturn;
    for (auto& [name, storageExtension] : storageExtensions) {
        storageExtensionsToReturn.push_back(storageExtension.get());
    }
    return storageExtensionsToReturn;
}

void ExtensionManager::autoLoadLinkedExtensions(main::ClientContext* context) {
    auto trxContext = transaction::TransactionContext::Get(*context);
    trxContext->beginRecoveryTransaction();
    loadLinkedExtensions(context, loadedExtensions);
    trxContext->commit();
}

ExtensionManager* ExtensionManager::Get(const main::ClientContext& context) {
    return context.getDatabase()->getExtensionManager();
}

} // namespace extension
} // namespace kuzu
