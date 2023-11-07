use integer::u256_sqrt;
use math::Oneable;
use opus::utils::wadray::Ray;
use opus::utils::wadray;

fn sqrt(x: Ray) -> Ray {
    let scaled_val: u256 = x.val.into() * wadray::RAY_SCALE.into();
    u256_sqrt(scaled_val).into()
}

fn pow<T, impl TMul: Mul<T>, impl TOneable: Oneable<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>>(
    x: T, mut n: u8
) -> T {
    if n == 0 {
        TOneable::one()
    } else if n == 1 {
        x
    } else if n % 2 == 0 {
        pow(x * x, n / 2)
    } else {
        x * pow(x * x, (n - 1) / 2)
    }
}
