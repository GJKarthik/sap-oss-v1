#include "parser/parser.h"

/**
 * P3-159: Parser - Cypher Query Parser
 * 
 * Purpose:
 * Entry point for parsing Cypher query strings into AST (Abstract Syntax Tree).
 * Uses ANTLR4 for lexical analysis and parsing, then transforms to Kuzu
 * internal statement representation.
 * 
 * Architecture:
 * ```
 * Query String
 *   │
 *   ├── 1. String Preprocessing
 *   │     └── Trim leading whitespace/newlines
 *   │
 *   ├── 2. Lexical Analysis (CypherLexer)
 *   │     └── Query → Token Stream
 *   │
 *   ├── 3. Syntactic Analysis (KuzuCypherParser)
 *   │     └── Token Stream → Parse Tree
 *   │
 *   └── 4. Transformation (Transformer)
 *         └── Parse Tree → Statement Objects
 * ```
 * 
 * ANTLR4 Pipeline:
 * ```
 * ┌─────────────────────────────────────────────────────────────┐
 * │  ANTLRInputStream ─→ CypherLexer ─→ CommonTokenStream       │
 * │                                            │                │
 * │                                            ▼                │
 * │                                    KuzuCypherParser         │
 * │                                            │                │
 * │                                            ▼                │
 * │                                    ku_Statements (CST)      │
 * │                                            │                │
 * │                                            ▼                │
 * │                                    Transformer              │
 * │                                            │                │
 * │                                            ▼                │
 * │                                  vector<Statement>          │
 * └─────────────────────────────────────────────────────────────┘
 * ```
 * 
 * Error Handling:
 * - ParserErrorListener: Captures lexer/parser errors
 * - ParserErrorStrategy: Custom error recovery
 * - ParserException: Thrown on syntax errors
 * 
 * Grammar Location:
 * - Cypher.g4: Main grammar file in antlr_parser/
 * - CypherLexer.g4: Lexer rules
 * - Generated files in build directory
 * 
 * Extension Support:
 * - transformerExtensions: Custom statement transformers
 * - Allows extensions to add new syntax
 * 
 * Key Classes:
 * | Class | Description |
 * |-------|-------------|
 * | CypherLexer | ANTLR-generated lexer |
 * | KuzuCypherParser | ANTLR-generated parser |
 * | Transformer | CST → AST conversion |
 * | ParserErrorListener | Error reporting |
 * 
 * Output:
 * - vector<shared_ptr<Statement>>
 * - Each Statement is a top-level query
 * - Multiple statements supported (separated by semicolons)
 * 
 * Usage:
 * ```cpp
 * auto statements = Parser::parseQuery(
 *     "MATCH (n:Person) RETURN n.name; MATCH (m:Movie) RETURN m.title",
 *     transformerExtensions
 * );
 * // Returns 2 Statement objects
 * ```
 */

// ANTLR4 generates code with unused parameters.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include "cypher_lexer.h"
#pragma GCC diagnostic pop

#include "common/exception/parser.h"
#include "common/string_utils.h"
#include "parser/antlr_parser/kuzu_cypher_parser.h"
#include "parser/antlr_parser/parser_error_listener.h"
#include "parser/antlr_parser/parser_error_strategy.h"
#include "parser/transformer.h"

using namespace antlr4;

namespace kuzu {
namespace parser {

std::vector<std::shared_ptr<Statement>> Parser::parseQuery(std::string_view query,
    std::vector<extension::TransformerExtension*> transformerExtensions) {
    auto queryStr = std::string(query);
    queryStr = common::StringUtils::ltrim(queryStr);
    queryStr = common::StringUtils::ltrimNewlines(queryStr);
    // LCOV_EXCL_START
    // We should have enforced this in connection, but I also realize empty query will cause
    // antlr to hang. So enforce a duplicate check here.
    if (queryStr.empty()) {
        throw common::ParserException(
            "Cannot parse empty query. This should be handled in connection.");
    }
    // LCOV_EXCL_STOP

    auto inputStream = ANTLRInputStream(queryStr);
    auto parserErrorListener = ParserErrorListener();

    auto cypherLexer = CypherLexer(&inputStream);
    cypherLexer.removeErrorListeners();
    cypherLexer.addErrorListener(&parserErrorListener);
    auto tokens = CommonTokenStream(&cypherLexer);
    tokens.fill();

    auto kuzuCypherParser = KuzuCypherParser(&tokens);
    kuzuCypherParser.removeErrorListeners();
    kuzuCypherParser.addErrorListener(&parserErrorListener);
    kuzuCypherParser.setErrorHandler(std::make_shared<ParserErrorStrategy>());

    Transformer transformer(*kuzuCypherParser.ku_Statements(), std::move(transformerExtensions));
    return transformer.transform();
}

} // namespace parser
} // namespace kuzu
