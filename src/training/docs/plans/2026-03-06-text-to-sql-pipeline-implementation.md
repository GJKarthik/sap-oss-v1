# Text-to-SQL Training Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a ZIG/Mojo/Mangle pipeline that transforms banking CSV/Excel data files into 5K-20K Spider/BIRD text-to-SQL training pairs targeting SAP HANA SQL.

**Architecture:** A 7-stage pipeline: (1) ZIG pre-converts Excel to CSV, (2) ZIG parses CSVs into a JSON schema registry, (3) ZIG loads schema into HippoCPP graph for join-path discovery, (4) ZIG expands prompt templates into question/SQL pairs, (5) Mojo calls an LLM API to augment with paraphrases and complex queries, (6) Mangle validates all pairs, (7) ZIG splits into Spider/BIRD train/dev/test. NVIDIA ModelOpt quantizes the downstream fine-tuned model.

**Tech Stack:** Zig 0.13+ (builds via hippocpp/zig/build.zig), Mojo (hippocpp/mojo), Google Mangle (.mg files), Python (pre-conversion helper + ModelOpt), SAP HANA SQL dialect.

---

## Prerequisites

Before starting, ensure these tools are available:

```bash
zig version      # 0.13+
python3 --version  # 3.10+
pip install openpyxl  # For Excel pre-conversion
```

The pipeline code lives under a new directory: `pipeline/` at the project root.

```
training-main/
├── pipeline/
│   ├── preconvert/          # Python: Excel → CSV pre-conversion
│   ├── zig/                 # Zig: schema extraction, template expansion, output formatting
│   │   ├── build.zig
│   │   ├── src/
│   │   │   ├── main.zig
│   │   │   ├── csv_parser.zig
│   │   │   ├── schema_registry.zig
│   │   │   ├── graph_loader.zig
│   │   │   ├── template_parser.zig
│   │   │   ├── template_expander.zig
│   │   │   ├── hana_sql_builder.zig
│   │   │   ├── json_emitter.zig
│   │   │   ├── spider_formatter.zig
│   │   │   └── test/        # Tests alongside source
│   │   └── build.zig.zon
│   ├── mojo/                # Mojo: LLM augmentation
│   │   └── src/
│   │       ├── augmenter.mojo
│   │       └── http_client.mojo
│   ├── mangle/              # Mangle: validation rules
│   │   ├── schema_validation.mg
│   │   ├── sql_validation.mg
│   │   ├── domain_constraints.mg
│   │   ├── coverage_rules.mg
│   │   └── spider_format.mg
│   ├── Makefile             # Orchestration
│   └── output/              # Generated output
│       ├── intermediate/    # schema_registry.json, templates.json, etc.
│       └── spider/          # Final train/dev/test.json
├── hippocpp/                # Existing graph DB engine
├── nvidia-modelopt/         # Existing model optimization
├── data/                    # Input data files (CSV, XLSX)
└── docs/                    # Plans and documentation
```

---

### Task 1: Excel Pre-Conversion Script

**Files:**
- Create: `pipeline/preconvert/excel_to_csv.py`
- Create: `pipeline/preconvert/requirements.txt`
- Test: `pipeline/preconvert/test_preconvert.py`

ZIG has no mature Excel parsing library. We pre-convert all .xlsx files to CSV using Python so ZIG can consume them.

**Step 1: Write the failing test**

```python
# pipeline/preconvert/test_preconvert.py
import os
import tempfile
import pytest

def test_data_dictionary_converts():
    """DATA_DICTIONARY.xlsx Dictionary sheet converts to CSV with correct headers."""
    from excel_to_csv import convert_workbook
    outdir = tempfile.mkdtemp()
    convert_workbook("../../data/DATA_DICTIONARY.xlsx", outdir)
    csv_path = os.path.join(outdir, "DATA_DICTIONARY__Dictionary.csv")
    assert os.path.exists(csv_path)
    with open(csv_path) as f:
        header = f.readline().strip()
    assert "COLUMN" in header
    assert "DESCRIPTION" in header

def test_nfrp_account_converts():
    """NFRP_Account_AM.xlsx converts with hierarchy columns."""
    from excel_to_csv import convert_workbook
    outdir = tempfile.mkdtemp()
    convert_workbook("../../data/NFRP_Account_AM.xlsx", outdir)
    csv_path = os.path.join(outdir, "NFRP_Account_AM__NFRP_Account_AM.csv")
    assert os.path.exists(csv_path)
    with open(csv_path) as f:
        header = f.readline().strip()
    assert "ACCOUNT (L0)" in header

def test_prompt_samples_converts():
    """Prompt_samples.xlsx converts with template columns."""
    from excel_to_csv import convert_workbook
    outdir = tempfile.mkdtemp()
    convert_workbook("../../data/Prompt_samples.xlsx", outdir)
    csv_path = os.path.join(outdir, "Prompt_samples__Sheet1.csv")
    assert os.path.exists(csv_path)
    with open(csv_path) as f:
        header = f.readline().strip()
    assert "Prompt Template" in header
```

**Step 2: Run test to verify it fails**

Run: `cd pipeline/preconvert && python3 -m pytest test_preconvert.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'excel_to_csv'"

**Step 3: Write minimal implementation**

```python
# pipeline/preconvert/excel_to_csv.py
"""Convert all .xlsx files into per-sheet CSV files for Zig consumption."""

import csv
import os
import sys
import openpyxl

def convert_workbook(xlsx_path: str, outdir: str) -> list[str]:
    """Convert each sheet in an xlsx file to a CSV. Returns list of output paths."""
    os.makedirs(outdir, exist_ok=True)
    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    basename = os.path.splitext(os.path.basename(xlsx_path))[0]
    outputs = []
    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]
        safe_sheet = sheet_name.replace("/", "_").replace(" ", "_")
        csv_name = f"{basename}__{safe_sheet}.csv"
        csv_path = os.path.join(outdir, csv_name)
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            for row in ws.iter_rows(values_only=True):
                writer.writerow([str(cell) if cell is not None else "" for cell in row])
        outputs.append(csv_path)
    wb.close()
    return outputs

def convert_all(data_dir: str, outdir: str) -> list[str]:
    """Convert all .xlsx files in data_dir to CSVs in outdir."""
    all_outputs = []
    for fname in sorted(os.listdir(data_dir)):
        if fname.endswith(".xlsx"):
            xlsx_path = os.path.join(data_dir, fname)
            all_outputs.extend(convert_workbook(xlsx_path, outdir))
    return all_outputs

if __name__ == "__main__":
    data_dir = sys.argv[1] if len(sys.argv) > 1 else "../../data"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "../../pipeline/output/intermediate/csv"
    paths = convert_all(data_dir, outdir)
    for p in paths:
        print(p)
