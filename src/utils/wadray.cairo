use option::OptionTrait;
use traits::TryInto;
use traits::Into;

mod wad_ray {
    const WAD_SCALE: u128 = 1000000000000000000_u128;
    const RAY_SCALE: u128 = 1000000000000000000000000000_u128;
    const WAD_ONE: u128 = 1000000000000000000_u128;
    const RAY_ONE: u128 = 1000000000000000000000000000_u128;
    // The difference between WAD_SCALE and RAY_SCALE. RAY_SCALE = WAD_SCALE * DIFF
    const DIFF: u128 = 1000000000_u128;

    #[derive(Copy, Drop)]
    struct Wad {
        val: u128, 
    }

    #[derive(Copy, Drop)]
    struct Ray {
        val: u128
    }

    // Core functions

    fn wmul(lhs: Wad, rhs: Wad) -> Wad {
        // Work-around since we can't have non-felt constants yet
        Wad { val: (lhs.val * rhs.val) / WAD_ONE }
    }

    // wmul of Wad and Ray -> Ray
    fn wmul_wr(lhs: Wad, rhs: Ray) -> Ray {
        Ray { val: (lhs.val * rhs.val) / WAD_ONE }
    }

    fn wmul_rw(lhs: Ray, rhs: Wad) -> Ray {
        Ray { val: (lhs.val * rhs.val) / WAD_ONE }
    }

    fn rmul(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: (lhs.val * rhs.val) / RAY_ONE }
    }

    // rmul of Wad and Ray -> Wad
    fn rmul_rw(lhs: Ray, rhs: Wad) -> Wad {
        Wad { val: (lhs.val * rhs.val) / RAY_ONE }
    }

    fn rmul_wr(lhs: Wad, rhs: Ray) -> Wad {
        rmul_rw(rhs, lhs)
    }

    fn wdiv(lhs: Wad, rhs: Wad) -> Wad {
        Wad { val: (lhs.val * WAD_ONE) / rhs.val }
    }

    // wdiv of Ray by Wad -> Ray
    fn wdiv_rw(lhs: Ray, rhs: Wad) -> Ray {
        Ray { val: (lhs.val * WAD_ONE) / rhs.val }
    }

    fn rdiv(lhs: Ray, rhs: Ray) -> Ray {
        Ray { val: (lhs.val * RAY_ONE) / rhs.val }
    }

    // rdiv of Wad by Ray -> Wad
    fn rdiv_wr(lhs: Wad, rhs: Ray) -> Wad {
        Wad { val: (lhs.val * RAY_ONE) / rhs.val }
    }

    // Traits
    trait FixedPointTrait<T> {
        fn new(val: u128) -> T;
        fn val(self: T) -> u128;
    }

    // Implementations

    impl WadImpl of FixedPointTrait::<Wad> {
        fn new(val: u128) -> Wad {
            Wad { val: val }
        }

        fn val(self: Wad) -> u128 {
            self.val
        }
    }

    impl RayImpl of FixedPointTrait::<Ray> {
        fn new(val: u128) -> Ray {
            Ray { val: val }
        }

        fn val(self: Ray) -> u128 {
            self.val
        }
    }

    // Addition
    impl WadAdd of Add::<Wad> {
        fn add(lhs: Wad, rhs: Wad) -> Wad {
            Wad { val: lhs.val + rhs.val }
        }
    }

    impl RayAdd of Add::<Ray> {
        fn add(lhs: Ray, rhs: Ray) -> Ray {
            Ray { val: lhs.val + rhs.val }
        }
    }

    // Subtraction
    impl WadSub of Sub::<Wad> {
        fn sub(lhs: Wad, rhs: Wad) -> Wad {
            Wad { val: lhs.val - rhs.val }
        }
    }

    impl RaySub of Sub::<Ray> {
        fn sub(lhs: Ray, rhs: Ray) -> Ray {
            Ray { val: lhs.val - rhs.val }
        }
    }

    // Multiplication
    impl WadMul of Mul::<Wad> {
        fn mul(lhs: Wad, rhs: Wad) -> Wad {
            wmul(lhs, rhs)
        }
    }

    impl RayMul of Mul::<Ray> {
        fn mul(lhs: Ray, rhs: Ray) -> Ray {
            rmul(lhs, rhs)
        }
    }

    // Division
    impl WadDiv of Div::<Wad> {
        fn div(lhs: Wad, rhs: Wad) -> Wad {
            wdiv(lhs, rhs)
        }
    }

    impl RayDiv of Div::<Ray> {
        fn div(lhs: Ray, rhs: Ray) -> Ray {
            rdiv(lhs, rhs)
        }
    }

    // Conversions
    impl WadIntoRay of Into::<Wad, Ray> {
        fn into(self: Wad) -> Ray {
            Ray { val: self.val * DIFF }
        }
    }

    impl RayIntoWad of Into::<Ray, Wad> {
        fn into(self: Ray) -> Wad {
            // The value will get truncated if it has more than 18 decimals.
            Wad { val: self.val / DIFF }
        }
    }
}
