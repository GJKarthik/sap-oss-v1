# Kuzu TODO Remediation Plan

**Total Items:** 220 TODOs/FIXMEs  
**Target:** Fix all issues to make Kuzu production-ready for SAP integration  
**Estimated Effort:** 40-60 engineering days

---

## Executive Summary

| Priority | Count | Effort | Timeline |
|----------|-------|--------|----------|
| 🔴 Critical (P0) | 15 | 10 days | Week 1-2 |
| 🟠 High (P1) | 35 | 15 days | Week 2-4 |
| 🟡 Medium (P2) | 85 | 20 days | Week 4-8 |
| 🟢 Low (P3) | 85 | 15 days | Week 8-12 |

---

## Phase 1: Critical Issues (P0) - Week 1-2

### 1.1 Query Correctness Issues (5 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 1 | `optimizer/factorization_rewriter.cpp` | 44 | Cardinality not correctly set | Implement proper cardinality propagation |
| 2 | `processor/operator/hash_join/hash_join_probe.cpp` | 132 | LEFT JOIN bug discarding NULL keys | Fix NULL key handling in left join |
| 3 | `processor/operator/hash_join/hash_join_probe.cpp` | 53 | Bug: all keys' states should be restored | Implement proper state restoration |
| 4 | `planner/operator/logical_hash_join.cpp` | 196 | Shouldn't require flatten | Remove unnecessary flatten requirement |
| 5 | `storage/index/hash_index.cpp` | 84 | Should vacuum index during checkpoint | Implement index vacuum |

### 1.2 Buffer Manager Bugs (4 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 6 | `include/storage/buffer_manager/page_state.h` | 54 | Rare bug #2289 | Track down and fix assertion failure |
| 7 | `include/storage/buffer_manager/page_state.h` | 59 | Rare bug #2289 | Same as above |
| 8 | `storage/table/column_chunk_data.cpp` | 1050 | FIXME: need split recursively | Implement recursive split |
| 9 | `storage/table/column_chunk_data.cpp` | 469 | FIXME: not always working | Fix compression edge case |

### 1.3 Data Integrity Issues (6 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 10 | `storage/table/csr_node_group.cpp` | 1086 | FIXME: needs segmentation | Implement proper segmentation |
| 11 | `storage/table/list_column.cpp` | 127 | FIXME: better solution needed | Refactor list column handling |
| 12 | `include/processor/operator/persistent/reader/parquet/parquet_dbp_decoder.h` | 65 | Width=0 unhandled | Add width=0 case handling |
| 13 | `include/processor/operator/persistent/reader/parquet/parquet_rle_bp_decoder.h` | 112 | Buffer overflow risk | Add buffer bounds checking |
| 14 | `processor/operator/persistent/reader/parquet/column_reader.cpp` | 482 | dict_width can be 0 | Handle zero dict_width |
| 15 | `storage/table/column_chunk_data.cpp` | 779 | FIX-ME: enableCompression | Fix compression flag handling |

---

## Phase 2: High Priority (P1) - Week 2-4

### 2.1 Query Optimizer Issues (12 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 16 | `planner/join_order/cardinality_estimator.cpp` | 77 | Use HLL for distinct keys | Implement HyperLogLog |
| 17 | `optimizer/filter_push_down_optimizer.cpp` | 109 | Only left=right supported | Extend filter push-down |
| 18 | `optimizer/filter_push_down_optimizer.cpp` | 166 | Fold parameter expression | Move to binder |
| 19 | `optimizer/acc_hash_join_optimizer.cpp` | 208 | Check semi mask application | Implement semi mask checks |
| 20 | `optimizer/acc_hash_join_optimizer.cpp` | 269 | Not best solution for semi mask | Optimize semi mask passing |
| 21 | `optimizer/acc_hash_join_optimizer.cpp` | 326 | No SIP from build to probe | Implement SIP both directions |
| 22 | `optimizer/projection_push_down_optimizer.cpp` | 115 | Replace with separate optimizer | Refactor optimizer |
| 23 | `optimizer/remove_unnecessary_join_optimizer.cpp` | 39 | Double check changes | Verify and test changes |
| 24 | `optimizer/top_k_optimizer.cpp` | 27 | Remove projection between ORDER BY and MULTIPLICITY REDUCER | Optimize query plan |
| 25 | `planner/join_order/cost_model.cpp` | 46 | Calculate intersect cost | Implement cost calculation |
| 26 | `planner/join_order/join_plan_solver.cpp` | 141 | Interface to append operator | Add append interface |
| 27 | `planner/plan/plan_join_order.cpp` | 452 | Fixme per description | Implement fix |

