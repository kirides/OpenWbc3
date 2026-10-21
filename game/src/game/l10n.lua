-- Localised texts: lookups into the install's language files (Game.txt, XCIStrings.txt) with an English fallback,
-- and openwbc3's own texts, the lines the original has no string for (keyed by their English wording; the
-- translations are openwbc3's own, English is used for a language without one).
local config = require("src.core.config")
local strings = require("src.game.strings")

local M = {}

-- Game.txt line `key` ("0308") of the current language.
---@param key string
---@param fallback string
---@return string
function M.game(key, fallback)
    return strings.get("Game.txt", key) or fallback
end

-- XCIStrings.txt string `sub` of resource `id` (read with the interface; headless runs get the fallback).
---@param id integer
---@param sub integer
---@param fallback string
---@return string
function M.xci(id, sub, fallback)
    local ui = package.loaded["src.ui.interface"]
    return ui and ui.ui and ui.text(id, sub) or fallback
end

-- openwbc3's own texts by language, keyed by the English text (format strings keep their placeholders in order)
local OWN = {
    German = {
        -- battle
        ["Your forces are under attack!"] = "Ihre Truppen werden angegriffen!",
        ["Upgraded to %s"] = "Aufgewertet zu %s",
        ["%s reached level %d - click the portrait to spend points, K for spells"] =
            "%s hat Stufe %d erreicht - Porträt anklicken, um Punkte zu verteilen, K für Zaubersprüche",
        ["Found %s"] = "%s gefunden",
        ["Found %d %s"] = "%d %s gefunden",
        ["Treasure!"] = "Ein Schatz!",
        ["Ironman hero lost - the hero is gone"] = "Eisenmann-Held verloren - der Held ist fort",
        ["You have been defeated"] = "Sie wurden besiegt",
        ["Invalid target"] = "Ungültiges Ziel",
        ["No idle builders"] = "Keine untätigen Arbeiter",
        ["Nothing to convert nearby"] = "Hier ist nichts, was umgewandelt werden kann",
        ["Not enough mana"] = "Nicht genug Mana",
        ["Cannot cast now"] = "Kann jetzt nicht zaubern",
        ["Choose a place for %s"] = "Ort für %s wählen",
        ["Choose an enemy for %s"] = "Feind für %s wählen",
        ["Choose a unit for %s"] = "Einheit für %s wählen",
        ["Hero: stats and items (I)"] = "Held: Werte und Gegenstände (I)",
        ["Hero: skills"] = "Held: Fertigkeiten",
        ["Pause (P)"] = "Pause (P)",
        ["Menu (Esc)"] = "Menü (Esc)",
        ["%+d%% Spell Failure"] = "%+d%% Zauberfehlschlag",
        -- game menu
        ["Your hero keeps its experience."] = "Ihr Held behält seine Erfahrung.",
        -- hero
        ["Fallen hero"] = "Gefallener Held",
        ["Your hero has fallen."] = "Ihr Held ist gefallen.",
        -- saving and loading
        ["Saving failed"] = "Speichern fehlgeschlagen",
        ["Loading failed"] = "Laden fehlgeschlagen",
        -- options
        ["Fog of war mode: %s"] = "Kriegsnebel-Modus: %s",
        ["Modern"] = "Modern",
        ["Classic"] = "Klassisch",
        ["Loading failed: %s"] = "Laden fehlgeschlagen: %s",
        ["No saved games for this hero"] = "Keine gespeicherten Spiele für diesen Helden",
        -- main menu, cutscenes
        ["Tutorial scenario not found"] = "Tutorial-Szenario nicht gefunden",
        ["Not implemented yet"] = "Noch nicht umgesetzt",
        ["Press any key to skip"] = "Taste drücken zum Überspringen",
        -- campaign map
        ["Open the campaign menu."] = "Das Kampagnenmenü öffnen.",
        ["Finish Campaign"] = "Kampagne beenden",
        ["End the campaign and see the credits."] = "Die Kampagne beenden und den Abspann ansehen.",
        ["Finish the Campaign?"] = "Kampagne beenden?",
        ["You have completed every mission. Do you wish to finish the campaign now?"] =
            "Sie haben alle Missionen erfüllt. Möchten Sie die Kampagne jetzt beenden?",
        ["You have finished all but %d of the campaign's missions. Do you wish to finish the campaign now?"] =
            "Ihnen fehlen noch %d Missionen der Kampagne. Möchten Sie die Kampagne jetzt beenden?",
        ["Finish"] = "Beenden",
        ["Keep Playing"] = "Weiterspielen",
        ["You cannot afford the entry fee."] = "Sie können sich die Gebühr nicht leisten.",
        ["Train"] = "Ausbilden",
        ["Nobody is looking for work today."] = "Heute sucht niemand Arbeit.",
        ["You receive:"] = "Sie erhalten:",
        ["Journal"] = "Tagebuch",
        ["Nothing has been written yet."] = "Bisher wurde nichts geschrieben.",
        ["Newer"] = "Neuer",
        ["Older"] = "Älter",
        ["Experience %d / %s"] = "Erfahrung %d / %s",
        ["Unspent points: attributes %d, skills %d"] = "Freie Punkte: Attribute %d, Fertigkeiten %d",
        ["You travel alone."] = "Sie reisen allein.",
        ["Stash (click to take)"] = "Gepäck (anklicken zum Nehmen)",
        ["Backpack (click to store)"] = "Rucksack (anklicken zum Verstauen)",
        ["Your answer is noted."] = "Ihre Antwort wurde vermerkt.",
        ["Your training is complete."] = "Ihre Ausbildung ist abgeschlossen.",
        ["A new recruit joins your retinue."] = "Ein neuer Rekrut schließt sich Ihrem Gefolge an.",
        ["You cannot travel there directly."] = "Dorthin können Sie nicht direkt reisen.",
    },
}

-- An own text in the current language (`en` itself when there is no translation).
---@param en string
---@return string
function M.own(en)
    local t = OWN[config.language]
    return t and t[en] or en
end

return M
