// the side buttons' lettering, as the other Re apps'
import '@fontsource/noto-sans-jp/400.css';
// the terminal's answers: Noto of one width
import '@fontsource/noto-sans-mono/400.css';
import '@fontsource/noto-sans-mono/700.css';
import '@fontsource/noto-sans-jp/700.css';
// glass's lettering, as the other Re apps'
import '@fontsource/m-plus-1p/400.css';
import '@fontsource/m-plus-1p/700.css';
import '@xterm/xterm/css/xterm.css';
import './app.css';
import { followDeskGlass } from './lib/glass';
import { followDeskLanguage } from './lib/lang.svelte';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { mount } from 'svelte';
import App from './App.svelte';

const app = mount(App, { target: document.getElementById('app')! });

// drawn, with its fonts (or not later than 300 ms): the window fades in (it starts hidden)
Promise.race([document.fonts.ready, new Promise((done) => setTimeout(done, 300))]).then(() => invoke('window_ready'));

// ⌘N: another window (src-tauri/src/lib.rs, new_window), ⌘W: this one closes; before the terminal's own keys
window.addEventListener(
	'keydown',
	(e) => {
		if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey && e.code === 'KeyN') {
			e.preventDefault();
			e.stopImmediatePropagation();
			invoke('new_window');
		} else if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey && e.code === 'KeyW') {
			// ⌘W: this window closes (it fades out: lib.rs, fade_on_close), and its shell with it
			e.preventDefault();
			e.stopImmediatePropagation();
			getCurrentWindow().close();
		}
	},
	true,
);

export default app;

// the side buttons in the desk's language (ReDesk › Settings › Language)
followDeskLanguage();
// the window as glass, when ReDesk says so (Settings › Glass windows)
followDeskGlass();