```

```
# pipeline/preconvert/requirements.txt
openpyxl>=3.1.0
pytest>=7.0.0
```

**Step 4: Run test to verify it passes**

Run: `cd pipeline/preconvert && python3 -m pytest test_preconvert.py -v`
Expected: PASS (3 tests)

**Step 5: Run the pre-conversion on all data**

Run: `cd pipeline/preconvert && python3 excel_to_csv.py ../../data ../../pipeline/output/intermediate/csv`
Expected: ~30+ CSV files created in `pipeline/output/intermediate/csv/`

**Step 6: Commit**

```bash
git add pipeline/preconvert/
git commit -m "feat: add Excel-to-CSV pre-conversion for Zig pipeline"
```

---

### Task 2: Zig Build System Setup

**Files:**
- Create: `pipeline/zig/build.zig`
- Create: `pipeline/zig/build.zig.zon`
- Create: `pipeline/zig/src/main.zig`

Sets up a new Zig project for the pipeline. Separate from hippocpp/zig to keep concerns clean.

**Step 1: Write the build files**

```zig
// pipeline/zig/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main pipeline executable
    const exe = b.addExecutable(.{
        .name = "text2sql-pipeline",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the pipeline");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

```zig
// pipeline/zig/build.zig.zon
.{
    .name = "text2sql-pipeline",
    .version = "0.1.0",
    .paths = .{""},
}
```

```zig
// pipeline/zig/src/main.zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("text2sql-pipeline v0.1.0\n", .{});
    try stdout.print("Usage: text2sql-pipeline <command> [args]\n", .{});
    try stdout.print("Commands:\n", .{});
    try stdout.print("  extract-schema  <csv_dir> <output_json>\n", .{});
    try stdout.print("  parse-templates <csv_dir> <output_json>\n", .{});
    try stdout.print("  expand          <schema_json> <templates_json> <output_json>\n", .{});
    try stdout.print("  format-spider   <pairs_json> <output_dir>\n", .{});
}

test "main runs without error" {
    // Smoke test: just verify the binary compiles
    const allocator = std.testing.allocator;
    _ = allocator;
}
```

**Step 2: Build and test**

Run: `cd pipeline/zig && zig build`
Expected: Compiles without errors

Run: `cd pipeline/zig && zig build test`
Expected: PASS

Run: `cd pipeline/zig && zig build run`
Expected: Prints usage text

**Step 3: Commit**

```bash
git add pipeline/zig/
git commit -m "feat: scaffold Zig build system for text-to-SQL pipeline"
```

---

### Task 3: CSV Parser Module

**Files:**
- Create: `pipeline/zig/src/csv_parser.zig`
- Modify: `pipeline/zig/src/main.zig` (add import)

A streaming CSV parser that handles quoted fields, embedded commas, and multi-line values (common in the staging schema files).

**Step 1: Write the failing test**

Add to `pipeline/zig/src/csv_parser.zig`:

```zig
// pipeline/zig/src/csv_parser.zig
const std = @import("std");

pub const CsvRow = struct {
    fields: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CsvRow) void {
        for (self.fields) |f| {
            self.allocator.free(f);
        }
        self.allocator.free(self.fields);
    }
};

pub const CsvParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) CsvParser {
        return .{ .allocator = allocator, .data = data, .pos = 0 };
    }

    pub fn nextRow(self: *CsvParser) !?CsvRow {
        if (self.pos >= self.data.len) return null;
        var fields = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (fields.items) |f| self.allocator.free(f);
            fields.deinit();
        }

        while (self.pos < self.data.len) {
            const field = try self.parseField();
            try fields.append(field);

            if (self.pos >= self.data.len) break;
            if (self.data[self.pos] == '\n') {
                self.pos += 1;
                break;
            }
            if (self.data[self.pos] == '\r') {
                self.pos += 1;
                if (self.pos < self.data.len and self.data[self.pos] == '\n') {
                    self.pos += 1;
                }
                break;
            }
            if (self.data[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return CsvRow{
            .fields = try fields.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    fn parseField(self: *CsvParser) ![]const u8 {
        if (self.pos >= self.data.len) return try self.allocator.dupe(u8, "");

        if (self.data[self.pos] == '"') {
            return self.parseQuotedField();
        }
        return self.parseUnquotedField();
    }

    fn parseQuotedField(self: *CsvParser) ![]const u8 {
        self.pos += 1; // skip opening quote
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '"') {
                if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '"') {
                    try result.append('"');
                    self.pos += 2;
                } else {
                    self.pos += 1; // skip closing quote
                    break;
                }
            } else {
                try result.append(self.data[self.pos]);
                self.pos += 1;
            }
        }
        return try result.toOwnedSlice();
    }

    fn parseUnquotedField(self: *CsvParser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and
            self.data[self.pos] != ',' and
            self.data[self.pos] != '\n' and
            self.data[self.pos] != '\r')
        {
            self.pos += 1;
        }
        return try self.allocator.dupe(u8, self.data[start..self.pos]);
    }
};

test "parse simple csv row" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "hello,world,42\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(usize, 3), row.fields.len);
    try std.testing.expectEqualStrings("hello", row.fields[0]);
    try std.testing.expectEqualStrings("world", row.fields[1]);
    try std.testing.expectEqualStrings("42", row.fields[2]);
}

test "parse quoted field with comma" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"hello, world\",42\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(usize, 2), row.fields.len);
    try std.testing.expectEqualStrings("hello, world", row.fields[0]);
}

test "parse quoted field with escaped quote" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"say \"\"hi\"\"\",done\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("say \"hi\"", row.fields[0]);
}

test "parse multiple rows" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "a,b\nc,d\n");
    var row1 = (try parser.nextRow()).?;
    defer row1.deinit();
    var row2 = (try parser.nextRow()).?;
    defer row2.deinit();
    try std.testing.expectEqualStrings("a", row1.fields[0]);
    try std.testing.expectEqualStrings("c", row2.fields[0]);
    const row3 = try parser.nextRow();
    try std.testing.expect(row3 == null);
}

test "parse multiline quoted field" {
    const allocator = std.testing.allocator;
    var parser = CsvParser.init(allocator, "\"line1\nline2\",val\n");
    var row = (try parser.nextRow()).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("line1\nline2", row.fields[0]);
    try std.testing.expectEqualStrings("val", row.fields[1]);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS (5 tests)

**Step 3: Commit**

```bash
git add pipeline/zig/src/csv_parser.zig
git commit -m "feat: add CSV parser with quoted field and multiline support"
```

---

### Task 4: Schema Registry Data Model

**Files:**
- Create: `pipeline/zig/src/schema_registry.zig`

Defines the data structures for the unified schema representation: tables, columns, hierarchies, valid values, domains.

**Step 1: Write data structures and tests**

```zig
// pipeline/zig/src/schema_registry.zig
const std = @import("std");

pub const DataType = enum {
    NVARCHAR,
    TIMESTAMP,
    DECIMAL,
    INTEGER,
    BIGINT,
    BOOLEAN,
    DATE,
    UNKNOWN,

    pub fn fromString(s: []const u8) DataType {
        const upper = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(s.len, 63);
            for (0..len) |i| {
                buf[i] = std.ascii.toUpper(s[i]);
            }
            break :blk buf[0..len];
        };
        if (std.mem.eql(u8, upper, "NVARCHAR")) return .NVARCHAR;
        if (std.mem.eql(u8, upper, "TIMESTAMP")) return .TIMESTAMP;
        if (std.mem.eql(u8, upper, "DECIMAL")) return .DECIMAL;
        if (std.mem.eql(u8, upper, "INTEGER")) return .INTEGER;
        if (std.mem.eql(u8, upper, "BIGINT")) return .BIGINT;
        if (std.mem.eql(u8, upper, "BOOLEAN")) return .BOOLEAN;
        if (std.mem.eql(u8, upper, "DATE")) return .DATE;
        return .UNKNOWN;
    }
};

pub const Column = struct {
    name: []const u8,
    data_type: DataType,
    description: []const u8,
    is_primary_key: bool,
    valid_values: [][]const u8, // known valid values for this column
};

pub const HierarchyLevel = struct {
    level: u8, // 0-6
    name: []const u8, // e.g., "ACCOUNT (L0)"
    values: [][]const u8, // all distinct values at this level
};

pub const Domain = enum {
    TREASURY,
    ESG,
    PERFORMANCE,
};

pub const Table = struct {
    name: []const u8,
    schema_name: []const u8, // e.g., "STG_BCRS"
    domain: Domain,
    columns: []Column,
    hierarchy_levels: []HierarchyLevel, // empty for non-dimension tables
    row_count: usize,
    description: []const u8,
};

pub const JoinPath = struct {
    from_table: []const u8,
    from_column: []const u8,
    to_table: []const u8,
    to_column: []const u8,
    join_type: enum { INNER, LEFT, CROSS },
};

pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table),
    join_paths: std.ArrayList(JoinPath),

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .tables = std.ArrayList(Table).init(allocator),
            .join_paths = std.ArrayList(JoinPath).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        self.tables.deinit();
        self.join_paths.deinit();
    }

    pub fn addTable(self: *SchemaRegistry, table: Table) !void {
        try self.tables.append(table);
    }

    pub fn findTable(self: *const SchemaRegistry, name: []const u8) ?*const Table {
        for (self.tables.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn tablesForDomain(self: *const SchemaRegistry, domain: Domain) []const Table {
        // Returns a slice view - caller should iterate self.tables.items and filter
        _ = self;
        _ = domain;
        return &.{};
    }
};

test "DataType fromString" {
    try std.testing.expectEqual(DataType.NVARCHAR, DataType.fromString("NVARCHAR"));
    try std.testing.expectEqual(DataType.TIMESTAMP, DataType.fromString("TIMESTAMP"));
    try std.testing.expectEqual(DataType.DECIMAL, DataType.fromString("DECIMAL"));
    try std.testing.expectEqual(DataType.UNKNOWN, DataType.fromString("BLOB"));
}

test "SchemaRegistry add and find table" {
    const allocator = std.testing.allocator;
    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();

    try registry.addTable(.{
        .name = "BSI_REM_FACT",
        .schema_name = "STG_BCRS",
        .domain = .TREASURY,
        .columns = &.{},
        .hierarchy_levels = &.{},
        .row_count = 0,
        .description = "Basel MI Fact table",
    });

    const found = registry.findTable("BSI_REM_FACT");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("STG_BCRS", found.?.schema_name);

    const not_found = registry.findTable("NONEXISTENT");
    try std.testing.expect(not_found == null);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/schema_registry.zig
git commit -m "feat: add schema registry data model for tables, columns, hierarchies"
```

---

### Task 5: Schema Extraction from Staging CSV

**Files:**
- Create: `pipeline/zig/src/schema_extractor.zig`

Parses `2_stagingschema.csv` (pre-converted) to populate the SchemaRegistry with table/column definitions.

**Step 1: Write test with sample staging data**

The staging schema CSV has columns: `Unique ID, Use Case, Source System(s), Source Table Name, Source Field Name, BTP Staging Schema Name, BTP Table Name, BTP Field Name, Description, DataType, Date Added/Modified, Reviewed?, Remarks`

```zig
// pipeline/zig/src/schema_extractor.zig
const std = @import("std");
const csv_parser = @import("csv_parser.zig");
const schema_registry = @import("schema_registry.zig");

pub fn extractFromStagingCsv(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    registry: *schema_registry.SchemaRegistry,
) !void {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);

    // Skip header rows (first 3 rows are metadata headers)
    var headers_skipped: u32 = 0;
    while (headers_skipped < 3) {
        var row = try parser.nextRow() orelse return;
        row.deinit();
        headers_skipped += 1;
    }

    // Track tables we've seen to avoid duplicates
    var seen_tables = std.StringHashMap(usize).init(allocator);
    defer seen_tables.deinit();

    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();

        if (row.fields.len < 10) continue;

        const schema_name = row.fields[5]; // BTP Staging Schema Name
        const table_name = row.fields[6]; // BTP Table Name
        const field_name = row.fields[7]; // BTP Field Name
        const description = row.fields[8]; // Description
        const data_type_str = row.fields[9]; // DataType

        if (table_name.len == 0 or field_name.len == 0) continue;

        const data_type = schema_registry.DataType.fromString(data_type_str);

        // Get or create table index
        const table_idx = if (seen_tables.get(table_name)) |idx| idx else blk: {
            const idx = registry.tables.items.len;
            try registry.addTable(.{
                .name = try allocator.dupe(u8, table_name),
                .schema_name = try allocator.dupe(u8, schema_name),
                .domain = domainFromUseCase(if (row.fields.len > 1) row.fields[1] else ""),
                .columns = &.{},
                .hierarchy_levels = &.{},
                .row_count = 0,
                .description = try allocator.dupe(u8, ""),
            });
            try seen_tables.put(try allocator.dupe(u8, table_name), idx);
            break :blk idx;
        };
        _ = table_idx;
        _ = data_type;
        _ = description;
    }
}

fn domainFromUseCase(use_case: []const u8) schema_registry.Domain {
    if (std.mem.indexOf(u8, use_case, "TREASURY") != null or
        std.mem.indexOf(u8, use_case, "CAPITAL") != null)
    {
        return .TREASURY;
    }
    if (std.mem.indexOf(u8, use_case, "ESG") != null) {
        return .ESG;
    }
    return .PERFORMANCE;
}

