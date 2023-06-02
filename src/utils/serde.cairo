use array::{ArrayTrait, SpanTrait};
use option::OptionTrait;
use serde::{deserialize_array_helper, Serde, serialize_array_helper};
use starknet::contract_address::{ContractAddress, ContractAddressSerde};
use traits::Default;

impl SpanSerde<T, impl TSerde: Serde<T>, impl TDrop: Drop<T>> of Serde<Span<T>> {
    fn serialize(self: @Span<T>, ref output: Array<felt252>) {
        (*self).len().serialize(ref output);
        serialize_array_helper(*self, ref output)
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Span<T>> {
        let length = *serialized.pop_front()?;
        let mut arr = Default::default();
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
