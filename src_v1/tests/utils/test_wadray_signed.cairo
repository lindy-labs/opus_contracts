#[cfg(test)]
mod tests {
    use debug::PrintTrait;
    use math::Oneable;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::utils::wadray_signed;
    use aura::utils::wadray_signed::{SignedRay, SignedRayOneable, SignedRayZeroable};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, Wad, WAD_ONE};


    #[test]
    fn test_add_sub() {
        let a = SignedRay { val: 100, sign: false };
        let b = SignedRay { val: 100, sign: true };
        let c = SignedRay { val: 40, sign: true };

        assert(a + b == SignedRayZeroable::zero(), 'a + b != 0');
        assert(a - b == SignedRay { val: 200, sign: false }, 'a - b != 200');
        assert(b - a == SignedRay { val: 200, sign: true }, 'b - a != -200');
        assert(a + c == SignedRay { val: 60, sign: false }, 'a + c != 60');
        assert(a - c == SignedRay { val: 140, sign: false }, 'a - c != 140');
    }

    #[test]
    fn test_mul_div() {
        let a = SignedRay { val: RAY_ONE, sign: false }; // 1.0 ray
        let b = SignedRay { val: 2 * RAY_ONE, sign: true }; // -2.0 ray
        let c = SignedRay { val: 5 * RAY_ONE, sign: false }; // 5.0 ray
        let d = SignedRay { val: RAY_ONE, sign: true }; // -1.0 ray

        // Test multiplication
        assert((a * b) == SignedRay { val: 2 * RAY_ONE, sign: true }, 'a * b != -2.0');
        assert((a * c) == SignedRay { val: 5 * RAY_ONE, sign: false }, 'a * c != 5.0');
        assert((b * c) == SignedRay { val: 10 * RAY_ONE, sign: true }, 'b * c != -10.0');

        // Test division
        assert((c / a) == SignedRay { val: 5 * RAY_ONE, sign: false }, 'c / a != 5.0');
        assert((a / d) == SignedRay { val: 1 * RAY_ONE, sign: true }, 'a / d != -1.0');
        assert((b / d) == SignedRay { val: 2 * RAY_ONE, sign: false }, 'b / d != 2.0');
    }

    #[test]
    fn test_comparison() {
        let a = SignedRay { val: 100, sign: false };
        let b = SignedRay { val: 100, sign: true };
        let c = SignedRay { val: 40, sign: true };
        let d = SignedRay { val: 40, sign: false };
        let zero = SignedRay { val: 0, sign: false };

        // Test greater than operator
        assert(a > b, 'a > b');
        assert(a > c, 'a > c');
        assert(!(b > a), 'b > a');
        assert(!(c > a), 'c > a');
        assert(!(zero > a), '0 > a');
        assert(a > zero, 'a > 0');

        // Test less than operator
        assert(b < a, 'b < a');
        assert(c < a, 'c < a');
        assert(!(a < b), 'a < b');
        assert(!(a < c), 'a < c');
        assert(zero < a, '0 < a');
        assert(!(a < zero), 'a < 0');

        // Test greater than or equal to operator
        assert(a >= b, 'a >= b');
        assert(a >= d, 'a >= d');
        assert(!(b >= a), 'b >= a');
        assert(c >= c, 'c >= c');
        assert(zero >= zero, '0 >= 0');
        assert(a >= zero, 'a >= 0');
        assert(!(zero >= a), '0 >= a');

        // Test less than or equal to operator
        assert(b <= a, 'b <= a');
        assert(d <= a, 'd <= a');
        assert(!(a <= b), 'a <= b');
        assert(c <= c, 'c <= c');
        assert(zero <= zero, '0 <= 0');
        assert(zero <= a, '0 <= a');
        assert(!(a <= zero), 'a <= 0');
    }

    #[test]
    fn test_into_conversions() {
        // Test U128IntoSignedRay
        let a: u128 = 100;
        let a_signed: SignedRay = a.into();
        assert(a_signed.val == a, 'U128IntoSignedRay val fail');
        assert(!a_signed.sign, 'U128IntoSignedRay sign fail');

        // Test RayIntoSignedRay
        let b = Ray { val: 200 };
        let b_signed: SignedRay = b.into();
        assert(b_signed.val == b.val, 'RayIntoSignedRay val fail');
        assert(!b_signed.sign, 'RayIntoSignedRay sign fail');

        // Test WadIntoSignedRay
        let c = Wad { val: 300 * WAD_ONE };
        let c_signed: SignedRay = c.into();
        assert(c_signed.val == c.val * wadray::DIFF, 'WadIntoSignedRay val fail');
        assert(!c_signed.sign, 'WadIntoSignedRay sign fail');

        // Test SignedRayTryIntoRay
        let d = SignedRay { val: 400, sign: false };
        let d_ray: Option<Ray> = d.try_into();
        assert(d_ray.is_some(), 'SignedRayTryIntoRay pos fail');
        assert(d_ray.unwrap().val == d.val, 'SignedRayTryIntoRay val fail');

        let e = SignedRay { val: 500, sign: true };
        let e_ray: Option<Ray> = e.try_into();
        assert(e_ray.is_none(), 'SignedRayTryIntoRay neg fail');
    }

    #[test]
    fn test_zeroable_oneable() {
        // Test SignedRayZeroable
        let zero = SignedRayZeroable::zero();
        assert(zero.val == 0, 'Zeroable zero fail');
        assert(!zero.sign, 'Zeroable zero sign fail');
        assert(zero.is_zero(), 'Zeroable is_zero fail');
        assert(!zero.is_non_zero(), 'Zeroable is_non_zero fail');

        let non_zero = SignedRay { val: 100, sign: false };
        assert(!non_zero.is_zero(), 'Zeroable non_zero fail');
        assert(non_zero.is_non_zero(), 'Zeroable non_zero fail');

        // Test SignedRayOneable
        let one = SignedRayOneable::one();
        assert(one.val == RAY_ONE, 'Oneable one fail');
        assert(!one.sign, 'Oneable one sign fail');
        assert(one.is_one(), 'Oneable is_one fail');
        assert(!one.is_non_one(), 'Oneable is_non_one fail');

        let non_one = SignedRay { val: 200, sign: false };
        assert(!non_one.is_one(), 'Oneable non_one fail');
        assert(non_one.is_non_one(), 'Oneable non_one fail');
    }
}