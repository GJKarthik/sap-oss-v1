# ===----------------------------------------------------------------------=== #
# ToonSPy Signatures - DSPy-style input/output field definitions
#
# Signatures define the schema for LLM interactions with TOON output format.
# ===----------------------------------------------------------------------=== #

from collections import Dict, List
from utils import Variant


@value
struct InputField:
    """Define an input field for a signature."""
    var name: String
    var desc: String
    var required: Bool
    var default: String
    
    fn __init__(
        inout self,
        name: String = "",
        desc: String = "",
        required: Bool = True,
        default: String = ""
    ):
        self.name = name
        self.desc = desc
        self.required = required
        self.default = default
    
    fn to_prompt(self) -> String:
        """Generate prompt fragment for this input."""
        if self.desc:
            return self.name + " (" + self.desc + ")"
        return self.name


@value
struct OutputField:
    """Define an output field for a signature with TOON formatting hints."""
    var name: String
    var desc: String
    var field_type: String  # "string", "int", "float", "bool", "array", "enum"
    var enum_values: List[String]
    var range_min: Float64
    var range_max: Float64
    var array_separator: String
    
    fn __init__(
        inout self,
        name: String = "",
        desc: String = "",
        field_type: String = "string",
        enum_values: List[String] = List[String](),
        range_min: Float64 = 0.0,
        range_max: Float64 = 0.0,
        array_separator: String = "|"
    ):
        self.name = name
        self.desc = desc
        self.field_type = field_type
        self.enum_values = enum_values
        self.range_min = range_min
        self.range_max = range_max
        self.array_separator = array_separator
    
    fn to_toon_spec(self) -> String:
        """Generate TOON format specification for this field."""
        var spec = self.name + ":"
        
        if self.field_type == "enum" and len(self.enum_values) > 0:
            # enum: field:<opt1|opt2|opt3>
            var opts = String()
            for i in range(len(self.enum_values)):
                if i > 0:
                    opts += "|"
                opts += self.enum_values[i]
            spec += "<" + opts + ">"
        elif self.field_type == "float" and self.range_max > self.range_min:
            # range: field:<0.0-1.0>
            spec += "<" + String(self.range_min) + "-" + String(self.range_max) + ">"
        elif self.field_type == "int" and self.range_max > self.range_min:
            # range: field:<0-100>
            spec += "<" + String(Int(self.range_min)) + "-" + String(Int(self.range_max)) + ">"
        elif self.field_type == "bool":
            spec += "<true|false>"
        elif self.field_type == "array":
            spec += "<val1|val2|...>"
        else:
            spec += "<value>"
        
        return spec


@value
struct Field:
    """Generic field that can be input or output."""
    var name: String
    var is_input: Bool
    var input_field: InputField
    var output_field: OutputField
    
    fn __init__(inout self, name: String, is_input: Bool = True):
        self.name = name
        self.is_input = is_input
        self.input_field = InputField(name=name)
        self.output_field = OutputField(name=name)


struct Signature:
    """
    DSPy-style Signature for defining LLM interaction schemas.
    
    Signatures specify:
    - Input fields: What data the LLM receives
    - Output fields: What data the LLM should return (in TOON format)
    - Description: Task description for the prompt
    - Mangle rules: Optional validation rules
    
    Example:
        var sig = Signature("Classify text sentiment")
        sig.add_input(InputField(name="text", desc="Text to classify"))
        sig.add_output(OutputField(
            name="sentiment",
            field_type="enum",
            enum_values=List("positive", "negative", "neutral")
        ))
        sig.add_output(OutputField(
            name="confidence",
            field_type="float",
            range_min=0.0,
            range_max=1.0
        ))
        
        # Generated TOON prompt spec:
        # sentiment:<positive|negative|neutral> confidence:<0.0-1.0>
    """
    var name: String
    var description: String
    var inputs: List[InputField]
    var outputs: List[OutputField]
    var mangle_rules: String
    
    fn __init__(
        inout self,
        description: String = "",
        name: String = "",
        mangle_rules: String = ""
    ):
        self.name = name
        self.description = description
        self.inputs = List[InputField]()
        self.outputs = List[OutputField]()
        self.mangle_rules = mangle_rules
    
    fn add_input(inout self, field: InputField):
        """Add an input field to the signature."""
        self.inputs.append(field)
    
    fn add_output(inout self, field: OutputField):
        """Add an output field to the signature."""
        self.outputs.append(field)
    
    fn generate_toon_prompt(self) -> String:
        """
        Generate a TOON-optimized prompt from the signature.
        
        Format:
            {description}
            
            Respond in TOON format:
            field1:<spec> field2:<spec> field3:<spec>
            
            Input:
            input1: {value}
        """
        var prompt = self.description + "\n\n"
        prompt += "Respond in TOON format (key:value, arrays use |):\n"
        
        # Output specification
        for i in range(len(self.outputs)):
            if i > 0:
                prompt += " "
            prompt += self.outputs[i].to_toon_spec()
        
        return prompt
    
    fn generate_system_prompt(self) -> String:
        """Generate system prompt for TOON output."""
        return """You are a precise assistant that responds in TOON format.
TOON rules:
- Use key:value syntax (no quotes around simple values)
- Arrays use pipe separator: items:a|b|c
- Nested objects use space: person:name:John age:30
- Null is ~
- Boolean is true/false

Always respond with the exact fields requested, nothing more."""
    
    fn validate_inputs(self, inputs: Dict[String, String]) -> Bool:
        """Validate that all required inputs are provided."""
        for i in range(len(self.inputs)):
            var field = self.inputs[i]
            if field.required:
                if field.name not in inputs:
                    return False
        return True


# ===----------------------------------------------------------------------=== #
# Helper functions for creating common signature patterns
# ===----------------------------------------------------------------------=== #

fn create_classification_signature(
    description: String,
    categories: List[String]
) -> Signature:
    """Create a classification signature with enum output."""
    var sig = Signature(description=description)
    sig.add_input(InputField(name="text", desc="Text to classify"))
    sig.add_output(OutputField(
        name="category",
        field_type="enum",
        enum_values=categories
    ))
    sig.add_output(OutputField(
        name="confidence",
        field_type="float",
        range_min=0.0,
        range_max=1.0
    ))
    return sig


fn create_extraction_signature(
    description: String,
    fields: List[String]
) -> Signature:
    """Create an extraction signature with multiple string outputs."""
    var sig = Signature(description=description)
    sig.add_input(InputField(name="text", desc="Source text"))
    
    for i in range(len(fields)):
        sig.add_output(OutputField(name=fields[i], field_type="string"))
    
    return sig


fn create_qa_signature(description: String = "Answer the question.") -> Signature:
    """Create a question-answering signature."""
    var sig = Signature(description=description)
    sig.add_input(InputField(name="question", desc="Question to answer"))
    sig.add_input(InputField(name="context", desc="Context for answering", required=False))
    sig.add_output(OutputField(name="answer", field_type="string"))
    sig.add_output(OutputField(
        name="confidence",
        field_type="float",
        range_min=0.0,
        range_max=1.0
    ))
    return sig