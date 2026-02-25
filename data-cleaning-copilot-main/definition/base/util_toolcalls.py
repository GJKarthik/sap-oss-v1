from typing import List


def extract_tool_descriptions(tool_union_type) -> List[str]:
    """
    Dynamically extract tool descriptions from a Union type of Pydantic models.
    """
    # Get all tool classes from the Union type
    tool_classes = getattr(tool_union_type, "__args__", [])

    # Define parameter formatting rules inline
    list_params = {"table_names", "checks", "corruptors", "check_names", "corruptor_names"}

    return [
        f"{cls.__name__}({', '.join([f'{name}=[...]' if name in list_params else f'{name}="..."' for name in cls.model_fields.keys() if name != 'type'])}) - {(cls.__doc__ or '').strip().rstrip('.')}"
        for cls in tool_classes
    ]
