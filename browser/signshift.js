var P = [
  "P",
  "p",
  "℘",
  "𝒫",
  "𝓅",
  "𝔓",
  "𝖕",
  "Ρ",
  "ρ",
  "Р",
  "р",
  "⍴",
  "Ᵽ",
  "ᖘ",
  "ᑸ",
  "ᑹ",
  "Ⓟ",
  "Ꝑ",
  "ꝑ",
  "Ꝓ",
  "ꝓ",
];

var L = [
  "L",
  "l",
  "ℒ",
  "ℓ",
  "𝓛",
  "𝓁",
  "𝔏",
  "𝖑",
  "Լ",
  "լ",
  "ʟ",
  "ɭ",
  "Ĺ",
  "Ļ",
  "Ľ",
  "Ŀ",
  "Ł",
  "ł",
  "ɫ",
  "ɬ",
  "Ꮮ",
  "Ⅼ",
  "ⅼ",
];
var A = [
  "A",
  "a",
  "Á",
  "á",
  "À",
  "à",
  "â",
  "Ä",
  "ä",
  "Å",
  "å",
  "Ā",
  "ā",
  "Ă",
  "ă",
  "Ą",
  "ą",
  "Ⱥ",
  "ⱥ",
  "∀",
  "Α",
  "α",
  "А",
  "а",
  "Ⴀ",
  "@",
  "ɑ",
  "ɒ",
  "Ⰰ",
];
var Y = [
  "Y",
  "y",
  "Ý",
  "ý",
  "Ÿ",
  "ÿ",
  "Ŷ",
  "ŷ",
  "Ȳ",
  "ȳ",
  "Υ",
  "Ү",
  "ү",
  "Ұ",
  "ұ",
  "ʏ",
  "ɏ",
  "𝓨",
  "𝒴",
  "𝓨",
];
var N = [
  "N",
  "n",
  "Ñ",
  "ñ",
  "Ň",
  "ň",
  "Ń",
  "ń",
  "Ņ",
  "ņ",
  "Ŋ",
  "ŋ",
  "Ƞ",
  "ɴ",
  "Ν",
  "ɲ",
  "Ɲ",
  "ɳ",
  "ℕ",
  "𝒩",
  "𝓃",
  "𝓝",
  "𝔑",
  "𝕟",
  "𝖭",
  "𝐍",
  "𝐧",
  "𝑁",
  "𝑛",
];
var E = [
  "E",
  "e",
  "É",
  "é",
  "È",
  "è",
  "Ê",
  "ê",
  "Ë",
  "ë",
  "Ē",
  "ē",
  "Ĕ",
  "ĕ",
  "Ė",
  "ė",
  "Ę",
  "ę",
  "Ě",
  "ě",
  "Ε",
  "ε",
  "Е",
  "е",
  "Ё",
  "ё",
  "Э",
  "э",
  "ℰ",
  "𝓔",
  "𝔈",
  "𝔼",
  "𝕰",
];
var T = [
  "T",
  "t",
  "Ť",
  "ť",
  "Ţ",
  "ţ",
  "Ṫ",
  "ṫ",
  "Ŧ",
  "ŧ",
  "Τ",
  "τ",
  "Т",
  "т",
  "Ŧ",
  "ʇ",
  "ʈ",
  "Ⱦ",
];

var allChars = [P, L, A, Y, N, E, T];
var currentIndexes = [0, 0, 0, 0, 0, 0, 0];

var elements = [
  document.querySelector("#P"),
  document.querySelector("#L"),
  document.querySelector("#A"),
  document.querySelector("#Y"),
  document.querySelector("#N"),
  document.querySelector("#E"),
  document.querySelector("#T"),
];

var PChangeEnabled = true;
var LChangeEnabled = true;
var AChangeEnabled = true;
var YChangeEnabled = true;
var NChangeEnabled = true;
var EChangeEnabled = true;
var TChangeEnabled = true;

