// app/glyphs.ts — a glyph for a good by its name, when its specification
// carries none. The spec's own emoji always wins (knownEmoji, slots/model.ts);
// this is the fallback that keeps a shelf legible: the first keyword that
// matches, longest keys first, else the generic box.
const TABLE = [
    ["bread", "🍞"], ["loaf", "🍞"], ["flour", "🌾"], ["wheat", "🌾"], ["grain", "🌾"], ["rice", "🍚"], ["oat", "🌾"],
    ["vegetable", "🥬"], ["greens", "🥬"], ["salad", "🥗"], ["carrot", "🥕"], ["potato", "🥔"], ["tomato", "🍅"], ["onion", "🧅"], ["bean", "🫘"], ["lentil", "🫘"],
    ["apple", "🍎"], ["fruit", "🍎"], ["berry", "🫐"], ["pear", "🍐"], ["grape", "🍇"],
    ["cheese", "🧀"], ["milk", "🥛"], ["dairy", "🥛"], ["butter", "🧈"], ["egg", "🥚"], ["yogurt", "🥛"],
    ["salmon", "🐟"], ["fish", "🐟"], ["meat", "🥩"], ["chicken", "🍗"], ["sausage", "🌭"],
    ["honey", "🍯"], ["jam", "🍯"], ["sugar", "🍬"], ["salt", "🧂"], ["oil", "🫒"], ["olive", "🫒"],
    ["tea", "🍵"], ["coffee", "☕"], ["beer", "🍺"], ["wine", "🍷"], ["juice", "🧃"], ["water", "💧"],
    ["meal", "🍲"], ["soup", "🍲"], ["stew", "🍲"], ["pizza", "🍕"], ["cake", "🍰"],
    ["bicycle", "🚲"], ["bike", "🚲"], ["car", "🚗"], ["bus", "🚌"], ["train", "🚆"], ["boat", "⛵"], ["ride", "🚲"], ["seat", "💺"],
    ["coat", "🧥"], ["jacket", "🧥"], ["shirt", "👕"], ["dress", "👗"], ["trouser", "👖"], ["jeans", "👖"], ["shoe", "👟"], ["boot", "🥾"], ["sock", "🧦"], ["hat", "🧢"], ["scarf", "🧣"], ["glove", "🧤"], ["fabric", "🧵"], ["cloth", "🧵"], ["wool", "🧶"], ["yarn", "🧶"],
    ["chair", "🪑"], ["table", "🪑"], ["bed", "🛏"], ["berth", "🛏"], ["sofa", "🛋"], ["lamp", "💡"], ["shelf", "🗄"], ["cupboard", "🗄"],
    ["house", "🏠"], ["room", "🚪"], ["shelter", "🏠"], ["dwelling", "🏠"], ["tent", "⛺"],
    ["oven", "🔥"], ["stove", "🔥"], ["firewood", "🪵"], ["wood", "🪵"], ["timber", "🪵"], ["fuel", "⛽"], ["electric", "⚡"], ["energy", "⚡"], ["solar", "☀️"], ["battery", "🔋"],
    ["hammer", "🔨"], ["saw", "🪚"], ["tool", "🔧"], ["wrench", "🔧"], ["drill", "🛠"], ["nail", "🔩"], ["screw", "🔩"],
    ["soap", "🧼"], ["towel", "🧻"], ["toothbrush", "🪥"], ["medicine", "💊"], ["medical", "🩺"], ["clinic", "🩺"], ["doctor", "🩺"], ["bandage", "🩹"],
    ["book", "📚"], ["paper", "📄"], ["pen", "🖊"], ["phone", "📱"], ["laptop", "💻"], ["computer", "💻"], ["radio", "📻"],
    ["child", "🧸"], ["toy", "🧸"], ["care", "🤲"],
    ["seed", "🌱"], ["plant", "🌱"], ["compost", "🪱"], ["manure", "💩"], ["hay", "🌾"],
    ["euro", "💶"], ["dollar", "💵"], ["cash", "💵"], ["monero", "🔒"], ["xmr", "🔒"], ["bitcoin", "🪙"], ["coin", "🪙"],
];
const SORTED = TABLE.slice().sort((a, b) => b[0].length - a[0].length);
/** The glyph for NAME (and, second, its classification path), or the box. */
export function emojiFor(name, cats) {
    const hay = [String(name || ""), ...(Array.isArray(cats) ? cats : [String(cats || "")])].join(" ").toLowerCase();
    for (const [k, g] of SORTED)
        if (hay.includes(k))
            return g;
    return "📦";
}
