// The desk's language, as ReDesk's Settings › Language says (English or Japanese): the side buttons are
// written in it. ReDesk keeps it (read at start, `desk_language`) and says when it changes (a `language`
// event from src-tauri's listen_for_desk_language). A word not here stays in English.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

const japanese: Record<string, string> = {
	// four characters each, as the English words are four letters
	TERM: '端末画面',
	HOMO: '人と話す',
	CHAT: '人工知能',
	FULL: '全画面化',
	NEW: '新規作成',
};

// the longer words: the line to type, the conversations
const japaneseText: Record<string, string> = {};

export const language = $state({ japanese: false });

// The language turning, as on a departures board: each letter runs through others (Latin and katakana)
// before it stops at its new one, the first soonest, the next a little later (as ReDesk's corner words).
const POOL = [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'];
const STEP = 55, SETTLE = 260, STAGGER = 110, LENGTH = 1200;
const flap = $state({ frame: -1 });

/** a button's word in the desk's language; `as` names it where the same word means another thing (NEW TAB) */
export function t(word: string, as?: string): string {
	const target = language.japanese ? (japanese[as ?? word] ?? word) : word;
	const frame = flap.frame;
	if (frame < 0) return target;
	const elapsed = frame * STEP;
	return [...target]
		.map((letter, i) => {
			if (letter === ' ' || elapsed >= SETTLE + i * STAGGER) return letter;
			let hash = frame * 31 + i * 17;
			for (const c of as ?? word) hash = (hash * 33 + c.charCodeAt(0)) | 0;
			return POOL[Math.abs(hash) % POOL.length];
		})
		.join('');
}

/** the popups' words (any length) in the desk's language; {name} in them is filled from `values` */
export function tx(text: string, values?: Record<string, string | number>): string {
	let out = language.japanese ? (japaneseText[text] ?? text) : text;
	if (values) for (const [key, value] of Object.entries(values)) out = out.replaceAll(`{${key}}`, String(value));
	return out;
}

let flapTimer: ReturnType<typeof setInterval> | null = null;
function turn() {
	if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
	if (flapTimer) clearInterval(flapTimer);
	flap.frame = 0;
	flapTimer = setInterval(() => {
		if ((flap.frame + 1) * STEP > LENGTH) {
			flap.frame = -1;
			clearInterval(flapTimer!);
			flapTimer = null;
		} else flap.frame++;
		repaint();
	}, STEP);
}

// WebKit leaves upright vertical words in a see-through window as they were painted, though their text has
// changed: each frame (and the last, after the words have settled) the buttons are told to paint again
// (app.css: html[data-flap] changes nothing to look at)
function repaint() {
	const root = document.documentElement;
	root.dataset.flap = root.dataset.flap === '1' ? '0' : '1';
	if (flap.frame < 0) requestAnimationFrame(() => requestAnimationFrame(() => delete root.dataset.flap));
}

function set(code: string, animate = false) {
	const japanese = code === 'ja';
	if (animate && japanese !== language.japanese) turn();
	language.japanese = japanese;
	document.documentElement.lang = language.japanese ? 'ja' : 'en';
}

/** once, at start: the language ReDesk keeps, and its word when it changes */
export function followDeskLanguage() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<string>('desk_language').then(set).catch(() => {});
	listen<string>('language', e => set(e.payload, true));
}