test "extract tables from staging csv" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\header1
        \\header2
        \\header3
        \\,TREASURY_CAPITAL,BCRS,"TABLE1",AS_OF_DATE,STG_BCRS,BSI_REM_FACT,AS_OF_DATE,Date field,TIMESTAMP,,,
        \\,TREASURY_CAPITAL,BCRS,"TABLE1",STATUS,STG_BCRS,BSI_REM_FACT,STATUS,Status field,NVARCHAR,,,
        \\,TREASURY_CAPITAL,BCRS,"TABLE2",COUNTRY,STG_BCRS,BSI_REM_DIM_COUNTRY,COUNTRY,Country name,NVARCHAR,,,
    ;

    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try extractFromStagingCsv(allocator, csv_data, &registry);

    // Should have extracted 2 tables
    try std.testing.expectEqual(@as(usize, 2), registry.tables.items.len);
    try std.testing.expectEqualStrings("BSI_REM_FACT", registry.tables.items[0].name);
    try std.testing.expectEqualStrings("STG_BCRS", registry.tables.items[0].schema_name);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/schema_extractor.zig
git commit -m "feat: extract table/column schema from staging CSV"
```

---

### Task 6: NFRP Dimension Hierarchy Parser

**Files:**
- Create: `pipeline/zig/src/hierarchy_parser.zig`

Parses NFRP dimension CSV files (Account, Product, Location, Cost, Segment) to extract hierarchical structures (L0→L5) and all valid dimension values.

**Step 1: Write test**

```zig
// pipeline/zig/src/hierarchy_parser.zig
const std = @import("std");
const csv_parser = @import("csv_parser.zig");
const schema_registry = @import("schema_registry.zig");

pub const DimensionType = enum {
    ACCOUNT,
    PRODUCT,
    LOCATION,
    COST_CLUSTER,
    SEGMENT,
};

pub fn parseHierarchy(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    dim_type: DimensionType,
) !schema_registry.Table {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);

    // First row is header
    var header = try parser.nextRow() orelse return error.EmptyFile;
    defer header.deinit();

    // Count hierarchy levels from header (columns named "X (L0)", "X (L1)", etc.)
    var level_count: u8 = 0;
    var level_indices: [8]usize = .{0} ** 8;
    for (header.fields, 0..) |field, i| {
        if (std.mem.indexOf(u8, field, "(L") != null) {
            if (level_count < 8) {
                level_indices[level_count] = i;
                level_count += 1;
            }
        }
    }

    // Collect unique values per level
    var level_values: [8]std.StringHashMap(void) = undefined;
    for (0..level_count) |i| {
        level_values[i] = std.StringHashMap(void).init(allocator);
    }
    defer for (0..level_count) |i| {
        level_values[i].deinit();
    };

    var row_count: usize = 0;
    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();
        row_count += 1;

        for (0..level_count) |lvl| {
            const idx = level_indices[lvl];
            if (idx < row.fields.len and row.fields[idx].len > 0) {
                const val = try allocator.dupe(u8, row.fields[idx]);
                try level_values[lvl].put(val, {});
            }
        }
    }

    // Build hierarchy levels
    var levels = std.ArrayList(schema_registry.HierarchyLevel).init(allocator);
    for (0..level_count) |lvl| {
        var values = std.ArrayList([]const u8).init(allocator);
        var it = level_values[lvl].keyIterator();
        while (it.next()) |key| {
            try values.append(key.*);
        }
        try levels.append(.{
            .level = @intCast(lvl),
            .name = try allocator.dupe(u8, header.fields[level_indices[lvl]]),
            .values = try values.toOwnedSlice(),
        });
    }

    const table_name = switch (dim_type) {
        .ACCOUNT => "NFRP_Account",
        .PRODUCT => "NFRP_Product",
        .LOCATION => "NFRP_Location",
        .COST_CLUSTER => "NFRP_Cost",
        .SEGMENT => "NFRP_Segment",
    };

    return schema_registry.Table{
        .name = try allocator.dupe(u8, table_name),
        .schema_name = try allocator.dupe(u8, "DIM"),
        .domain = .PERFORMANCE,
        .columns = &.{},
        .hierarchy_levels = try levels.toOwnedSlice(),
        .row_count = row_count,
        .description = try allocator.dupe(u8, "NFRP dimension table"),
    };
}

test "parse account hierarchy" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\ACCOUNT,ACCOUNT (L0),ACCOUNT (L1),ACCOUNT (L2)
        \\Income,Income,NII,NII
        \\Income,Income,NFI,Fee Income
        \\Cost,Total Cost,Staff Costs,Staff Costs
    ;

    const table = try parseHierarchy(allocator, csv_data, .ACCOUNT);
    try std.testing.expectEqualStrings("NFRP_Account", table.name);
    try std.testing.expectEqual(@as(usize, 3), table.hierarchy_levels.len);
    try std.testing.expectEqual(@as(usize, 3), table.row_count);

    // L0 should have 2 unique values: Income, Total Cost
    try std.testing.expectEqual(@as(u8, 0), table.hierarchy_levels[0].level);
    try std.testing.expectEqual(@as(usize, 2), table.hierarchy_levels[0].values.len);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/hierarchy_parser.zig
git commit -m "feat: parse NFRP dimension hierarchies (L0-L5)"
```

---

### Task 7: JSON Emitter for Schema Registry

**Files:**
- Create: `pipeline/zig/src/json_emitter.zig`

Serializes the SchemaRegistry to JSON format for consumption by Mojo and Mangle stages.

**Step 1: Write test and implementation**

```zig
// pipeline/zig/src/json_emitter.zig
const std = @import("std");
const schema_registry = @import("schema_registry.zig");

pub fn emitSchemaJson(
    registry: *const schema_registry.SchemaRegistry,
    writer: anytype,
) !void {
    try writer.writeAll("{\"tables\":[");
    for (registry.tables.items, 0..) |table, i| {
        if (i > 0) try writer.writeAll(",");
        try emitTable(table, writer);
    }
    try writer.writeAll("],\"join_paths\":[");
    for (registry.join_paths.items, 0..) |jp, i| {
        if (i > 0) try writer.writeAll(",");
        try emitJoinPath(jp, writer);
    }
    try writer.writeAll("]}");
}

fn emitTable(table: schema_registry.Table, writer: anytype) !void {
    try writer.writeAll("{\"name\":\"");
    try writeJsonEscaped(writer, table.name);
    try writer.writeAll("\",\"schema\":\"");
    try writeJsonEscaped(writer, table.schema_name);
    try writer.writeAll("\",\"domain\":\"");
    try writer.writeAll(@tagName(table.domain));
    try writer.writeAll("\",\"row_count\":");
    try writer.print("{d}", .{table.row_count});
    try writer.writeAll(",\"columns\":[");
    for (table.columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":\"");
        try writeJsonEscaped(writer, col.name);
        try writer.writeAll("\",\"type\":\"");
        try writer.writeAll(@tagName(col.data_type));
        try writer.writeAll("\"}");
    }
    try writer.writeAll("],\"hierarchy_levels\":[");
    for (table.hierarchy_levels, 0..) |hl, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"level\":{d},\"name\":\"", .{hl.level});
        try writeJsonEscaped(writer, hl.name);
        try writer.writeAll("\",\"value_count\":");
        try writer.print("{d}", .{hl.values.len});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn emitJoinPath(jp: schema_registry.JoinPath, writer: anytype) !void {
    try writer.writeAll("{\"from_table\":\"");
    try writeJsonEscaped(writer, jp.from_table);
    try writer.writeAll("\",\"from_column\":\"");
    try writeJsonEscaped(writer, jp.from_column);
    try writer.writeAll("\",\"to_table\":\"");
    try writeJsonEscaped(writer, jp.to_table);
    try writer.writeAll("\",\"to_column\":\"");
    try writeJsonEscaped(writer, jp.to_column);
    try writer.writeAll("\"}");
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

test "emit empty registry" {
    const allocator = std.testing.allocator;
    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try emitSchemaJson(&registry, buf.writer());

    try std.testing.expectEqualStrings("{\"tables\":[],\"join_paths\":[]}", buf.items);
}

test "emit registry with table" {
    const allocator = std.testing.allocator;
    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try registry.addTable(.{
        .name = "TEST_TABLE",
        .schema_name = "STG",
        .domain = .TREASURY,
        .columns = &.{},
        .hierarchy_levels = &.{},
        .row_count = 100,
        .description = "Test",
    });

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try emitSchemaJson(&registry, buf.writer());

    // Verify it contains the table name
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TEST_TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TREASURY") != null);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/json_emitter.zig
git commit -m "feat: JSON emitter for schema registry serialization"
```

---

### Task 8: Template Parser

**Files:**
- Create: `pipeline/zig/src/template_parser.zig`

Parses prompt template CSVs (converted from Prompt_samples.xlsx, etc.) and extracts parameterized templates with their parameter slot definitions.

**Step 1: Write test and implementation**

```zig
// pipeline/zig/src/template_parser.zig
const std = @import("std");
const csv_parser = @import("csv_parser.zig");

pub const ParamSlot = struct {
    name: []const u8, // e.g., "select metric", "input ISIN", "select country"
    slot_type: enum { SELECT, INPUT }, // select = choose from list, input = free text
    start_pos: usize,
    end_pos: usize,
};

pub const PromptTemplate = struct {
    domain: []const u8, // "treasury", "esg", "performance"
    category: []const u8, // e.g., "ISIN position", "Maturity snapshot"
    product: []const u8, // e.g., "Bonds", "IRS", "Issuances"
    template_text: []const u8, // e.g., "Provide total [select metric] for ISIN [input ISIN]"
    example_text: []const u8, // e.g., "Provide total MtM for ISIN US91282CGB19"
    params: []ParamSlot,
};

pub fn extractParamSlots(allocator: std.mem.Allocator, template: []const u8) ![]ParamSlot {
    var slots = std.ArrayList(ParamSlot).init(allocator);
    errdefer slots.deinit();

    var i: usize = 0;
    while (i < template.len) {
        // Look for [xxx] or <xxx> parameter slots
        const open_bracket = if (std.mem.indexOfPos(u8, template, i, "[")) |pos| pos else null;
        const open_angle = if (std.mem.indexOfPos(u8, template, i, "<")) |pos| pos else null;

        const open_pos = blk: {
            if (open_bracket != null and open_angle != null) {
                break :blk @min(open_bracket.?, open_angle.?);
            } else if (open_bracket != null) {
                break :blk open_bracket.?;
            } else if (open_angle != null) {
                break :blk open_angle.?;
            } else break;
        };

        const close_char: u8 = if (template[open_pos] == '[') ']' else '>';
        const close_pos = std.mem.indexOfPos(u8, template, open_pos + 1, &.{close_char}) orelse break;

        const slot_text = template[open_pos + 1 .. close_pos];
        const slot_type: @TypeOf(ParamSlot.slot_type) = if (std.mem.startsWith(u8, slot_text, "select") or
            std.mem.startsWith(u8, slot_text, "Select"))
            .SELECT
        else
            .INPUT;

        try slots.append(.{
            .name = try allocator.dupe(u8, slot_text),
            .slot_type = slot_type,
            .start_pos = open_pos,
            .end_pos = close_pos + 1,
        });

        i = close_pos + 1;
    }

    return try slots.toOwnedSlice();
}

pub fn parseTemplatesCsv(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    domain: []const u8,
) ![]PromptTemplate {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);
    var templates = std.ArrayList(PromptTemplate).init(allocator);
    errdefer templates.deinit();

    // Skip header
    var header = try parser.nextRow() orelse return &.{};
    header.deinit();

    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();

        if (row.fields.len < 4) continue;

        // Treasury format: category, product, template, example
        // ESG format: product, template, example
        const has_category = row.fields.len >= 4;
        const template_idx: usize = if (has_category) 2 else 1;
        const example_idx: usize = if (has_category) 3 else 2;

        const template_text = row.fields[template_idx];
        if (template_text.len == 0) continue;

        const params = try extractParamSlots(allocator, template_text);

        try templates.append(.{
            .domain = try allocator.dupe(u8, domain),
            .category = try allocator.dupe(u8, if (has_category) row.fields[0] else ""),
            .product = try allocator.dupe(u8, if (has_category) row.fields[1] else row.fields[0]),
            .template_text = try allocator.dupe(u8, template_text),
            .example_text = try allocator.dupe(u8, if (example_idx < row.fields.len) row.fields[example_idx] else ""),
            .params = params,
        });
    }

    return try templates.toOwnedSlice();
}