function changeRandomCharacters() {
  // First, count how many letters are enabled
  var enabledLetters = [
    PChangeEnabled,
    LChangeEnabled,
    AChangeEnabled,
    YChangeEnabled,
    NChangeEnabled,
    EChangeEnabled,
    TChangeEnabled
  ].filter(Boolean).length;

  // Don't try to change more letters than are enabled
  var numCharsToChange = Math.min(
    Math.floor(Math.random() * enabledLetters) + 1,
    enabledLetters
  );

  var indicesToChange = [];
  var attempts = 0;
  const maxAttempts = 100; // Prevent infinite loops

  while (indicesToChange.length < numCharsToChange && attempts < maxAttempts) {
    attempts++;
    var randomIndex = Math.floor(Math.random() * allChars.length);
    
    // Check if this index is enabled and not already chosen
    if (!indicesToChange.includes(randomIndex) && 
        ((randomIndex === 0 && PChangeEnabled) ||
         (randomIndex === 1 && LChangeEnabled) ||
         (randomIndex === 2 && AChangeEnabled) ||
         (randomIndex === 3 && YChangeEnabled) ||
         (randomIndex === 4 && NChangeEnabled) ||
         (randomIndex === 5 && EChangeEnabled) ||
         (randomIndex === 6 && TChangeEnabled))) {
      indicesToChange.push(randomIndex);
    }
  }

  indicesToChange.forEach(function (index) {
    currentIndexes[index] = changeCharContent(
      allChars[index],
      elements[index],
      currentIndexes[index]
    );
  });
}

function changeCharContent(arr, element, index) {
  element.textContent = arr[index];
  return (index + 1) % arr.length;
}

function changeContent(arr, element, index, changeEnabled) {
  if (!changeEnabled) return index; // Respect the flag
  element.textContent = arr[index];
  return (index + 1) % arr.length;
}

setInterval(changeRandomCharacters, 500);

