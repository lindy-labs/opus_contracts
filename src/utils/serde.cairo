use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use serde::Serde;

impl SpanSerde<T, impl TSerde: Serde<T>, impl TDrop: Drop<T>> of Serde<Span<T>> {
    fn serialize(self: @Span<T>, ref output: Array<felt252>) {
        (*self).len().serialize(ref output);
        serialize_array_helper(*self, ref output)
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Span<T>> {
        let length = *serialized.pop_front()?;
        let mut arr = ArrayTrait::new();
        match deserialize_array_helper(ref serialized, arr, length) {
            Option::Some(arr) => {
                Option::Some(arr.span())
            },
            Option::None(_) => {
                Option::None(())
            }
        }
    }
}

// copied from `corelib/src/array.cairo`
fn serialize_array_helper<T, impl TSerde: Serde<T>, impl TDrop: Drop<T>>(
    mut input: Span<T>, ref output: Array<felt252>
) {
    match input.pop_front() {
        Option::Some(value) => {
            value.serialize(ref output);
            serialize_array_helper(input, ref output);
        },
        Option::None(_) => {},
    }
}

// copied from `corelib/src/array.cairo`
fn deserialize_array_helper<T, impl TSerde: Serde<T>, impl TDrop: Drop<T>>(
    ref serialized: Span<felt252>, mut curr_output: Array<T>, remaining: felt252
) -> Option<Array<T>> {
    if remaining == 0 {
        return Option::Some(curr_output);
    }
    curr_output.append(TSerde::deserialize(ref serialized)?);
    deserialize_array_helper(ref serialized, curr_output, remaining - 1)
}