### 2.2 Storage Layer Issues (15 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 28 | `storage/storage_manager.cpp` | 83 | API for single rel table | Add API |
| 29 | `storage/table/csr_node_group.cpp` | 494 | Skip early if no changes | Add early exit |
| 30 | `storage/table/csr_node_group.cpp` | 501 | Find max node offset | Implement max offset |
| 31 | `storage/table/csr_node_group.cpp` | 750 | Optimize for loop | Batch append |
| 32 | `storage/table/csr_node_group.cpp` | 846 | Optimize scan | Use sequential scan |
| 33 | `storage/table/csr_node_group.cpp` | 1053 | Skip deleted rows | Add deletion check |
| 34 | `storage/table/csr_node_group.cpp` | 1096 | Use finalizeCheckpoint | Implement |
| 35 | `storage/table/node_group.cpp` | 216 | Move locked part to initScan | Refactor |
| 36 | `storage/table/node_group.cpp` | 543 | Optimize version info access | Direct access |
| 37 | `storage/table/node_group_collection.cpp` | 138 | Optimize startRowIdx | Direct calculation |
| 38 | `storage/table/node_table.cpp` | 604 | Optimize local storage loop | Batch processing |
| 39 | `storage/compression/compression.cpp` | 856 | Use integer bitpacking | Implement SIMD |
| 40 | `storage/compression/compression.cpp` | 869 | Use integer bitpacking | Implement SIMD |
| 41 | `storage/compression/compression.cpp` | 737 | Better system for choosing | Implement selector |
| 42 | `storage/index/hash_index.cpp` | 268-298 | Multiple optimizations | Batch operations |

### 2.3 SAP AI Core Integration (8 items - NEW)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 43 | `extension/llm/src/providers/` | NEW | Add SAP AI Core provider | Implement SAPAICoreEmbedding |
| 44 | `extension/llm/src/function/` | NEW | Register SAP provider | Add to factory |
| 45 | `extension/vector/` | NEW | SIMD distance functions | Add AVX2/NEON support |
| 46 | `extension/vector/` | NEW | Product quantization | Add PQ support |
| 47 | `extension/vector/` | NEW | Incremental index updates | Add delta updates |
| 48 | `extension/fts/` | NEW | HANA vector sync | Add federation |
| 49 | `src/main/` | NEW | Connection pooling | Add pool manager |
| 50 | `src/main/` | NEW | Metrics export | Add Prometheus metrics |

---

## Phase 3: Medium Priority (P2) - Week 4-8

### 3.1 Binder Issues (10 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 51 | `binder/bind/bind_import_database.cpp` | 68 | Temporary workaround | Fix parser |
| 52 | `binder/bind/bind_projection_clause.cpp` | 212 | Remove augment group by | Clean up |
| 53 | `binder/bind_expression/bind_function_expression.cpp` | 93 | Return deep copy | Fix reference |
| 54 | `binder/bind_expression/bind_property_expression.cpp` | 101 | Remove propertyDataExprs | Refactor |
| 55 | `binder/binder.cpp` | 200-202 | Assert name not in scope | Add assertion |
| 56 | `include/binder/expression_binder.h` | 44 | Move to expression rewriter | Refactor |
| 57 | `include/function/built_in_function_utils.h` | 20 | Unified interface | Implement |
| 58 | `include/function/built_in_function_utils.h` | 42 | Move casting to binder | Refactor |
| 59 | `function/built_in_function_utils.cpp` | 76 | Check any type | Add check |
| 60 | `function/vector_cast_functions.cpp` | 291 | Handle special cases | Implement |