var genre = [
  "A bottom-up game",
  "An adventure game",
  "A strategy game",
  "A role-playing game",
  "A puzzle game",
  "A network simulation",
  "A journalist investigation game",
  "A street busking rhythm game",
  "A shamanic ritual",
  "A mythical creature management game",
  "A cybernetic quest",
  "A post-rational media theory game",
  "A modular jewelry design game",
  "A cybersecurity challenge",
  "A spiritual health simulation",
  "A tantric bliss journey",
  "A care network builder",
  "A playful fashion design game",
  "A character outfit customization game",
  "A communal living simulation",
  "A portal opening game",
  "A ritual fasting challenge",
  "An exergame",
  "A magical potion crafting game",
  "An ancient artifact discovery game",
  "A spellbook writing game",
  "A divine nonchalance experience",
  "A mythical farm simulation",
  "A festival planning game",
  "A communal feast organization game",
  "A magical realist story game",
  "A spiritual meditation and dancing game",
  "A yoga and wellness game",
  "A post-apocalyptic bunkers survival game",
  "A tree house construction game",
  "A volcanic island exploration game",
  "A castle defense strategy game",
  "A clarification and obfuscation game",
  "A warp zone discovery game",
  "A butterfly-wing-iridescence puzzle game",
  "A subterranean lake adventure",
  "A bioluminescent slime farming game",
  "A secret stairway exploration game",
  "A magical realist narrative game",
  "A dark matter and nebula exploration game",
  "A subterranean city builder",
  "A train-yard management game",
  "A flea market treasure hunt game",
  "A library stacks mystery game",
  "A mythopoetic storytelling game",
  "A unicorn and narwhal sanctuary game",
  "A goblet and doubloon collection game",
  "A gremlin and pixie mischief game",
  "A ritualistic sauna experience",
  "A cauldron and potion brewing game",
  "A holy grail quest",
  "A fragrance and incense crafting game",
  "A fairy tale game",
  "A hyperstitial loom weaving game",
  "A mythical loom crafting game",
  "A spellcasting duel game",
  "A divine intervention and prophecy game",
  "A secret doors and hidden passageways game",
  "A digital efficiency optimization game",
  "A shared subscriptions management game",
  "A mythical creatures alliance",
  "A fiscal intermediary strategy game",
  "An offworld game",
  "A modular living space design game",
  "A pirate game",
  "A cosmic exploration",
  "An iridescent materials crafting game",
  "A microtonal game",
];
var action = [
  "erase the boundaries of",
  "dissolve",
  "build",
  "unite",
  "infiltrate",
  "discover",
  "explore",
  "trade with",
  "mutually stake with",
  "lead the rebels in",
  "make peace with",
  "investigate",
  "rename",
  "collect gold from",
  "collect crystals from",
  "mine concepts from",
  "align",
  "click on",
  "match",
  "throw",
  "toss",
  "fire pellets at",
  "control",
  "touch",
  "stack",
  "guess",
  "memorize",
  "rotate",
  "swap",
  "slide",
  "avoid",
  "drag and drop",
  "tickle",
  "race",
  "challenge",
  "collect",
  "draw",
  "unlock",
  "cook",
  "break",
  "solve puzzles involving",
  "collect",
  "juggle",
  "script",
  "cast",
  "direct",
  "invest",
  "bet",
  "undersee",
  "inspire",
  "motivate",
  "prioritize",
  "align",
  "counter-espionage",
  "innovate",
  "design",
  "evaluate",
  "test",
  "envelope",
  "overwhelm",
  "teleport",
  "curate",
  "instigate",
  "perturb",
  "mismanage",
  "prune",
  "fertilize",
  "catalyze",
  "ritualize",
  "enact",
  "decree",
  "prophecizes",
  "sabotage",
  "legislate",
  "imbue",
  "invoke",
  "evoke",
  "derive",
  "metabolize",
  "breed",
  "feed",
  "pet",
  "touch",
  "summon",
  "visit",
  "dream",
  "conjure",
  "redeems",
  "envelop",
  "extoll",
  "tweak",
  "eviscerate",
  "re-position",
  "re-locate",
  "invite",
  "celebrate",
  "deals (in)",
  "trick",
  "mimic",
  "reflect",
  "echoe",
  "imposterize",
  "dupe",
  "anoint",
  "marry",
  "reconcile",
  "reimagine",
];
var things = [
  "nations",
  "castles",
  "cities",
  "strongholds",
  "towers",
  "dungeons",
  "citadels",
  "kingdoms",
  "unknown worlds",
  "other worlds",
  "parallel worlds",
  "other dimensions",
  "alien worlds",
  "heaven",
  "hell",
  "houses",
  "apartments",
  "mythological places",
  "historical places",
  "islands",
  "sanctuaries",
  "temples",
  "ruins",
  "factories",
  "caves",
  "gems",
  "diamonds",
  "gold nuggets",
  "bricks",
  "bubbles",
  "squares",
  "triangles",
  "treasure",
  "blobs",
  "kitchen appliances",
  "nondescript fruits",
  "animals",
  "birds",
  "baby animals",
  "farm animals",
  "elementals",
  "exotic fruits",
  "sentient plants",
  "your friends",
  "shapes",
  "jewels",
  "letters",
  "words",
  "numbers",
  "tokens",
  "coins",
  "eggs",
  "hats",
  "candy",
  "chocolate",
  "shoes",
  "gnomes",
  "fairies",
  "elves",
  "fools",
  "wizards",
  "princes",
  "princesses",
  "priestesses",
  "the holy grail",
  "goblets",
  "doubloons",
  "hyperstitial looms",
  "unicorns",
  "narwhals",
  "yetis",
  "golems",
  "gremlins",
  "moss people",
  "pixies",
  "blocks",
  "cubes",
  "asteroids",
  "stars",
  "balls",
  "spheres",
  "magnets",
  "riddles",
  "vibes",
  "ancient objects",
  "wands",
  "divine nonchalance",
  "staffs",
  "spellbooks",
  "tomes",
  "maps",
  "poems",
  "item-set bonuses",
  "capes",
  "sewing kits",
  "print-ons",
  "heeleys",
  "charms and enchantments",
  "temporary and non-Temporary Tattoos",
  "stuffed animals",
  "satchels",
  "robes",
  "scepters",
  "candles",
  "fragrances",
  "zests",
  "qualia",
  "creams and ointments",
  "potions",
  "test tubes",
  "vials",
  "cauldrons",
  "alpha",
  "goblets",
  "incense",
  "tents",
  "containers",
  "dwellings",
  "abodes",
  "bunkers",
  "community spaces",
  "caves",
  "tree houses",
  "hypermedia",
  "sailboats",
  "playgrounds",
  "volcanic islands",
  "castles",
  "clubs",
  "venues",
  "bridges",
  "secret wardrobes",
  "farms",
  "ecovillages",
  "cottages",
  "mountains",
  "springs",
  "wells",
  "rivers",
  "creeks",
  "liminal spaces",
  "fountains",
  "oases",
  "waterFalls",
  "glaciers",
];

