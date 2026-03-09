#include "binder/binder.h"
#include "binder/bound_import_database.h"
#include "common/copier_config/csv_reader_config.h"
#include "common/exception/binder.h"
#include "common/file_system/virtual_file_system.h"
#include "main/client_context.h"
#include "parser/copy.h"
#include "parser/parser.h"
#include "parser/port_db.h"

using namespace kuzu::common;
using namespace kuzu::parser;

namespace kuzu {
namespace binder {

static std::string getQueryFromFile(VirtualFileSystem* vfs, const std::string& boundFilePath,
    const std::string& fileName, main::ClientContext* context) {
    auto filePath = vfs->joinPath(boundFilePath, fileName);
    if (!vfs->fileOrPathExists(filePath, context)) {
        if (fileName == PortDBConstants::COPY_FILE_NAME) {
            return "";
        }
        if (fileName == PortDBConstants::INDEX_FILE_NAME) {
            return "";
        }
        throw BinderException(stringFormat("File {} does not exist.", filePath));
    }
    auto fileInfo = vfs->openFile(filePath, FileOpenFlags(FileFlags::READ_ONLY
#ifdef _WIN32
                                                          | FileFlags::BINARY
#endif
                                                ));
    auto fsize = fileInfo->getFileSize();
    auto buffer = std::make_unique<char[]>(fsize);
    fileInfo->readFile(buffer.get(), fsize);
    return std::string(buffer.get(), fsize);
}

static std::string getColumnNamesToCopy(const CopyFrom& copyFrom) {
    std::string columns = "";
    std::string delimiter = "";
    for (auto& column : copyFrom.getCopyColumnInfo().columnNames) {
        columns += delimiter;
        columns += "`" + column + "`";
        if (delimiter == "") {
            delimiter = ",";
        }
    }
    if (columns.empty()) {
        return columns;
    }
    return stringFormat("({})", columns);
}

/**
 * Escape special characters in file path for Cypher parser
 * 
 * P2-51: Windows Path Escaping for Import Database
 * 
 * Problem:
 * The Cypher parser requires special characters in string literals to be escaped.
 * On Windows, file paths use backslash (\) as the path separator, which is also
 * the escape character in Cypher strings. This creates a conflict:
 * 
 * Flow:
 * 1. User inputs: IMPORT DATABASE 'C:\\db\\uw'
 * 2. Parser unescapes to: C:\db\uw
 * 3. This function receives: C:\db\uw
 * 4. Path is passed to parser for COPY query generation
 * 5. Parser fails because unescaped backslashes are invalid
 * 
 * Solution:
 * Re-escape backslashes before passing to parser. This is necessary because
 * we're generating Cypher queries programmatically that will be re-parsed.
 * 
 * Long-term Fix:
 * The proper solution is to use parameterized queries or a query builder
 * that handles escaping automatically, rather than string concatenation.
 * This would require changes to:
 * - Parser to support parameterized string literals
 * - Query builder utility to escape strings properly
 * - All places that generate Cypher dynamically
 * 
 * Why This Works:
 * | Input | After Escape | After Parse |
 * |-------|--------------|-------------|
 * | C:\db | C:\\db | C:\db |
 * | /unix | /unix | /unix |
 * 
 * @param boundFilePath Base directory path
 * @param filePath Relative file path from COPY statement
 * @return Properly escaped file path for Cypher parser
 */
static std::string escapePathForParser(const std::string& path) {
    std::string result = path;
#if defined(_WIN32)
    // Escape backslashes for Windows paths
    // Each \ must become \\ for the Cypher parser
    size_t pos = 0;
    while ((pos = result.find('\\', pos)) != std::string::npos) {
        result.replace(pos, 1, "\\\\");
        pos += 2;
    }
#endif
    // Also escape any quotes in the path
    size_t quotePos = 0;
    while ((quotePos = result.find('"', quotePos)) != std::string::npos) {
        result.replace(quotePos, 1, "\\\"");
        quotePos += 2;
    }
    return result;
}

static std::string getCopyFilePath(const std::string& boundFilePath, const std::string& filePath) {
    if (filePath[0] == '/' || (std::isalpha(filePath[0]) && filePath[1] == ':')) {
        // Note:
        // Unix absolute path starts with '/'
        // Windows absolute path starts with "[DiskID]://"
        // This code path is for backward compatibility, we used to export the absolute path for
        // csv files to copy.cypher files.
        return escapePathForParser(filePath);
    }

    auto path = boundFilePath + "/" + filePath;
    return escapePathForParser(path);
}

std::unique_ptr<BoundStatement> Binder::bindImportDatabaseClause(const Statement& statement) {
    auto& importDB = statement.constCast<ImportDB>();
    auto fs = VirtualFileSystem::GetUnsafe(*clientContext);
    auto boundFilePath = fs->expandPath(clientContext, importDB.getFilePath());
    if (!fs->fileOrPathExists(boundFilePath, clientContext)) {
        throw BinderException(stringFormat("Directory {} does not exist.", boundFilePath));
    }
    std::string finalQueryStatements;
    finalQueryStatements +=
        getQueryFromFile(fs, boundFilePath, PortDBConstants::SCHEMA_FILE_NAME, clientContext);
    // replace the path in copy from statements with the bound path
    auto copyQuery =
        getQueryFromFile(fs, boundFilePath, PortDBConstants::COPY_FILE_NAME, clientContext);
    if (!copyQuery.empty()) {
        auto parsedStatements = Parser::parseQuery(copyQuery);
        for (auto& parsedStatement : parsedStatements) {
            KU_ASSERT(parsedStatement->getStatementType() == StatementType::COPY_FROM);
            auto& copyFromStatement = parsedStatement->constCast<CopyFrom>();
            KU_ASSERT(copyFromStatement.getSource()->type == ScanSourceType::FILE);
            auto filePaths =
                copyFromStatement.getSource()->constPtrCast<FileScanSource>()->filePaths;
            KU_ASSERT(filePaths.size() == 1);
            auto fileTypeInfo = bindFileTypeInfo(filePaths);
            std::string query;
            auto copyFilePath = getCopyFilePath(boundFilePath, filePaths[0]);
            auto columnNames = getColumnNamesToCopy(copyFromStatement);
            auto parsingOptions = bindParsingOptions(copyFromStatement.getParsingOptions());
            std::unordered_map<std::string, std::string> copyFromOptions;
            if (parsingOptions.contains(CopyConstants::FROM_OPTION_NAME)) {
                KU_ASSERT(parsingOptions.contains(CopyConstants::TO_OPTION_NAME));
                copyFromOptions[CopyConstants::FROM_OPTION_NAME] = stringFormat("'{}'",
                    parsingOptions.at(CopyConstants::FROM_OPTION_NAME).getValue<std::string>());
                copyFromOptions[CopyConstants::TO_OPTION_NAME] = stringFormat("'{}'",
                    parsingOptions.at(CopyConstants::TO_OPTION_NAME).getValue<std::string>());
                parsingOptions.erase(CopyConstants::FROM_OPTION_NAME);
                parsingOptions.erase(CopyConstants::TO_OPTION_NAME);
            }
            if (fileTypeInfo.fileType == FileType::CSV) {
                auto csvConfig = CSVReaderConfig::construct(parsingOptions);
                csvConfig.option.autoDetection = false;
                auto optionsMap = csvConfig.option.toOptionsMap(csvConfig.parallel);
                if (!copyFromOptions.empty()) {
                    optionsMap.insert(copyFromOptions.begin(), copyFromOptions.end());
                }
                query =
                    stringFormat("COPY `{}` {} FROM \"{}\" {};", copyFromStatement.getTableName(),
                        columnNames, copyFilePath, CSVOption::toCypher(optionsMap));
            } else {
                query =
                    stringFormat("COPY `{}` {} FROM \"{}\" {};", copyFromStatement.getTableName(),
                        columnNames, copyFilePath, CSVOption::toCypher(copyFromOptions));
            }
            finalQueryStatements += query;
        }
    }
    return std::make_unique<BoundImportDatabase>(boundFilePath, finalQueryStatements,
        getQueryFromFile(fs, boundFilePath, PortDBConstants::INDEX_FILE_NAME, clientContext));
}

} // namespace binder
} // namespace kuzu
