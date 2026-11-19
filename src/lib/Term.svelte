<script lang="ts">
	// ReTerm: the terminal as a conversation. Each command is a message (on the right, framed), the shell's
	// answer under it, written on the paper in its colours; the line to type is at the bottom (↑ ↓ the
	// commands before, Tab completes). The shell is the user's zsh in a pseudo-terminal
	// (src-tauri/src/pty.rs), its marks (src-tauri/src/zsh) saying where each command starts and ends.
	// A program that takes the whole screen (vim, htop, less…) has the whole window while it runs. Another
	// shell than zsh: a plain terminal. When the shell ends, the window closes.
	// Each session is kept (its commands and their answers as text): ⌘K starts a new one, the ones before
	// are on the left (History), each to go on with (the shell goes to where it was); ⌥↑ / ⌥↓ the one
	// above / below.
	import { onMount, tick } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { getCurrentWebview } from '@tauri-apps/api/webview';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import { Terminal, type ITheme } from '@xterm/xterm';
	import { FitAddon } from '@xterm/addon-fit';
	import { Unicode11Addon } from '@xterm/addon-unicode11';
	import History from './History.svelte';
	import { scrollFade } from './scrollFade';

	// active: TERM is the mode shown (App.svelte); the keys are its only then
	let { active = true }: { active?: boolean } = $props();

	/** the other Re apps' lettering (app.css --font: Noto Sans JP, M PLUS 1p on glass), the terminal's too */
	const font = () => getComputedStyle(document.documentElement).getPropertyValue('--mono').trim() || "'Noto Sans Mono', monospace";
	const SIZE_KEY = 'font-size';
	const SIZES = { min: 9, max: 28, plain: 14 };
	const LINE_HEIGHT = 1.25;

	// the ink's colours: quiet, as the paper's grey is; the night's lighter
	const COLORS = {
		light: {
			black: '#474747', red: '#a5534d', green: '#5f7a52', yellow: '#8c763a',
			blue: '#4f6a87', magenta: '#7d5a7a', cyan: '#4c7b78', white: '#9a9a9a',
			brightBlack: '#8a8a8a', brightRed: '#b8655e', brightGreen: '#6f8c60', brightYellow: '#9f8a4c',
			brightBlue: '#5f7c9a', brightMagenta: '#8f6a8c', brightCyan: '#5d8e8a', brightWhite: '#bdbdbd',
		},
		dark: {
			black: '#3a3a3a', red: '#b0645e', green: '#7f9a70', yellow: '#b09a62',
			blue: '#6f8aa8', magenta: '#9c7a99', cyan: '#6f9c98', white: '#a6a6a6',
			brightBlack: '#666666', brightRed: '#c27a73', brightGreen: '#93ad84', brightYellow: '#c4ae76',
			brightBlue: '#86a0bc', brightMagenta: '#b090ad', brightCyan: '#86b0ac', brightWhite: '#d0d0d0',
		},
	};
	const PALETTE_KEYS = Object.keys(COLORS.light) as (keyof typeof COLORS.light)[];

	function isDark() {
		const root = document.documentElement;
		return root.classList.contains('glass') || root.dataset.theme === 'dark';
	}

	/** the theme as the page is now: light, dark or glass (app.css) */
	function theme(): ITheme {
		const dark = isDark();
		const text = getComputedStyle(document.documentElement).getPropertyValue('--text').trim() || '#474747';
		return {
			...(dark ? COLORS.dark : COLORS.light),
			// the paper (or the glass) shows through
			background: '#00000000',
			foreground: text,
			cursor: text,
			cursorAccent: dark ? '#1d1d1d' : '#f4f4f4',
			selectionBackground: dark ? '#ffffff2e' : '#4747472e',
			scrollbarSliderBackground: '#00000000',
			scrollbarSliderHoverBackground: '#00000000',
			scrollbarSliderActiveBackground: '#00000000',
		};
	}

	/** the palette as CSS variables, for the answers kept as text (--c0 … --c15) */
	function paintPalette() {
		const colors = isDark() ? COLORS.dark : COLORS.light;
		PALETTE_KEYS.forEach((k, i) => document.documentElement.style.setProperty(`--c${i}`, colors[k]));
	}

	function keptSize() {
		try {
			const n = Number(localStorage.getItem(SIZE_KEY));
			if (n >= SIZES.min && n <= SIZES.max) return n;
		} catch {}
		return SIZES.plain;
	}

	// ── what is on the page ──

	interface Block {
		id: number;
		/** what was typed; null: output with no message of its own (a second command of one line) */
		command: string | null;
		/** the answer while it comes: a terminal of its own */
		host: HTMLDivElement | null;
		term: Terminal | null;
		/** its height while it comes, px */
		height: number;
		/** the answer done, kept as text in its colours */
		html: string;
		/** the shell's status when done; null while running */
		status: number | null;
		/** it took the whole window (vim…) */
		fullscreen: boolean;
	}

	let blocks: Block[] = $state([]);
	let nextId = 1;
	/** plain: no marks (another shell than zsh): one terminal, as any */
	let mode: 'starting' | 'chat' | 'plain' = $state('starting');
	/** idle: the shell waits for a command; running: one runs (its answer to its block) */
	let shell: 'idle' | 'running' = $state('idle');
	/** a program has the whole window (the alternate screen) */
	let full = $state(false);
	let fontSize = $state(keptSize());

	let cwd = $state('');
	let home = '';
	let shellPath = '';
	const place = $derived(home && (cwd === home || cwd.startsWith(home + '/')) ? '~' + cwd.slice(home.length) : cwd);

	let input = $state('');
	let field: HTMLTextAreaElement | undefined = $state();
	let chat: HTMLDivElement | undefined = $state();
	let fullHost: HTMLDivElement | undefined = $state();
	let hints: string[] = $state([]);

	let history: string[] = [];
	let historyAt = -1;
	let draft = '';

	let screen: Terminal;
	let fit: FitAddon;

	// ── the sessions: this one, live, and the ones before ──

	interface Kept {
		command: string | null;
		html: string;
		status: number | null;
		fullscreen: boolean;
	}
	interface Session {
		id: number;
		started: number;
		last: number;
		/** where it was last: as shown, and the folder (to go back to) */
		place: string;
		cwd?: string;
		blocks: Kept[];
	}
	const SESSIONS = 'sessions';
	const MOST = 100;
	/** what is kept of all of them, at most (localStorage holds a few MB) */
	const ROOM = 2_500_000;
	/** one answer kept, at most: its end */
	const ANSWER = 100_000;

	const begun = Date.now();
	let sessionId = $state(begun);
	let started = $state(begun);
	let past: Session[] = $state([]);

	function storedSessions(): Session[] {
		try {
			const s = JSON.parse(localStorage.getItem(SESSIONS) ?? '[]');
			return Array.isArray(s) ? s : [];
		} catch {
			return [];
		}
	}

	const keptOf = (b: Block): Kept => ({
		command: b.command,
		html: b.html.length > ANSWER ? b.html.slice(b.html.indexOf('\n', b.html.length - ANSWER) + 1) : b.html,
		status: b.status,
		fullscreen: b.fullscreen,
	});

	/** this session written over what is kept (the other windows' sessions kept too) */
	function keepSession() {
		const done = blocks.filter((b) => !b.term && (b.command !== null || b.html));
		const others = storedSessions().filter((p) => p.id !== sessionId);
		let all = others;
		if (done.some((b) => b.command !== null)) {
			all = [{ id: sessionId, started, last: Date.now(), place, cwd, blocks: done.map(keptOf) }, ...others];
		}
		all = all.sort((a, b) => b.last - a.last).slice(0, MOST);
		let json = JSON.stringify(all);
		while (json.length > ROOM && all.length > 1) {
			all = all.slice(0, -1);
			json = JSON.stringify(all);
		}
		try {
			localStorage.setItem(SESSIONS, json);
		} catch {}
		past = all.filter((p) => p.id !== sessionId);
	}

	/** ⌘K: this session kept on the left, a new one begun (a command running goes on in it) */
	function newSession() {
		keepSession();
		blocks = blocks.filter((b) => b.term);
		sessionId = Date.now();
		started = sessionId;
		past = storedSessions().filter((p) => p.id !== sessionId);
		tick().then(() => field?.focus());
	}

	const sessionTitle = (kept: { command: string | null }[], where: string) =>
		(kept.find((b) => b.command !== null)?.command ?? where ?? '~').split('\n')[0].slice(0, 80) || '~';
	const when = (ms: number) => new Date(ms).toLocaleString([], { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

	/** all of them, the newest begun first (one gone on with keeps its place) */
	const listed = $derived(
		[
			{ id: sessionId, started, title: sessionTitle(blocks, place), hint: place },
			...past.map((p) => ({ id: p.id, started: p.started, title: sessionTitle(p.blocks, p.place), hint: `${when(p.started)} · ${p.place}` })),
		].sort((a, b) => b.started - a.started),
	);

	const quote = (path: string) => "'" + path.replace(/'/g, "'\\''") + "'";

	/** a session before, gone on with: its commands and answers here again, the shell where it was
	 * (this one kept on the left; a command running goes on in it) */
	function pick(id: number | string) {
		const session = past.find((p) => p.id === Number(id));
		if (!session) return tick().then(() => field?.focus());
		keepSession();
		const running = blocks.filter((b) => b.term);
		blocks = [
			...session.blocks.map((k) => ({ id: nextId++, command: k.command, host: null, term: null, height: 0, html: k.html, status: k.status, fullscreen: k.fullscreen })),
			...running,
		];
		sessionId = session.id;
		started = session.started;
		past = storedSessions().filter((p) => p.id !== sessionId);
		const folder = session.cwd ?? (session.place.startsWith('~') && home ? home + session.place.slice(1) : session.place);
		// a cd of its own, with no message (its answer, none, not kept)
		if (folder && folder !== cwd && shell === 'idle' && mode === 'chat') send(` cd ${quote(folder)}\r`);
		stickToBottom(true);
		tick().then(() => field?.focus());
	}

	/** ⌥↑ / ⌥↓: the session above / below on the left */
	function step(by: number) {
		const at = listed.findIndex((l) => l.id === sessionId);
		const next = listed[Math.min(listed.length - 1, Math.max(0, at + by))];
		if (next) pick(next.id);
	}

	const send = (data: string) => invoke('pty_write', { data }).catch(() => {});

	// ── the answers kept as text ──

	const escapeHTML = (s: string) => s.replace(/[&<>]/g, (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));

	/** a 256-colour index past the 16: its colour */
	function color256(n: number): string {
		if (n >= 232) {
			const v = 8 + (n - 232) * 10;
			return `rgb(${v},${v},${v})`;
		}
		n -= 16;
		const step = (v: number) => (v ? 55 + v * 40 : 0);
		return `rgb(${step(Math.floor(n / 36))},${step(Math.floor(n / 6) % 6)},${step(n % 6)})`;
	}

	const hex = (n: number) => '#' + n.toString(16).padStart(6, '0');

	/** The terminal's text as HTML: its colours (the 16 by the palette's variables, so they follow light and
	 * dark), bold, dim, italic, underline; lines it wrapped joined again, so the text wraps with the window. */
	function toHTML(term: Terminal): string {
		const buffer = term.buffer.active;
		const cell = buffer.getNullCell();
		const lines: string[] = [];
		for (let y = 0; y < buffer.length; y++) {
			const line = buffer.getLine(y);
			if (!line) continue;
			let html = '';
			let style = '';
			let run = '';
			const flush = () => {
				if (!run) return;
				html += style ? `<span style="${style}">${escapeHTML(run)}</span>` : escapeHTML(run);
				run = '';
			};
			// the text ends at its last character, not the line's
			let end = line.length;
			while (end > 0) {
				line.getCell(end - 1, cell);
				const chars = cell.getChars();
				if ((chars && chars !== ' ') || cell.getWidth() === 0 || !cell.isBgDefault() || cell.isInverse()) break;
				end--;
			}
			for (let x = 0; x < end; x++) {
				line.getCell(x, cell);
				if (cell.getWidth() === 0) continue;
				let fg = '';
				let bg = '';
				if (cell.isFgPalette()) fg = cell.getFgColor() < 16 ? `var(--c${cell.getFgColor()})` : color256(cell.getFgColor());
				else if (cell.isFgRGB()) fg = hex(cell.getFgColor());
				if (cell.isBgPalette()) bg = cell.getBgColor() < 16 ? `var(--c${cell.getBgColor()})` : color256(cell.getBgColor());
				else if (cell.isBgRGB()) bg = hex(cell.getBgColor());
				if (cell.isInverse()) [fg, bg] = [bg || 'var(--bg)', fg || 'var(--text)'];
				let next = '';
				if (fg) next += `color:${fg};`;
				if (bg) next += `background:${bg};`;
				if (cell.isBold()) next += 'font-weight:700;';
				if (cell.isItalic()) next += 'font-style:italic;';
				if (cell.isDim()) next += 'opacity:0.6;';
				if (cell.isUnderline()) next += 'text-decoration:underline;';
				if (cell.isStrikethrough()) next += 'text-decoration:line-through;';
				if (cell.isInvisible()) next += 'visibility:hidden;';
				if (next !== style) {
					flush();
					style = next;
				}
				run += cell.getChars() || ' ';
			}
			flush();
			if (line.isWrapped && lines.length) lines[lines.length - 1] += html;
			else lines.push(html);
		}
		while (lines.length && lines[lines.length - 1] === '') lines.pop();
		while (lines.length && lines[0] === '') lines.shift();
		return lines.join('\n');
	}

	// ── the answers while they come ──

	function newTerminal(rows: number) {
		const term = new Terminal({
			fontFamily: font(),
			fontSize,
			lineHeight: LINE_HEIGHT,
			cols: screen.cols,
			rows,
			cursorBlink: false,
			cursorStyle: 'bar',
			cursorInactiveStyle: 'none',
			allowTransparency: true,
			allowProposedApi: true,
			scrollback: 5000,
			theme: theme(),
		});
		term.loadAddon(new Unicode11Addon());
		term.unicode.activeVersion = '11';
		// its answers to the program's questions (where the cursor is…), and keys typed into it
		term.onData(send);
		return term;
	}

	/** the block now coming: the one waiting for its answer, or a new one */
	function startBlock() {
		let block = blocks.at(-1);
		if (!block || block.status !== null || block.term || block.html) {
			blocks.push({ id: nextId++, command: null, host: null, term: null, height: 0, html: '', status: null, fullscreen: false });
			block = blocks.at(-1)!;
		}
		const host = document.createElement('div');
		host.className = 'live';
		const term = newTerminal(screen.rows);
		block.host = host;
		block.term = term;
		shell = 'running';
		// drawn once it is on the page (it measures its letters there); written to meanwhile
		tick().then(() => {
			if (block.term === term) {
				term.open(host);
				measure(block);
			}
		});
	}

	const current = () => {
		const block = blocks.at(-1);
		return block && block.term ? block : null;
	};

	/** the live answer's height: its lines so far, the window's at most */
	function measure(block: Block) {
		const term = block.term;
		if (!term) return;
		const buffer = term.buffer.active;
		const line = buffer.getLine(buffer.baseY + buffer.cursorY);
		const onEmptyLine = buffer.cursorX === 0 && !line?.translateToString(true);
		const used = buffer.cursorY + (onEmptyLine ? 0 : 1);
		const rows = fullHost?.querySelector('.xterm-screen') as HTMLElement | null;
		const rowHeight = rows && screen.rows ? rows.offsetHeight / screen.rows : Math.round(fontSize * LINE_HEIGHT);
		block.height = Math.max(0, Math.min(term.rows, used)) * rowHeight;
		stickToBottom();
	}

	function finishBlock(status: number) {
		const block = current();
		if (full) leaveFull();
		if (!block) {
			// a command that never had its answer started (an empty line): its message stays
			const last = blocks.at(-1);
			if (last && last.status === null) last.status = status;
			shell = 'idle';
			return;
		}
		const term = block.term!;
		term.write('', () => {
			block.html = toHTML(term);
			block.status = status;
			block.term = null;
			block.host = null;
			term.dispose();
			const words = (block.command ?? '').trim();
			if (words === 'clear' || words === 'reset') newSession();
			else keepSession();
			stickToBottom(true);
		});
		shell = 'idle';
		tick().then(() => field?.focus());
	}

	// ── a program with the whole window ──

	function enterFull() {
		full = true;
		const block = current();
		if (block) block.fullscreen = true;
		screen.reset();
		screen.options.theme = theme();
		tick().then(() => screen.focus());
	}

	function leaveFull() {
		full = false;
		tick().then(() => field?.focus());
	}

	// ── what the shell writes ──

	let pending = '';
	let ready = false;
	let startup = '';

	/** the shell's marks: OSC 133 (A ready, C a command starts, D done), 7 where, 6973 its PATH */
	function mark(body: string) {
		if (body.startsWith('133;')) {
			const [, kind, arg] = body.split(';');
			if (kind === 'A') {
				if (mode === 'starting') {
					mode = 'chat';
					startup = '';
				}
				ready = true;
			} else if (kind === 'C') {
				startBlock();
			} else if (kind === 'D' && ready && shell === 'running') {
				finishBlock(Number(arg) || 0);
			} else if (kind === 'D' && ready) {
				const last = blocks.at(-1);
				if (last && last.status === null && !last.term) last.status = Number(arg) || 0;
			}
		} else if (body.startsWith('7;')) {
			const url = body.slice(2).replace(/^file:\/\/[^/]*/, '');
			cwd = url || cwd;
		} else if (body.startsWith('6973;')) {
			shellPath = body.slice(5);
		}
	}

	const ALT = /\x1b\[\?(?:1049|1047|47)([hl])/;

	/** text for where it goes now: the screen, the live answer, or nowhere (the shell's own prompt) */
	function route(text: string) {
		if (!text) return;
		if (mode === 'plain') return screen.write(text);
		if (mode === 'starting') {
			startup += text;
			return;
		}
		if (shell !== 'running') return;
		while (text) {
			const m = ALT.exec(text);
			const before = m ? text.slice(0, m.index + (m[1] === 'l' ? m[0].length : 0)) : text;
			if (full) screen.write(before);
			else {
				const block = current();
				if (block?.term) {
					const term = block.term;
					term.write(before, () => measure(block));
				}
			}
			if (!m) break;
			if (m[1] === 'h') {
				enterFull();
				screen.write(m[0]);
				text = text.slice(m.index + m[0].length);
			} else {
				leaveFull();
				text = text.slice(m.index + m[0].length);
			}
		}
	}

	/** what the shell wrote: its marks taken out (never cut in two), the rest routed */
	function received(chunk: string) {
		let s = pending + chunk;
		pending = '';
		let i = 0;
		while (i < s.length) {
			const j = s.indexOf('\x1b]', i);
			if (j < 0) {
				route(s.slice(i));
				break;
			}
			const bel = s.indexOf('\x07', j);
			const st = s.indexOf('\x1b\\', j);
			const end = bel < 0 ? st : st < 0 ? bel : Math.min(bel, st);
			if (end < 0) {
				route(s.slice(i, j));
				// the mark goes on in the next piece (a broken one is let through)
				if (s.length - j < 8192) pending = s.slice(j);
				else route(s.slice(j));
				break;
			}
			const length = end === st ? 2 : 1;
			const body = s.slice(j + 2, end);
			if (/^(133;|7;|6973;)/.test(body)) {
				route(s.slice(i, j));
				mark(body);
			} else {
				route(s.slice(i, end + length));
			}
			i = end + length;
		}
	}

	// ── the line to type ──

	function stickToBottom(always = false) {
		if (!chat) return;
		const near = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 80;
		if (always || near) tick().then(() => chat && (chat.scrollTop = chat.scrollHeight));
	}

	function grow() {
		if (!field) return;
		field.style.height = 'auto';
		field.style.height = field.scrollHeight + 'px';
	}

	function setInput(text: string) {
		input = text;
		tick().then(() => {
			grow();
			field?.setSelectionRange(text.length, text.length);
		});
	}

	function submit() {
		const text = input;
		if (shell === 'running' || mode !== 'chat') {
			// to the program running: a line it reads
			send(text + '\r');
			setInput('');
			return;
		}
		if (!text.trim()) return;
		blocks.push({ id: nextId++, command: text, host: null, term: null, height: 0, html: '', status: null, fullscreen: false });
		if (history.at(-1) !== text) history.push(text);
		historyAt = -1;
		setInput('');
		hints = [];
		// more than a line: pasted whole, run as one
		send(text.includes('\n') ? `\x1b[200~${text}\x1b[201~\r` : text + '\r');
		stickToBottom(true);
	}

	async function completeWord() {
		if (!field) return;
		const caret = field.selectionStart;
		const before = input.slice(0, caret);
		const m = /(?:\\.|[^\s\\])*$/.exec(before);
		const word = m ? m[0] : '';
		const head = before.slice(0, before.length - word.length);
		const command = !/\S/.test(head.split(/[|;&]/).at(-1) ?? '');
		const items = await invoke<string[]>('complete', { cwd, word, command, path: shellPath }).catch(() => [] as string[]);
		if (!items.length) return;
		let common = items[0];
		for (const item of items) while (!item.startsWith(common)) common = common.slice(0, -1);
		const done = items.length === 1;
		const put = done && !common.endsWith('/') ? common + ' ' : common;
		const after = input.slice(caret);
		input = head + put + after;
		await tick();
		grow();
		const at = head.length + put.length;
		field.setSelectionRange(at, at);
		hints = done ? [] : items.slice(0, 60).map((item) => item.replace(/\/$/, '').split('/').pop() + (item.endsWith('/') ? '/' : ''));
	}

	function keydown(e: KeyboardEvent) {
		if (e.isComposing) return;
		const running = shell === 'running' || mode !== 'chat';
		if (e.key !== 'Tab') hints = [];
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			submit();
		} else if (e.key === 'Tab' && !running) {
			e.preventDefault();
			completeWord();
		} else if (e.ctrlKey && !e.metaKey && e.key === 'c') {
			e.preventDefault();
			if (running) send('\x03');
			else setInput('');
		} else if (e.ctrlKey && !e.metaKey && e.key === 'd') {
			e.preventDefault();
			if (running || !input) send('\x04');
		} else if (e.ctrlKey && !e.metaKey && e.key === 'z' && running) {
			e.preventDefault();
			send('\x1a');
		} else if ((e.ctrlKey && !e.metaKey && e.key === 'l') || (e.metaKey && e.key === 'k')) {
			e.preventDefault();
			newSession();
		} else if (e.altKey && !e.metaKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
			e.preventDefault();
			step(e.key === 'ArrowUp' ? -1 : 1);
		} else if (e.key === 'ArrowUp' && field && !input.slice(0, field.selectionStart).includes('\n')) {
			if (!history.length) return;
			e.preventDefault();
			if (historyAt < 0) {
				draft = input;
				historyAt = history.length;
			}
			historyAt = Math.max(0, historyAt - 1);
			setInput(history[historyAt]);
		} else if (e.key === 'ArrowDown' && field && historyAt >= 0 && !input.slice(field.selectionEnd).includes('\n')) {
			e.preventDefault();
			historyAt++;
			if (historyAt >= history.length) {
				historyAt = -1;
				setInput(draft);
			} else setInput(history[historyAt]);
		} else if (e.metaKey && !e.shiftKey && (e.key === '=' || e.key === '+' || e.key === '-' || e.key === '0')) {
			e.preventDefault();
			setSize(e.key === '0' ? SIZES.plain : fontSize + (e.key === '-' ? -1 : 1));
		} else if (e.metaKey && !e.shiftKey && e.key === 'ArrowLeft' && field && !input) {
			// nothing typed: as in a terminal, nothing to do
		}
	}

	function setSize(n: number) {
		fontSize = Math.min(SIZES.max, Math.max(SIZES.min, n));
		try {
			localStorage.setItem(SIZE_KEY, String(fontSize));
		} catch {}
		screen.options.fontSize = fontSize;
		for (const b of blocks) if (b.term) b.term.options.fontSize = fontSize;
		refit();
	}

	/** the window's size in characters: the screen's, the shell's and the live answer's */
	function refit() {
		if (!screen) return;
		fit.fit();
		for (const b of blocks) {
			if (b.term && (b.term.cols !== screen.cols || b.term.rows !== screen.rows)) {
				b.term.resize(screen.cols, screen.rows);
				measure(b);
			}
		}
	}

	/** a click on the page (not a selection made): the line to type has the keys */
	function pageClick() {
		if (full || mode === 'plain' || !active) return;
		if (String(getSelection() ?? '')) return;
		field?.focus();
	}

	onMount(() => {
		let disposed = false;
		const cleanups: (() => void)[] = [];
		paintPalette();
		past = storedSessions();

		(async () => {
			// measured in its own lettering, not a fallback's
			await Promise.race([
				Promise.all([document.fonts.load(`14px 'Noto Sans Mono'`), document.fonts.load(`14px 'Noto Sans JP'`), document.fonts.load(`14px 'M PLUS 1p'`)]),
				new Promise((done) => setTimeout(done, 1000)),
			]);
			if (disposed || !fullHost) return;

			screen = new Terminal({
				fontFamily: font(),
				fontSize,
				lineHeight: LINE_HEIGHT,
				cursorBlink: true,
				cursorStyle: 'bar',
				cursorInactiveStyle: 'none',
				allowTransparency: true,
				allowProposedApi: true,
				scrollback: 10000,
				macOptionClickForcesSelection: true,
				theme: theme(),
			});
			fit = new FitAddon();
			screen.loadAddon(fit);
			screen.loadAddon(new Unicode11Addon());
			screen.unicode.activeVersion = '11';
			screen.open(fullHost);
			fit.fit();
			cleanups.push(() => screen.dispose());

			// the Mac's keys a terminal on it is expected to know
			screen.attachCustomKeyEventHandler((e) => {
				if (e.type !== 'keydown' || !e.metaKey || e.ctrlKey) return true;
				const keys: Record<string, string> = { ArrowLeft: '\x01', ArrowRight: '\x05', Backspace: '\x15' };
				if (keys[e.key]) {
					e.preventDefault();
					send(keys[e.key]);
				} else if (e.key === 'k') {
					e.preventDefault();
					screen.clear();
				} else if (['=', '+', '-', '0'].includes(e.key)) {
					e.preventDefault();
					setSize(e.key === '0' ? SIZES.plain : fontSize + (e.key === '-' ? -1 : 1));
				}
				// ⌘C, ⌘V, ⌘A… go to the menu, as in any app
				return false;
			});
			screen.onData(send);

			invoke<string[]>('history').then((h) => (history = h)).catch(() => {});
			invoke<string>('home_dir').then((h) => (home = h)).catch(() => {});

			const webview = getCurrentWebview();
			const offData = await webview.listen<string>('pty-data', (e) => received(e.payload));
			const offExit = await webview.listen('pty-exit', () => getCurrentWindow().close());
			cleanups.push(offData, offExit);
			if (disposed) return cleanups.forEach((f) => f());

			screen.onResize(({ cols, rows }) => invoke('pty_resize', { cols, rows }).catch(() => {}));
			const marked = await invoke<boolean>('pty_open', { cols: screen.cols, rows: screen.rows, chat: true }).catch((err) => {
				screen.write(`\r\n${String(err)}\r\n`);
				return false;
			});
			// no marks, or none in time: a plain terminal, with what the shell wrote meanwhile
			const plain = () => {
				if (mode !== 'starting') return;
				mode = 'plain';
				screen.write(startup);
				startup = '';
				screen.focus();
			};
			if (!marked) plain();
			else setTimeout(plain, 6000);

			// the window resized (or tiled by ReDesk): as many characters as now fit
			let frame = 0;
			const resized = new ResizeObserver(() => {
				cancelAnimationFrame(frame);
				frame = requestAnimationFrame(refit);
			});
			resized.observe(fullHost);
			cleanups.push(() => resized.disconnect());

			// light and dark, glass and paper: the ink follows
			const recolor = () => {
				paintPalette();
				screen.options.theme = theme();
				// on glass and off it, its lettering too
				screen.options.fontFamily = font();
				for (const b of blocks) {
					if (!b.term) continue;
					b.term.options.theme = theme();
					b.term.options.fontFamily = font();
				}
				refit();
			};
			addEventListener('themechange', recolor);
			cleanups.push(() => removeEventListener('themechange', recolor));

			// the window in use: the keys go to the line to type (or the program with the whole window)
			const focus = () => {
				if (!active) return;
				if (full || mode === 'plain') screen.focus();
				else field?.focus();
			};
			addEventListener('focus', focus);
			cleanups.push(() => removeEventListener('focus', focus));
			// typing anywhere goes to the line
			const anyKey = (e: KeyboardEvent) => {
				if (!active || full || mode === 'plain') return;
				if (e.metaKey || e.ctrlKey || e.altKey) return;
				const at = document.activeElement;
				if (at === field || at?.closest('.live')) return;
				field?.focus();
			};
			addEventListener('keydown', anyKey);
			cleanups.push(() => removeEventListener('keydown', anyKey));
			focus();
		})();

		return () => {
			disposed = true;
			cleanups.forEach((f) => f());
		};
	});

	// shown again: the keys come back to it, its size as the area's now
	$effect(() => {
		if (!active) return;
		tick().then(() => {
			refit();
			if (full || mode === 'plain') screen?.focus();
			else field?.focus();
		});
	});
</script>

<!-- svelte-ignore a11y_click_events_have_key_events -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="page" class:hidden={!active || full || mode !== 'chat'} style="--size: {fontSize}px;" onclick={pageClick}>
	<h1 class="shown-title">{sessionTitle(blocks, place)}</h1>
	<History items={listed} shown={sessionId} {pick} />
	<div class="talk">
	<div class="chat" bind:this={chat} use:scrollFade>
		{#each blocks as block (block.id)}
			{#if block.command !== null}
				<div class="said" class:running={block.status === null}>{block.command}</div>
			{/if}
			{#if block.host}
				<div class="answer live-box" style="height: {block.height}px;" {@attach (el) => { el.appendChild(block.host!); }}></div>
			{:else if block.html}
				<pre class="answer">{@html block.html}</pre>
			{:else if block.fullscreen}
				<p class="note">⋯</p>
			{/if}
			{#if block.status !== null && block.status !== 0}
				<p class="status">✕ {block.status}</p>
			{/if}
		{/each}
	</div>

	<div class="type">
		{#if hints.length}
			<div class="hints">{#each hints as hint}<span>{hint}</span>{/each}</div>
		{/if}
		<p class="where">{place}{#if shell === 'running'}<span class="busy"> ⋯</span>{/if}</p>
		<textarea
			bind:this={field}
			bind:value={input}
			rows="1"
			spellcheck="false"
			autocomplete="off"
			autocapitalize="off"
			oninput={grow}
			onkeydown={keydown}
		></textarea>
	</div>
	</div>
</div>

<div class="screen" class:shown={active && (full || mode === 'plain')} class:wide={mode === 'plain'} bind:this={fullHost}></div>

<style>
	/* the area between the side buttons, or the whole window (FULL): App.svelte's --area */
	.page {
		position: fixed;
		inset: var(--area);
		display: flex;
		font-family: var(--font);
		font-size: var(--size);
		line-height: 1.25;
	}

	/* the conversation's column, right of the history: the program with the whole window has it too */
	.screen {
		position: fixed;
		inset: var(--top) var(--right) var(--bottom) calc(var(--left) + var(--list));
	}

	/* a plain terminal (another shell than zsh): no history beside it, the whole area */
	.screen.wide {
		inset: var(--area);
	}

	.talk {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}


	.page.hidden {
		visibility: hidden;
	}

	/* the program with the whole window, and the measure of the window in characters meanwhile */
	.screen {
		visibility: hidden;
		pointer-events: none;
	}

	.screen.shown {
		visibility: visible;
		pointer-events: auto;
	}

	.screen :global(.xterm),
	.live-box :global(.xterm) {
		height: 100%;
	}

	.screen :global(.xterm-viewport),
	.live-box :global(.xterm-viewport) {
		background: transparent !important;
	}

	.chat {
		flex: 1;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-bottom: 12px;
		/* the newest at the bottom, as a conversation */
		justify-content: flex-start;
	}

	.chat > :first-child {
		margin-top: auto;
	}

	/* what was typed: a message on the right */
	.said {
		align-self: flex-end;
		max-width: 80%;
		margin-top: 8px;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		user-select: text;
		cursor: text;
	}

	.said.running {
		animation: breathe 1.6s ease-in-out infinite;
	}

	@keyframes breathe {
		50% {
			opacity: 0.4;
		}
	}

	/* the answer: on the paper, as written, in the terminal's lettering (its columns stand) */
	.answer {
		align-self: stretch;
		margin: 0;
		font: inherit;
		font-family: var(--mono);
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		user-select: text;
		cursor: text;
	}

	.live-box {
		overflow: hidden;
		flex-shrink: 0;
	}

	.note,
	.status {
		font-size: 0.85em;
		opacity: 0.5;
	}

	.status {
		margin-top: -6px;
	}

	.type {
		flex-shrink: 0;
		padding-top: 6px;
	}

	.where {
		font-size: 0.8em;
		opacity: 0.5;
		margin-bottom: 4px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.busy {
		animation: breathe-text 1.6s ease-in-out infinite;
	}

	@keyframes breathe-text {
		50% {
			opacity: 0.2;
		}
	}

	.hints {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 18px;
		margin-bottom: 8px;
		font-size: 0.85em;
		opacity: 0.6;
		max-height: 8em;
		overflow: hidden;
	}

	textarea {
		display: block;
		width: 100%;
		max-height: 40vh;
		resize: none;
		border: none;
		border-bottom: 2px solid var(--line);
		padding: 4px 0 8px;
		background: transparent;
		color: var(--text);
		caret-color: var(--text);
		font: inherit;
		outline: none;
		overflow-y: auto;
	}

	:global(html.glass) textarea {
		border-bottom-width: 1px;
	}
</style>