var goals = [
  `to "win"`,
  "in the name of love",
  "as an end in itself",
  "to win points",
  "to surpass the highscore",
  "to unlock bonus items",
  "to issue tokens",
  "to unlock the next level",
  "to create thriving community",
  "to manage resources effectively",
  "to protect the realm",
  "to open new portals",
  "to reconstruct reality",
  "for economic space agency",
  "for a post-capitalist present",
  "to care for one another",
  "to enter our bliss bodies",
  "to find the others",
  "to revel in the beauty of every moment",
  "to dance organizations into existence",
  "to explore qualia",
  "to go where no one has ever gone before",
  "to defy the odds",
  "to witness more miracles",
  "to unite enchantment and majesty",
  "because reality is our art",
  "to make divine interventions redundant",
];

var allGenres = genre.length,
  allActions = action.length,
  allThings = things.length,
  allGoals = goals.length;

var firstGenre = 0,
  firstAction = 0,
  firstThing = 0,
  firstGoal = 0;

// Flags to indicate if changes should be enabled
let genreChangeEnabled = true;
let actionChangeEnabled = true;
let thingsChangeEnabled = true;
let goalsChangeEnabled = true;

var selectedgenre = document.querySelector("#genre");
var selectedaction = document.querySelector("#action");
var selectedthings = document.querySelector("#things");
var selectedgoals = document.querySelector("#goals");

function setEvents(element, changeFunction, intervalLength) {
  var intervalId;
  intervalId = setInterval(changeFunction, intervalLength);
  // element.addEventListener("mouseenter", function() {
  // });
  // element.addEventListener("mouseleave", function() {
  //   clearInterval(intervalId);
  // });
  // element.addEventListener("touchstart", function() {
  //   clearInterval(intervalId);
  //   changeFunction();
  // });
}

function getRandomArbitrary(min, max) {
  return Math.random() * (max - min) + min;
}
setEvents(
  selectedgenre,
  function () {
    firstGenre = changeContent(
      genre,
      selectedgenre,
      firstGenre,
      genreChangeEnabled
    );
  },
  getRandomArbitrary(3000, 5000)
);
setEvents(
  selectedaction,
  function () {
    firstAction = changeContent(
      action,
      selectedaction,
      firstAction,
      actionChangeEnabled
    );
  },
  getRandomArbitrary(3000, 5000)
);
setEvents(
  selectedthings,
  function () {
    firstThing = changeContent(
      things,
      selectedthings,
      firstThing,
      thingsChangeEnabled
    );
  },
  getRandomArbitrary(3000, 5000)
);
setEvents(
  selectedgoals,
  function () {
    firstGoal = changeContent(
      goals,
      selectedgoals,
      firstGoal,
      goalsChangeEnabled
    );
  },
  getRandomArbitrary(3000, 5000)
);

var selectedgenre = document.querySelector("#genre");
var selectedaction = document.querySelector("#action");
var selectedthings = document.querySelector("#things");
var selectedgoals = document.querySelector("#goals");

const genreElement = document.getElementById("genre");
const actionElement = document.getElementById("action");
const thingsElement = document.getElementById("things");
const goalsElement = document.getElementById("goals");

