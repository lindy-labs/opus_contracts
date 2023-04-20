use option::OptionTrait;
use traits::TryInto;
use traits::Into;
use debug::PrintTrait;

const WAD_SCALE: felt252 = 1000000000000000000;
const RAY_SCALE: felt252 = 1000000000000000000000000000;
const WAD_ONE: felt252 = 1000000000000000000;
const RAY_ONE: felt252 = 1000000000000000000000000000;
// The difference between WAD_SCALE and RAY_SCALE. RAY_SCALE = WAD_SCALE * DIFF
const DIFF: felt252 = 1000000000;

mod wad_ray {
    #[derive(Copy, Drop)]
    struct Wad {
        val: u128, 
    }

    #[derive(Copy, Drop)]
    struct Ray {
        val: u128
    }

    // Core functions

    fn wmul(a: Wad, b: Wad) -> Wad {
        // Work-around since we can't have non-felt constants yet
        let wad_one: u128 = WAD_ONE.try_into().unwrap();
        Wad { val: (a.val * b.val) / wad_one }
    }

    // wmul of Wad and Ray -> Ray
    fn wmul_wr(a: Wad, b: Ray) -> Ray {
        let wad_one: u128 = WAD_ONE.try_into().unwrap();
        Ray { val: (a.val * b.val) / wad_one }
    }

    fn wmul_rw(a: Ray, b: Wad) -> Ray {
        let wad_one: u128 = WAD_ONE.try_into().unwrap();
        Ray { val: (a.val * b.val) / wad_one }
    }

    fn rmul(a: Ray, b: Ray) -> Ray {
        let ray_one: u128 = WAD_ONE.try_into().unwrap();
        Ray { val: (a.val * b.val) / ray_one }
    }

    // rmul of Wad and Ray -> Wad
    fn rmul_rw(a: Ray, b: Wad) -> Wad {
        let ray_one: u128 = WAD_ONE.try_into().unwrap();
        Wad { val: (a.val * b.val) / ray_one }
    }

    fn rmul_wr(a: Wad, b: Ray) -> Wad {
        rmul_rw(b, a)
    }

    fn wdiv(a: Wad, b: Wad) -> Wad {
        let wad_one: u128 = WAD_ONE.try_into().unwrap();
        Wad { val: (a.val * wad_one) / b.val }
    }

    // wdiv of Ray by Wad -> Ray
    fn wdiv_rw(a: Ray, b: Wad) -> Wad {
        let wad_one: u128 = WAD_ONE.try_into().unwrap();
        Ray { val: (a.val * wad_one) / b.val }
    }


    fn rdiv(a: Ray, b: Ray) -> Ray {
        let ray_one: u128 = RAY_ONE.try_into().unwrap();
        Ray { val: (a.val * ray_one) / b.val }
    }

    // rdiv of Wad by Ray -> Wad
    fn rdiv_wr(a: Wad, b: Ray) -> Wad {
        let ray_one: u128 = RAY_ONE.try_into().unwrap();
        Wad { val: (a.val * ray_one) / b.val }
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
        fn add(a: Wad, b: Wad) -> Wad {
            Wad { val: a.val + b.val }
        }
    }

    impl RayAdd of Add::<Ray> {
        fn add(a: Ray, b: Ray) -> Ray {
            Ray { val: a.val + b.val }
        }
    }

    // Subtraction
    impl WadSub of Sub::<Wad> {
        fn sub(a: Wad, b: Wad) -> Wad {
            Wad { val: a.val - b.val }
        }
    }

    impl RaySub of Sub::<Ray> {
        fn sub(a: Ray, b: Ray) -> Ray {
            Ray { val: a.val - b.val }
        }
    }

    // Multiplication
    impl WadMul of Mul::<Wad> {
        fn mul(a: Wad, b: Wad) -> Wad {
            wmul(a, b)
        }
    }

    impl RayMul of Mul::<Ray> {
        fn mul(a: Ray, b: Ray) -> Ray {
            rmul(a, b)
        }
    }

    // Division
    impl WadDiv of Div::<Wad> {
        fn div(a: Wad, b: Wad) -> Wad {
            wdiv(a, b)
        }
    }

    impl RayDiv of Div::<Ray> {
        fn div(a: Ray, b: Ray) -> Ray {
            rdiv(a, b)
        }
    }

    // Conversions
    impl WadIntoRay of Into::<Wad, Ray> {
        fn into(self: Wad) -> Ray {
            let diff: u128 = DIFF.try_into().unwrap();
            Ray { val: self.val * diff }
        }
    }

    impl RayIntoWad of Into::<Ray, Wad> {
        fn into(self: Ray) -> Wad {
            let diff: u128 = DIFF.try_into().unwrap();
            // The value will get truncated if it has more than 18 decimals.
            Wad { val: self.val / diff }
        }
    }
}
