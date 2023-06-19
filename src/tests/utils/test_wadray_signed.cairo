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
        let a = SignedRay{val: 100, sign: true};
    }
}