genreElement.addEventListener("click", () => {
  genreChangeEnabled = !genreChangeEnabled;
  genreElement.classList.toggle("active", !genreChangeEnabled);
  checkAllFrozen();
});

actionElement.addEventListener("click", () => {
  actionChangeEnabled = !actionChangeEnabled;
  actionElement.classList.toggle("active", !actionChangeEnabled);
  checkAllFrozen();
});

thingsElement.addEventListener("click", () => {
  thingsChangeEnabled = !thingsChangeEnabled;
  thingsElement.classList.toggle("active", !thingsChangeEnabled);
  checkAllFrozen();
});

goalsElement.addEventListener("click", () => {
  goalsChangeEnabled = !goalsChangeEnabled;
  goalsElement.classList.toggle("active", !goalsChangeEnabled);
  checkAllFrozen();
});

const PE = document.getElementById("P");
const LE = document.getElementById("L");
const AE = document.getElementById("A");
const YE = document.getElementById("Y");
const NE = document.getElementById("N");
const EE = document.getElementById("E");
const TE = document.getElementById("T");

PE.addEventListener("click", () => {
  PChangeEnabled = !PChangeEnabled;
  PE.classList.toggle("active");
  checkAllFrozen();
});

LE.addEventListener("click", () => {
  LChangeEnabled = !LChangeEnabled;
  LE.classList.toggle("active");
  checkAllFrozen();
});

AE.addEventListener("click", () => {
  AChangeEnabled = !AChangeEnabled;
  AE.classList.toggle("active");
  checkAllFrozen();
});

YE.addEventListener("click", () => {
  YChangeEnabled = !YChangeEnabled;
  YE.classList.toggle("active");
  checkAllFrozen();
});

NE.addEventListener("click", () => {
  NChangeEnabled = !NChangeEnabled;
  NE.classList.toggle("active");
  checkAllFrozen();
});

EE.addEventListener("click", () => {
  EChangeEnabled = !EChangeEnabled;
  EE.classList.toggle("active");
  checkAllFrozen();
});

TE.addEventListener("click", () => {
  TChangeEnabled = !TChangeEnabled;
  TE.classList.toggle("active");
  checkAllFrozen();
});

