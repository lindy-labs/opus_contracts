# Cairo conventions

Cairo is a young language, tooling, best pracitces and conventions are still evolving. As is true for all blockchain programming (with the possible exception of [Solana](https://twitter.com/KyleSamani/status/1418661490274439169)) writing secure, correct smart contrats is of highest importance. Yet code is read much more often than it is written, hence it should be written in an easy to understand and comprehend fashion. Conventions like the following lead to better security, less cognitive load on the reader and improve collaboration.

Please open a PR if you have anything that you'd like to add to this list.

## Use the official formatter

cairo-lang comes with the official formatter tool, `cairo-format`. Use it. We shouldn't be bike shedding about a contract's formatting, but rather spend our energy elsewhere. If you're using VSCode, every cairo-lang release contains a .vsix file. Install it and use it.

## Use felt over Uint256 whenever possible

The usage of `felt` for holding numerical values is preferrable to `Uint256`. Felts are cheaper and (subjectively) easier to use. There are exceptions to this rule - to conform with ERC standards or if the potential value of a variable doesn't fit a `felt`, use `Uint256`.

## Imports

Use fully qualified path when importing. The top-level module is always `contracts`:

```cairo
from contracts.module.submodule.file_name import function
```

This prevents any issues when compiling contracts.

## @storage_var naming

To prevent [`@storage_var` conflicts](https://github.com/crytic/amarna/issues/10) and clearly distinguish between a local variable and a storage container, a `@storage_var` should be named using the following template: `ModuleName_variable_name_storage` - that is, the variable name is prefixed by the module name and suffixed by the string `storage`, separated by underscores.

An example of a variable named `balance` inside a module called `Treasury`:

```cairo
@storage_var
func Treasury_balance_storage() -> (balance : felt):
end
```

## Getters

A `@view` function that retrieve a `@storage_var` (essentailly a getter) should be named `get_FOO`:

```cairo
@storage_var
func Module_amount_storage() -> (amount : felt):
end

@view
func get_amount{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (amount : felt):
    let (amount : felt) = Module_amount_storage.read()
    return (amount)
end
```

## Events

Use Capitalized names (`Mint` 👍 / `mint` 👎) for [Events](https://www.cairo-lang.org/docs/hello_starknet/events.html) (note that the linked page doesn't follow this convention).

Only emit events from `@external`, `@l1_handler` or `@constructor` functions, never from `@view` or private functions.

## Use module names in error messages

When using the `with_attr error_message()` pattern to do a check and raise an error if it fails, prepend the error message itself with the module name. It makes it easier for debugging, etc. An example from the `direct_deposit` module:

```cairo
with_attr error_message("direct_deposit: transferFrom failed":
    assert was_transfered = TRUE
end
```
