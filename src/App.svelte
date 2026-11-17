<script lang="ts">
	// ReTerm: the paper is the terminal, nothing else on it. The user's login shell runs in a
	// pseudo-terminal (src-tauri/src/pty.rs); xterm.js draws it here in the paper's ink. When the shell
	// ends, the window closes.
	import { onMount } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { getCurrentWebview } from '@tauri-apps/api/webview';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import { Terminal, type ITheme } from '@xterm/xterm';
	import { FitAddon } from '@xterm/addon-fit';
	import { Unicode11Addon } from '@xterm/addon-unicode11';
	import WindowControls from './lib/WindowControls.svelte';

	const FONT = "'M PLUS 1 Code', Menlo, monospace";
	const SIZE_KEY = 'font-size';
	const SIZES = { min: 9, max: 28, plain: 14 };

	let host: HTMLDivElement | undefined = $state();

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

	/** the theme as the page is now: light, dark or glass (app.css) */
	function theme(): ITheme {
		const root = document.documentElement;
		const glass = root.classList.contains('glass');
		const dark = glass || root.dataset.theme === 'dark';
		const text = getComputedStyle(root).getPropertyValue('--text').trim() || '#474747';
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

	function keptSize() {
		try {
			const n = Number(localStorage.getItem(SIZE_KEY));
			if (n >= SIZES.min && n <= SIZES.max) return n;
		} catch {}
		return SIZES.plain;
	}

	onMount(() => {
		let disposed = false;
		const cleanups: (() => void)[] = [];

		(async () => {
			// measured in its own lettering, not a fallback's
			await Promise.race([document.fonts.load(`14px ${FONT}`), new Promise((done) => setTimeout(done, 1000))]);
			if (disposed || !host) return;

			const term = new Terminal({
				fontFamily: FONT,
				fontSize: keptSize(),
				lineHeight: 1.25,
				cursorBlink: true,
				cursorStyle: 'bar',
				cursorInactiveStyle: 'none',
				allowTransparency: true,
				allowProposedApi: true,
				scrollback: 10000,
				macOptionClickForcesSelection: true,
				theme: theme(),
			});
			const fit = new FitAddon();
			term.loadAddon(fit);
			term.loadAddon(new Unicode11Addon());
			term.unicode.activeVersion = '11';
			term.open(host);
			fit.fit();
			cleanups.push(() => term.dispose());

			const setSize = (n: number) => {
				n = Math.min(SIZES.max, Math.max(SIZES.min, n));
				term.options.fontSize = n;
				try {
					localStorage.setItem(SIZE_KEY, String(n));
				} catch {}
				fit.fit();
			};

			// the Mac's keys a terminal on it is expected to know
			term.attachCustomKeyEventHandler((e) => {
				if (e.type !== 'keydown' || !e.metaKey || e.ctrlKey) return true;
				const send = (data: string) => {
					e.preventDefault();
					invoke('pty_write', { data });
					return false;
				};
				switch (e.key) {
					case 'ArrowLeft':
						return send('\x01'); // the start of the line
					case 'ArrowRight':
						return send('\x05'); // its end
					case 'Backspace':
						return send('\x15'); // the line, gone
					case 'k':
						e.preventDefault();
						term.clear();
						return false;
					case '=':
					case '+':
						e.preventDefault();
						setSize((term.options.fontSize ?? SIZES.plain) + 1);
						return false;
					case '-':
						e.preventDefault();
						setSize((term.options.fontSize ?? SIZES.plain) - 1);
						return false;
					case '0':
						e.preventDefault();
						setSize(SIZES.plain);
						return false;
				}
				// ⌘C, ⌘V, ⌘A… go to the menu, as in any app
				return false;
			});

			const webview = getCurrentWebview();
			const offData = await webview.listen<string>('pty-data', (e) => term.write(e.payload));
			const offExit = await webview.listen('pty-exit', () => getCurrentWindow().close());
			cleanups.push(offData, offExit);
			if (disposed) return cleanups.forEach((f) => f());

			term.onData((data) => invoke('pty_write', { data }));
			term.onResize(({ cols, rows }) => invoke('pty_resize', { cols, rows }).catch(() => {}));
			await invoke('pty_open', { cols: term.cols, rows: term.rows }).catch((err) =>
				term.write(`\r\n${String(err)}\r\n`),
			);

			// the window resized (or tiled by ReDesk): as many characters as now fit
			let frame = 0;
			const resized = new ResizeObserver(() => {
				cancelAnimationFrame(frame);
				frame = requestAnimationFrame(() => fit.fit());
			});
			resized.observe(host);
			cleanups.push(() => resized.disconnect());

			// light and dark, glass and paper: the ink follows
			const recolor = () => (term.options.theme = theme());
			addEventListener('themechange', recolor);
			cleanups.push(() => removeEventListener('themechange', recolor));

			// the window in use: the keys go to the terminal
			const focus = () => term.focus();
			addEventListener('focus', focus);
			cleanups.push(() => removeEventListener('focus', focus));
			term.focus();
		})();

		return () => {
			disposed = true;
			cleanups.forEach((f) => f());
		};
	});
</script>

<WindowControls />

<div class="term" bind:this={host}></div>

<style>
	/* the paper's margins round it, clear of the corner's diamond */
	.term {
		position: fixed;
		inset: 36px 30px 22px 34px;
	}

	.term :global(.xterm) {
		height: 100%;
	}

	.term :global(.xterm-viewport) {
		background: transparent !important;
	}
</style>
