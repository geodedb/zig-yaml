# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.11] - 2026-11-15

### Changed

- Converge on thread-pool v0.2.11, clearing the v0.2.9 vs v0.2.11 diamond
  in the otel dependency tree (SONNY-6630).
- CI: bump devnw/ci-catalog to v1.56.1 (interruptible scan and build jobs),
  cancel obsolete branch builds, fail fast on the first blocking job
  failure, and retire the GitLab enterprise security scanners.
- Renovate refresh of the pre-commit hooks.

## [0.1.9] - 2026-10-11

### Changed

- Converge on thread-pool v0.2.8 (Renovate dependency refresh).
- CI: run default jobs on Linux runners; create GitLab Releases with the job token.

## [0.1.8] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.2.0] - 2024-12-31

### Added
- **Testing**: Comprehensive test suite with 100+ tests
  - Scanner unit tests for tokenization
  - Emitter unit tests for YAML output
  - Round-trip verification tests
  - Performance benchmarks (`zig build bench`)
- **Emitter Options**: Configurable YAML output
  - `CollectionStyle`: block, flow_simple, flow
  - `QuoteStyle`: minimal, single, double
  - `doc_start`/`doc_end`: Control document markers
  - `blank_lines_between_keys`: Spacing option
- **Schema Validation**: Runtime value validation
  - Type checking (int, str, bool, seq, map, etc.)
  - Pattern matching for strings
  - Range validation for integers
  - Composite schemas (oneOf, optional, mapOf)
- **JSON Conversion**: YAML to JSON output
  - `toJson()`: Convert values to JSON
  - Pretty-print option with configurable indent
- **Comptime Parsing**: Compile-time YAML parsing
  - `comptimeParse()`: Embed YAML config at compile time
- **Streaming API**: Memory-efficient event iteration
  - `streamEvents()`: SAX-style event parsing
  - `loadAllFromReader()`: Parse from any Reader
  - `loadAllFromFile()`: Parse from file path
- **Version Management**: Semantic versioning
  - `yaml.version`: SemanticVersion struct
  - `yaml.version_string`: Version as string
- **Error Messages**: Human-readable error descriptions
  - `ErrorCode.message()`: Get error description from code
  - `ParseError.message()`: Get error description from error struct
  - `ParseError.formatBuf()`: Format error with location to buffer
  - `ParseError.format()`: Format error to static buffer
  - `ParseError.context`: Optional context (e.g., anchor name)
  - `formatError()`: Allocate formatted error string
  - `writeError()`: Write formatted error to any writer
- **Error Details API**: Detailed error information on parse failure
  - `LoadResult`: Struct with documents and optional parse_error
  - `loadAllWithDetails()`: Load documents with error details on failure
- **Robustness Tests**: Corpus-based parser robustness testing
  - Edge cases: empty inputs, special values, nested structures
  - Malformed inputs: unterminated strings, invalid escapes, bad indentation
  - Binary data: random byte sequences
  - Unicode edge cases: BOM, surrogate pairs, overlong encodings
  - Stress tests: deep nesting, repeated patterns
- **YAML 1.1 Compatibility Mode**: Parse legacy YAML 1.1 documents
  - `Schema.yaml11`: Enable YAML 1.1 type resolution
  - Boolean literals: yes/no, on/off, y/n (case-insensitive)
  - Octal integers: 0755 (leading zero, in addition to 0o755)
  - Binary integers: 0b1010
  - Sexagesimal integers: 1:30:00 (base-60 notation)
  - Sexagesimal floats: 1:30:00.5
  - Underscores in integers: 1_000_000
- **Scanner Error Recovery**: Improved error context tracking
  - `Scanner.getErrorInfo()`: Get line, column, offset, and context of last error
  - Error context preserved for string parsing (e.g., "in double-quoted string")
  - Block scalar errors include context (e.g., "in literal block scalar")
  - Parser `setScanError()`: Captures scanner error details in ParseError

### Fixed
- Error mapping in composer (was mapping all errors to OutOfMemory)
- Added alias_cycle to error codes
- State restoration on parser errors (errdefer)
- Memory leak in validation error handling
- `\xNN` escape sequences now produce proper UTF-8 (equivalent to `\u00NN` per YAML 1.2.2 spec)
- Surrogate pair code points (U+D800-U+DFFF) rejected in `\u` escape sequences
- Invalid code points above U+10FFFF rejected in `\U` escape sequences

### Changed
- Internal ArrayList API updated for Zig 0.15.1 compatibility
- **Error Type Consolidation**: Unified error types across all components
  - New `error.zig` module with consolidated `ErrorCode`, `ParseError`, and error unions
  - Parser and yaml modules now import from shared error module
  - Added error conversion functions: `scanErrorToCode()`, `composerErrorToCode()`, `limitErrorToCode()`
  - Eliminates duplicate error type definitions between parser.zig and yaml.zig
- **Scanner Lookahead Helpers**: Extracted common lookahead patterns
  - `skipSpacesFrom()`: Skip spaces from a position
  - `skipWhitespaceFrom()`: Skip whitespace and newlines
  - `skipToEndOfLine()`: Skip to end of line
  - `skipComment()`: Skip comment to end of line
  - `isValueIndicatorAt()`: Check for value indicator (colon)
  - `skipWhitespaceAndComments()`: Skip whitespace, newlines, and comments
  - Refactored several scanner instances to use these helpers
- **Parser State Machine Documentation**: Comprehensive documentation added
  - Module-level documentation with state flow diagram
  - Detailed descriptions of all 22 parser states
  - State transition documentation
  - Events produced by the parser
- **API Documentation**: Added doc comments to public API
  - Schema enum with type resolution descriptions
  - ParseOptions with field documentation
  - loadAll(), resolveToValue(), dumpAll() with examples
  - EmitOptions with field documentation
- **Memory Efficiency Documentation**: Guidance for large documents
  - Module-level section on memory-efficient parsing
  - Parser struct documented as streaming API for bounded memory
  - Example code for event-by-event processing
  - Use cases: large log files, selective field extraction

## [0.1.0] - 2024-12-30

### Added
- Initial release
- Full YAML 1.2.2 specification compliance
- 406/406 YAML test suite tests passing
- Scanner/tokenizer with full Unicode support
- Parser with document graph representation
- Schema resolver (failsafe, json, core)
- Canonical emitter
- Anchor and alias support
- Block and flow collections
- Block scalars (literal and folded)
- Tag handling (verbatim and shorthand)
- Multi-document streams
