use math::Oneable;
use traits::Into;
use zeroable::Zeroable;

use aura::utils::wadray;
use aura::utils::wadray::Ray;
use debug::PrintTrait;

fn sqrt(x: Ray) -> Ray {
    // Early return if x is zero
    if x.is_zero() {
        return x;
    }

    // Initial guess as half the number
    let mut guess = Ray { val: x.val / 2 };

    // A small number for precision checking
    // There is a negligible change in performance when using a larger allowed error
    let EPSILON = Ray { val: 1 };

    loop {
        let previous_guess = guess;

        // Babylonian Method: (guess + (x.val / guess)) / 2
        guess = Ray { val: (guess + x / guess).val / 2 };

        // Check if the guess is close enough to the previous guess
        if previous_guess >= guess {
            if (previous_guess - guess) < EPSILON {
                break guess;
            }
        } else {
            if (guess - previous_guess) < EPSILON {
                break guess;
            }
        };
    }
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
