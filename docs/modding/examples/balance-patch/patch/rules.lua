-- Rule numbers are settings; the economy reads them when the content has been built. A mine of level 0 produces 2 instead of 1.
content.setting:patch("eco.mineProduce", { value = { [0] = 2, 2, 4 } })
