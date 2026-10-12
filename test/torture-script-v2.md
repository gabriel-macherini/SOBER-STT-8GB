# Manual torture script v2 (PT-BR, ~2 min)

Same protocol as v1: read aloud in **one** hold, paste into Notepad, then
compare. `raw` vs `text` land in `%TEMP%\opencode-stt.last.json`.

## BASE TEXT (read aloud)

> Vamos testar os limites com o checklist da revisão do firmware, dois
> pontos. Primeiro, compilar o heartbeat e conferir o Serial com o monitor
> em cento e quinze mil e duzentos baud. Segundo, rodar o I2C scan e anotar
> os endereços do BH1750 e do BMP280 no README. Terceiro, trocar todo delay
> por millis com timestamp no log e nível de debug. Quarto, desenhar o menu
> no TFT com backlight em PWM e destacar o item selecionado em amber.
> Quinto, calibrar o LD2410 e publicar presença via MQTT com retain e QoS
> um. Sexto, acionar o relay e medir a corrente de pico com o multimeter na
> escala de dez ampères. Sétimo, gravar o Jason de configuração na flash com
> checksum CRC32. Oitavo e último, fazer o upload over the air e confirmar o
> reboot pelo watchdog. Preciso de um arquivo com esse checklist porque o
> item um é o mais crítico e o item dois depende do pullup do SDA e do SCL.
> Tipo assim, o get revisou o sink do bullion ontem, né? O cash do dotter
> expirou, o rap do endpoint quebrou o build e os locks encheram o disco. A
> versão 2.0 saiu ontem com o changelog em markdown. Abre o SystemTray com
> Caps Lock, segura o Control e aperta Enter para colar. Além disso eu quero
> saber três coisas. Um, quanto ele aguenta de espaço e tempo numa fala
> longa. Dois, como fica quando eu misturo Cloud, System e pipeline no meio
> da frase. Três, como ele finaliza quando eu termino com uma pergunta?

## What each trap checks

| # | Trap | Expected |
|---|---|---|
| 1 | 8 coherent firmware items, ordinals + glued `e` | 8 numbered items, one per line, domain terms intact |
| 2 | Heavy EN load (Serial, I2C, BH1750, MQTT, QoS, CRC32, watchdog…) | Exact terms, untranslated |
| 3 | `QoS um` (value, not an item) | Stays inline as `QoS 1`, never a new item |
| 4 | `item um` / `item dois` references | Whole, no phantom breaks |
| 5 | Homophone burst (Jason, cash, dotter, rap, locks, get, bullion, sink) | JSON, cache, docker, wrap, logs, GET/Git, boolean, sync |
| 6 | Fillers (`Tipo assim`, `né`) | Removed |
| 7 | `versão 2.0` (twice, prose) | Never split |
| 8 | Second mini-list (3 meta questions) + closing `?` | 3 items, question marks kept |
| 9 | One hold, ~2 min | No truncation (`maxTokens` scales with length) |
