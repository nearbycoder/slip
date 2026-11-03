import Foundation

/// Generates `"<Adjective> <Fruit>"` aliases from protocol/aliases.json.
public enum AliasGenerator {
    public static let adjectives: [String] = [
        "Adorable", "Beautiful", "Big", "Bright", "Clean", "Clever", "Cool", "Cute",
        "Cunning", "Determined", "Energetic", "Efficient", "Fantastic", "Fast", "Fine", "Fresh",
        "Good", "Gorgeous", "Great", "Handsome", "Hot", "Kind", "Lovely", "Mystic",
        "Neat", "Nice", "Patient", "Pretty", "Powerful", "Rich", "Secret", "Smart",
        "Solid", "Special", "Strategic", "Strong", "Tidy", "Wise",
    ]

    public static let fruits: [String] = [
        "Apple", "Avocado", "Banana", "Blackberry", "Blueberry", "Broccoli", "Carrot", "Cherry",
        "Coconut", "Grape", "Lemon", "Lettuce", "Mango", "Melon", "Mushroom", "Onion",
        "Orange", "Papaya", "Peach", "Pear", "Pineapple", "Potato", "Pumpkin", "Raspberry",
        "Strawberry", "Tomato",
    ]

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        "\(adjectives.randomElement(using: &generator)!) \(fruits.randomElement(using: &generator)!)"
    }

    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }
}
