#!/usr/bin/env python3
import sys
import os
import re
import time

def mangle_to_zig_type(mangle_type):
    mapping = {
        "String": "[]const u8",
        "i32": "i32",
        "i64": "i64",
        "f64": "f64"
    }
    return mapping.get(mangle_type, "[]const u8")

def snake_to_pascal(name):
    return "".join(word.capitalize() for word in name.split("_"))

def generate_connector(schema_path, output_path, service_id):
    with open(schema_path, "r") as f:
        content = f.read()

    # Find Decl statements
    decls = re.findall(r"Decl\s+([a-zA-Z0-9_]+)\s*\((.*?)\)\.", content, re.DOTALL)

    output = []
    output.append(f"//! Auto-generated connector from {os.path.basename(schema_path)}")
    output.append(f"//! Service: {service_id}")
    output.append(f"//! Generated at: {int(time.time())}")
    output.append("//!")
    output.append("//! DO NOT EDIT MANUALLY\n")
    output.append('const std = @import("std");\n')

    for name, fields_str in decls:
        # Strip inline comments from the entire fields block
        fields_str_clean = re.sub(r"//.*", "", fields_str)
        
        pascal_name = snake_to_pascal(name)
        output.append(f"/// {name}")
        output.append(f"pub const {pascal_name} = struct {{")
        
        fields_data = []
        fields = fields_str_clean.split(",")
        for field_raw in fields:
            field_raw = field_raw.strip()
            if not field_raw: continue
            
            if ":" in field_raw:
                f_parts = field_raw.split(":")
                if len(f_parts) >= 2:
                    f_name = f_parts[0].strip()
                    f_type_raw = f_parts[1].strip()
                    f_type = mangle_to_zig_type(f_type_raw)
                    fields_data.append((f_name, f_type))
                    output.append(f"    {f_name}: {f_type},")
        
        # Add default() method
        output.append("\n    pub fn default() @This() {")
        output.append("        return .{")
        for f_name, f_type in fields_data:
            if f_type == "[]const u8":
                val = f'"{service_id}"' if f_name == "service_id" else '""'
                output.append(f"            .{f_name} = {val},")
            elif f_type == "i32" or f_type == "i64":
                output.append(f"            .{f_name} = 0,")
            elif f_type == "f64":
                output.append(f"            .{f_name} = 0.0,")
        output.append("        };")
        output.append("    }")
        output.append("};\n")

    with open(output_path, "w") as f:
        f.write("\n".join(output))

    print(f"Generated {output_path} with {len(decls)} structs")

if __name__ == "__main__":
    schema = ""
    output = ""
    service = "generated_service"
    
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--schema":
            schema = sys.argv[i+1]
            i += 2
        elif sys.argv[i] == "--output":
            output = sys.argv[i+1]
            i += 2
        elif sys.argv[i] == "--service":
            service = sys.argv[i+1]
            i += 2
        else:
            i += 1
            
    if not schema or not output:
        print("Usage: codegen.py --schema <path.mg> --output <path.zig> [--service <id>]")
        sys.exit(1)
        
    generate_connector(schema, output, service)