### 3.2 Processor Issues (25 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 61 | `processor/map/map_copy_to.cpp` | 27 | Handle null datatype | Fix type handling |
| 62 | `processor/map/map_dummy_scan.cpp` | 16 | Remove vectors after refactor | Clean up |
| 63 | `processor/operator/aggregate/base_aggregate.cpp` | 68 | Benchmark queue size | Optimize |
| 64 | `processor/operator/aggregate/hash_aggregate.cpp` | 152 | Merge functions | Refactor |
| 65 | `processor/operator/flatten.cpp` | 18 | Part of restore/save | Refactor |
| 66 | `processor/operator/hash_join/join_hash_table.cpp` | 99 | Check un-filtered state | Fix |
| 67 | `processor/operator/index_lookup.cpp` | 31 | Short path unfiltered | Add fast path |
| 68 | `processor/operator/index_lookup.cpp` | 74 | Short path unfiltered | Add fast path |
| 69 | `processor/operator/intersect/intersect.cpp` | 28 | Keys any order | Refactor |
| 70 | `processor/operator/order_by/order_by_merge.cpp` | 35 | Feed sharedState directly | Refactor |
| 71 | `processor/operator/order_by/sort_state.cpp` | 151 | Hacky lookup | Proper interface |
| 72 | `processor/operator/path_property_probe.cpp` | 69 | Print order | Consider |
| 73 | `processor/operator/persistent/insert_executor.cpp` | 65 | Reference instead of copy | Optimize |
| 74 | `processor/operator/persistent/merge.cpp` | 53 | Remove types | Clean up |
| 75 | `processor/operator/persistent/node_batch_insert.cpp` | 180 | Reuse chunk | Optimize |
| 76 | `processor/operator/persistent/reader/csv/base_csv_reader.cpp` | 20 | Reduce fields | Optimize |
| 77 | `processor/operator/persistent/reader/npy/npy_reader.cpp` | 191 | Set ARRAY type | Fix type |
| 78 | `processor/operator/persistent/reader/npy/npy_reader.cpp` | 279 | Double check | Verify |
| 79 | `processor/operator/persistent/reader/parquet/column_reader.cpp` | 92 | Optimize bitunpack | Performance |
| 80 | `processor/operator/persistent/reader/parquet/column_reader.cpp` | 162 | Keep in state | Optimize |
| 81 | `processor/operator/persistent/reader/parquet/parquet_reader.cpp` | 319 | Check return value | Add check |
| 82 | `processor/operator/persistent/reader/parquet/parquet_reader.cpp` | 534 | Support binary_as_string | Add option |
| 83 | `processor/operator/persistent/rel_batch_insert.cpp` | 48 | Remove hard-coded IDs | Parameterize |
| 84 | `processor/operator/persistent/rel_batch_insert.cpp` | 113 | Handle concurrency | Add locking |
| 85 | `processor/operator/result_collector.cpp` | 67 | Add interface | Implement |

### 3.3 Storage Table Issues (25 items)

