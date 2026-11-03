//! Random `"<Adjective> <Fruit>"` aliases (lists mirror `protocol/aliases.json`).

use rand::seq::SliceRandom;

pub const ADJECTIVES: &[&str] = &[
    "Adorable", "Beautiful", "Big", "Bright", "Clean", "Clever", "Cool", "Cute", "Cunning",
    "Determined", "Energetic", "Efficient", "Fantastic", "Fast", "Fine", "Fresh", "Good",
    "Gorgeous", "Great", "Handsome", "Hot", "Kind", "Lovely", "Mystic", "Neat", "Nice",
    "Patient", "Pretty", "Powerful", "Rich", "Secret", "Smart", "Solid", "Special", "Strategic",
    "Strong", "Tidy", "Wise",
];

pub const FRUITS: &[&str] = &[
    "Apple", "Avocado", "Banana", "Blackberry", "Blueberry", "Broccoli", "Carrot", "Cherry",
    "Coconut", "Grape", "Lemon", "Lettuce", "Mango", "Melon", "Mushroom", "Onion", "Orange",
    "Papaya", "Peach", "Pear", "Pineapple", "Potato", "Pumpkin", "Raspberry", "Strawberry",
    "Tomato",
];

/// Generate a random alias such as `"Nice Orange"`.
pub fn generate_alias() -> String {
    let mut rng = rand::thread_rng();
    let adj = ADJECTIVES.choose(&mut rng).copied().unwrap_or("Nice");
    let fruit = FRUITS.choose(&mut rng).copied().unwrap_or("Orange");
    format!("{adj} {fruit}")
}
