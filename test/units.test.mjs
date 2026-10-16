// Unit tests for the pure pipeline functions (M2). Zero deps: node --test.
// Fixtures come from real dictation shapes; the 1.0.1 regression cases
// (accent-less FR routed to EN, "mostra os locks" routed to EN) are locked.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  detectLang,
  detectListTrigger,
  heuristicPostClean,
  splitChunks,
  STT_SYSTEM_PROMPT,
} from "../lib/stt.js";

const ROOT = path.dirname(fileURLToPath(import.meta.url));

describe("detectLang", () => {
  it("defaults to en on plain English", () => {
    assert.equal(detectLang("send the report by three pm"), "en");
  });
  it("routes accent-less PT tech sentences to pt (1.0.1 regression)", () => {
    assert.equal(detectLang("mostra os locks do servidor"), "pt");
    assert.equal(detectLang("aperta entre para confirmar"), "pt");
  });
  it("scores PT function words and accents", () => {
    assert.equal(detectLang("você precisa ver isso aqui"), "pt");
    assert.equal(detectLang("preciso que você mande o resumo"), "pt");
  });
  it("routes accent-less French to fr (1.0.1 regression)", () => {
    assert.equal(detectLang("merci fais ca sans accent"), "fr");
    assert.equal(detectLang("je veux une liste deux points pain lait"), "fr");
  });
  it("lets FR win when both sides have markers", () => {
    assert.equal(detectLang("que veux tu faire avec ca"), "fr");
  });
});

describe("detectListTrigger", () => {
  it("treats a literal colon + content as the strongest cue", () => {
    assert.equal(detectListTrigger("quero uma lista: pão queijo"), ":");
  });
  it("matches PT cues", () => {
    assert.equal(detectListTrigger("em forma de lista pão queijo"), "em forma de lista");
    assert.equal(detectListTrigger("quero uma lista dois pontos pão"), "dois pontos");
    assert.equal(detectListTrigger("enumera os itens por favor"), "enumera");
  });
  it("matches EN cues", () => {
    assert.equal(detectListTrigger("shopping list: milk bread"), ":");
    assert.equal(detectListTrigger("shopping list colon milk bread"), "colon");
    assert.equal(detectListTrigger("enumerate the cows please"), "enumerate");
  });
  it("matches FR cues with or without accents/hyphen", () => {
    assert.equal(detectListTrigger("liste deux points pain lait"), "deux points");
    // "liste" matches before the longer "sous forme de liste": either cue
    // is a valid list announcement for the prompt.
    assert.equal(detectListTrigger("sous forme de liste pain lait"), "liste");
  });
  it("returns empty for prose", () => {
    assert.equal(detectListTrigger("send the report by three pm"), "");
  });
});

describe("heuristicPostClean", () => {
  it("fixes code homophones", () => {
    assert.match(heuristicPostClean("Jason precisa do sink"), /JSON.*sync/);
    assert.match(heuristicPostClean("mostra os locks"), /logs/);
    assert.match(heuristicPostClean("limpa o cash do dotter"), /cache.*docker/);
  });
  it("removes fillers but keeps PT 'um' (article/numeral)", () => {
    assert.equal(heuristicPostClean("tipo assim um arquivo", "pt"), "Um arquivo.");
    assert.doesNotMatch(heuristicPostClean("um arquivo", "pt"), /^ arquivo/);
  });
  it("turns 'né?' into a sentence break", () => {
    // Only the first letter is capitalized (LLM output is already cased;
    // the heuristic only guarantees the break itself).
    assert.equal(heuristicPostClean("ontem, né? vamos", "pt"), "Ontem. vamos.");
  });
  it("ends sentences with a period and capitalizes", () => {
    assert.equal(heuristicPostClean("manda o resumo"), "Manda o resumo.");
  });
  it("converts ordinal markers into a digit list", () => {
    const out = heuristicPostClean("Primeiro, subir. Segundo, descer.", "pt");
    assert.match(out, /1\. subir/);
    assert.match(out, /2\. descer/);
  });
  it("never breaks 'item N' references", () => {
    assert.doesNotMatch(heuristicPostClean("vai para o item 1 agora", "pt"), /\n1\./);
  });
});

describe("splitChunks", () => {
  it("keeps short dictations whole", () => {
    const pieces = splitChunks("Manda o resumo da reunião de ontem por favor.");
    assert.equal(pieces.length, 1);
    assert.equal(pieces[0].isList, false);
  });
  it("splits long prose around ~40 words (at sentence boundaries)", () => {
    // Sentences are atomic: one 100-word sentence stays whole, ten
    // 12-word sentences split into 2+ pieces.
    const oneSentence = Array.from({ length: 100 }, (_, i) => `palavra${i}`).join(" ") + ".";
    assert.equal(splitChunks(oneSentence).length, 1);
    const many = Array.from({ length: 10 }, (_, i) => `Esta é a frase número ${i} com palavras suficientes`).join(". ") + ".";
    const pieces = splitChunks(many);
    assert.ok(pieces.length >= 2, `expected 2+ pieces, got ${pieces.length}`);
    for (const p of pieces) assert.ok(p.text.trim().length > 0);
  });
  it("marks pieces and never splits a list region", () => {
    const filler = (s) => `Isto é enchimento ${s} para passar das quarenta palavras sem lista alguma.`;
    const text = [filler("um"), filler("dois"), "Quero uma lista dois pontos. Um pão. Dois queijo. Três presunto.", filler("três"), filler("quatro")].join(" ");
    const pieces = splitChunks(text);
    const listPieces = pieces.filter((p) => p.isList);
    assert.equal(listPieces.length, 1);
    assert.match(listPieces[0].text, /Um pão/);
    assert.match(listPieces[0].text, /Três presunto/);
  });
});

describe("prompt sync (B8)", () => {
  it("lib fallback matches the canonical .md (doc block stripped)", () => {
    const md = fs
      .readFileSync(path.join(ROOT, "../prompts/stt-system-prompt.md"), "utf8")
      .replace(/\r\n/g, "\n")
      .replace(/^<!--[\s\S]*?-->\s*/, "")
      .replace(/\s+$/, "");
    assert.equal(STT_SYSTEM_PROMPT, md);
  });
});
