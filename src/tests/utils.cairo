mod test_access_control;
mod test_exp;
mod test_pow;
mod test_reentrancy_guard;
mod test_u256_conversions;
mod test_wadray;

use aura::utils::wadray::Wad;

#[inline(always)]
fn assert_equalish(a: Wad, b: Wad, error: Wad, message: felt252) {
    if a >= b {
        assert(a - b <= error, message);
    } else {
        assert(b - a <= error, message);
    }
}
