# Moonshot Mojo FFI primitives
# These helpers are intentionally small and deterministic so they can be
# embedded safely in the Zig runtime over time.

from memory import UnsafePointer

comptime c_int = Int
comptime c_float = Float64


fn mojo_init() -> c_int:
    return 0


fn mojo_shutdown():
    pass


fn normalize_prompt_text(text: String) -> String:
    var output = String()
    var previous_whitespace = False

    for i in range(len(text)):
        var ch = text[i]
        var is_whitespace = ch == " " or ch == "\n" or ch == "\t" or ch == "\r"

        if is_whitespace:
            if not previous_whitespace:
                output += " "
            previous_whitespace = True
        else:
            output += ch
            previous_whitespace = False

    var cleaned = output.strip()
    return String(cleaned)


fn refusal_keyword_score(text: String) -> c_float:
    var lowered = text.lower()
    var hits = 0
    var keywords = ["cannot", "can't", "unable", "refuse", "not assist", "sorry"]

    for i in range(len(keywords)):
        if keywords[i] in lowered:
            hits += 1

    if hits > 3:
        hits = 3

    return Float64(hits) / 3.0


fn mojo_normalize_prompt(
    prompt: UnsafePointer[UInt8],
    prompt_len: c_int,
    output: UnsafePointer[UInt8],
    output_capacity: c_int,
) -> c_int:
    var text = String()
    for i in range(prompt_len):
        text += chr(Int(prompt[i]))

    var normalized = normalize_prompt_text(text)
    var copy_len = len(normalized)
    if copy_len > output_capacity:
        copy_len = output_capacity

    _ = output
    return copy_len


fn mojo_refusal_score(
    response: UnsafePointer[UInt8],
    response_len: c_int,
) -> c_float:
    var text = String()
    for i in range(response_len):
        text += chr(Int(response[i]))

    return refusal_keyword_score(text)
