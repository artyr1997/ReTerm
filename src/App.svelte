<script lang="ts">
	// ReTerm: three ways to talk, as the other Re apps have their side buttons: TERM the shell, HOMO people
	// (Telegram), CHAT an LLM (claude, codex). Each goes on while another is shown. FULL: the one shown has
	// the whole window, the buttons go (⌘⇧F back).
	import { t } from './lib/lang.svelte';
	import WindowControls from './lib/WindowControls.svelte';
	import Term from './lib/Term.svelte';
	import Homo from './lib/Homo.svelte';
	import Chat from './lib/Chat.svelte';

	type Mode = 'term' | 'homo' | 'chat';
	const KEY = 'view';

	let mode: Mode = $state('term');
	let full = $state(false);
	try {
		const saved = JSON.parse(localStorage.getItem(KEY) ?? 'null');
		if (saved?.mode === 'term' || saved?.mode === 'homo' || saved?.mode === 'chat') mode = saved.mode;
		full = !!saved?.full;
	} catch {}

	$effect(() => {
		document.documentElement.classList.toggle('full', full);
		try {
			localStorage.setItem(KEY, JSON.stringify({ mode, full }));
		} catch {}
	});

	// ⌘⇧T / ⌘⇧H / ⌘⇧C: the three; ⌘⇧F: FULL. Before the terminal hears them.
	function keydown(e: KeyboardEvent) {
		if (!e.metaKey || !e.shiftKey || e.ctrlKey || e.altKey) return;
		const to: Record<string, () => void> = {
			KeyT: () => (mode = 'term'),
			KeyH: () => (mode = 'homo'),
			KeyC: () => (mode = 'chat'),
			KeyF: () => (full = !full),
		};
		if (!to[e.code]) return;
		e.preventDefault();
		e.stopImmediatePropagation();
		to[e.code]();
	}
</script>

<svelte:window onkeydowncapture={keydown} />

<WindowControls />

<button class="side switch nav-term" class:ink-mark-v={mode === 'term'} onclick={() => (mode = 'term')} title="Terminal (⌘⇧T)">{t('TERM')}</button>
<button class="side switch nav-homo" class:ink-mark-v={mode === 'homo'} onclick={() => (mode = 'homo')} title="People (⌘⇧H)">{t('HOMO')}</button>
<button class="side switch nav-chat" class:ink-mark-v={mode === 'chat'} onclick={() => (mode = 'chat')} title="LLM (⌘⇧C)">{t('CHAT')}</button>
<button class="side switch nav-full" class:ink-mark-v={full} onclick={() => (full = !full)} title="The whole window (⌘⇧F)">{t('FULL')}</button>

<Term active={mode === 'term'} />
<Homo active={mode === 'homo'} />
<Chat active={mode === 'chat'} />

<style>
	.nav-term { left: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.nav-homo { right: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.nav-chat { left: calc(6.25% - 28px); bottom: 6.25%; }
	.nav-full { right: calc(6.25% - 28px); bottom: 6.25%; }
</style>