| # | File | Line | TODO | Fix |
|---|------|------|------|-----|
| 86-110 | Various storage/table/*.cpp | Various | Multiple optimizations | See detailed list below |

#### Detailed Storage Table TODOs:
```
86. column.cpp:371 - Adapt offsets
87. column.cpp:423 - Update numValues
88. column.cpp:456 - Predict compression needs
89. column_chunk.cpp:201 - Modify stats in-place
90. column_chunk_data.cpp:734 - NullChunkData append
91. csr_chunked_node_group.cpp:156 - Vectorize length chunk
92. csr_chunked_node_group.cpp:189 - Vectorize
93. csr_chunked_node_group.cpp:268 - Reuse deserialize
94. csr_chunked_node_group.cpp:315 - Simplify check
95. csr_chunked_node_group.cpp:328 - Simplify check
96. csr_chunked_node_group.cpp:73 - Simplify check
97. csr_chunked_node_group.cpp:86 - Simplify check
98. dictionary_column.cpp:90 - Scan batches
99. rel_table.cpp:345 - Support unflat vectors
100. string_column.cpp:213 - Replace indices
101. string_column.cpp:242 - Optimize scans
102. struct_column.cpp:49 - Remove necessity
103. struct_column.cpp:98 - Split together
104. update_info.cpp:177 - Move to UndoBuffer
105. update_info.cpp:276 - Sort rowsInVector
106. version_info.cpp:16 - Add ALWAYS_INSERTED
107. version_info.cpp:20 - Add optimization field
108. chunked_node_group.cpp:452 - Predictive splitting
109. shadow_file.cpp:165 - Remove shadow file
110. overflow_file.cpp:241 - Parallel HashIndex
```

---

## Phase 4: Low Priority (P3) - Week 8-12

### 4.1 Header File Cleanups (30 items)

| Category | Files | Action |
|----------|-------|--------|
| Renaming | `logical_operator_collector.h` | Rename class |
| Interface | `storage_driver.h:22` | Merge functions |
| Refactor | `expression_mapper.h:55` | Add comments |
| Remove | `standalone_call.h:32` | Delete unused |
| Types | `csv_reader_config.h:12,48` | Add options |
| Cleanup | Various `.h` files | Documentation |

### 4.2 Type System Issues (15 items)

```
111. c_api/value.cpp:567 - Bind int128_t functions
112. common/arrow/arrow_array_scan.cpp:487 - Pure time type
113. common/arrow/arrow_type.cpp:80 - Pure time type
114. common/arrow/arrow_type.cpp:83 - Timezone support
115. common/types/int128_t.cpp:537 - isFinite check
116. common/types/timestamp_t.cpp:303 - Add tests
117. common/types/types.cpp:1458 - Use UINT8 for tag
118. function/cast_from_string_functions.cpp:213 - Escape char
119. function/vector_cast_functions.cpp:1186 - Unify binding
120. include/function/cast/functions/cast_string_non_nested_functions.h:119 - Handle decimals
121. include/function/cast/functions/cast_string_non_nested_functions.h:188 - Exponent+decimal
122. function/base_lower_upper_operation.cpp:22 - Invalid UTF-8
123. include/common/types/types.h:312 - Float compression
124. include/common/types/value/value.h:287 - Remove val suffix
125. include/c_api/kuzu.h:775 - Refactor datatype
```

### 4.3 Code Organization (20 items)

```
126-145. Various files - Documentation, naming, interface cleanup
```

### 4.4 Test and Documentation (20 items)

```
146-165. Add tests, documentation, comments
```

---

## Implementation Checklist

### Week 1-2: Critical (P0)
- [ ] Fix cardinality propagation in factorization_rewriter.cpp
- [ ] Fix LEFT JOIN NULL key handling
- [ ] Track down buffer manager bug #2289
- [ ] Fix column_chunk_data recursive split
- [ ] Handle parquet width=0 case
- [ ] Add buffer bounds checking in RLE decoder

### Week 2-4: High (P1)
- [ ] Implement HyperLogLog for cardinality estimation
- [ ] Extend filter push-down beyond equality
- [ ] Add SAP AI Core embedding provider
- [ ] Implement SIMD distance functions
- [ ] Add API for single rel table
- [ ] Optimize CSR node group operations

### Week 4-8: Medium (P2)
- [ ] Fix binder workarounds
- [ ] Refactor processor operators
- [ ] Optimize storage table operations
- [ ] Add Parquet binary_as_string option
- [ ] Handle concurrency in rel_batch_insert

### Week 8-12: Low (P3)
- [ ] Header file cleanups
- [ ] Type system improvements
- [ ] Code organization
- [ ] Documentation and tests

---

## Resource Requirements

| Role | FTE | Duration |
|------|-----|----------|
| Senior C++ Engineer | 2 | 12 weeks |
| Database Engineer | 1 | 12 weeks |
| QA Engineer | 1 | 8 weeks |
| Technical Writer | 0.5 | 4 weeks |

**Total Effort:** ~40-60 engineering days

---

## Risk Mitigation

1. **Regression Testing:** Run full test suite after each phase
2. **Code Review:** All changes require 2 approvers
3. **Benchmarking:** Performance testing after P1 changes
4. **Rollback Plan:** Git tags at each phase completion

---

## Success Criteria

1. All 220 TODOs resolved or documented as "won't fix"
2. No critical or high priority items remaining
3. Test coverage ≥ 80%
4. Performance within 10% of baseline
5. SAP AI Core integration working

---

## Next Steps

1. **Approve plan** with stakeholders
2. **Assign engineers** to phases
3. **Create JIRA epics** for each phase
4. **Begin Phase 1** critical fixes
5. **Weekly status updates**