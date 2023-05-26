use traits::Into;

impl BoolIntoFelt252 of Into<bool, felt252> {
    #[inline(always)]
    fn into(self: bool) -> felt252 {
        if self {
            1
        } else {
            0
        }
    }
}
