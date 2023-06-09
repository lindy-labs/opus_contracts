use debug::PrintTrait;

use aura::utils::wadray::{Wad, Ray};

impl WadPrintImpl of PrintTrait<Wad> {
    fn print(self: Wad) {
        self.val.print();
    }
}

impl RayPrintImpl of PrintTrait<Ray> {
    fn print(self: Ray) {
        self.val.print();
    }
}
