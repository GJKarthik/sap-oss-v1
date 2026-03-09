% =============================================================================
% Spider / BIRD Format Validation
% Ensures output conforms to the expected dataset schema.
% =============================================================================

% Every Spider entry must have all three required fields
valid_spider_entry(EntryId) :-
    spider_entry(EntryId),
    spider_db_id(EntryId, _DbId),
    spider_question(EntryId, _Q),
    spider_query(EntryId, _Sql).

invalid_spider_entry(EntryId) :-
    spider_entry(EntryId),
    !valid_spider_entry(EntryId).

% db_id must be consistent across all entries
consistent_db_id(EntryId) :-
    spider_db_id(EntryId, DbId),
    canonical_db_id(DbId).

inconsistent_db_id(EntryId, DbId) :-
    spider_db_id(EntryId, DbId),
    !canonical_db_id(DbId).

% Question must not be empty
non_empty_question(EntryId) :-
    spider_question(EntryId, Q),
    string_length(Q, Len),
    Len > 0.

empty_question(EntryId) :-
    spider_question(EntryId, Q),
    string_length(Q, 0).

% Query must start with SELECT (normalised)
valid_query_start(EntryId) :-
    spider_query(EntryId, Sql),
    starts_with_upper(Sql, "SELECT").

invalid_query_start(EntryId) :-
    spider_query(EntryId, Sql),
    !starts_with_upper(Sql, "SELECT").

% Train/dev/test split ratios
split_ratio_valid(TrainCount, DevCount, TestCount) :-
    split_count("train", TrainCount),
    split_count("dev", DevCount),
    split_count("test", TestCount),
    Total = TrainCount + DevCount + TestCount,
    TrainRatio = TrainCount * 100 / Total,
    TrainRatio >= 70,
    TrainRatio <= 90.

% BIRD format extras (evidence field)
valid_bird_entry(EntryId) :-
    valid_spider_entry(EntryId),
    bird_evidence(EntryId, _Evidence).

% No duplicate questions in same split
duplicate_in_split(Split, Q) :-
    split_entry(Split, E1, Q),
    split_entry(Split, E2, Q),
    E1 != E2.

