#[abi]
mod IBlesser {
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    fn bless() -> u128 {}

    fn preview_bless() -> u128 {}
}