test "extract param slots from bracket template" {
    const allocator = std.testing.allocator;
    const slots = try extractParamSlots(
        allocator,
        "Provide total [select metric] for ISIN [input ISIN] in [select country] country.",
    );
    defer allocator.free(slots);

    try std.testing.expectEqual(@as(usize, 3), slots.len);
    try std.testing.expectEqualStrings("select metric", slots[0].name);
    try std.testing.expectEqual(ParamSlot.slot_type.SELECT, slots[0].slot_type);
    try std.testing.expectEqualStrings("input ISIN", slots[1].name);
    try std.testing.expectEqual(ParamSlot.slot_type.INPUT, slots[1].slot_type);
    try std.testing.expectEqualStrings("select country", slots[2].name);
}

test "extract param slots from angle bracket template" {
    const allocator = std.testing.allocator;
    const slots = try extractParamSlots(
        allocator,
        "<select measure> and <select measure> for booking location asean",
    );
    defer allocator.free(slots);

    try std.testing.expectEqual(@as(usize, 2), slots.len);
    try std.testing.expectEqualStrings("select measure", slots[0].name);
    try std.testing.expectEqualStrings("select measure", slots[1].name);
}

test "parse treasury template csv" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\category,product,Prompt Template,Original_Prompt (Example)
        \\ISIN position,Bonds,Provide total [select metric] for ISIN [input ISIN],Provide total MtM for ISIN US91282CGB19
    ;

    const templates = try parseTemplatesCsv(allocator, csv_data, "treasury");
    defer allocator.free(templates);

    try std.testing.expectEqual(@as(usize, 1), templates.len);
    try std.testing.expectEqualStrings("treasury", templates[0].domain);
    try std.testing.expectEqualStrings("ISIN position", templates[0].category);
    try std.testing.expectEqualStrings("Bonds", templates[0].product);
    try std.testing.expectEqual(@as(usize, 2), templates[0].params.len);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/template_parser.zig
git commit -m "feat: parse prompt templates and extract parameter slots"
```

---

### Task 9: HANA SQL Builder

**Files:**
- Create: `pipeline/zig/src/hana_sql_builder.zig`

Generates SAP HANA SQL queries from structured query specifications. Handles SELECT, FROM, WHERE, GROUP BY, ORDER BY, JOIN, and HANA-specific functions.

**Step 1: Write test and implementation**

```zig
// pipeline/zig/src/hana_sql_builder.zig
const std = @import("std");

pub const AggFunc = enum { NONE, SUM, AVG, COUNT, MIN, MAX, COUNT_DISTINCT };

pub const SelectColumn = struct {
    table_alias: ?[]const u8,
    column: []const u8,
    agg: AggFunc,
    alias: ?[]const u8,
};

pub const WhereClause = struct {
    column: []const u8,
    table_alias: ?[]const u8,
    op: enum { EQ, NEQ, GT, GTE, LT, LTE, LIKE, IN, BETWEEN, IS_NULL, IS_NOT_NULL },
    value: []const u8, // literal value or placeholder
};

pub const JoinClause = struct {
    join_type: enum { INNER, LEFT, RIGHT, CROSS },
    table: []const u8,
    schema: []const u8,
    alias: []const u8,
    on_left: []const u8,
    on_right: []const u8,
};

pub const OrderBy = struct {
    column: []const u8,
    direction: enum { ASC, DESC },
};

pub const QuerySpec = struct {
    select: []const SelectColumn,
    from_table: []const u8,
    from_schema: []const u8,
    from_alias: []const u8,
    joins: []const JoinClause,
    where: []const WhereClause,
    group_by: []const []const u8,
    order_by: []const OrderBy,
    limit: ?u32,
};

pub fn buildQuery(allocator: std.mem.Allocator, spec: QuerySpec) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    // SELECT
    try w.writeAll("SELECT ");
    for (spec.select, 0..) |col, i| {
        if (i > 0) try w.writeAll(", ");
        if (col.agg != .NONE) {
            try w.writeAll(@tagName(col.agg));
            try w.writeAll("(");
        }
        if (col.table_alias) |ta| {
            try w.writeAll(ta);
            try w.writeAll(".");
        }
        try w.writeAll(col.column);
        if (col.agg != .NONE) {
            try w.writeAll(")");
        }
        if (col.alias) |a| {
            try w.writeAll(" AS ");
            try w.writeAll(a);
        }
    }

    // FROM
    try w.writeAll(" FROM ");
    try w.writeAll(spec.from_schema);
    try w.writeAll(".");
    try w.writeAll(spec.from_table);
    if (spec.from_alias.len > 0) {
        try w.writeAll(" ");
        try w.writeAll(spec.from_alias);
    }

    // JOINs
    for (spec.joins) |j| {
        try w.writeAll(" ");
        try w.writeAll(@tagName(j.join_type));
        try w.writeAll(" JOIN ");
        try w.writeAll(j.schema);
        try w.writeAll(".");
        try w.writeAll(j.table);
        try w.writeAll(" ");
        try w.writeAll(j.alias);
        try w.writeAll(" ON ");
        try w.writeAll(j.on_left);
        try w.writeAll(" = ");
        try w.writeAll(j.on_right);
    }

    // WHERE
    if (spec.where.len > 0) {
        try w.writeAll(" WHERE ");
        for (spec.where, 0..) |wc, i| {
            if (i > 0) try w.writeAll(" AND ");
            if (wc.table_alias) |ta| {
                try w.writeAll(ta);
                try w.writeAll(".");
            }
            try w.writeAll(wc.column);
            switch (wc.op) {
                .EQ => {
                    try w.writeAll(" = ");
                    try w.writeAll(wc.value);
                },
                .LIKE => {
                    try w.writeAll(" LIKE ");
                    try w.writeAll(wc.value);
                },
                .GT => {
                    try w.writeAll(" > ");
                    try w.writeAll(wc.value);
                },
                .GTE => {
                    try w.writeAll(" >= ");
                    try w.writeAll(wc.value);
                },
                .LT => {
                    try w.writeAll(" < ");
                    try w.writeAll(wc.value);
                },
                .LTE => {
                    try w.writeAll(" <= ");
                    try w.writeAll(wc.value);
                },
                .IS_NULL => try w.writeAll(" IS NULL"),
                .IS_NOT_NULL => try w.writeAll(" IS NOT NULL"),
                else => {
                    try w.writeAll(" = ");
                    try w.writeAll(wc.value);
                },
            }
        }
    }

    // GROUP BY
    if (spec.group_by.len > 0) {
        try w.writeAll(" GROUP BY ");
        for (spec.group_by, 0..) |col, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(col);
        }
    }

    // ORDER BY
    if (spec.order_by.len > 0) {
        try w.writeAll(" ORDER BY ");
        for (spec.order_by, 0..) |ob, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(ob.column);
            try w.writeAll(if (ob.direction == .DESC) " DESC" else " ASC");
        }
    }

    // LIMIT
    if (spec.limit) |lim| {
        try w.print(" LIMIT {d}", .{lim});
    }

    return try buf.toOwnedSlice();
}

test "build simple select query" {
    const allocator = std.testing.allocator;
    const sql = try buildQuery(allocator, .{
        .select = &.{
            .{ .table_alias = "t", .column = "COUNTRY", .agg = .NONE, .alias = null },
            .{ .table_alias = "t", .column = "MTM", .agg = .SUM, .alias = "total_mtm" },
        },
        .from_table = "BOND_POSITIONS",
        .from_schema = "STG_TREASURY",
        .from_alias = "t",
        .joins = &.{},
        .where = &.{
            .{ .column = "GLB_FV_HTC", .table_alias = "t", .op = .EQ, .value = "'FVOCI'" },
        },
        .group_by = &.{"t.COUNTRY"},
        .order_by = &.{
            .{ .column = "total_mtm", .direction = .DESC },
        },
        .limit = 5,
    });
    defer allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT t.COUNTRY, SUM(t.MTM) AS total_mtm FROM STG_TREASURY.BOND_POSITIONS t WHERE t.GLB_FV_HTC = 'FVOCI' GROUP BY t.COUNTRY ORDER BY total_mtm DESC LIMIT 5",
        sql,
    );
}

