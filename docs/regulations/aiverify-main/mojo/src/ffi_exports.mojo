# AI Verify Mojo FFI primitives
# The helpers below are deterministic building blocks for parity-sensitive
# checks that Zig can call over time.

from memory import UnsafePointer
from sys.ffi import c_int

comptime c_float = Float64


@export("mojo_init", ABI="C")
fn mojo_init() -> c_int:
    return 0


@export("mojo_shutdown", ABI="C")
fn mojo_shutdown():
    pass


fn normalize_plugin_gid(text: String) -> String:
    var lowered = text.lower()
    var output = String()
    var previous_whitespace = False

    for i in range(len(lowered)):
        var ch = lowered[i]
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


fn parity_gap(reference: c_float, candidate: c_float) -> c_float:
    var delta = candidate - reference
    if delta < 0.0:
        delta = -delta
    return delta


@export("mojo_normalize_plugin_gid", ABI="C")
fn mojo_normalize_plugin_gid(
    input_text: UnsafePointer[UInt8, ImmutExternalOrigin],
    input_len: c_int,
    output: UnsafePointer[UInt8, MutExternalOrigin],
    output_capacity: c_int,
) -> c_int:
    var input_count = Int(input_len)
    if input_count <= 0:
        return 0

    var out_cap = Int(output_capacity)
    if out_cap <= 0:
        return 0

    var text = String()
    for i in range(input_count):
        text += chr(Int(input_text[i]))

    var normalized = normalize_plugin_gid(text)
    var copy_len = len(normalized)
    if copy_len > out_cap:
        copy_len = out_cap

    for i in range(copy_len):
        output[i] = UInt8(ord(normalized[i]))

    return copy_len


@export("mojo_parity_gap", ABI="C")
fn mojo_parity_gap(reference: c_float, candidate: c_float) -> c_float:
    return parity_gap(reference, candidate)
