import re


def get_functions(content: str) -> list:
    pattern = r"\s*fn[^{]*{[^}]*}"
    # Making it non-greedy and enabling DOTALL mode (to match newline characters with .)

    # The following code ensures proper handling of nested braces
    open_braces = 0
    functions = []

    for match in re.finditer(pattern, content, re.DOTALL):
        for i in range(match.start(), len(content)):
            if content[i] == "{":
                open_braces += 1
            elif content[i] == "}":
                open_braces -= 1
                if open_braces == 0:
                    functions.append(content[match.start() : i + 1])
                    break
    return functions


def convert_storage(content):
    # replace #[contract] with #[starknet::contract]
    updated_content = re.sub(r"#\[contract\]", "#[starknet::contract]", content)

    # find all functions
    # function_pattern = re.compile(r"(fn .+?{.+?})", re.DOTALL)
    # functions = re.findall(function_pattern, updated_content)
    functions = get_functions(updated_content)
    write_funcs = set()
    read_funcs = set()
    funcs_to_update = []

    for function in functions:
        function_name = re.search(r"fn (\w+)\(", function).group(1)
        if "::write" in function:
            write_funcs.add(function_name)
        elif "::read" in function:
            read_funcs.add(function_name)

    for function in functions:
        updated_function = function
        function_name = re.search(r"fn (\w+)\(", function).group(1)
        if (
            any(re.search(rf"\b{func}\(", function) for func in write_funcs)
            and "ref self: ContractState" not in function
        ):
            updated_function = re.sub(r"(fn .+?\()\s*\)", r"\1ref self: ContractState)", updated_function)
            if updated_function == function:
                updated_function = re.sub(r"(fn .+?\()", r"\1ref self: ContractState, ", updated_function)
            if function != updated_function:
                funcs_to_update.append((function, updated_function))
            continue
        elif any(re.search(rf"\b{func}\(", function) for func in read_funcs) and "self: @ContractState" not in function:
            updated_function = re.sub(r"(fn .+?\()\s*\)", r"\1self: @ContractState)", updated_function)
            if updated_function == function:
                updated_function = re.sub(r"(fn .+?\()", r"\1self: @ContractState, ", updated_function)
            if function != updated_function:
                funcs_to_update.append((function, updated_function))

    for original, updated in funcs_to_update:
        updated_content = updated_content.replace(original, updated)

    updated_content = re.sub(r"#\[view\]", "#[external(v0)]", updated_content)
    updated_content = re.sub(r"#\[external\]", "#[external(v0)]", updated_content)
    updated_content = re.sub(r"\s*struct Storage", "\n\n\t#[storage]\n\tstruct Storage", updated_content)
    updated_content = re.sub(r"(\w+)::write", r"self.\1.write", updated_content)
    updated_content = re.sub(r"(\w+)::read", r"self.\1.read", updated_content)

    return updated_content
