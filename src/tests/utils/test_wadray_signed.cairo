#[cfg(test)]
mod tests {
    use aura::utils::wadray_signed; 
    use aura::utils::wadray_signed::{SignedRay, SignedRayZeroable};
    use aura::utils::wadray::{RAY_ONE};


    #[test]
    fn test_add_sub() {
        let a = SignedRay{val: 100, sign: true};
        let b = SignedRay{val: 100, sign: false};
        let c = SignedRay{val: 40, sign: false};
        
        assert(a + b == SignedRayZeroable::zero(), 'a + b != 0'); 
        assert(a - b == SignedRay{val: 200, sign: true}, 'a - b != 200');
        assert(b - a == SignedRay{val: 200, sign: false}, 'b - a != -200');
        assert(a + c == SignedRay{val: 60, sign: true}, 'a + c != 60');
        assert(a - c == SignedRay{val: 140, sign: true}, 'a - c != 140');
    }

    #[test]
    fn test_mul_div() {
        let a = SignedRay{val: RAY_ONE, sign: true}; // 1.0 ray
        let b = SignedRay{val: 2*RAY_ONE, sign: false}; // -2.0 ray
        let c = SignedRay{val: 5*RAY_ONE, sign: true}; // 5.0 ray
        let d = SignedRay{val: RAY_ONE, sign: false}; // -1.0 ray

        // Test multiplication
        assert((a * b) == SignedRay{val: 2*RAY_ONE, sign: false}, 'a * b != -2.0');
        assert((a * c) == SignedRay{val: 5*RAY_ONE, sign: true}, 'a * c != 5.0');
        assert((b * c) == SignedRay{val: 10*RAY_ONE, sign: false}, 'b * c != -10.0');

        // Test division
        assert((c / a) == SignedRay{val: 5*RAY_ONE, sign: true}, 'c / a != -5.0');
        assert((a / d) == SignedRay{val: 1*RAY_ONE, sign: false}, 'a / d != -1.0');
        assert((b / d) == SignedRay{val: 2*RAY_ONE, sign: true}, 'b / d != 2.0');
    }

}
