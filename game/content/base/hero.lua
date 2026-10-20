-- The numbers of hero progression (docs/data-driven/04-heroes-abilities-rules.md 4.1) as settings; hero.lua reads them when it loads.
-- They are the original's wherever docs/hero.md could verify them (the game binary's hero stat, bonus, skill effect and experience
-- functions, the potions of FUN_0054fd50 and the regeneration of FUN_0051b460 / FUN_0051b580; the kill experience is not traced in the
-- 1.04 binary yet); what is not original is flagged `own`.
return {
    ---@param content Content
    define = function(content)
        local function setting(id, value, doc, own) content.setting:add({ id = id, value = value, doc = doc, own = own }) end
        setting("hero.maxLevel", 999, "the level cap (the level gain FUN_00455b40 stops at 999)")
        setting("hero.attrPoints", 1, "attribute points per level (the original gives 1 stat and 1 skill point)")
        setting("hero.skillPoints", 1, "skill points per level")
        setting("hero.packSize", 4, "a hero holds 11 items = 7 worn + 4 backpack")
        setting("hero.baseAttr", { str = 5, dex = 5, int = 5, cha = 5 }, "the attributes of a new hero before the race and class modifiers")
        setting("hero.startPotions", 4, "every hero starts a battle with four of each potion (the hero stat builder FUN_0054fd50)")
        setting("hero.maxPotions", 9, "at most nine of each potion")
        setting("hero.xpTable", {
            [0] = 0, 10, 50, 100, 200, 400, 800, 1200, 1600, 2000, 2500,
            3000, 3500, 4000, 4500, 5000, 6000, 7000, 8000, 9000, 10000,
            11000, 12000, 13000, 14000, 15000, 16000, 17000, 18000, 19000, 20000,
            22000, 24000, 26000, 28000, 30000, 32000, 34000, 36000, 38000, 40000,
            43000, 46000, 49000, 52000, 55000, 58000, 61000, 64000, 67000, 70000,
        },
            "total experience for level n + 1 (table at 0x00607070 for levels 1-51, then +4000 a level: FUN_00409ef0)")
        setting("hero.convTime", { [0] = 100, 80, 70, 60, 50, 48, 45, 42, 39, 36, 33,
            32, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12,
            12, 12, 12, 12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10,
            10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 8,
            8, 8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 6,
            6, 6, 6, 6, 6, 6, 6, 6, 6, 5 },
            "conversion time in seconds by conversion rating (table 0x0060782c, FUN_0040ad40; hero rating 8 + level / 2)")
        -- Which classes' items a worn slot takes (item class = Items.bmp row: 0 sword, 1 staff, 2 armour, 3 necklace, 4 shield, 5 ring,
        -- 6 crown, 7 helm, 8 banner, 9 boots, 10 charm). Seven worn slots (the slot rule is not traced in the
        -- 1.04 binary yet).
        setting("hero.slotLayout", {
            { class = 6, classes = { [6] = true, [7] = true }, name = "Crown / Helm" },
            { class = 2, classes = { [2] = true, [3] = true }, name = "Armour / Necklace" },
            { class = 0, classes = { [0] = true, [1] = true }, name = "Sword / Staff" },
            { class = 4, classes = { [4] = true, [8] = true }, name = "Shield / Banner" },
            { class = 5, classes = { [5] = true, [10] = true }, name = "Ring / Charm" },
            { class = 5, classes = { [5] = true, [10] = true }, name = "Ring / Charm" },
            { class = 9, classes = { [9] = true }, name = "Boots" },
        }, "the seven worn slots and the item classes each takes")
        -- the original's attribute bonuses (FUN_0054a6a0 / formula switch FUN_0054a720, total = base + attribute part): functions of the hero's attributes
        setting("hero.bonus", {
            combat = function(a) return 4 + a.str end,
            life = function(a) return 3 * a.str end,
            lifeRegen = function(a) return 1 + math.floor(a.str / 3) end,         -- points per 20 s
            speed = function(a) return 8 + math.floor((a.dex + 1) / 2) end,
            resistance = function(a) return a.dex end,
            armor = function(a) return math.floor(a.dex / 2) end,
            attackSpeed = function(a) return math.min(2 * a.dex - 10, 60) end,      -- percent
            mana = function(a) return 3 * a.int end,
            manaRegen = function(a) return 2 + math.floor(a.int / 10) end,         -- points per 20 s
            morale = function(a) return math.floor(a.cha / 2) end,
            discount = function(a) return -5 + a.cha end,
        }, "the attribute bonus formulas (FUN_0054a720 of the original)")
    end,
}