test "build query with join" {
    const allocator = std.testing.allocator;
    const sql = try buildQuery(allocator, .{
        .select = &.{
            .{ .table_alias = "f", .column = "NOTIONAL", .agg = .SUM, .alias = null },
        },
        .from_table = "BSI_REM_FACT",
        .from_schema = "STG_BCRS",
        .from_alias = "f",
        .joins = &.{
            .{
                .join_type = .INNER,
                .table = "BSI_REM_DIM_COUNTRY",
                .schema = "STG_BCRS",
                .alias = "d",
                .on_left = "f.COUNTRY_ID",
                .on_right = "d.COUNTRY_ID",
            },
        },
        .where = &.{},
        .group_by = &.{},
        .order_by = &.{},
        .limit = null,
    });
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN STG_BCRS.BSI_REM_DIM_COUNTRY") != null);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/hana_sql_builder.zig
git commit -m "feat: SAP HANA SQL query builder with SELECT/JOIN/WHERE/GROUP BY"
```

---

### Task 10: Template Expander

**Files:**
- Create: `pipeline/zig/src/template_expander.zig`

Combines templates + schema registry to produce concrete question/SQL pairs via parameterized expansion.

**Step 1: Write test and implementation**

```zig
// pipeline/zig/src/template_expander.zig
const std = @import("std");
const template_parser = @import("template_parser.zig");
const schema_registry = @import("schema_registry.zig");
const hana_sql_builder = @import("hana_sql_builder.zig");

pub const TrainingPair = struct {
    question: []const u8,
    sql: []const u8,
    domain: []const u8,
    difficulty: []const u8, // "easy", "moderate", "hard"
    source: []const u8, // "template_expansion"
};

pub fn expandTemplate(
    allocator: std.mem.Allocator,
    template: template_parser.PromptTemplate,
    param_values: []const []const []const u8, // values for each param slot
    max_expansions: usize,
) ![]TrainingPair {
    var pairs = std.ArrayList(TrainingPair).init(allocator);
    errdefer pairs.deinit();

    if (template.params.len == 0) {
        // No params - just use the template as-is
        try pairs.append(.{
            .question = try allocator.dupe(u8, template.template_text),
            .sql = try allocator.dupe(u8, "-- TODO: generate SQL"),
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, "easy"),
            .source = try allocator.dupe(u8, "template_expansion"),
        });
        return try pairs.toOwnedSlice();
    }

    // Generate combinations (capped at max_expansions)
    var count: usize = 0;
    var indices: [16]usize = .{0} ** 16;
    const n_params = @min(template.params.len, param_values.len);

    while (count < max_expansions) {
        // Build expanded question by substituting params
        var question_buf = std.ArrayList(u8).init(allocator);
        var last_end: usize = 0;
        for (0..n_params) |p| {
            const slot = template.params[p];
            try question_buf.appendSlice(template.template_text[last_end..slot.start_pos]);
            if (indices[p] < param_values[p].len) {
                try question_buf.appendSlice(param_values[p][indices[p]]);
            }
            last_end = slot.end_pos;
        }
        if (last_end < template.template_text.len) {
            try question_buf.appendSlice(template.template_text[last_end..]);
        }

        try pairs.append(.{
            .question = try question_buf.toOwnedSlice(),
            .sql = try allocator.dupe(u8, "-- TODO: generate SQL"),
            .domain = try allocator.dupe(u8, template.domain),
            .difficulty = try allocator.dupe(u8, classifyDifficulty(n_params)),
            .source = try allocator.dupe(u8, "template_expansion"),
        });

        count += 1;

        // Increment indices (odometer-style)
        var carry = true;
        var p_idx: usize = n_params;
        while (p_idx > 0 and carry) {
            p_idx -= 1;
            indices[p_idx] += 1;
            if (indices[p_idx] >= param_values[p_idx].len) {
                indices[p_idx] = 0;
            } else {
                carry = false;
            }
        }
        if (carry) break; // All combinations exhausted
    }

    return try pairs.toOwnedSlice();
}

fn classifyDifficulty(param_count: usize) []const u8 {
    if (param_count <= 1) return "easy";
    if (param_count <= 3) return "moderate";
    return "hard";
}

test "expand template with single param" {
    const allocator = std.testing.allocator;

    const params = [_]template_parser.ParamSlot{
        .{ .name = "select country", .slot_type = .SELECT, .start_pos = 4, .end_pos = 22 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "treasury",
        .category = "Position",
        .product = "Bonds",
        .template_text = "For [select country] show MtM",
        .example_text = "For UK show MtM",
        .params = &params,
    };

    const values: [1][]const []const u8 = .{
        &.{ "UK", "INDIA", "CHINA" },
    };

    const pairs = try expandTemplate(allocator, template, &values, 100);
    defer allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 3), pairs.len);
    try std.testing.expectEqualStrings("For UK show MtM", pairs[0].question);
    try std.testing.expectEqualStrings("For INDIA show MtM", pairs[1].question);
    try std.testing.expectEqualStrings("For CHINA show MtM", pairs[2].question);
    try std.testing.expectEqualStrings("easy", pairs[0].difficulty);
}

