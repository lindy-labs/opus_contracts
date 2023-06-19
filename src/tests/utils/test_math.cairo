#[cfg(test)]
mod tests {
    use traits::Into;
    use debug::PrintTrait;
    use aura::utils::wadray;
    use aura::utils::wadray::Ray; 
    use aura::utils::math::sqrt;

    #[test]
    #[available_gas(20000000000)]
    fn test_sqrt() {
        sqrt(1000000000000000000000000000000_u128.into()).val.print(); // 1000
        sqrt(6969000000000000000000000000000_u128.into()).val.print(); // 6969
        sqrt(3141592653589793238462643383_u128.into()).val.print(); // pi 
        sqrt(2718281828459045235360287471_u128.into()).val.print(); // e 
        sqrt(299792458000000000000000000_u128.into()).val.print(); // speed of light
        sqrt(10234524522354524543529990530_u128.into()).val.print(); // random number
    }
}
