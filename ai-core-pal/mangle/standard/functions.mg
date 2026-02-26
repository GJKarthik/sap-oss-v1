# Mangle ODPS Standard - Functions
# Built-in functions in the fn: namespace
# Reference documentation for available functions

# =============================================================================
# DATE/TIME FUNCTIONS
# =============================================================================

# fn:now() -> datetime
# Returns the current timestamp
# Example: let current = fn:now()

# fn:days_between(start: datetime, end: datetime) -> integer
# Returns number of days between two dates
# Example: let days = fn:days_between(start_date, fn:now())

# fn:hours_between(start: datetime, end: datetime) -> float
# Returns number of hours between two timestamps
# Example: let hours = fn:hours_between(last_update, fn:now())

# fn:extract_year(dt: datetime) -> integer
# Extracts year from datetime
# Example: fn:extract_year(created_at, year)

# fn:extract_month(dt: datetime) -> integer
# Extracts month (1-12) from datetime
# Example: fn:extract_month(created_at, month)

# fn:extract_day(dt: datetime) -> integer
# Extracts day of month from datetime
# Example: fn:extract_day(created_at, day)

# =============================================================================
# STRING FUNCTIONS
# =============================================================================

# fn:string_contains(haystack: string, needle: string) -> boolean
# Returns true if needle is found in haystack
# Example: fn:string_contains(tags, "important")

# fn:string_length(s: string) -> integer
# Returns length of string
# Example: let len = fn:string_length(name)

# fn:string_lower(s: string) -> string
# Converts string to lowercase
# Example: let lower = fn:string_lower(name)

# fn:string_upper(s: string) -> string
# Converts string to uppercase
# Example: let upper = fn:string_upper(code)

# fn:string_concat(a: string, b: string) -> string
# Concatenates two strings
# Example: let full = fn:string_concat(first, last)

# fn:string_split(s: string, delimiter: string) -> list
# Splits string by delimiter
# Example: let parts = fn:string_split(csv_line, ",")

# =============================================================================
# NUMERIC FUNCTIONS
# =============================================================================

# fn:abs(n: number) -> number
# Returns absolute value
# Example: let positive = fn:abs(difference)

# fn:round(n: float, decimals: integer) -> float
# Rounds to specified decimal places
# Example: let rounded = fn:round(score, 2)

# fn:floor(n: float) -> integer
# Rounds down to nearest integer
# Example: let floored = fn:floor(value)

# fn:ceil(n: float) -> integer
# Rounds up to nearest integer
# Example: let ceiled = fn:ceil(value)

# fn:min(a: number, b: number) -> number
# Returns smaller of two values
# Example: let smaller = fn:min(a, b)

# fn:max(a: number, b: number) -> number
# Returns larger of two values
# Example: let larger = fn:max(a, b)

# =============================================================================
# JSON FUNCTIONS
# =============================================================================

# fn:json_get(json: string, path: string) -> string
# Extracts value from JSON by path
# Example: let value = fn:json_get(config, "$.settings.timeout")

# fn:json_object(key: string, value: any) -> string
# Creates JSON object
# Example: let obj = fn:json_object("count", 42)

# =============================================================================
# TYPE CONVERSION
# =============================================================================

# fn:to_string(value: any) -> string
# Converts value to string
# Example: let s = fn:to_string(count)

# fn:to_integer(s: string) -> integer
# Parses string as integer
# Example: let n = fn:to_integer("42")

# fn:to_float(s: string) -> float
# Parses string as float
# Example: let f = fn:to_float("3.14")

# =============================================================================
# VERSION FUNCTIONS
# =============================================================================

# fn:semver_satisfies(version: string, constraint: string) -> boolean
# Checks if version satisfies semver constraint
# Example: fn:semver_satisfies("2.1.0", ">=2.0.0")

# fn:semver_compare(a: string, b: string) -> integer
# Compares two semver versions (-1, 0, 1)
# Example: let cmp = fn:semver_compare("1.0.0", "2.0.0")