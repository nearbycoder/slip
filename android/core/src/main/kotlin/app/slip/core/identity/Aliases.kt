package app.slip.core.identity

import kotlin.random.Random

/** Word lists mirrored from protocol/aliases.json (a unit test keeps them in sync). */
object Aliases {
    val adjectives = listOf(
        "Adorable", "Beautiful", "Big", "Bright", "Clean", "Clever", "Cool", "Cute", "Cunning", "Determined",
        "Energetic", "Efficient", "Fantastic", "Fast", "Fine", "Fresh", "Good", "Gorgeous", "Great", "Handsome",
        "Hot", "Kind", "Lovely", "Mystic", "Neat", "Nice", "Patient", "Pretty", "Powerful", "Rich", "Secret",
        "Smart", "Solid", "Special", "Strategic", "Strong", "Tidy", "Wise",
    )
    val fruits = listOf(
        "Apple", "Avocado", "Banana", "Blackberry", "Blueberry", "Broccoli", "Carrot", "Cherry", "Coconut",
        "Grape", "Lemon", "Lettuce", "Mango", "Melon", "Mushroom", "Onion", "Orange", "Papaya", "Peach", "Pear",
        "Pineapple", "Potato", "Pumpkin", "Raspberry", "Strawberry", "Tomato",
    )

    /** `"<Adjective> <Fruit>"`, e.g. "Nice Orange". */
    fun generate(random: Random = Random.Default): String = "${adjectives.random(random)} ${fruits.random(random)}"
}
