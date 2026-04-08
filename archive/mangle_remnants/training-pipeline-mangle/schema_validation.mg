% =============================================================================
% Schema Validation Rules for text-to-SQL pipeline
% Ensures extracted schemas are well-formed and complete.
% =============================================================================

% A column must belong to exactly one table
column_table(Col, Tab) :-
    table_column(Tab, Col, _Type, _Desc).

% Every table must have at least one column
valid_table(Tab) :-
    table_column(Tab, _Col, _Type, _Desc).

invalid_table(Tab) :-
    table_name(Tab),
    !valid_table(Tab).

% Primary key exists for every table
has_primary_key(Tab) :-
    table_column(Tab, Col, _Type, _Desc),
    primary_key(Tab, Col).

missing_primary_key(Tab) :-
    valid_table(Tab),
    !has_primary_key(Tab).

% Every column must have a known data type
known_type(Col, Tab) :-
    table_column(Tab, Col, Type, _Desc),
    hana_type(Type).

unknown_type(Col, Tab) :-
    table_column(Tab, Col, Type, _Desc),
    !hana_type(Type).

% Known SAP HANA data types
hana_type("NVARCHAR").
hana_type("VARCHAR").
hana_type("INTEGER").
hana_type("BIGINT").
hana_type("DECIMAL").
hana_type("DOUBLE").
hana_type("BOOLEAN").
hana_type("DATE").
hana_type("TIMESTAMP").
hana_type("NCLOB").
hana_type("BLOB").

% Table name follows SAP naming conventions (uppercase, underscores)
well_named_table(Tab) :-
    table_name(Tab),
    is_uppercase_identifier(Tab).

poorly_named_table(Tab) :-
    table_name(Tab),
    !well_named_table(Tab).

% Join path references existing tables and columns
valid_join(FromTab, FromCol, ToTab, ToCol) :-
    join_path(FromTab, FromCol, ToTab, ToCol),
    table_column(FromTab, FromCol, _, _),
    table_column(ToTab, ToCol, _, _).

dangling_join(FromTab, FromCol, ToTab, ToCol) :-
    join_path(FromTab, FromCol, ToTab, ToCol),
    !valid_join(FromTab, FromCol, ToTab, ToCol).

