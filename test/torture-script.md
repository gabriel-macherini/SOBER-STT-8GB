# Manual torture script (PT-BR)

Read the BASE TEXT aloud in **one** hold (tests duration + long input).
Paste into Notepad, then compare against this file: `raw` vs `text` land in
`%TEMP%\sober-stt.last.json` after every dictation.

## BASE TEXT (read aloud)

> Quero uma lista de compras, dois pontos. Um, café e dois pães. Dois,
> Jason de configuração. Três, revisar o cash e quatro, testar o async.
> Quinto, locks do dotter. Sexto, Enter e Caps Lock. Sétimo e último,
> versão 2.0 do app. Preciso de um arquivo. Texto um vai pro item um
> e texto dois pro item dois. Tipo assim, abre o SystemTray, clica com
> o control e aperta Enter, né? O get mandou um sink com bullion e um
> rap pro endpoint. A versão 2.0 saiu ontem. Abre o item 1 e me mostra.

## What each trap checks

| # | Trap | Expected |
|---|---|---|
| 1 | Preamble + 7-item mixed list (words, ordinals, glued `e`) | Intro line kept, 7 numbered items, one per line |
| 2 | `café e dois pães` inside item 1 | **Known risk:** safety net may over-split into a phantom item. Model should ideally keep it whole |
| 3 | Homophone burst (`Jason`, `cash`→cache, `async`, `locks`→logs, `dotter`→docker) | JSON, cache, async, logs, docker |
| 4 | `Enter`/`Caps Lock`/`SystemTray`/`control`→Control inside PT | Exact EN terms, capitalized, untranslated |
| 5 | Fillers (`Tipo assim`, `né`) | Removed |
| 6 | `um` as article (`um arquivo`) vs number (`Texto um`, `item um`) | Article kept, numbers become markers |
| 7 | Non-list numbers (`versão 2.0`, `item 1`) | Never split, never listed |
| 8 | Whole thing in one hold (~60–75 s) | No truncation (qwen `maxTokens` scales with length) |