function countdown() {
  // var count = 6800; // 3 weeks in seconds
  // Instead of a simple countdown, we'll use a fixed reference date
  // This date represents when the countdown should end
  // Let's set it to a date that repeats every 3 weeks from a fixed point
  
  var countdownElement = document.getElementById("countdown"); // get the countdown element

  var countdownInterval = setInterval(function () {
    // Get current date and time
    const now = new Date();
    
    // Use a fixed reference date (January 1, 2024)
    const referenceDate = new Date(2024, 0, 1);
    
    // Calculate total milliseconds since reference date
    const msSinceReference = now.getTime() - referenceDate.getTime();
    
    // Calculate the cycle duration (3 weeks in milliseconds)
    const cycleDuration = 3 * 7 * 24 * 60 * 60 * 1000;
    
    // Calculate where we are in the current cycle
    const msInCurrentCycle = msSinceReference % cycleDuration;
    
    // Calculate remaining time in the cycle
    const msRemaining = cycleDuration - msInCurrentCycle;
    
    // Convert to seconds
    const secondsRemaining = Math.floor(msRemaining / 1000);
    
    // Calculate days, hours, minutes, seconds
    var days = Math.floor(secondsRemaining / (24 * 60 * 60));
    var hours = Math.floor((secondsRemaining % (24 * 60 * 60)) / (60 * 60));
    var minutes = Math.floor((secondsRemaining % (60 * 60)) / 60);
    var seconds = secondsRemaining % 60;

    var mysticalEmojis = [
      "🔮", "🌙", "⚡️", "🧙‍♂️", "🔥", "🌟", "🌈", "🦄", "🧚‍♀️", "🌕",
      "🌑", "🪄", "✨", "☄️", "💫", "👽", "👾", "🛸", "🧞‍♂️", "🧞‍♀️",
      "🧜‍♂️", "🧜‍♀️", "🧝‍♂️", "🧝‍♀️", "🌌", "🌠", "🎇", "🎆", "🧙‍♀️", "🧚‍♂️",
      "🐉", "🐲", "🧸", "🧿", "🪬", "🕉️", "☯️", "🔆", "🌅", "🌄",
      "🏞️", "🏰", "🎠", "🎢", "🔱", "⚛️", "💖", "💗", "💓", "💞",
      "💕", "💟", "❣️", "❤️‍🔥", "❤️‍🩹", "❤️", "🌹", "🌸", "🌺", "🏵️",
      "💐", "💮", "💍", "👑", "🧡", "💛", "💚", "💙", "💜", "🤍",
      "🤎", "🖤", "💝", "💘", "💌", "🪽"
    ];

    // Use consistent indices based on the global time values
    var dayEmoji = mysticalEmojis[days % mysticalEmojis.length];
    var hourEmoji = mysticalEmojis[hours % mysticalEmojis.length];
    var minuteEmoji = mysticalEmojis[minutes % mysticalEmojis.length];
    var secondEmoji =
      seconds >= 10
        ? ["0️⃣", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"][
            Math.floor(seconds / 10)
          ] +
          ["0️⃣", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"][
            seconds % 10
          ]
        : ["0️⃣", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"][seconds % 10];

    countdownElement.textContent =
      dayEmoji + ":" + hourEmoji + ":" + minuteEmoji + ":" + secondEmoji; // display the emojis

    // No need to check for count === 0 as this is a cyclical countdown
    // The countdown will reset automatically at the end of each 3-week cycle
  }, 1000); // update the count every second
}

countdown(); // start the countdown when the page loads

function checkAllFrozen() {
  const allLettersFrozen = !PChangeEnabled && !LChangeEnabled && !AChangeEnabled && 
                          !YChangeEnabled && !NChangeEnabled && !EChangeEnabled && 
                          !TChangeEnabled;
  
  const allWordsFrozen = !genreChangeEnabled && !actionChangeEnabled && 
                        !thingsChangeEnabled && !goalsChangeEnabled;
  
  if (allLettersFrozen && allWordsFrozen) {
    triggerHackerTerminal();
  }
}

function triggerHackerTerminal() {
  const box = document.getElementById('box');
  
  // Immediately hide the symbols
  const symbols = box.querySelectorAll('#genre, #action, #things, #goals, #countdown');
  symbols.forEach(symbol => symbol.style.display = 'none');
  
  // First fade out existing content
  box.style.transition = 'opacity 0.4s ease-out';
  box.style.opacity = '0';
  
  // After fade out, add terminal
  setTimeout(() => {
    box.innerHTML = `
      <div class="terminal-text">
        <span class="terminal-prompt">🌌 > </span>
        <span class="terminal-message">✨ welcome to the subverse 👾</span>
        <div class="terminal-input-line">
          <span class="terminal-prompt">🌌 > </span>
          <span class="terminal-input"></span>
          <span class="terminal-cursor">▊</span>
        </div>
      </div>
    `;
    box.style.opacity = '1';
    
    // Add keyboard listener
    const terminalInput = box.querySelector('.terminal-input');
    const cursor = box.querySelector('.terminal-cursor');
    let inputText = '';
    
    document.addEventListener('keydown', function(e) {
      // Prevent space from scrolling the page
      if (e.key === ' ') {
        e.preventDefault();
      }
      
      if (e.key.length === 1) { // Regular character
        inputText += e.key;
        terminalInput.textContent = inputText;
      } else if (e.key === 'Backspace') {
        inputText = inputText.slice(0, -1);
        terminalInput.textContent = inputText;
      } else if (e.key === 'Enter') {
        // Add new line with previous input
        const newLine = document.createElement('div');
        newLine.innerHTML = `
          <span class="terminal-prompt">🌌 > </span>
          <span class="terminal-text-line">${inputText}</span>
        `;
        cursor.parentElement.before(newLine);
        inputText = '';
        terminalInput.textContent = '';
        
        // Scroll to bottom
        box.scrollTop = box.scrollHeight;
      }
    });
  }, 400);
}
