% =============================================================================
% Coverage Rules for training data completeness
% Ensures the generated text-to-SQL corpus covers all required patterns.
% =============================================================================

% Every table should have at least one training pair
table_covered(Tab) :-
    training_pair(SqlId, _Q, _Sql),
    sql_table_ref(SqlId, Tab).

table_not_covered(Tab) :-
    table_name(Tab),
    !table_covered(Tab).

% Every domain should have at least 10 training pairs
domain_pair_count(Domain, Count) :-
    aggregate(Count, count, SqlId, training_pair(SqlId, _, _), sql_domain(SqlId, Domain)).

domain_undercovered(Domain) :-
    domain_pair_count(Domain, Count),
    Count < 10.

% SQL pattern coverage — each pattern should appear in training data
sql_pattern_covered(Pattern) :-
    training_pair(SqlId, _, _),
    sql_has_pattern(SqlId, Pattern).

sql_pattern_not_covered(Pattern) :-
    required_pattern(Pattern),
    !sql_pattern_covered(Pattern).

% Required SQL patterns for a complete training corpus
required_pattern("SELECT").
required_pattern("WHERE_EQ").
required_pattern("WHERE_LIKE").
required_pattern("WHERE_BETWEEN").
required_pattern("GROUP_BY").
required_pattern("ORDER_BY").
required_pattern("LIMIT").
required_pattern("JOIN").
required_pattern("AGGREGATE_SUM").
required_pattern("AGGREGATE_COUNT").
required_pattern("AGGREGATE_AVG").
required_pattern("SUBQUERY").
required_pattern("HAVING").
required_pattern("DISTINCT").
required_pattern("CASE_WHEN").
required_pattern("UNION").

% Difficulty distribution — training set should have all levels
difficulty_covered(Difficulty) :-
    training_pair(SqlId, _, _),
    pair_difficulty(SqlId, Difficulty).

difficulty_not_covered(Difficulty) :-
    required_difficulty(Difficulty),
    !difficulty_covered(Difficulty).

required_difficulty("easy").
required_difficulty("moderate").
required_difficulty("hard").
required_difficulty("extra_hard").

