import re


def convert_event_call(code_line, events):
    for event_name, params in events.items():
        if event_name in code_line:
            if "(" in code_line and ")" in code_line:
                # Event calls with parameters
                params_str = ", ".join(
                    f"{param[0]}: {val}" for param, val in zip(params, code_line.split("(")[1].split(")")[0].split(","))
                )
                replacement = f"self.emit({event_name} {{ {params_str} }});"
            else:
                # Event calls without parameters
                replacement = f"self.emit({event_name} {{}});"
            pattern = r"\b" + event_name + r"\s*\((.*?)\)\s*;"
            return re.sub(pattern, replacement, code_line)
    return code_line


def get_events(contract):
    pattern = r"\s*#\[event\]\s+fn\s+([a-zA-Z_][a-zA-Z_0-9]*)\s*\(([\s\S]*?)\)\s*\{\s*\}"
    events = re.findall(pattern, contract)
    events = {
        event[0]: [
            (param.split(":")[0].strip(), param.split(":")[1].strip())
            for param in event[1].split(",")
            if param.strip()  # Ignore empty strings
        ]
        if event[1].strip() != ""
        else []
        for event in events
    }
    return events


def remove_events(contract):
    pattern = r"\s*#\[event\]\s+fn\s+[a-zA-Z_][a-zA-Z_0-9]*\s*\(([\s\S]*?)\)\s*\{\s*\}"
    return re.sub(pattern, "", contract)


def convert_event_declaration(contract, events):
    old_declarations = ""
    new_declarations = ""

    for event_name, params in events.items():
        old_declaration = (
            "#[event]\nfn " + event_name + "(" + ", ".join(f"{name}: {type}" for name, type in params) + ") {}\n"
        )
        params_str = ",\n".join(f"\t\t{name}: {type}" for name, type in params)
        new_declaration = f"""
\t#[derive(Drop, starknet::Event)]
\tstruct {event_name} {{
{params_str}
\t}}\n"""
        old_declarations += old_declaration
        new_declarations += new_declaration

    if events:  # prepare enum
        event_enum = "\n\t#[event]\n\t#[derive(Drop, starknet::Event)]\n\tenum Event {\n"
        for event_name in events.keys():
            event_enum += f"\t\t{event_name}: {event_name},\n"
        event_enum += "\t}\n"
        new_declarations = event_enum + new_declarations

    contract = contract.replace(old_declarations, "")  # remove old declarations

    # Replace pattern with pattern + new declarations
    first_occurrence = [True]
    pattern = r"struct Storage\s*{[\s\S]*?}"  # pattern to match the 'Storage' struct

    def replace_first(match):
        if first_occurrence[0]:  # if this is the first occurrence
            first_occurrence[0] = False  # update the flag
            return match.group(0) + "\n\n" + new_declarations  # return the matched text + new_declarations
        else:  # for all other occurrences
            return match.group(0)  # return the matched text as is

    contract = re.sub(pattern, replace_first, contract, flags=re.MULTILINE | re.DOTALL)

    return contract


def convert_events(contract):
    events = get_events(contract)
    lines = contract.split("\n")
    for i in range(len(lines)):
        lines[i] = convert_event_call(lines[i], events)
    contract = "\n".join(lines)
    contract = convert_event_declaration(contract, events)
    contract = remove_events(contract)
    return contract


def read_file(file_name):
    with open(file_name, "r") as file:
        return file.read()


def write_file(file_name, content):
    with open(file_name, "w") as file:
        file.write(content)


def convert_file(input_file_name, output_file_name=None):
    contract = read_file(input_file_name)
    contract = convert_events(contract)
    if output_file_name is None:
        output_file_name = input_file_name
    write_file(output_file_name, contract)


# Use this to convert a file:
# convert_file("your_contract.rs", "your_converted_contract.rs")


# print(get_events(read_file("shrine.cairo")))
# convert_file("shrine.cairo", "converted_shrine.cairo")