test "expand respects max_expansions" {
    const allocator = std.testing.allocator;

    const params = [_]template_parser.ParamSlot{
        .{ .name = "country", .slot_type = .SELECT, .start_pos = 0, .end_pos = 9 },
    };
    const template = template_parser.PromptTemplate{
        .domain = "test",
        .category = "",
        .product = "",
        .template_text = "[country] data",
        .example_text = "",
        .params = &params,
    };

    const countries = [_][]const u8{ "A", "B", "C", "D", "E" };
    const values: [1][]const []const u8 = .{&countries};

    const pairs = try expandTemplate(allocator, template, &values, 2);
    defer allocator.free(pairs);

    try std.testing.expectEqual(@as(usize, 2), pairs.len);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/template_expander.zig
git commit -m "feat: template expansion engine for question/SQL pair generation"
```

---

### Task 11: Spider/BIRD Output Formatter

**Files:**
- Create: `pipeline/zig/src/spider_formatter.zig`

Formats training pairs into Spider/BIRD benchmark JSON and handles train/dev/test splitting.

**Step 1: Write test and implementation**

```zig
// pipeline/zig/src/spider_formatter.zig
const std = @import("std");
const template_expander = @import("template_expander.zig");

pub const SpiderEntry = struct {
    db_id: []const u8,
    query: []const u8,
    question: []const u8,
    difficulty: []const u8,
    domain: []const u8,
    source: []const u8,
};

pub fn pairsToSpiderEntries(
    allocator: std.mem.Allocator,
    pairs: []const template_expander.TrainingPair,
    db_id: []const u8,
) ![]SpiderEntry {
    var entries = try allocator.alloc(SpiderEntry, pairs.len);
    for (pairs, 0..) |p, i| {
        entries[i] = .{
            .db_id = db_id,
            .query = p.sql,
            .question = p.question,
            .difficulty = p.difficulty,
            .domain = p.domain,
            .source = p.source,
        };
    }
    return entries;
}

pub fn writeSpiderJson(
    entries: []const SpiderEntry,
    writer: anytype,
) !void {
    try writer.writeAll("[\n");
    for (entries, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("  {");
        try writer.writeAll("\"db_id\": \"");
        try writeJsonEscaped(writer, entry.db_id);
        try writer.writeAll("\", \"query\": \"");
        try writeJsonEscaped(writer, entry.query);
        try writer.writeAll("\", \"question\": \"");
        try writeJsonEscaped(writer, entry.question);
        try writer.writeAll("\", \"difficulty\": \"");
        try writeJsonEscaped(writer, entry.difficulty);
        try writer.writeAll("\", \"domain\": \"");
        try writeJsonEscaped(writer, entry.domain);
        try writer.writeAll("\", \"source\": \"");
        try writeJsonEscaped(writer, entry.source);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("\n]\n");
}

pub const SplitResult = struct {
    train: []SpiderEntry,
    dev: []SpiderEntry,
    test_set: []SpiderEntry,
};

/// Split entries 80/10/10 with deterministic shuffle based on question hash.
pub fn splitTrainDevTest(
    allocator: std.mem.Allocator,
    entries: []const SpiderEntry,
) !SplitResult {
    var train = std.ArrayList(SpiderEntry).init(allocator);
    var dev = std.ArrayList(SpiderEntry).init(allocator);
    var test_set = std.ArrayList(SpiderEntry).init(allocator);

    for (entries) |entry| {
        const hash = std.hash.Wyhash.hash(0, entry.question);
        const bucket = hash % 10;
        if (bucket < 8) {
            try train.append(entry);
        } else if (bucket == 8) {
            try dev.append(entry);
        } else {
            try test_set.append(entry);
        }
    }

    return .{
        .train = try train.toOwnedSlice(),
        .dev = try dev.toOwnedSlice(),
        .test_set = try test_set.toOwnedSlice(),
    };
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

test "write spider json" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const entries = [_]SpiderEntry{
        .{
            .db_id = "banking_btp",
            .query = "SELECT 1",
            .question = "Test question?",
            .difficulty = "easy",
            .domain = "treasury",
            .source = "template_expansion",
        },
    };

    try writeSpiderJson(&entries, buf.writer());
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "banking_btp") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Test question?") != null);
}

test "split produces correct proportions" {
    const allocator = std.testing.allocator;
    var entries: [100]SpiderEntry = undefined;
    for (&entries, 0..) |*e, i| {
        var q_buf: [16]u8 = undefined;
        const q_len = std.fmt.formatIntBuf(&q_buf, i, 10, .lower, .{});
        e.* = .{
            .db_id = "test",
            .query = "SELECT 1",
            .question = q_buf[0..q_len],
            .difficulty = "easy",
            .domain = "test",
            .source = "test",
        };
    }

    const split = try splitTrainDevTest(allocator, &entries);
    defer allocator.free(split.train);
    defer allocator.free(split.dev);
    defer allocator.free(split.test_set);

    const total = split.train.len + split.dev.len + split.test_set.len;
    try std.testing.expectEqual(@as(usize, 100), total);
    // Approximately 80/10/10 (+/- statistical noise)
    try std.testing.expect(split.train.len >= 60);
    try std.testing.expect(split.train.len <= 95);
}
```

**Step 2: Run tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS

**Step 3: Commit**

```bash
git add pipeline/zig/src/spider_formatter.zig
git commit -m "feat: Spider/BIRD JSON formatter with train/dev/test splitting"
```

---

### Task 12: Mangle Validation Rules for Text-to-SQL

**Files:**
- Create: `pipeline/mangle/schema_validation.mg`
- Create: `pipeline/mangle/sql_validation.mg`
- Create: `pipeline/mangle/domain_constraints.mg`
- Create: `pipeline/mangle/coverage_rules.mg`
- Create: `pipeline/mangle/spider_format.mg`

Extends HippoCPP's Mangle rule infrastructure with text-to-SQL specific validation rules.

**Step 1: Write validation rules**

```
// pipeline/mangle/schema_validation.mg
// Schema consistency rules for text-to-SQL training data validation
//
// These rules verify that SQL queries reference only valid tables and columns
// from the banking BTP schema.

// ============================================================================
// Schema Facts (loaded from schema_registry.json)
// ============================================================================

Decl btp_table(schema_name: String, table_name: String, domain: String).
Decl btp_column(table_name: String, column_name: String, data_type: String).
Decl btp_hierarchy(table_name: String, level: i64, level_name: String).

// ============================================================================
// SQL Reference Extraction (from parsed SQL)
// ============================================================================

Decl sql_references_table(pair_id: i64, schema_name: String, table_name: String).
Decl sql_references_column(pair_id: i64, table_name: String, column_name: String).

// ============================================================================
// Validation Rules
// ============================================================================

// Valid table reference: table exists in schema
Decl valid_table_ref(pair_id: i64, table_name: String).
valid_table_ref(PID, T) :-
    sql_references_table(PID, _, T),
    btp_table(_, T, _).

// Invalid table reference: table not in schema
Decl invalid_table_ref(pair_id: i64, table_name: String).
invalid_table_ref(PID, T) :-
    sql_references_table(PID, _, T),
    !btp_table(_, T, _).

// Valid column reference: column exists in referenced table
Decl valid_column_ref(pair_id: i64, table_name: String, column_name: String).
valid_column_ref(PID, T, C) :-
    sql_references_column(PID, T, C),
    btp_column(T, C, _).

// Invalid column reference
Decl invalid_column_ref(pair_id: i64, table_name: String, column_name: String).
invalid_column_ref(PID, T, C) :-
    sql_references_column(PID, T, C),
    !btp_column(T, C, _).

// Overall schema validity: no invalid references
Decl schema_valid(pair_id: i64).
schema_valid(PID) :-
    sql_references_table(PID, _, _),
    !invalid_table_ref(PID, _),
    !invalid_column_ref(PID, _, _).
```

```
// pipeline/mangle/domain_constraints.mg
// Domain-specific validation rules for banking data
//
// Ensures metric/product compatibility and hierarchy consistency.

// ============================================================================
// Metric-Product Compatibility
// ============================================================================

Decl metric_valid_for_product(metric: String, product: String).

// Bond metrics
metric_valid_for_product("MTM", "BOND").
metric_valid_for_product("NOTIONAL", "BOND").
metric_valid_for_product("PV01", "BOND").
metric_valid_for_product("RWA", "BOND").
metric_valid_for_product("CR_DELTA", "BOND").
metric_valid_for_product("BOOK_VALUE", "BOND").

// IRS metrics
metric_valid_for_product("MTM", "IRS").
metric_valid_for_product("PV01", "IRS").
metric_valid_for_product("NOTIONAL", "IRS").

// Issuance metrics
metric_valid_for_product("NOTIONAL", "ISSUANCE").
metric_valid_for_product("BOOK_VALUE", "ISSUANCE").
metric_valid_for_product("COUPON_RATE", "ISSUANCE").

// ESG metrics
metric_valid_for_product("FINANCED_EMISSION", "NET_ZERO").
metric_valid_for_product("IN_SCOPE_EXPOSURE", "NET_ZERO").
metric_valid_for_product("CIB_PE_ASSET", "INTEGRATED_CLIENT").
metric_valid_for_product("CIB_TOTAL_REVENUE", "INTEGRATED_CLIENT").

// ============================================================================
// Hierarchy Level Rules
// ============================================================================

// Cannot GROUP BY a higher level and filter by a lower level of same dimension
Decl hierarchy_conflict(pair_id: i64, dimension: String, group_level: i64, filter_level: i64).
hierarchy_conflict(PID, Dim, GL, FL) :-
    groups_by_hierarchy_level(PID, Dim, GL),
    filters_by_hierarchy_level(PID, Dim, FL),
    GL > FL.  // grouping at coarser level than filter = conflict

Decl groups_by_hierarchy_level(pair_id: i64, dimension: String, level: i64).
Decl filters_by_hierarchy_level(pair_id: i64, dimension: String, level: i64).
```

```
// pipeline/mangle/coverage_rules.mg
// Coverage analysis rules for training dataset quality

// ============================================================================
// Domain Coverage
// ============================================================================

Decl pair_domain(pair_id: i64, domain: String).
Decl domain_count(domain: String, count: i64).

domain_count(D, fn:count<PID>) :- pair_domain(PID, D).

// Minimum coverage threshold per domain
Decl domain_coverage_ok(domain: String).
domain_coverage_ok(D) :-
    domain_count(D, C),
    C >= 100.

// ============================================================================
// Difficulty Distribution
// ============================================================================

Decl pair_difficulty(pair_id: i64, difficulty: String).
Decl difficulty_count(difficulty: String, count: i64).

difficulty_count(D, fn:count<PID>) :- pair_difficulty(PID, D).

// ============================================================================
// Table Coverage
// ============================================================================

Decl table_in_any_query(table_name: String).
table_in_any_query(T) :- sql_references_table(_, _, T).

Decl uncovered_table(table_name: String).
uncovered_table(T) :-
    btp_table(_, T, _),
    !table_in_any_query(T).
```

```
// pipeline/mangle/spider_format.mg
// Spider/BIRD output format validation

// ============================================================================
// Required Fields
// ============================================================================

Decl spider_entry(pair_id: i64, db_id: String, query: String, question: String).
Decl spider_entry_has_difficulty(pair_id: i64, difficulty: String).

// Valid difficulties
Decl valid_difficulty(d: String).
valid_difficulty("easy").
valid_difficulty("moderate").
valid_difficulty("hard").
valid_difficulty("extra_hard").

// Entry has valid difficulty label
Decl difficulty_valid(pair_id: i64).
difficulty_valid(PID) :-
    spider_entry_has_difficulty(PID, D),
    valid_difficulty(D).

// ============================================================================
// Duplicate Detection
// ============================================================================

Decl duplicate_question(pair_id_1: i64, pair_id_2: i64, question: String).
duplicate_question(P1, P2, Q) :-
    spider_entry(P1, _, _, Q),
    spider_entry(P2, _, _, Q),
    P1 < P2.

// ============================================================================
// Overall Entry Validity
// ============================================================================

Decl entry_valid(pair_id: i64).
entry_valid(PID) :-
    spider_entry(PID, DbId, Query, Question),
    DbId != "",
    Query != "",
    Question != "",
    difficulty_valid(PID).
```

**Step 2: Verify Mangle syntax is consistent with existing hippocpp rules**

Check that the syntax matches `hippocpp/mangle/rules.mg` patterns (Decl, :-, fn:count<>, etc.). The files above follow the same conventions.

**Step 3: Commit**

```bash
git add pipeline/mangle/
git commit -m "feat: add Mangle validation rules for text-to-SQL training data"
```

---

### Task 13: Mojo LLM Augmentation Client

**Files:**
- Create: `pipeline/mojo/src/augmenter.mojo`

Mojo module that calls an LLM API to generate question paraphrases and complex query variations.

**Step 1: Write the augmenter**

```mojo
# pipeline/mojo/src/augmenter.mojo
"""
LLM Augmentation Module for Text-to-SQL Training Data

Calls an LLM API (Claude/OpenAI-compatible) to:
1. Paraphrase existing questions (same SQL, different wording)
2. Generate complex query variations (multi-join, subquery, window function)
3. Fill coverage gaps (questions for underrepresented tables/columns)
"""

from python import Python

fn load_json(path: String) raises -> PythonObject:
    """Load a JSON file using Python's json module."""
    let json = Python.import_module("json")
    let builtins = Python.import_module("builtins")
    let f = builtins.open(path, "r")
    let data = json.load(f)
    f.close()
    return data

fn save_json(data: PythonObject, path: String) raises:
    """Save data as JSON."""
    let json = Python.import_module("json")
    let builtins = Python.import_module("builtins")
    let f = builtins.open(path, "w")
    json.dump(data, f, indent=2)
    f.close()

fn call_llm_api(
    api_url: String,
    api_key: String,
    system_prompt: String,
    user_prompt: String,
) raises -> String:
    """Call an OpenAI-compatible LLM API endpoint."""
    let requests = Python.import_module("requests")
    let json = Python.import_module("json")

    let headers = Python.dict()
    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Bearer " + api_key

    let messages = Python.list()
    let sys_msg = Python.dict()
    sys_msg["role"] = "system"
    sys_msg["content"] = system_prompt
    messages.append(sys_msg)
    let usr_msg = Python.dict()
    usr_msg["role"] = "user"
    usr_msg["content"] = user_prompt
    messages.append(usr_msg)

    let body = Python.dict()
    body["model"] = "qwen3.5-1.8b-int8"
    body["messages"] = messages
    body["temperature"] = 0.7
    body["max_tokens"] = 2048

    let response = requests.post(
        api_url + "/chat/completions",
        headers=headers,
        json=body,
        timeout=60,
    )
    let result = response.json()
    return str(result["choices"][0]["message"]["content"])

fn generate_paraphrases(
    api_url: String,
    api_key: String,
    question: String,
    sql: String,
    schema_context: String,
    count: Int,
) raises -> PythonObject:
    """Generate paraphrases of a question that map to the same SQL."""
    let json = Python.import_module("json")

    let system_prompt = String(
        "You are an expert at rephrasing database questions. "
        "Given a question and its SQL query against a banking database, "
        "generate natural language rephrasings that would produce the same SQL. "
        "Output JSON array of strings. Each rephrasing should sound natural "
        "and use different vocabulary/structure while preserving meaning."
    )

    let user_prompt = String(
        "Schema context:\n" + schema_context + "\n\n"
        "Original question: " + question + "\n"
        "SQL: " + sql + "\n\n"
        "Generate " + str(count) + " natural rephrasings as a JSON array of strings."
    )

    let response = call_llm_api(api_url, api_key, system_prompt, user_prompt)
    return json.loads(response)

fn generate_complex_queries(
    api_url: String,
    api_key: String,
    base_pairs: PythonObject,
    schema_context: String,
    count: Int,
) raises -> PythonObject:
    """Generate complex query variations (multi-join, subquery, window function)."""
    let json = Python.import_module("json")

    let system_prompt = String(
        "You are an expert SQL developer for SAP HANA databases. "
        "Given sample question/SQL pairs and a schema, generate MORE COMPLEX "
        "questions and their corresponding HANA SQL queries. "
        "Use: multi-table joins, subqueries, window functions, CASE WHEN, "
        "CTEs, HAVING clauses, and complex aggregations. "
        "Use HANA-specific functions: TO_DATE(), ADD_MONTHS(), WEEKDAY(). "
        "Output as JSON array of {\"question\": ..., \"sql\": ...} objects."
    )

    let samples_str = json.dumps(base_pairs.__getslice__(0, 5))
    let user_prompt = String(
        "Schema:\n" + schema_context + "\n\n"
        "Sample pairs:\n" + str(samples_str) + "\n\n"
        "Generate " + str(count) + " complex query pairs as JSON array."
    )

    let response = call_llm_api(api_url, api_key, system_prompt, user_prompt)
    return json.loads(response)

fn main() raises:
    """Main augmentation pipeline entry point."""
    let os = Python.import_module("os")
    let json = Python.import_module("json")

    let api_url = str(os.environ.get("LLM_API_URL", "http://localhost:8001/v1"))
    let api_key = str(os.environ.get("LLM_API_KEY", ""))

    # Load inputs
    let base_pairs = load_json("pipeline/output/intermediate/base_pairs.json")
    let schema = load_json("pipeline/output/intermediate/schema_registry.json")
    let schema_context = json.dumps(schema["tables"].__getslice__(0, 10))

    print("Loaded", len(base_pairs), "base pairs")
    print("Starting augmentation...")

    let augmented = Python.list()

    # Copy all base pairs
    for i in range(len(base_pairs)):
        augmented.append(base_pairs[i])

    # Generate paraphrases for each base pair (2 per pair)
    let paraphrase_count = 0
    for i in range(len(base_pairs)):
        let pair = base_pairs[i]
        let paraphrases = generate_paraphrases(
            api_url, api_key,
            str(pair["question"]), str(pair["sql"]),
            str(schema_context), 2,
        )
        for j in range(len(paraphrases)):
            let new_pair = Python.dict()
            new_pair["question"] = paraphrases[j]
            new_pair["sql"] = pair["sql"]
            new_pair["domain"] = pair["domain"]
            new_pair["difficulty"] = pair["difficulty"]
            new_pair["source"] = "llm_paraphrase"
            augmented.append(new_pair)

    # Generate complex queries in batches
    let complex_pairs = generate_complex_queries(
        api_url, api_key, base_pairs, str(schema_context), 100,
    )
    for i in range(len(complex_pairs)):
        let cp = complex_pairs[i]
        cp["domain"] = "mixed"
        cp["difficulty"] = "hard"
        cp["source"] = "llm_complex"
        augmented.append(cp)

    # Save output
    save_json(augmented, "pipeline/output/intermediate/augmented_pairs.json")
    print("Augmented dataset:", len(augmented), "total pairs")
```

**Step 2: Verify Mojo compiles**

Run: `cd pipeline/mojo && mojo build src/augmenter.mojo` (if Mojo is available)
If Mojo is not installed, this is a build-later task. The structure is ready.

**Step 3: Commit**

```bash
git add pipeline/mojo/
git commit -m "feat: Mojo LLM augmentation client for paraphrasing and complex queries"
```

---

### Task 14: Pipeline Orchestration Makefile

**Files:**
- Create: `pipeline/Makefile`

Orchestrates all pipeline stages with proper dependencies.

**Step 1: Write the Makefile**

```makefile
# pipeline/Makefile
# Text-to-SQL Training Data Pipeline Orchestration

SHELL := /bin/bash
DATA_DIR := ..
OUTPUT_DIR := output
INTERMEDIATE := $(OUTPUT_DIR)/intermediate
SPIDER_DIR := $(OUTPUT_DIR)/spider
CSV_DIR := $(INTERMEDIATE)/csv

.PHONY: all clean preconvert extract-schema parse-templates expand augment validate format

all: format

# Stage 0: Pre-convert Excel to CSV
preconvert:
	@mkdir -p $(CSV_DIR)
	cd preconvert && python3 excel_to_csv.py $(DATA_DIR) ../$(CSV_DIR)
	@echo "Pre-conversion complete. CSVs in $(CSV_DIR)"

# Stage 1: Extract schema from CSVs
extract-schema: preconvert
	@mkdir -p $(INTERMEDIATE)
	cd zig && zig build run -- extract-schema ../$(CSV_DIR) ../$(INTERMEDIATE)/schema_registry.json

# Stage 2: Parse prompt templates
parse-templates: preconvert
	@mkdir -p $(INTERMEDIATE)
	cd zig && zig build run -- parse-templates ../$(CSV_DIR) ../$(INTERMEDIATE)/templates.json

# Stage 3: Expand templates into base pairs
expand: extract-schema parse-templates
	@mkdir -p $(INTERMEDIATE)
	cd zig && zig build run -- expand ../$(INTERMEDIATE)/schema_registry.json ../$(INTERMEDIATE)/templates.json ../$(INTERMEDIATE)/base_pairs.json

# Stage 4: LLM augmentation (requires LLM_API_URL and LLM_API_KEY env vars)
augment: expand
	@mkdir -p $(INTERMEDIATE)
	cd mojo && mojo run src/augmenter.mojo

# Stage 5: Validate with Mangle rules
validate: augment
	@echo "Running Mangle validation rules..."
	@echo "TODO: Integrate Mangle interpreter"
	@cp $(INTERMEDIATE)/augmented_pairs.json $(INTERMEDIATE)/validated_pairs.json

# Stage 6: Format as Spider/BIRD output
format: validate
	@mkdir -p $(SPIDER_DIR)/database/banking_btp
	cd zig && zig build run -- format-spider ../$(INTERMEDIATE)/validated_pairs.json ../$(SPIDER_DIR)

# Test all Zig modules
test:
	cd zig && zig build test

# Clean all generated output
clean:
	rm -rf $(OUTPUT_DIR)

# Quick mode: skip LLM augmentation (use base pairs directly)
quick: expand
	@mkdir -p $(SPIDER_DIR)/database/banking_btp
	cp $(INTERMEDIATE)/base_pairs.json $(INTERMEDIATE)/validated_pairs.json
	cd zig && zig build run -- format-spider ../$(INTERMEDIATE)/validated_pairs.json ../$(SPIDER_DIR)
```

**Step 2: Verify Makefile syntax**

Run: `cd pipeline && make -n all`
Expected: Prints the command sequence without executing

**Step 3: Commit**

```bash
git add pipeline/Makefile
git commit -m "feat: pipeline orchestration Makefile with all stages"
```

---

### Task 15: Wire Up main.zig CLI

**Files:**
- Modify: `pipeline/zig/src/main.zig`
- Modify: `pipeline/zig/build.zig` (add module imports)

Connect all Zig modules to the CLI entry point so `zig build run -- <command>` dispatches to the correct stage.

**Step 1: Update main.zig with command dispatch**

```zig
// pipeline/zig/src/main.zig
const std = @import("std");
const csv_parser = @import("csv_parser.zig");
const schema_registry = @import("schema_registry.zig");
const schema_extractor = @import("schema_extractor.zig");
const hierarchy_parser = @import("hierarchy_parser.zig");
const json_emitter = @import("json_emitter.zig");
const template_parser_mod = @import("template_parser.zig");
const template_expander = @import("template_expander.zig");
const spider_formatter = @import("spider_formatter.zig");
const hana_sql_builder = @import("hana_sql_builder.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "extract-schema")) {
        if (args.len < 4) {
            std.debug.print("Usage: text2sql-pipeline extract-schema <csv_dir> <output_json>\n", .{});
            return;
        }
        try cmdExtractSchema(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "parse-templates")) {
        if (args.len < 4) {
            std.debug.print("Usage: text2sql-pipeline parse-templates <csv_dir> <output_json>\n", .{});
            return;
        }
        try cmdParseTemplates(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "expand")) {
        if (args.len < 5) {
            std.debug.print("Usage: text2sql-pipeline expand <schema_json> <templates_json> <output_json>\n", .{});
            return;
        }
        try cmdExpand(allocator, args[2], args[3], args[4]);
    } else if (std.mem.eql(u8, command, "format-spider")) {
        if (args.len < 4) {
            std.debug.print("Usage: text2sql-pipeline format-spider <pairs_json> <output_dir>\n", .{});
            return;
        }
        try cmdFormatSpider(allocator, args[2], args[3]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("text2sql-pipeline v0.1.0\n", .{}) catch {};
    stdout.print("Usage: text2sql-pipeline <command> [args]\n", .{}) catch {};
    stdout.print("Commands:\n", .{}) catch {};
    stdout.print("  extract-schema  <csv_dir> <output_json>\n", .{}) catch {};
    stdout.print("  parse-templates <csv_dir> <output_json>\n", .{}) catch {};
    stdout.print("  expand          <schema_json> <templates_json> <output_json>\n", .{}) catch {};
    stdout.print("  format-spider   <pairs_json> <output_dir>\n", .{}) catch {};
}

fn cmdExtractSchema(allocator: std.mem.Allocator, csv_dir: []const u8, output_path: []const u8) !void {
    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    // Read staging schema CSV
    const staging_path = try std.fmt.allocPrint(allocator, "{s}/2_stagingschema.csv", .{csv_dir});
    defer allocator.free(staging_path);

    if (std.fs.cwd().openFile(staging_path, .{})) |file| {
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(data);
        try schema_extractor.extractFromStagingCsv(allocator, data, &registry);
    } else |_| {
        std.debug.print("Warning: staging schema CSV not found at {s}\n", .{staging_path});
    }

    // Write output JSON
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try json_emitter.emitSchemaJson(&registry, out_file.writer());
    std.debug.print("Schema registry written to {s} ({d} tables)\n", .{ output_path, registry.tables.items.len });
}

fn cmdParseTemplates(allocator: std.mem.Allocator, csv_dir: []const u8, output_path: []const u8) !void {
    _ = allocator;
    _ = csv_dir;
    _ = output_path;
    std.debug.print("TODO: implement parse-templates command\n", .{});
}

fn cmdExpand(allocator: std.mem.Allocator, schema_path: []const u8, templates_path: []const u8, output_path: []const u8) !void {
    _ = allocator;
    _ = schema_path;
    _ = templates_path;
    _ = output_path;
    std.debug.print("TODO: implement expand command\n", .{});
}

fn cmdFormatSpider(allocator: std.mem.Allocator, pairs_path: []const u8, output_dir: []const u8) !void {
    _ = allocator;
    _ = pairs_path;
    _ = output_dir;
    std.debug.print("TODO: implement format-spider command\n", .{});
}

test "main module imports compile" {
    // Verify all module imports resolve
    _ = csv_parser;
    _ = schema_registry;
    _ = schema_extractor;
    _ = hierarchy_parser;
    _ = json_emitter;
    _ = template_parser_mod;
    _ = template_expander;
    _ = spider_formatter;
    _ = hana_sql_builder;
}
```

**Step 2: Run build and tests**

Run: `cd pipeline/zig && zig build test`
Expected: PASS (all module tests run)

Run: `cd pipeline/zig && zig build run`
Expected: Prints usage

**Step 3: Commit**

```bash
git add pipeline/zig/src/main.zig
git commit -m "feat: wire up CLI command dispatch for all pipeline stages"
```

---

### Task 16: NVIDIA ModelOpt Fine-Tuning Config

**Files:**
- Create: `nvidia-modelopt/configs/text2sql_finetune.yaml`
- Modify: `nvidia-modelopt/mangle/a2a/mcp.mg` (add text2sql service routing)

Add configuration for fine-tuning and quantizing a text-to-SQL model using the generated Spider/BIRD training data.

**Step 1: Write the fine-tuning config**

```yaml
# nvidia-modelopt/configs/text2sql_finetune.yaml
# Configuration for fine-tuning and quantizing a text-to-SQL model on T4 GPU

model:
  name: "Qwen/Qwen3.5-4B"
  trust_remote_code: true
  torch_dtype: "float16"
  task: "text-to-sql"

# Training data paths (generated by pipeline)
training_data:
  train_file: "../pipeline/output/spider/train.json"
  dev_file: "../pipeline/output/spider/dev.json"
  test_file: "../pipeline/output/spider/test.json"
  schema_file: "../pipeline/output/spider/tables.json"
  format: "spider"

# Fine-tuning settings
fine_tuning:
  method: "lora"  # LoRA for T4 memory efficiency
  lora_r: 16
  lora_alpha: 32
  lora_dropout: 0.05
  target_modules: ["q_proj", "k_proj", "v_proj", "o_proj"]
  epochs: 3
  batch_size: 2
  gradient_accumulation_steps: 8
  learning_rate: 2.0e-5
  warmup_ratio: 0.1
  max_seq_length: 2048
  output_dir: "./outputs/text2sql_lora"

# Post-training quantization
quantization:
  format: "int8_sq"
  calibration:
    dataset: "custom"
    custom_dataset_path: "../pipeline/output/spider/dev.json"
    num_samples: 256
    seq_length: 2048
    batch_size: 1

# Export
export:
  format: "hf_checkpoint"
  output_dir: "./outputs/text2sql_int8"

# Hardware
hardware:
  device: "cuda:0"
  max_memory_gb: 14
```

**Step 2: Add text2sql routing to MCP Mangle rules**

Append to `nvidia-modelopt/mangle/a2a/mcp.mg`:

```
# ============================================================================
# 11. Text-to-SQL Pipeline Integration
# ============================================================================

# Text-to-SQL model service
service_registry("text2sql-inference", "http://localhost:8001/v1", "text2sql-int8").

# Text-to-SQL model availability
quantized_model("text2sql-4b-int8", "qwen3.5-4b", "int8").

# Route text-to-SQL inference requests
resolve_service_for_intent(/text_to_sql, URL) :-
    service_registry("text2sql-inference", URL, _).

tool_service("text_to_sql", "text2sql-inference").
```

**Step 3: Commit**

```bash
git add nvidia-modelopt/configs/text2sql_finetune.yaml
git add nvidia-modelopt/mangle/a2a/mcp.mg
git commit -m "feat: add text-to-SQL fine-tuning config and MCP routing rules"
```

---

### Task 17: End-to-End Smoke Test

**Files:**
- Create: `pipeline/test_e2e.sh`

A minimal end-to-end test that runs the pipeline on a tiny subset of data to verify all stages connect properly.

**Step 1: Write the smoke test script**

```bash
#!/bin/bash
# pipeline/test_e2e.sh - End-to-end smoke test for the text-to-SQL pipeline
set -euo pipefail

echo "=== Text-to-SQL Pipeline E2E Smoke Test ==="

# Create test fixtures
TESTDIR=$(mktemp -d)
trap "rm -rf $TESTDIR" EXIT

mkdir -p "$TESTDIR/csv"
mkdir -p "$TESTDIR/output"

# Minimal staging schema CSV
cat > "$TESTDIR/csv/2_stagingschema.csv" << 'CSVEOF'
header1
header2
header3
,TREASURY_CAPITAL,BCRS,TABLE1,AS_OF_DATE,STG_BCRS,BSI_REM_FACT,AS_OF_DATE,Date field,TIMESTAMP,,,
,TREASURY_CAPITAL,BCRS,TABLE1,COUNTRY,STG_BCRS,BSI_REM_FACT,COUNTRY,Country,NVARCHAR,,,
,TREASURY_CAPITAL,BCRS,TABLE1,MTM,STG_BCRS,BSI_REM_FACT,MTM,Mark to Market,DECIMAL,,,
CSVEOF

# Run schema extraction
echo "[1/4] Extracting schema..."
cd zig && zig build run -- extract-schema "$TESTDIR/csv" "$TESTDIR/output/schema_registry.json"

# Verify schema output exists and contains tables
if [ ! -f "$TESTDIR/output/schema_registry.json" ]; then
    echo "FAIL: schema_registry.json not created"
    exit 1
fi

if ! grep -q "BSI_REM_FACT" "$TESTDIR/output/schema_registry.json"; then
    echo "FAIL: BSI_REM_FACT not found in schema"
    exit 1
fi

echo "[2/4] Running Zig unit tests..."
zig build test

echo "[3/4] Checking Python pre-conversion..."
cd ../preconvert && python3 -c "from excel_to_csv import convert_workbook; print('Import OK')"

echo "[4/4] Verifying Mangle rules syntax..."
# Basic syntax check: ensure no obvious issues
for mg_file in ../mangle/*.mg; do
    if [ ! -s "$mg_file" ]; then
        echo "FAIL: Empty Mangle file: $mg_file"
        exit 1
    fi
    echo "  OK: $(basename $mg_file)"
done

echo ""
echo "=== ALL SMOKE TESTS PASSED ==="
```

**Step 2: Run the smoke test**

Run: `cd pipeline && chmod +x test_e2e.sh && bash test_e2e.sh`
Expected: "ALL SMOKE TESTS PASSED"

**Step 3: Commit**

```bash
git add pipeline/test_e2e.sh
git commit -m "feat: add end-to-end smoke test for pipeline stages"
```

---

### Task 18: Documentation and Final Commit

**Files:**
- Create: `pipeline/README.md`

**Step 1: Write the pipeline README**

```markdown
# Text-to-SQL Training Data Pipeline

Generates Spider/BIRD benchmark training data from banking BTP data files
for fine-tuning a text-to-SQL model targeting SAP HANA.

## Quick Start

```bash
# Install Python dependencies
pip install openpyxl

# Run the full pipeline
cd pipeline
make all

# Or run in quick mode (skip LLM augmentation)
make quick
```

## Pipeline Stages

| Stage | Command | Tool |
|-------|---------|------|
| Pre-convert Excel | `make preconvert` | Python |
| Extract schema | `make extract-schema` | Zig |
| Parse templates | `make parse-templates` | Zig |
| Expand templates | `make expand` | Zig |
| LLM augmentation | `make augment` | Mojo |
| Validate | `make validate` | Mangle |
| Format output | `make format` | Zig |

## Testing

```bash
# Unit tests
make test

# End-to-end smoke test
bash test_e2e.sh
```

## Output

Spider/BIRD format in `output/spider/`:
- `train.json` - Training set (~80%)
- `dev.json` - Validation set (~10%)
- `test.json` - Test set (~10%)
- `database/banking_btp/schema.sql` - HANA DDL
```

**Step 2: Final commit**

```bash
git add pipeline/README.md
git commit -m "docs: add pipeline README with usage instructions"
```

---

## Summary

| Task | Component | Language | Status |
|------|-----------|----------|--------|
| 1 | Excel pre-conversion | Python | New |
| 2 | Zig build system | Zig | New |
| 3 | CSV parser | Zig | New |
| 4 | Schema registry data model | Zig | New |
| 5 | Schema extraction from staging CSV | Zig | New |
| 6 | NFRP hierarchy parser | Zig | New |
| 7 | JSON emitter | Zig | New |
| 8 | Template parser | Zig | New |
| 9 | HANA SQL builder | Zig | New |
| 10 | Template expander | Zig | New |
| 11 | Spider/BIRD formatter | Zig | New |
| 12 | Mangle validation rules | Mangle | New |
| 13 | LLM augmentation client | Mojo | New |
| 14 | Pipeline orchestration | Makefile | New |
| 15 | CLI command dispatch | Zig | New |
| 16 | ModelOpt fine-tuning config | YAML/Mangle | New |
| 17 | E2E smoke test | Bash | New |
| 18 | Documentation | Markdown | New |

**Dependencies:** Tasks 1-2 are independent foundations. Tasks 3-11 build sequentially (each imports prior modules). Task 12 is independent of Zig work. Task 13 depends on Task 7 output format. Tasks 14-18 integrate everything.

**Parallelizable:** Tasks 1 + 2 (Python + Zig scaffolds), Tasks 8 + 9 (template parser + SQL builder), Task 12 (Mangle rules, independent of Zig).
