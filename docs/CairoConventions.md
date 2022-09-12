# Cairo conventions

Cairo is a young language, so tooling, best practices and conventions are still evolving. As is true for all blockchain programming (with the possible exception of [Solana](https://twitter.com/KyleSamani/status/1418661490274439169)) writing secure, correct smart contracts is of highest importance. Yet code is read much more often than it is written, hence it should be written in an easy to understand and comprehend fashion. Conventions like the following lead to better security, less cognitive load on the reader and improve collaboration.

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

## General naming conventions

We follow these conventions when naming things

| thing                     | convention                 | example                                                          |
|---------------------------|----------------------------|------------------------------------------------------------------|
| directories and files     | snake_case                 | `module_name/module.cairo`                                       |
| functions                 | snake_case                 | `func open_account{...}(){}`                                      |
| namespaces                | CamelCase                  | `namespace Engine`                                               |
| contract interfaces       | CamelCase prepended with I | <pre>@contract_interface<br />namespace IAccount {<br />}</pre> |
| structs                   | CamelCase                  | `struct Loan`                                                    |
| variables, struct members | snake_case                 | `let user_balance = 100;`                                         |
| events                    | CamelCase                  | <pre>@event<br />func ThingHappened() {<br />}</pre>            |
| constants                 | UPPER_SNAKE_CASE           | `const CAP = 10**18;`                                             |

See sections below for further specific rules.

# Specifying variable and function argument types

Always specify the type of a function argument or return value.


## Type Aliases

Cairo lets us create aliases, or custom names, for types, using the `using` key word. This is particularly useful because felts are used to represent many different "types" in Cairo. A felt can contain a boolean (0 or 1), an address, a signed integer, and unsigned integer, a fixed point number, etc. This can make it difficult to determine the "true" type of a given variable, which is why using aliases can help make our code a lot more readable. We currently use the following aliases:

| Alias           | Explanation                                                         |
|-----------------|---------------------------------------------------------------------|
| `wad`           | 18-decimal number, in the range [-2**125, 2**125]                   |
| `ray`           | 27-decimal number, in the range [-2**125, 2**125]                   |
| `str`           | Cairo short-string                                                  |
| `bool`          | 0 or 1                                                              |
| `ufelt`         | 'regular' felt                                                      |
| `sfelt`         | 'signed' felt, in the range [-2**128 2**128)                        |
| `address`       | a StarkNet address                                                  |
| `packed`        | a felt containing multiple values that have been packed together    |

to use these aliases, include the following import in your contract (include aliases in the import statement as needed):

```cairo
from contracts.shared.aliases import wad, ray, str
```

#### Examples

Variable Definition:
```cairo
let is_le_ten: bool = is_le(4, 10);
```

Function Definition:
```cairo
func foo(eth: address, amount: wad, some_check: bool) -> bool {
    ...
}

func bar(values: packed, num_packed: ufelt) -> (first_val: ufelt, second_val: sfelt) {
    ...
}
```




## @storage_var naming

To prevent `@storage_var` conflicts and clearly distinguish between a local variable and a storage container, a `@storage_var` should be named using the following template: `modulename_variable_name` - that is, the variable name is prefixed by the module name (lowercase, no separation), separated by an underscore.

An example of a variable named `balance` inside a module called `Treasury`:

```cairo
@storage_var
func treasury_balance() -> (balance : felt) {
}
```

## Getters

A `@view` function that retrieves a `@storage_var` (essentially a getter) should be named `get_FOO`:

```cairo
@storage_var
func module_amount_storage() -> (amount : felt) {
}

@view
func get_amount{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (amount : felt) {
    let (amount) = module_amount_storage.read();
    return (amount);
}
```

## Events

Use Capitalized names (`Mint` 👍 / `mint` 👎) for [Events](https://www.cairo-lang.org/docs/hello_starknet/events.html) (note that the linked page doesn't follow this convention).

Prefer emitting events from `@external`, `@l1_handler` or `@constructor` functions, i.e. public functions that presumably change the state. It's ok to emit from internal helper functions as well if they change the state. Never emit from `@view` functions.

## Use module names in error messages

When using the `with_attr error_message()` pattern to do a check and raise an error if it fails, prepend the error message itself with the module name. It makes it easier for debugging, etc. An example from the `direct_deposit` module:

```cairo
with_attr error_message("direct_deposit: transferFrom failed") {
    assert was_transfered = TRUE;
}
```

## `*_external.cairo` modules a.k.a. mixins

You can create files that hold reusable (i.e. useful for distinct smart contracts) functionality. These files must have the `_external.cairo` suffix in their name. When using these mixins in a smart contract, simply import the required function using the `import` statement.

As an example, have a look at the [`auth_external.cairo`](../contracts/lib/auth_external.cairo) file; to import its functions, do `from contracts.lib.auth_external import authorize, revoke, get_auth`.
